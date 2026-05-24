# fix-vpn.ps1 — Run this when qBittorrent trackers show "Operation not permitted"
# or "Host not found". Resets Gluetun iptables state and reconnects qBittorrent.
#
# Must be run from M:\Media or pass the -f flag to docker compose.

$ErrorActionPreference = "Continue"
$compose = "M:\Media\docker-compose.yml"

Write-Host "Recreating Gluetun to reset VPN firewall state..."
docker compose -f $compose up -d --force-recreate gluetun
Start-Sleep -Seconds 8

Write-Host "Checking VPN connection..."
$vpn = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
Write-Host $vpn

Write-Host "Cleaning stale qBittorrent lockfile..."
Remove-Item -Path "M:\Media\config\qbittorrent\qBittorrent\lockfile" -ErrorAction SilentlyContinue
Remove-Item -Path "M:\Media\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue

Write-Host "Restarting qBittorrent..."
docker compose -f $compose up -d --force-recreate qbittorrent

Write-Host "Done. Give qBittorrent ~30 seconds to start, then check tracker status."
