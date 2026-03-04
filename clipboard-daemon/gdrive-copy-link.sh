#!/bin/bash
# Copy GDrive link with Google URL
# Called by Automator Service

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

for f in "$@"; do
    # Skip if not in Google Drive
    if [[ "$f" != *"/Library/CloudStorage/GoogleDrive-"* ]]; then
        continue
    fi

    # Create gdrive:// URL with selective encoding
    # Encodes @#?&% and spaces, keeps Cyrillic readable
    RELATIVE_PATH="${f#*/Library/}"
    ENCODED=$(printf '%s' "$RELATIVE_PATH" | python3 -c "
import sys, urllib.parse
text = sys.stdin.read().strip()
result = []
for ch in text:
    if ch == '/':
        result.append(ch)
    elif ord(ch) > 127:
        result.append(ch)  # Cyrillic etc — keep readable
    elif ch.isalnum() or ch in '-_.~':
        result.append(ch)
    else:
        result.append(urllib.parse.quote(ch))
print(''.join(result), end='')
")
    GDRIVE_URL="gdrive://$ENCODED"

    # Get filename
    FILENAME=$(basename "$f")

    # Extract display path (e.g. /SKMS Main/Биздев/research/...)
    if [[ "$f" == *"/Общие диски/"* ]]; then
        DISPLAY_PATH="/${f#*Общие диски/}"
    elif [[ "$f" == *"/My Drive/"* ]]; then
        DISPLAY_PATH="/${f#*My Drive/}"
    else
        DISPLAY_PATH="/$FILENAME"
    fi

    # Get Google Drive file ID via xattr
    FILE_ID=$(xattr -p "com.google.drivefs.item-id#S" "$f" 2>/dev/null)

    # Create wrapped format
    if [[ -n "$FILE_ID" ]]; then
        # Determine if folder or file
        if [[ -d "$f" ]]; then
            GOOGLE_URL="https://drive.google.com/drive/folders/$FILE_ID"
        else
            GOOGLE_URL="https://drive.google.com/file/d/$FILE_ID/view"
        fi

        WRAPPED="**$FILENAME**

$GOOGLE_URL

\`'$DISPLAY_PATH'\`

\`\`\`
$GDRIVE_URL
\`\`\`"
    else
        WRAPPED="**$FILENAME**

\`'$DISPLAY_PATH'\`

\`\`\`
$GDRIVE_URL
\`\`\`"
    fi

    # Copy to clipboard
    printf '%s' "$WRAPPED" | pbcopy

    # Notify (escape to prevent AppleScript injection)
    SAFE_FILENAME="${FILENAME//\\/\\\\}"
    SAFE_FILENAME="${SAFE_FILENAME//\"/\\\"}"
    osascript -e "display notification \"Link copied with Google URL\" with title \"$SAFE_FILENAME\""
done
