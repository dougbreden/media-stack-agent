<#
.SYNOPSIS
    Daily health check and auto-repair for the media stack.

.DESCRIPTION
    Run manually any time something seems wrong, or let the scheduled task
    call it on boot. Steps:
      1. Disk space check       -- warn/fail if M:\ is getting full
      2. Container status       -- restart anything that stopped
      3. VPN connectivity       -- force-recreate Gluetun if VPN is down
      4. qBittorrent health     -- clear lockfile + restart if unhealthy
      5. Download audit         -- dead metaDL, dangerous files (calls maintain-downloads.ps1)
      6. Library standardization-- remux + dedup + Tdarr scan (daily gate)
      7. Firewall rules         -- re-apply if missing (admin only)

    Output goes to console and M:\Media\logs\automation-YYYY-MM.log.
    Does not require Administrator unless firewall repair is needed.

.NOTES
    Replaces: check-stack.ps1
#>

$ErrorActionPreference = "Continue"
$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$ScriptName  = "maintain-stack"
$Fixes       = @()
$Issues      = @()

# -- Logging -------------------------------------------------------------------
$LogDir  = "$StackDir\logs"
$LogFile = "$LogDir\automation-$(Get-Date -Format 'yyyy-MM').log"
$null    = New-Item -ItemType Directory -Force -Path $LogDir

function Write-Log([string]$Msg, [string]$Level = "INFO") {
    $line = "{0} | {1,-5} | {2,-22} | {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $ScriptName, $Msg
    [System.IO.File]::AppendAllText($LogFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
}

function Write-OK   { param($msg) Write-Host "  OK   $msg" -ForegroundColor Green;  Write-Log "OK   $msg" "INFO" }
function Write-Warn { param($msg) Write-Host "  WARN $msg" -ForegroundColor Yellow; Write-Log "WARN $msg" "WARN" }
function Write-Fix  { param($msg)
    Write-Host "  FIX  $msg" -ForegroundColor Cyan
    $script:Fixes += $msg
    Write-Log "FIX  $msg" "INFO"
}
function Write-Fail { param($msg)
    Write-Host "  FAIL $msg" -ForegroundColor Red
    $script:Issues += $msg
    Write-Log "FAIL $msg" "FAIL"
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

Write-Log "===== START =====" "INFO"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Media Stack Health Check" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# -- 1. Disk space check -------------------------------------------------------
Write-Host "`n[1/7] Disk space..." -ForegroundColor Cyan
try {
    $drive   = Get-PSDrive M -ErrorAction Stop
    $freeGB  = [math]::Round($drive.Free / 1GB, 1)
    $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)
    if ($freeGB -lt 200) {
        Write-Fail "M:\ only ${freeGB} GB free of ${totalGB} GB -- downloads and Tdarr cache will fail soon"
    } elseif ($freeGB -lt 500) {
        Write-Warn "M:\ ${freeGB} GB free of ${totalGB} GB -- below 500 GB threshold, plan expansion"
    } else {
        Write-OK "M:\ ${freeGB} GB free of ${totalGB} GB"
    }
} catch {
    Write-Warn "Could not read disk space for M:\: $_"
}

# -- 2. Ensure all containers are running --------------------------------------
Write-Host "`n[2/7] Container status..." -ForegroundColor Cyan
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

# -- 3. VPN check + Gluetun repair --------------------------------------------
Write-Host "`n[3/7] VPN connectivity..." -ForegroundColor Cyan
$vpnCheck = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
if ($vpnCheck -match "You are connected to Mullvad") {
    Write-OK "VPN connected - $vpnCheck"
} else {
    Write-Fix "VPN not connected - running fix-vpn.ps1..."
    & "$StackDir\scripts\fix-vpn.ps1"

    $vpnCheck2 = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
    if ($vpnCheck2 -match "You are connected to Mullvad") {
        Write-OK "VPN connected after repair"
    } else {
        Write-Fail "VPN still not connected - check: docker compose logs gluetun"
    }
}

# -- 4. qBittorrent repair -----------------------------------------------------
Write-Host "`n[4/7] qBittorrent health..." -ForegroundColor Cyan
$qbHealth  = docker inspect --format '{{.State.Health.Status}}' qbittorrent 2>&1
$qbRunning = docker inspect --format '{{.State.Running}}'       qbittorrent 2>&1

if ($qbHealth -eq "healthy") {
    Write-OK "qBittorrent - healthy"
} elseif ($qbRunning -ne "true") {
    Write-Fix "qBittorrent not running - clearing lockfile and starting..."
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

# -- 5. Download audit ---------------------------------------------------------
Write-Host "`n[5/7] Download audit (dead metaDL / dangerous files)..." -ForegroundColor Cyan
try {
    $dlOut = & "$StackDir\scripts\maintain-downloads.ps1" -DryRun:$false -MetaDLDeadHours 2 -StalledDeadHours 24 2>&1
    $dlOut | Where-Object { $_ -notmatch "^\[DRY RUN\]" } | ForEach-Object { Write-Host "  $_" }
    $cleaned  = ($dlOut | Where-Object { $_ -match "Dead metaDL cleaned\s+:" } | Select-Object -Last 1) -replace ".*:\s*", ""
    $dangerous = ($dlOut | Where-Object { $_ -match "Dangerous files\s+:" } | Select-Object -Last 1) -replace ".*:\s*", ""
    Write-Log "Downloads: ${cleaned} dead metaDL cleaned, ${dangerous} dangerous files" "INFO"
} catch {
    Write-Warn "maintain-downloads.ps1 failed: $_"
}

# -- 6. Library standardization (daily gate) -----------------------------------
Write-Host "`n[6/7] Library standardization (daily: remux + dedup + Tdarr scan)..." -ForegroundColor Cyan
$stampFile      = "$StackDir\.standardize-last-run"
$runStandardize = $true
if (Test-Path $stampFile) {
    try {
        $lastRun = [datetime](Get-Content $stampFile -ErrorAction SilentlyContinue)
        if ((Get-Date) - $lastRun -lt [TimeSpan]::FromDays(1)) {
            Write-Host "  Last run: $($lastRun.ToString('yyyy-MM-dd HH:mm')) -- skipping (runs daily)" -ForegroundColor Gray
            Write-Log "Standardize skipped (last run $($lastRun.ToString('yyyy-MM-dd HH:mm')))" "INFO"
            $runStandardize = $false
        }
    } catch { <# malformed stamp -- run anyway #> }
}
if ($runStandardize) {
    try {
        & "$StackDir\scripts\standardize-library.ps1" 2>&1 | ForEach-Object { Write-Host "  $_" }
        (Get-Date).ToString("o") | Set-Content $stampFile
    } catch {
        Write-Warn "standardize-library.ps1 failed: $_"
    }
}

# -- 7. Firewall check (via MediaStack-Firewall scheduled task) ---------------
Write-Host "`n[7/7] Firewall rules..." -ForegroundColor Cyan
$fwTask = Get-ScheduledTask -TaskName "MediaStack-Firewall" -ErrorAction SilentlyContinue
if ($fwTask) {
    Start-ScheduledTask -TaskName "MediaStack-Firewall"
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-ScheduledTask -TaskName "MediaStack-Firewall").State -eq "Running" -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    $fwResult = (Get-ScheduledTaskInfo -TaskName "MediaStack-Firewall").LastTaskResult
    if ($fwResult -eq 0) {
        Write-OK "Firewall rules applied"
        Write-Log "Firewall rules applied via MediaStack-Firewall task" "INFO"
    } else {
        Write-Warn "Firewall task exited with code $fwResult"
        Write-Log "Firewall task exited with code $fwResult" "WARN"
    }
} else {
    Write-Warn "MediaStack-Firewall task not registered -- run setup-scheduled-tasks.ps1 as Administrator once to enable automatic firewall repair"
    Write-Log "Firewall skipped: MediaStack-Firewall task not registered" "WARN"
}

# -- Summary -------------------------------------------------------------------
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

$endStatus = if ($Issues.Count -eq 0) { "OK" } else { "ISSUES: $($Issues -join '; ')" }
Write-Log "===== END ($($Fixes.Count) fixes, $($Issues.Count) issues) -- $endStatus =====" "INFO"
