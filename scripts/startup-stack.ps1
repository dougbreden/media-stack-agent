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

docker compose -f "M:\Media\docker-compose.yml" up -d

# Refresh firewall after docker compose rebuilds its network bridge
& "M:\Media\scripts\setup-firewall.ps1"
