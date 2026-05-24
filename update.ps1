#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Full maintenance run for the media stack: update images, fix VPN state,
    verify health, refresh Jellyfin metadata, and refresh firewall rules.

.DESCRIPTION
    Run this any time you want to update containers or recover from a broken
    state (stalled trackers, unhealthy containers, stale Jellyfin metadata).

    Gluetun and qBittorrent are excluded from Watchtower and must be updated
    via this script. All other containers are updated by Watchtower nightly.

    Must be run as Administrator (required for firewall step).
    Right-click PowerShell -> Run as Administrator, then: M:\Media\update.ps1
#>

$ErrorActionPreference = "Continue"
$StackDir  = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$Errors    = @()

Set-Location $StackDir

function Write-Step { param($n, $total, $msg)
    Write-Host "`n[$n/$total] $msg" -ForegroundColor Cyan
}
function Write-OK   { param($msg) Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg)
    Write-Host "  FAIL $msg" -ForegroundColor Red
    $script:Errors += $msg
}

function Wait-ContainerHealthy {
    param([string]$Name, [int]$TimeoutSec = 60)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        $status = (docker inspect --format "{{.State.Health.Status}}" $Name 2>$null)
        if ($status -eq "healthy") { return $true }
        # Containers with no healthcheck report "": treat as up if running
        $running = (docker inspect --format "{{.State.Running}}" $Name 2>$null)
        if ($status -eq "" -and $running -eq "true") { return $true }
        Start-Sleep -Seconds 3
        $elapsed += 3
    }
    return $false
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Media Stack Maintenance" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# ── 1. Pull latest images ─────────────────────────────────────────────────────
Write-Step 1 7 "Pulling latest images..."
$pullOut = docker compose -f $ComposeFile pull 2>&1
# Report which images actually changed
$pullOut | Select-String "Pull complete|Downloaded newer" | ForEach-Object { Write-OK $_.Line.Trim() }
$unchanged = ($pullOut | Select-String "Image is up to date").Count
if ($unchanged -gt 0) { Write-Host "  $unchanged images already up to date" -ForegroundColor Gray }

# ── 2. Apply updates to all containers except gluetun/qbittorrent ────────────
Write-Step 2 7 "Applying updates to stack (excluding VPN containers)..."
docker compose -f $ComposeFile up -d 2>&1 | Out-Null
Write-OK "Stack updated"

# ── 3. VPN gateway + torrent client ──────────────────────────────────────────
Write-Step 3 7 "Rebuilding VPN gateway and torrent client..."

# 3a. Clean stale qBittorrent lockfile — left behind when the container is
#     killed while writing. Causes qBittorrent to hang in D state on next start.
Remove-Item "$StackDir\config\qbittorrent\qBittorrent\lockfile"  -ErrorAction SilentlyContinue
Remove-Item "$StackDir\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue
Write-OK "Lockfile cleared"

# 3b. Force-recreate gluetun to reset iptables rules from scratch.
#     A plain restart preserves bad firewall state from hibernate/resume cycles.
docker compose -f $ComposeFile up -d --force-recreate gluetun 2>&1 | Out-Null

Write-Host "  Waiting for Gluetun to become healthy..." -ForegroundColor Gray
if (Wait-ContainerHealthy "gluetun" 60) {
    Write-OK "Gluetun healthy"
} else {
    Write-Fail "Gluetun did not become healthy within 60s — check: docker compose logs gluetun"
}

# 3c. Verify VPN tunnel is actually connected (not just container-healthy)
$vpnCheck = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
if ($vpnCheck -match "You are connected to Mullvad") {
    Write-OK "VPN connected — $vpnCheck"
} else {
    Write-Fail "VPN check failed: $vpnCheck"
}

# 3d. Start qBittorrent against the fresh gluetun network namespace
docker compose -f $ComposeFile up -d qbittorrent 2>&1 | Out-Null

Write-Host "  Waiting for qBittorrent to become healthy..." -ForegroundColor Gray
if (Wait-ContainerHealthy "qbittorrent" 90) {
    Write-OK "qBittorrent healthy"

    # 3e. Spot-check tracker connectivity
    try {
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        Invoke-WebRequest "http://localhost:8080/api/v2/auth/login" `
            -Method Post -Body "username=admin&password=idbeholdg" `
            -ContentType "application/x-www-form-urlencoded" `
            -WebSession $session | Out-Null
        $torrents = Invoke-RestMethod "http://localhost:8080/api/v2/torrents/info" -WebSession $session
        $errored = $torrents | Where-Object { $_.state -eq "error" }
        if ($errored.Count -eq 0) {
            Write-OK "qBittorrent — $($torrents.Count) torrent(s), no errors"
        } else {
            Write-Warn "qBittorrent — $($errored.Count) torrent(s) in error state"
        }
    } catch {
        Write-Warn "Could not reach qBittorrent API: $_"
    }
} else {
    Write-Fail "qBittorrent did not become healthy within 90s — check: docker compose logs qbittorrent"
}

# ── 4. Health check all containers ───────────────────────────────────────────
Write-Step 4 7 "Checking container health..."
$allContainers = docker compose -f $ComposeFile ps --format json 2>$null |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_ -ne $null }

foreach ($c in $allContainers) {
    $name   = $c.Name
    $status = $c.Status
    if ($status -match "healthy" -or $status -match "running") {
        Write-OK "$name — $status"
    } elseif ($status -match "unhealthy") {
        Write-Fail "$name — $status"
    } else {
        Write-Warn "$name — $status"
    }
}

# ── 5. Trigger Jellyfin library refresh ───────────────────────────────────────
# Tdarr converts HEVC files to H.264 in the background. Until Jellyfin rescans,
# it applies the wrong ffmpeg bitstream filter (hevc_mp4toannexb) to converted
# files, breaking HLS streaming. A post-update scan keeps metadata current.
Write-Step 5 7 "Triggering Jellyfin library scan (clears stale codec metadata from Tdarr)..."
try {
    Invoke-RestMethod -Method Post `
        "http://localhost:8096/Library/Refresh?api_key=f21e09ab3bc44eef9d50445aca69bf4e" | Out-Null
    Write-OK "Library scan triggered (runs in background)"
} catch {
    Write-Warn "Could not trigger Jellyfin scan: $_"
}

# ── 6. Prune old images ───────────────────────────────────────────────────────
Write-Step 6 7 "Pruning unused images..."
$pruneOut = docker image prune -f 2>&1
$freed = $pruneOut | Select-String "reclaimed"
if ($freed) { Write-OK $freed.Line.Trim() } else { Write-OK "Nothing to prune" }

# ── 7. Refresh firewall rules ─────────────────────────────────────────────────
# Docker Desktop block rules can reappear after Docker Desktop updates.
# Re-running setup-firewall.ps1 is idempotent.
Write-Step 7 7 "Refreshing firewall rules..."
& "$StackDir\scripts\setup-firewall.ps1"
Write-OK "Firewall rules applied"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
if ($Errors.Count -eq 0) {
    Write-Host "  All steps completed successfully" -ForegroundColor Green
} else {
    Write-Host "  Completed with $($Errors.Count) issue(s):" -ForegroundColor Yellow
    $Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host "==========================================" -ForegroundColor Cyan
