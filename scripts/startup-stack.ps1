# Wait for Docker Desktop to be ready (up to 2 minutes)
$attempts = 0
while ($attempts -lt 12) {
    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) { break }
    } catch {}
    Start-Sleep -Seconds 10
    $attempts++
}

if ($LASTEXITCODE -ne 0) {
    Write-EventLog -LogName Application -Source "MediaStack" -EventId 1001 -EntryType Error `
        -Message "MediaStack-Startup: Docker was not ready after 120 seconds. Stack not started." `
        -ErrorAction SilentlyContinue
    exit 1
}

# Start everything except gluetun/qbittorrent first
docker compose -f "M:\Media\docker-compose.yml" up -d

# Force-recreate gluetun on every boot so iptables rules are always fresh.
# Without this, resuming from hibernate or a Docker Desktop crash can leave
# Gluetun in a state where it blocks outbound UDP tracker connections.
docker compose -f "M:\Media\docker-compose.yml" up -d --force-recreate gluetun
Start-Sleep -Seconds 8

# Clean up any stale lockfile before starting qBittorrent — left behind if
# qBittorrent was killed mid-write when gluetun was stopped on the last shutdown.
Remove-Item -Path "M:\Media\config\qbittorrent\qBittorrent\lockfile" -ErrorAction SilentlyContinue
Remove-Item -Path "M:\Media\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue

docker compose -f "M:\Media\docker-compose.yml" up -d qbittorrent

# Refresh firewall if running elevated (requires admin; skipped otherwise)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if ($isAdmin) {
    & "M:\Media\scripts\setup-firewall.ps1"
}
