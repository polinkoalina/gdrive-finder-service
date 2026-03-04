# gdrive-handler.ps1
# Handles gdrive:// URL scheme clicks safely (avoids PowerShell injection via -Command)
#
# Registered in HKCU by install.ps1 as:
#   powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File gdrive-handler.ps1 "%1"

param(
    [Parameter(Position=0)]
    [string]$Url
)

if ($Url -match '^gdrive://') {
    Set-Clipboard -Value $Url
    Start-Sleep -Milliseconds 100
}
