# gdrive-copy-link.ps1
# Copy GDrive link for sharing — Windows version
# Called from Explorer context menu
#
# Usage: powershell -ExecutionPolicy Bypass -File gdrive-copy-link.ps1 "G:\Shared drives\SKMS Main\file.txt"

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$FilePath
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- Helper: Find Google Drive root ---
# Google Drive on Windows can be:
#   1. Virtual drive letter (e.g. G:\)
#   2. Under user profile (e.g. %USERPROFILE%\Google Drive\)
# We detect by checking if the path is on a Google Drive mount

function Find-GDriveInfo {
    param([string]$Path)

    # Normalize path
    $Path = [System.IO.Path]::GetFullPath($Path)

    # Pattern 1: Virtual drive (G:\Shared drives\..., G:\My Drive\...)
    # Google Drive virtual drives have "Shared drives" or "My Drive" at top level
    $driveLetter = $Path.Substring(0, 3)  # e.g. "G:\"

    # Check common Google Drive indicators
    $isGDrive = $false
    $gdriveRoot = ""
    $email = ""

    # Try to detect Google Drive via registry
    $drivefsKey = "HKCU:\Software\Google\DriveFS"
    if (Test-Path $drivefsKey) {
        try {
            $mountPoint = (Get-ItemProperty $drivefsKey -ErrorAction SilentlyContinue).MountPoint
            if ($mountPoint -and $Path.StartsWith($mountPoint, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isGDrive = $true
                $gdriveRoot = $mountPoint
            }
        } catch {}
    }

    # Try to find via known drive letters (scan A-Z for Google Drive markers)
    if (-not $isGDrive) {
        if ((Test-Path "$driveLetter`Shared drives") -or (Test-Path "$driveLetter`My Drive") -or
            (Test-Path "$driveLetter`Общие диски") -or (Test-Path "$driveLetter`Мой диск")) {
            $isGDrive = $true
            $gdriveRoot = $driveLetter
        }
    }

    # Pattern 2: User profile path
    if (-not $isGDrive) {
        $userProfile = $env:USERPROFILE
        $possiblePaths = @(
            "$userProfile\Google Drive",
            "$userProfile\Google Drive Stream"
        )
        foreach ($pp in $possiblePaths) {
            if ($Path.StartsWith($pp, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isGDrive = $true
                $gdriveRoot = $pp
                break
            }
        }
    }

    # Fallback: try to get email from environment or whoami
    if (-not $email) {
        # Check if path contains email hint
        if ($Path -match 'GoogleDrive-([^/\\]+)') {
            $email = $Matches[1] -replace '%40', '@'
        }
    }

    return @{
        IsGDrive  = $isGDrive
        Root      = $gdriveRoot.TrimEnd('\')
        Email     = $email
    }
}

# --- Main ---

$info = Find-GDriveInfo -Path $FilePath

if (-not $info.IsGDrive) {
    Write-Host "ERROR: Not a Google Drive path: $FilePath"
    exit 1
}

$Filename = [System.IO.Path]::GetFileName($FilePath)
$IsFolder = (Test-Path $FilePath -PathType Container)

# --- Build gdrive:// URL ---
# Format: gdrive://CloudStorage/GoogleDrive-user%40domain/Общие диски/SKMS Main/path
# We need to construct a URL that Mac daemon can also resolve

$relativePath = $FilePath.Substring($info.Root.Length).TrimStart('\')

# Determine the gdrive:// path prefix
$emailEncoded = ""
if ($info.Email) {
    $emailEncoded = $info.Email -replace '@', '%40'
}

# Detect shared vs personal drive
$gdriveUrlPath = ""
# Helper: selective URL encoding (encode special chars, keep Cyrillic readable)
function Invoke-SelectiveUrlEncode {
    param([string]$Text)
    return [string](& python3 -c @"
import sys, urllib.parse
text = sys.argv[1]
result = []
for ch in text:
    if ch == '/':
        result.append(ch)
    elif ord(ch) > 127:
        result.append(ch)
    elif ch.isalnum() or ch in '-_.~':
        result.append(ch)
    else:
        result.append(urllib.parse.quote(ch))
print(''.join(result), end='')
"@ $Text)
}

# Folder names depend on OS locale (RU: "Общие диски", EN: "Shared drives")
if ($relativePath -match '^(Shared drives|Общие диски)\\(.*)') {
    $folderName = $Matches[1]
    $innerPath = Invoke-SelectiveUrlEncode ($Matches[2] -replace '\\', '/')
    if ($emailEncoded) {
        $gdriveUrlPath = "gdrive://CloudStorage/GoogleDrive-$emailEncoded/$folderName/$innerPath"
    } else {
        $gdriveUrlPath = "gdrive://$folderName/$innerPath"
    }
} elseif ($relativePath -match '^(My Drive|Мой диск)\\(.*)') {
    $folderName = $Matches[1]
    $innerPath = Invoke-SelectiveUrlEncode ($Matches[2] -replace '\\', '/')
    if ($emailEncoded) {
        $gdriveUrlPath = "gdrive://CloudStorage/GoogleDrive-$emailEncoded/$folderName/$innerPath"
    } else {
        $gdriveUrlPath = "gdrive://$folderName/$innerPath"
    }
} else {
    # Generic fallback
    $innerPath = Invoke-SelectiveUrlEncode ($relativePath -replace '\\', '/')
    if ($emailEncoded) {
        $gdriveUrlPath = "gdrive://CloudStorage/GoogleDrive-$emailEncoded/$innerPath"
    } else {
        $gdriveUrlPath = "gdrive://$innerPath"
    }
}

# --- Extract display path ---
# Folder names depend on OS locale (RU: "Общие диски"/"Мой диск", EN: "Shared drives"/"My Drive")
if ($relativePath -match '^(Shared drives|Общие диски)\\(.*)') {
    $DisplayPath = "/" + ($Matches[2] -replace '\\', '/')
} elseif ($relativePath -match '^(My Drive|Мой диск)\\(.*)') {
    $DisplayPath = "/" + ($Matches[2] -replace '\\', '/')
} else {
    $DisplayPath = "/" + $Filename
}

# --- Try to get Google Drive file ID ---
# On Windows, Google Drive file IDs are not easily accessible from filesystem
# We try fsutil and alternate data streams
$FileId = ""
try {
    # Google Drive for Desktop may store metadata in alternate data streams
    $adsPath = "${FilePath}:com.google.drivefs.item-id"
    if (Test-Path -LiteralPath $adsPath -ErrorAction SilentlyContinue) {
        $FileId = Get-Content -LiteralPath $adsPath -ErrorAction SilentlyContinue
    }
} catch {}

# --- Build clipboard content ---
$lines = @()
$lines += "**$Filename**"
$lines += ""

if ($FileId) {
    if ($IsFolder) {
        $GoogleUrl = "https://drive.google.com/drive/folders/$FileId"
    } else {
        $GoogleUrl = "https://drive.google.com/file/d/$FileId/view"
    }
    $lines += $GoogleUrl
    $lines += ""
}

$lines += "``'$DisplayPath'``"
$lines += ""
$lines += '```'
$lines += $gdriveUrlPath
$lines += '```'

$wrapped = $lines -join "`n"

# --- Copy to clipboard ---
Set-Clipboard -Value $wrapped

# --- Show notification (Windows toast) ---
Add-Type -AssemblyName System.Windows.Forms
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.BalloonTipTitle = $Filename
$notifyIcon.BalloonTipText = "GDrive link copied to clipboard"
$notifyIcon.Visible = $true
$notifyIcon.ShowBalloonTip(3000)
Start-Sleep -Seconds 3
$notifyIcon.Dispose()
