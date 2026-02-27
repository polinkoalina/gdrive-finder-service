# Remote installer for gdrive-finder-service (Windows)
# Usage: irm https://raw.githubusercontent.com/polinkoalina/gdrive-finder-service/feature/utf8-urls-and-windows/windows/remote-install.ps1 | iex

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$installDir = "$env:LOCALAPPDATA\gdrive-finder-service"
$branch = "feature/utf8-urls-and-windows"
$baseUrl = "https://raw.githubusercontent.com/polinkoalina/gdrive-finder-service/$branch/windows"

$files = @(
    "gdrive-copy-link.ps1",
    "gdrive-daemon.ps1",
    "install.ps1",
    "uninstall.ps1"
)

Write-Host "Installing gdrive-finder-service..." -ForegroundColor Cyan

# Create install directory
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Download all files
foreach ($file in $files) {
    Write-Host "  Downloading $file..."
    $url = "$baseUrl/$file"
    $dest = "$installDir\$file"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

Write-Host "  Files downloaded to $installDir" -ForegroundColor Green

# Run the installer
Write-Host "  Running installer..." -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1"

Write-Host ""
Write-Host "Done! Right-click any file in Google Drive to copy a link." -ForegroundColor Green
