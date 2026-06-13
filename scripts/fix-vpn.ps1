<#
.SYNOPSIS
    Reset the Gluetun VPN and restart qBittorrent against the fresh container.

.DESCRIPTION
    Run this when qBittorrent trackers show "Operation not permitted", "Host not found",
    or all speeds are zero. Gluetun's iptables killswitch can drift into a bad state
    after Docker restarts, Windows hibernate/resume, or Watchtower updates.

    Also called automatically by check-stack.ps1 when VPN is detected as broken.

.EXAMPLE
    .\fix-vpn.ps1
#>

$ErrorActionPreference = "Continue"
$ComposeFile = "M:\Media\docker-compose.yml"
$StackDir    = "M:\Media"

Write-Host "Fixing VPN (force-recreating Gluetun)..." -ForegroundColor Cyan

docker compose -f $ComposeFile stop qbittorrent 2>&1 | Out-Null

Remove-Item "$StackDir\config\qbittorrent\qBittorrent\lockfile"   -ErrorAction SilentlyContinue
Remove-Item "$StackDir\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue

docker compose -f $ComposeFile up -d --force-recreate gluetun 2>&1 | Out-Null

# Wait for healthy (up to 60s)
$elapsed = 0
Write-Host "  Waiting for Gluetun to become healthy..." -ForegroundColor Gray
while ($elapsed -lt 60) {
    $health = docker inspect --format '{{.State.Health.Status}}' gluetun 2>&1
    if ($health -eq "healthy") { break }
    Start-Sleep 3
    $elapsed += 3
}

$vpn = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
if ($vpn -match "You are connected to Mullvad") {
    Write-Host "  VPN connected: $vpn" -ForegroundColor Green
} else {
    Write-Host "  WARNING: VPN still not confirmed -- $vpn" -ForegroundColor Yellow
    Write-Host "  Check: docker compose logs gluetun" -ForegroundColor Yellow
}

docker compose -f $ComposeFile up -d qbittorrent 2>&1 | Out-Null
Write-Host "  qBittorrent restarted against fresh Gluetun." -ForegroundColor Green
Write-Host "Done. Allow ~30s for trackers to reconnect." -ForegroundColor Cyan
