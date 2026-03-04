#!/bin/bash
# GDrive Clipboard Daemon v2.0
# Monitors clipboard for gdrive:// links and opens them automatically
#
# Install: ./install.sh
# Uninstall: ./uninstall.sh

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

LOG_FILE="$HOME/.gdrive-daemon.log"
MAX_LOG_LINES=500
LAST_CLIP=""

# Rotate log if too large
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if (( lines > MAX_LOG_LINES )); then
            tail -n $MAX_LOG_LINES "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

notify() {
    local message="$1"
    local title="$2"
    # Escape quotes to prevent AppleScript injection
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    title="${title//\\/\\\\}"
    title="${title//\"/\\\"}"
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"Pop\"" 2>/dev/null
}

# Rotate log on startup
rotate_log
log "Daemon started (v2.0)"

while true; do
    # Get current clipboard content
    CLIP=$(pbpaste 2>/dev/null)

    # Check if it's a gdrive:// link (raw or wrapped)
    # Handle both raw "gdrive://..." and wrapped "**filename**\n...\ngdrive://..." or "# filename\n...\ngdrive://..."

    RAW_URL=""
    IS_WRAPPED=false

    if [[ "$CLIP" == "# "* ]] && [[ "$CLIP" == *"gdrive://"* ]]; then
        # Wrapped format - extract the gdrive:// URL
        IS_WRAPPED=true
        RAW_URL=$(echo "$CLIP" | grep -o 'gdrive://[^`]*' | head -1)
    elif [[ "$CLIP" == gdrive://* ]]; then
        # Raw gdrive:// URL
        RAW_URL="$CLIP"
    fi

    if [[ -n "$RAW_URL" ]] && [[ "$CLIP" != "$LAST_CLIP" ]]; then
        # Decode filename + build local path in one python3 call (tab-separated for bash 3.2)
        IFS=$'\t' read -r FILENAME LOCAL_PATH < <(printf '%s' "$RAW_URL" | python3 -c "
import sys, urllib.parse, os
url = sys.stdin.read()
decoded = urllib.parse.unquote(url)
filename = os.path.basename(decoded)
home = os.path.expanduser('~')
local_path = decoded.replace('gdrive://', f'{home}/Library/')
print(filename + '\t' + local_path, end='')
" 2>/dev/null)
        # Fallback if python3 fails
        if [[ -z "$FILENAME" ]]; then FILENAME=$(basename "$RAW_URL"); fi
        if [[ -z "$LOCAL_PATH" ]]; then LOCAL_PATH=$(echo "$RAW_URL" | sed "s|gdrive://|$HOME/Library/|"); fi

        log "Opening: $FILENAME (wrapped=$IS_WRAPPED)"

        # Locale swap: try alternative folder names if path not found
        if [[ ! -e "$LOCAL_PATH" ]]; then
            for FROM_TO in "Shared drives:Общие диски" "Общие диски:Shared drives" "My Drive:Мой диск" "Мой диск:My Drive"; do
                FROM="${FROM_TO%%:*}"; TO="${FROM_TO#*:}"
                SWAPPED="${LOCAL_PATH/$FROM/$TO}"
                if [[ "$SWAPPED" != "$LOCAL_PATH" ]] && [[ -e "$SWAPPED" ]]; then
                    LOCAL_PATH="$SWAPPED"; break
                fi
            done
        fi

        # Path traversal guard: ensure path stays within Google Drive
        REAL_PATH=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$LOCAL_PATH" 2>/dev/null || echo "$LOCAL_PATH")
        if [[ "$REAL_PATH" != *"/Library/CloudStorage/GoogleDrive-"* ]]; then
            log "SECURITY: Path traversal blocked: $LOCAL_PATH -> $REAL_PATH"
            notify "Security: path outside Google Drive" "GDrive Error"
            LAST_CLIP="$CLIP"; continue
        fi

        # If already wrapped, treat as incoming (just open, don't re-wrap)
        if [[ "$IS_WRAPPED" == true ]]; then
            IS_OUTGOING="incoming"
            log "  Already wrapped, treating as incoming"
        else
            # Check if this is outgoing (from Finder) or incoming (from messenger)
            # If Finder is frontmost AND path exists → outgoing → wrap for sharing
            # Otherwise → incoming → just open, don't modify clipboard

            # Check frontmost app (using AppleScript to avoid sandbox issues)
            FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)

            if [[ "$FRONTMOST" == "Finder" ]] && [[ -e "$LOCAL_PATH" ]]; then
                # Outgoing from Finder - wrap for sharing
                # Note: xattr is blocked by LaunchAgent sandbox, so we skip Google URL
                IS_OUTGOING="outgoing"
                FILE_ID=""  # Can't get due to sandbox, will skip Google URL
                log "  Outgoing from Finder (sandbox blocks xattr, skipping Google URL)"
            else
                IS_OUTGOING="incoming"
                log "  Incoming (frontmost=$FRONTMOST)"
            fi
        fi  # end of IS_WRAPPED check

        # Determine if folder or file for Google URL generation
        if [[ -d "$LOCAL_PATH" ]]; then
            export IS_FOLDER="true"
        else
            export IS_FOLDER="false"
        fi

        if [[ "$IS_OUTGOING" == "outgoing" ]]; then
            # OUTGOING: Create shareable format
            # Pass FILE_ID via environment (may be empty due to sandbox)
            export FILE_ID
            printf '%s' "$RAW_URL" | python3 -c '
import urllib.parse
import subprocess
import os
import sys

url = sys.stdin.read()
decoded = urllib.parse.unquote(url)
filename = os.path.basename(decoded)
file_id = os.environ.get("FILE_ID", "")

# Format: filename + optional Google URL + gdrive:// (for desktop with daemon)
if file_id:
    # Check if folder or file
    is_folder = os.environ.get("IS_FOLDER", "false") == "true"
    if is_folder:
        gdrive_url = f"https://drive.google.com/drive/folders/{file_id}"
    else:
        gdrive_url = f"https://drive.google.com/file/d/{file_id}/view"
    wrapped = f"# {filename}\n📱 {gdrive_url}\n```\n{url}\n```"
else:
    # No file_id available (sandbox limitation) - skip Google URL
    wrapped = f"# {filename}\n```\n{url}\n```"

# Copy to clipboard
p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
p.communicate(wrapped.encode("utf-8"))
'
            log "Outgoing: prepared for sharing"
        else
            # INCOMING: Don't modify clipboard, just open
            log "Incoming: opening file"
        fi

        # Open by local path (avoids URL scheme which mangles UTF-8)
        if [[ -d "$LOCAL_PATH" ]]; then
            # Folder → open in Finder
            open "$LOCAL_PATH" 2>/dev/null
            notify "$FILENAME" "GDrive Link Opened"
        elif [[ -f "$LOCAL_PATH" ]]; then
            # File → reveal in Finder (not open with app)
            open -R "$LOCAL_PATH" 2>/dev/null
            notify "$FILENAME" "GDrive Link Opened"
        else
            log "ERROR: Path not found: $LOCAL_PATH"
            notify "File not found: $FILENAME" "GDrive Error"
        fi

        # Remember to avoid re-opening (store wrapped version too)
        LAST_CLIP="$CLIP"
    fi

    # Check every 0.5 seconds
    sleep 0.5
done
