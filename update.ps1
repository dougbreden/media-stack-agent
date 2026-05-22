#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Updates all media stack containers to latest images and refreshes firewall rules.

.DESCRIPTION
    Run this instead of Watchtower for manual updates, or any time you want to
    force-refresh the VPN container state. Watchtower handles most containers
    automatically at 3 AM, but gluetun and qbittorrent are excluded from Watchtower
    and must be updated manually via this script.

    Must be run as Administrator (required for firewall step).
    Right-click PowerShell → Run as Administrator, then: M:\Media\update.ps1
#>

$ErrorActionPreference = "Stop"
$StackDir = "M:\Media"

Set-Location $StackDir
Write-Host "Media Stack Update" -ForegroundColor Cyan
Write-Host "==================" -ForegroundColor Cyan

# ── 1. Pull latest images ─────────────────────────────────────────────────────
Write-Host "`n[1/5] Pulling latest images..." -ForegroundColor Cyan
docker compose pull

# ── 2. Update all non-VPN containers ─────────────────────────────────────────
# Standard up -d recreates containers that have a newer pulled image.
# Excludes gluetun/qbittorrent — handled separately in step 3.
Write-Host "`n[2/5] Applying updates to stack..." -ForegroundColor Cyan
docker compose up -d

# ── 3. Recreate gluetun + qbittorrent ────────────────────────────────────────
# Gluetun must be force-recreated (not just restarted) to rebuild iptables rules
# from scratch. qBittorrent must always be re-launched after gluetun so it gets
# a fresh reference to the new container's network namespace.
Write-Host "`n[3/5] Recreating VPN gateway and torrent client..." -ForegroundColor Cyan
docker compose up -d --force-recreate gluetun
Start-Sleep -Seconds 5
docker compose up -d qbittorrent

# ── 4. Prune old images ───────────────────────────────────────────────────────
Write-Host "`n[4/5] Pruning old images..." -ForegroundColor Cyan
docker image prune -f

# ── 5. Refresh firewall rules ─────────────────────────────────────────────────
# Docker Desktop's block rules come back after Docker Desktop updates.
# Re-running setup-firewall.ps1 is safe and idempotent.
Write-Host "`n[5/5] Refreshing firewall rules..." -ForegroundColor Cyan
& "$StackDir\scripts\setup-firewall.ps1"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`nDone. Container status:" -ForegroundColor Cyan
docker compose ps
