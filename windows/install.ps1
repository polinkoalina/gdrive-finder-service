# install.ps1
# GDrive Tools Installer — Windows version
# Installs: context menu, clipboard daemon, gdrive:// URL scheme
#
# Usage: Run as current user (no admin required for HKCU)
#   powershell -ExecutionPolicy Bypass -File install.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"

$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "gdrive-finder-service"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$TASK_NAME = "GDriveClipboardDaemon"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "          GDrive Tools Installer (Windows)                      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  1. Context Menu   - Right-click -> Copy GDrive Link           " -ForegroundColor White
Write-Host "  2. URL Scheme     - gdrive:// links open in Explorer          " -ForegroundColor White
Write-Host "  3. Clipboard Daemon - Auto-opens copied gdrive:// links       " -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# Step 1: Create install directory and copy scripts
# =============================================================================
Write-Host "[1/4] Copying scripts..." -ForegroundColor Yellow

if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}

Copy-Item (Join-Path $SCRIPT_DIR "gdrive-copy-link.ps1") $INSTALL_DIR -Force
Copy-Item (Join-Path $SCRIPT_DIR "gdrive-daemon.ps1") $INSTALL_DIR -Force
Copy-Item (Join-Path $SCRIPT_DIR "gdrive-handler.ps1") $INSTALL_DIR -Force
Copy-Item (Join-Path $SCRIPT_DIR "uninstall.ps1") $INSTALL_DIR -Force

Write-Host "  Scripts copied to: $INSTALL_DIR" -ForegroundColor Green

# =============================================================================
# Step 2: Register gdrive:// URL scheme (HKCU — no admin needed)
# =============================================================================
Write-Host "[2/4] Registering gdrive:// URL scheme..." -ForegroundColor Yellow

$urlSchemeKey = "HKCU:\Software\Classes\gdrive"

# Create scheme key
if (-not (Test-Path $urlSchemeKey)) {
    New-Item -Path $urlSchemeKey -Force | Out-Null
}
Set-ItemProperty -Path $urlSchemeKey -Name "(Default)" -Value "GDrive Link Protocol"
Set-ItemProperty -Path $urlSchemeKey -Name "URL Protocol" -Value ""

# shell\open\command
$commandKey = "$urlSchemeKey\shell\open\command"
New-Item -Path $commandKey -Force | Out-Null

# When a gdrive:// URL is clicked, pass it to the handler script (avoids -Command injection)
$handlerScript = Join-Path $INSTALL_DIR "gdrive-handler.ps1"
$commandValue = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$handlerScript`" `"%1`""
Set-ItemProperty -Path $commandKey -Name "(Default)" -Value $commandValue

Write-Host "  URL scheme registered: gdrive://" -ForegroundColor Green

# =============================================================================
# Step 3: Add Explorer context menu "Copy GDrive Link"
# =============================================================================
Write-Host "[3/4] Adding Explorer context menu..." -ForegroundColor Yellow

$copyLinkScript = Join-Path $INSTALL_DIR "gdrive-copy-link.ps1"

# Context menu for files (*)
$fileMenuKey = "HKCU:\Software\Classes\*\shell\CopyGDriveLink"
New-Item -Path $fileMenuKey -Force | Out-Null
Set-ItemProperty -Path $fileMenuKey -Name "(Default)" -Value "Copy GDrive Link"
Set-ItemProperty -Path $fileMenuKey -Name "Icon" -Value "shell32.dll,134"

$fileCommandKey = "$fileMenuKey\command"
New-Item -Path $fileCommandKey -Force | Out-Null
$fileCommand = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$copyLinkScript`" `"%1`""
Set-ItemProperty -Path $fileCommandKey -Name "(Default)" -Value $fileCommand

# Context menu for folders (Directory)
$dirMenuKey = "HKCU:\Software\Classes\Directory\shell\CopyGDriveLink"
New-Item -Path $dirMenuKey -Force | Out-Null
Set-ItemProperty -Path $dirMenuKey -Name "(Default)" -Value "Copy GDrive Link"
Set-ItemProperty -Path $dirMenuKey -Name "Icon" -Value "shell32.dll,134"

$dirCommandKey = "$dirMenuKey\command"
New-Item -Path $dirCommandKey -Force | Out-Null
$dirCommand = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$copyLinkScript`" `"%V`""
Set-ItemProperty -Path $dirCommandKey -Name "(Default)" -Value $dirCommand

# Context menu for directory background (right-click inside a folder)
$bgMenuKey = "HKCU:\Software\Classes\Directory\Background\shell\CopyGDriveLink"
New-Item -Path $bgMenuKey -Force | Out-Null
Set-ItemProperty -Path $bgMenuKey -Name "(Default)" -Value "Copy GDrive Link (this folder)"
Set-ItemProperty -Path $bgMenuKey -Name "Icon" -Value "shell32.dll,134"

$bgCommandKey = "$bgMenuKey\command"
New-Item -Path $bgCommandKey -Force | Out-Null
$bgCommand = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$copyLinkScript`" `"%V`""
Set-ItemProperty -Path $bgCommandKey -Name "(Default)" -Value $bgCommand

Write-Host "  Context menu added for files and folders" -ForegroundColor Green

# =============================================================================
# Step 4: Create scheduled task for clipboard daemon auto-start
# =============================================================================
Write-Host "[4/4] Setting up clipboard daemon..." -ForegroundColor Yellow

# Stop existing task if running
$existingTask = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "  Stopping existing daemon..."
    Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
}

# Stop any running daemon processes
Get-Process powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*gdrive-daemon.ps1*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue

# Create scheduled task to run daemon at logon
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$(Join-Path $INSTALL_DIR 'gdrive-daemon.ps1')`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Days 9999) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TASK_NAME `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Monitors clipboard for gdrive:// links and opens them in Explorer" `
    -Force | Out-Null

# Start daemon now
Start-ScheduledTask -TaskName $TASK_NAME

# Verify daemon is running
Start-Sleep -Seconds 2
$task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($task -and $task.State -eq "Running") {
    Write-Host "  Clipboard daemon installed and running" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Daemon may not have started. Check Task Scheduler." -ForegroundColor Yellow
    Write-Host "  Try: Start-ScheduledTask -TaskName $TASK_NAME" -ForegroundColor Yellow
}

# =============================================================================
# Done
# =============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "              Installation Complete!                             " -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  How to use:" -ForegroundColor White
Write-Host ""
Write-Host "  Clipboard method (automatic):" -ForegroundColor Yellow
Write-Host "    Copy a gdrive:// link -> file opens automatically in Explorer" -ForegroundColor White
Write-Host ""
Write-Host "  Explorer method:" -ForegroundColor Yellow
Write-Host "    Right-click file/folder -> Copy GDrive Link" -ForegroundColor White
Write-Host ""
Write-Host "  Commands:" -ForegroundColor Yellow
Write-Host "    Stop daemon:   Stop-ScheduledTask -TaskName $TASK_NAME" -ForegroundColor DarkGray
Write-Host "    Start daemon:  Start-ScheduledTask -TaskName $TASK_NAME" -ForegroundColor DarkGray
Write-Host "    View logs:     Get-Content ~\.gdrive-daemon.log -Tail 20" -ForegroundColor DarkGray
Write-Host "    Uninstall:     .\uninstall.ps1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Install dir: $INSTALL_DIR" -ForegroundColor DarkGray
Write-Host ""
