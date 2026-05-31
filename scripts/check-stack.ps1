<#
.SYNOPSIS
    Quick health check and auto-repair for the media stack.

.DESCRIPTION
    Faster than update.ps1 - no image pulling or updates.
    Detects and fixes common failure patterns:
      - Containers that have stopped -> docker compose up -d
      - Gluetun VPN not connected    -> force-recreate gluetun
      - qBittorrent unhealthy        -> clear lockfile + restart
      - Firewall rules missing       -> re-apply (requires admin)

    Run this whenever something seems wrong with the stack.
    Does not require Administrator unless firewall repair is needed.
#>

$ErrorActionPreference = "Continue"
$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$Fixes       = @()
$Issues      = @()

function Write-OK   { param($msg) Write-Host "  OK   $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Write-Fix  { param($msg)
    Write-Host "  FIX  $msg" -ForegroundColor Cyan
    $script:Fixes += $msg
}
function Write-Fail { param($msg)
    Write-Host "  FAIL $msg" -ForegroundColor Red
    $script:Issues += $msg
}

function Wait-ContainerHealthy {
    param([string]$Name, [int]$TimeoutSec = 60)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        $health  = docker inspect --format '{{.State.Health.Status}}' $Name 2>&1
        $running = docker inspect --format '{{.State.Running}}'       $Name 2>&1
        if ($health -eq "healthy") { return $true }
        if (($health -eq "") -and ($running -eq "true")) { return $true }
        Start-Sleep -Seconds 3
        $elapsed += 3
    }
    return $false
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Media Stack Health Check" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# -- 1. Ensure all containers are running -------------------------------------
Write-Host "`n[1/4] Container status..." -ForegroundColor Cyan
$psRaw = docker compose -f $ComposeFile ps --format json 2>&1
$containers = $psRaw | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { $null }
} | Where-Object { $_ -ne $null }

$anyDown = $false
foreach ($c in $containers) {
    $name   = $c.Name
    $status = $c.Status
    if ($status -match "healthy") {
        Write-OK "$name - $status"
    } elseif ($status -match "unhealthy") {
        Write-Warn "$name - $status (will repair below)"
    } elseif ($status -match "Up") {
        Write-OK "$name - $status"
    } else {
        Write-Warn "$name - DOWN ($status)"
        $anyDown = $true
    }
}

if ($anyDown) {
    Write-Fix "Starting stopped containers..."
    docker compose -f $ComposeFile up -d 2>&1 | Out-Null
}

# -- 2. VPN check + gluetun repair --------------------------------------------
Write-Host "`n[2/4] VPN connectivity..." -ForegroundColor Cyan
$vpnCheck = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
if ($vpnCheck -match "You are connected to Mullvad") {
    Write-OK "VPN connected - $vpnCheck"
} else {
    Write-Fix "VPN not connected ($vpnCheck) - force-recreating gluetun..."

    docker compose -f $ComposeFile stop qbittorrent 2>&1 | Out-Null

    Remove-Item "$StackDir\config\qbittorrent\qBittorrent\lockfile"   -ErrorAction SilentlyContinue
    Remove-Item "$StackDir\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue

    docker compose -f $ComposeFile up -d --force-recreate gluetun 2>&1 | Out-Null

    Write-Host "    Waiting for Gluetun..." -ForegroundColor Gray
    if (Wait-ContainerHealthy "gluetun" 60) {
        $vpnCheck2 = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
        if ($vpnCheck2 -match "You are connected to Mullvad") {
            Write-OK "VPN connected after repair"
        } else {
            Write-Fail "VPN still not connected after gluetun recreate - check: docker compose logs gluetun"
        }
    } else {
        Write-Fail "Gluetun did not become healthy - check: docker compose logs gluetun"
    }

    Write-Fix "Restarting qBittorrent against fresh gluetun..."
    docker compose -f $ComposeFile up -d qbittorrent 2>&1 | Out-Null
}

# -- 3. qBittorrent repair ----------------------------------------------------
Write-Host "`n[3/4] qBittorrent health..." -ForegroundColor Cyan
$qbHealth = docker inspect --format '{{.State.Health.Status}}' qbittorrent 2>&1
$qbRunning = docker inspect --format '{{.State.Running}}' qbittorrent 2>&1

if ($qbHealth -eq "healthy") {
    Write-OK "qBittorrent - healthy"
} elseif ($qbRunning -ne "true") {
    Write-Fix "qBittorrent is not running - clearing lockfile and starting..."
    Remove-Item "$StackDir\config\qbittorrent\qBittorrent\lockfile"   -ErrorAction SilentlyContinue
    Remove-Item "$StackDir\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue
    docker compose -f $ComposeFile up -d qbittorrent 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    if (Wait-ContainerHealthy "qbittorrent" 60) {
        Write-OK "qBittorrent - healthy after repair"
    } else {
        Write-Fail "qBittorrent still unhealthy - check: docker compose logs qbittorrent"
    }
} else {
    # Running but unhealthy - web UI not responding; clear lockfile and restart
    Write-Fix "qBittorrent running but unhealthy - clearing lockfile and restarting..."
    docker compose -f $ComposeFile stop qbittorrent 2>&1 | Out-Null
    Remove-Item "$StackDir\config\qbittorrent\qBittorrent\lockfile"   -ErrorAction SilentlyContinue
    Remove-Item "$StackDir\config\qbittorrent\qBittorrent\ipc-socket" -ErrorAction SilentlyContinue
    docker compose -f $ComposeFile up -d qbittorrent 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    if (Wait-ContainerHealthy "qbittorrent" 60) {
        Write-OK "qBittorrent - healthy after repair"
    } else {
        Write-Fail "qBittorrent still unhealthy - check: docker compose logs qbittorrent"
    }
}

# -- 4. Download health check -------------------------------------------------
Write-Host "`n[4/5] Download health (dead metaDL / dangerous files)..." -ForegroundColor Cyan
try {
    & "$StackDir\scripts\check-downloads.ps1" -DryRun:$false -MetaDLDeadHours 2 -StalledDeadHours 24 2>&1 |
        Where-Object { $_ -notmatch "^\[DRY RUN\]" } |
        ForEach-Object { Write-Host "  $_" }
} catch {
    Write-Warn "check-downloads.ps1 failed: $_"
}

# -- 5. Library standardization (weekly) --------------------------------------
Write-Host "`n[5/6] Library standardization (weekly: remux + dedup + Tdarr scan)..." -ForegroundColor Cyan
$stampFile = "$StackDir\.standardize-last-run"
$runStandardize = $true
if (Test-Path $stampFile) {
    $lastRun = [datetime](Get-Content $stampFile -ErrorAction SilentlyContinue)
    if ((Get-Date) - $lastRun -lt [TimeSpan]::FromDays(7)) {
        Write-Host "  Last run: $($lastRun.ToString('yyyy-MM-dd HH:mm')) -- skipping (runs weekly)" -ForegroundColor Gray
        $runStandardize = $false
    }
}
if ($runStandardize) {
    try {
        & "$StackDir\scripts\standardize-library.ps1" 2>&1 | ForEach-Object { Write-Host "  $_" }
        (Get-Date).ToString("o") | Set-Content $stampFile
    } catch {
        Write-Warn "standardize-library.ps1 failed: $_"
    }
}

# -- 6. Firewall check (admin only) -------------------------------------------
Write-Host "`n[6/6] Firewall rules..." -ForegroundColor Cyan
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)

if ($isAdmin) {
    $mediaRules = (Get-NetFirewallRule -DisplayName "Media Stack -*" -ErrorAction SilentlyContinue).Count
    if ($mediaRules -ge 10) {
        Write-OK "$mediaRules Media Stack firewall rules present"
    } else {
        Write-Fix "Only $mediaRules firewall rules found (expected 10+) - re-applying..."
        & "$StackDir\scripts\setup-firewall.ps1"
    }
} else {
    Write-Warn "Not running as Administrator - skipping firewall check (run elevated to include this)"
}

# -- Summary ------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
if ($Issues.Count -eq 0 -and $Fixes.Count -eq 0) {
    Write-Host "  Stack is healthy - nothing to repair" -ForegroundColor Green
} elseif ($Issues.Count -eq 0) {
    Write-Host "  Repaired $($Fixes.Count) issue(s) - stack is now healthy" -ForegroundColor Green
    $Fixes | ForEach-Object { Write-Host "  + $_" -ForegroundColor Cyan }
} else {
    Write-Host "  $($Fixes.Count) repair(s) attempted, $($Issues.Count) unresolved:" -ForegroundColor Yellow
    $Fixes  | ForEach-Object { Write-Host "  + $_" -ForegroundColor Cyan }
    $Issues | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Red }
}
Write-Host "==========================================" -ForegroundColor Cyan
