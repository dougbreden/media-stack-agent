<#
.SYNOPSIS
    Backs up M:\Media\config\ to a timestamped zip file.

.DESCRIPTION
    The config\ directory contains all app databases and settings for every container
    (Jellyfin, Radarr, Sonarr, qBittorrent, Prowlarr, Bazarr, Jellyseerr, Homarr, Unpackerr).
    It is gitignored (~1.3 GB) but must be preserved for migration to a new machine.

    Run this before:
      - Moving the stack to a new machine or hard drive
      - Major Docker Desktop or Windows updates
      - Any significant configuration change you might want to roll back

    Backups are saved to M:\Media\backups\ and are safe to copy to external storage or cloud.
    Old backups are NOT deleted automatically — manage disk space manually.

.EXAMPLE
    M:\Media\scripts\backup-config.ps1
#>

$ErrorActionPreference = "Stop"

$sourceDir  = "M:\Media\config"
$backupDir  = "M:\Media\backups"
$timestamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$backupFile = "$backupDir\config-backup-$timestamp.zip"

Write-Host "Media Stack Config Backup" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host "Source:      $sourceDir"
Write-Host "Destination: $backupFile"
Write-Host ""

# Create backup directory if it doesn't exist
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

# Stop containers first so databases are in a consistent state
Write-Host "Stopping containers for consistent database snapshot..." -ForegroundColor Yellow
Set-Location "M:\Media"
docker compose stop
Write-Host ""

# Create the zip using 7-Zip (handles locked/restricted files that Compress-Archive cannot)
# Exit code 1 = warnings (e.g. log files locked by running containers) — acceptable.
# Exit code 2+ = fatal error.
Write-Host "Creating backup zip..." -ForegroundColor Yellow
$7z = "C:\Program Files\7-Zip\7z.exe"
& $7z a -tzip -mx=5 $backupFile "$sourceDir\*" -r -xr!"logs" -xr!"ipc-socket" -xr!"*.log" | Out-Null
if ($LASTEXITCODE -ge 2) { throw "7-Zip exited with code $LASTEXITCODE" }
$sizeMB = [math]::Round((Get-Item $backupFile).Length / 1MB, 1)
Write-Host "  [OK] Backup created: $backupFile ($sizeMB MB)" -ForegroundColor Green
Write-Host ""

# Restart containers
Write-Host "Restarting containers..." -ForegroundColor Yellow
docker compose up -d
Write-Host "  [OK] Stack running" -ForegroundColor Green
Write-Host ""

Write-Host "Done. Copy $backupFile to external storage or cloud for safekeeping." -ForegroundColor Cyan
