<#
.SYNOPSIS
    Lightweight autonomous health probe for the media stack.

.DESCRIPTION
    Runs 6 read-only checks (containers, VPN, qBittorrent, disk, firewall, queue),
    writes M:\Media\logs\health.json, deduplicates alerts via alert-state.json,
    and sends ntfy push notifications when a check degrades or recovers.

    Does NOT auto-repair anything -- observation and alerting only.
    Repair is handled by heal-invoke.ps1 (Phase 2).

    Checks performed:
      1. Containers   -- docker compose ps, all must be "Up"
      2. VPN          -- am.i.mullvad.net/connected via gluetun
      3. qBittorrent  -- docker inspect health status
      4. Disk         -- M:\ free space, warn if < 200 GB
      5. Firewall     -- count "Media Stack -*" firewall rules (expect >= 10)
      6. Queue        -- Sonarr/Radarr items in warning state >4h (>2 = degraded)

    Output:
      M:\Media\logs\health.json       -- latest check results (no BOM)
      M:\Media\logs\alert-state.json  -- dedup state across runs (no BOM)
      M:\Media\logs\automation-YYYY-MM.log -- shared log (same as maintain-stack.ps1)

    Exit code: 0 = all healthy, 1 = any check degraded.

.NOTES
    Part of the agentic substrate (Phase 1). Intended to run every 5–15 minutes
    via a scheduled task registered by setup-scheduled-tasks.ps1.
#>

$ErrorActionPreference = "Continue"
$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$ScriptName  = "health-probe"

# -- Logging (same pattern as maintain-stack.ps1) ------------------------------
$LogDir  = "$StackDir\logs"
$LogFile = "$LogDir\automation-$(Get-Date -Format 'yyyy-MM').log"
$null    = New-Item -ItemType Directory -Force -Path $LogDir

function Write-Log([string]$Msg, [string]$Level = "INFO") {
    $line = "{0} | {1,-5} | {2,-22} | {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $ScriptName, $Msg
    [System.IO.File]::AppendAllText($LogFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
}

function Write-OK   { param($msg) Write-Host "  OK   $msg" -ForegroundColor Green;  Write-Log "OK   $msg" "INFO" }
function Write-Warn { param($msg) Write-Host "  WARN $msg" -ForegroundColor Yellow; Write-Log "WARN $msg" "WARN" }
function Write-Fail { param($msg) Write-Host "  FAIL $msg" -ForegroundColor Red;    Write-Log "FAIL $msg" "FAIL" }
function Write-Info { param($msg) Write-Host "  INFO $msg" -ForegroundColor Gray;   Write-Log "INFO $msg" "INFO" }

# -- Config (optional -- ntfy only) --------------------------------------------
$NtfyTopic = $null
$configPath = "$PSScriptRoot\config.ps1"
if (Test-Path $configPath) {
    try {
        . $configPath
    } catch {
        Write-Warn "config.ps1 load error (ntfy disabled): $_"
    }
} else {
    Write-Info "config.ps1 not found -- ntfy alerts disabled"
}

# -- ntfy alert function -------------------------------------------------------
function Send-NtfyAlert([string]$Service, [string]$Body, [string]$Priority = "default") {
    if (-not $NtfyTopic) { return }
    try {
        $headers = @{
            Title    = "Media Stack: $Service"
            Tags     = "warning"
            Priority = $Priority
        }
        $null = Invoke-RestMethod -Method Post `
            -Uri "https://ntfy.sh/$NtfyTopic" `
            -Headers $headers `
            -Body $Body `
            -ContentType "text/plain" `
            -TimeoutSec 10
        Write-Log "ntfy sent: [$Service] $Body" "INFO"
    } catch {
        Write-Log "ntfy send failed (non-fatal): $_" "WARN"
    }
}

# -- JSON helpers (no BOM) -----------------------------------------------------
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-JsonFile([string]$Path, [object]$Object) {
    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return @{} }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
        return $raw | ConvertFrom-Json
    } catch {
        Write-Log "Could not parse $Path (treating as empty): $_" "WARN"
        return @{}
    }
}

# -- Alert state helpers -------------------------------------------------------
$AlertStatePath = "$LogDir\alert-state.json"

function Get-AlertState {
    $raw = Read-JsonFile $AlertStatePath
    # ConvertFrom-Json returns a PSCustomObject; convert to hashtable for easy mutation
    $ht = @{}
    if ($raw -and $raw.PSObject.Properties) {
        foreach ($prop in $raw.PSObject.Properties) {
            $entry = $prop.Value
            $ht[$prop.Name] = @{
                status              = if ($null -ne $entry.status -and $entry.status -ne '') { $entry.status } else { "ok" }
                lastAlertTime       = if ($entry.lastAlertTime)       { $entry.lastAlertTime }       else { $null }
                lastHealAttempt     = if ($entry.lastHealAttempt)     { $entry.lastHealAttempt }     else { $null }
                consecutiveFailures = if ($null -ne $entry.consecutiveFailures) { [int]$entry.consecutiveFailures } else { 0 }
            }
        }
    }
    return $ht
}

function Save-AlertState([hashtable]$State) {
    Write-JsonFile $AlertStatePath $State
}

# Returns $true if we should suppress the alert (sent recently and already failing)
function Should-SuppressAlert([hashtable]$State, [string]$CheckName) {
    if (-not $State.ContainsKey($CheckName)) { return $false }
    $entry = $State[$CheckName]
    if ($entry.consecutiveFailures -le 0) { return $false }
    if (-not $entry.lastAlertTime)        { return $false }
    try {
        $lastAlert = [datetime]$entry.lastAlertTime
        $age = (Get-Date) - $lastAlert
        return $age.TotalHours -lt 2
    } catch {
        return $false
    }
}

# ============================================================================
Write-Log "===== START =====" "INFO"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Media Stack Health Probe" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$alertState = Get-AlertState
$checks     = @{}

# -- Check 1: Containers -------------------------------------------------------
Write-Host "`n[1/6] Container status..." -ForegroundColor Cyan
try {
    $psRaw = docker compose -f $ComposeFile ps --format json 2>&1
    $containers = $psRaw | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null }

    $downNames = @()
    foreach ($c in $containers) {
        $name   = $c.Name
        $status = $c.Status
        if ($status -match "Up" -and $status -notmatch "unhealthy") {
            Write-OK "$name -- $status"
        } else {
            Write-Warn "$name -- DOWN/UNHEALTHY ($status)"
            $downNames += $name
        }
    }

    $total = $containers.Count
    if ($downNames.Count -eq 0) {
        $checks["containers"] = @{ status = "ok"; total = $total; down = @() }
        Write-Log "Containers: $total/$total up" "INFO"
    } else {
        $checks["containers"] = @{ status = "degraded"; total = $total; down = $downNames }
        Write-Fail "Containers: $($downNames.Count) down of $total -- $($downNames -join ', ')"
    }
} catch {
    $checks["containers"] = @{ status = "degraded"; total = 0; down = @("check-error"); error = "$_" }
    Write-Fail "Container check error: $_"
}

# -- Check 2: VPN --------------------------------------------------------------
Write-Host "`n[2/6] VPN connectivity..." -ForegroundColor Cyan
try {
    $vpnRaw  = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
    # docker exec 2>&1 returns an array; -match on array filters elements but never populates $Matches.
    # Join to a single scalar string so -match can set $Matches[1] for IP extraction.
    $vpnText = ($vpnRaw | Where-Object { $_ -is [string] }) -join " "
    if ($vpnText -match "You are connected to Mullvad") {
        # Extract IP -- response is plain text like "You are connected to Mullvad. Your IP address is 185.195.233.194"
        $ip = ""
        if ($vpnText -match "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})") {
            $ip = $Matches[1]
        }
        $checks["vpn"] = @{ status = "ok"; ip = $ip }
        Write-OK "VPN connected -- IP: $ip"
    } else {
        $checks["vpn"] = @{ status = "degraded"; ip = "" }
        Write-Fail "VPN not connected -- response: $($vpnText -replace '\r?\n', ' ')"
    }
} catch {
    $checks["vpn"] = @{ status = "degraded"; ip = ""; error = "$_" }
    Write-Fail "VPN check error: $_"
}

# -- Check 3: qBittorrent ------------------------------------------------------
Write-Host "`n[3/6] qBittorrent health..." -ForegroundColor Cyan
try {
    $qbHealth = docker inspect --format '{{.State.Health.Status}}' qbittorrent 2>&1
    if ($qbHealth -eq "healthy") {
        $checks["qbittorrent"] = @{ status = "ok" }
        Write-OK "qBittorrent -- healthy"
    } else {
        $checks["qbittorrent"] = @{ status = "degraded"; healthStatus = "$qbHealth" }
        Write-Fail "qBittorrent -- $qbHealth"
    }
} catch {
    $checks["qbittorrent"] = @{ status = "degraded"; error = "$_" }
    Write-Fail "qBittorrent check error: $_"
}

# -- Check 4: Disk space -------------------------------------------------------
Write-Host "`n[4/6] Disk space..." -ForegroundColor Cyan
try {
    $drive   = Get-PSDrive M -ErrorAction Stop
    $freeGB  = [math]::Round($drive.Free / 1GB, 1)
    $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)

    if ($freeGB -lt 200) {
        $checks["disk"] = @{ status = "degraded"; freeGB = $freeGB; totalGB = $totalGB }
        Write-Fail "Disk: only ${freeGB} GB free of ${totalGB} GB -- below 200 GB critical threshold"
    } else {
        $checks["disk"] = @{ status = "ok"; freeGB = $freeGB; totalGB = $totalGB }
        if ($freeGB -lt 500) {
            Write-Warn "Disk: ${freeGB} GB free of ${totalGB} GB (below 500 GB advisory)"
        } else {
            Write-OK "Disk: ${freeGB} GB free of ${totalGB} GB"
        }
    }
} catch {
    $checks["disk"] = @{ status = "degraded"; error = "$_" }
    Write-Fail "Disk check error: $_"
}

# -- Check 5: Firewall ---------------------------------------------------------
# Observation-only: count "Media Stack -*" rules. setup-firewall.ps1 creates 10 port rules
# plus up to 2 relay rules; if < 10 exist the rules were never applied or got wiped.
# Repair is handled by maintain-stack.ps1 (triggers MediaStack-Firewall task) -- NOT here.
Write-Host "`n[5/6] Firewall rules..." -ForegroundColor Cyan
try {
    # Get-NetFirewallRule requires elevation on this host; use netsh which runs without it.
    $netshLines = netsh advfirewall firewall show rule name=all 2>&1
    $ruleCount  = @($netshLines | Where-Object { $_ -match "^Rule Name:\s+Media Stack " }).Count
    if ($ruleCount -ge 10) {
        $checks["firewall"] = @{ status = "ok"; ruleCount = $ruleCount }
        Write-OK "Firewall: $ruleCount Media Stack rules present"
    } else {
        $checks["firewall"] = @{ status = "degraded"; ruleCount = $ruleCount }
        Write-Fail "Firewall: only $ruleCount Media Stack rules found (expected >= 10) -- run setup-scheduled-tasks.ps1 + Start-ScheduledTask MediaStack-Firewall"
    }
} catch {
    $checks["firewall"] = @{ status = "degraded"; error = "$_" }
    Write-Fail "Firewall check error: $_"
}

# -- Check 6: Sonarr/Radarr download queue rot ---------------------------------
# Detects downloads stuck in warning state >4h -- sign of dead torrents needing rescue-downloads.ps1
Write-Host "`n[6/6] Sonarr/Radarr queue health..." -ForegroundColor Cyan
try {
    if (-not $sonarrKey -and -not $radarrKey) {
        $checks["sonarr-queue"] = @{ status = "ok"; stalledCount = 0; note = "config.ps1 not loaded" }
        Write-Info "Queue check: skipped (API keys not available)"
    } else {
        $qNow     = Get-Date
        $stalled  = @()

        if ($sonarrKey) {
            try {
                $sq = Invoke-RestMethod "http://localhost:8989/api/v3/queue?apikey=$sonarrKey&page=1&pageSize=500&includeUnknownSeriesItems=true" -TimeoutSec 15
                $stalled += @($sq.records | Where-Object {
                    $_.trackedDownloadStatus -eq "warning" -and
                    $_.status -ne "completed" -and $_.status -ne "delay" -and
                    $_.added -and ($qNow - [datetime]$_.added).TotalHours -gt 4
                })
            } catch { Write-Log "Sonarr queue API error (non-fatal): $_" "WARN" }
        }

        if ($radarrKey) {
            try {
                $rq = Invoke-RestMethod "http://localhost:7878/api/v3/queue?apikey=$radarrKey&page=1&pageSize=500&includeUnknownMovieItems=true" -TimeoutSec 15
                $stalled += @($rq.records | Where-Object {
                    $_.trackedDownloadStatus -eq "warning" -and
                    $_.status -ne "completed" -and $_.status -ne "delay" -and
                    $_.added -and ($qNow - [datetime]$_.added).TotalHours -gt 4
                })
            } catch { Write-Log "Radarr queue API error (non-fatal): $_" "WARN" }
        }

        $stalledCount = $stalled.Count
        if ($stalledCount -le 2) {
            # 0-2 stalled is tolerable -- transient tracker issues or new grabs
            $checks["sonarr-queue"] = @{ status = "ok"; stalledCount = $stalledCount }
            if ($stalledCount -eq 0) {
                Write-OK "Download queue: no warning-state items"
            } else {
                Write-Warn "Download queue: $stalledCount item(s) in warning state (threshold: >2)"
            }
        } else {
            $checks["sonarr-queue"] = @{ status = "degraded"; stalledCount = $stalledCount }
            Write-Fail "Download queue: $stalledCount items in warning state >4h -- run rescue-downloads.ps1"
            Write-Log "Queue rot: $stalledCount stalled items" "WARN"
        }
    }
} catch {
    $checks["sonarr-queue"] = @{ status = "degraded"; error = "$_" }
    Write-Fail "Queue check error: $_"
}

# -- Compute overall status ----------------------------------------------------
$anyDegraded  = ($checks.Values | Where-Object { $_.status -eq "degraded" }).Count -gt 0
$overallStatus = if ($anyDegraded) { "degraded" } else { "healthy" }
$timestamp     = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

# -- Write health.json ---------------------------------------------------------
$healthDoc = [ordered]@{
    timestamp = $timestamp
    status    = $overallStatus
    checks    = [ordered]@{
        containers    = $checks["containers"]
        vpn           = $checks["vpn"]
        qbittorrent   = $checks["qbittorrent"]
        disk          = $checks["disk"]
        firewall      = $checks["firewall"]
        "sonarr-queue" = $checks["sonarr-queue"]
    }
}
try {
    Write-JsonFile "$LogDir\health.json" $healthDoc
    Write-Log "health.json written -- overall: $overallStatus" "INFO"
} catch {
    Write-Log "Failed to write health.json: $_" "WARN"
}

# -- Alert dedup + ntfy notifications ------------------------------------------
Write-Host "`n[Alerts]" -ForegroundColor Cyan

foreach ($checkName in $checks.Keys) {
    $result       = $checks[$checkName]
    $currentStatus = $result.status
    $prevEntry    = if ($alertState.ContainsKey($checkName)) { $alertState[$checkName] } else { $null }
    $prevStatus   = if ($prevEntry) { $prevEntry.status } else { "ok" }
    $prevFailures = if ($prevEntry -and $null -ne $prevEntry.consecutiveFailures) { [int]$prevEntry.consecutiveFailures } else { 0 }

    if ($currentStatus -eq "ok") {
        if ($prevStatus -eq "degraded" -and $prevFailures -gt 0) {
            # Recovered -- send low-priority resolution alert
            Write-Info "Sending recovery ntfy for $checkName"
            Send-NtfyAlert -Service $checkName -Body "RESOLVED: $checkName is healthy again." -Priority "low"
        }
        # Reset alert state
        $alertState[$checkName] = @{
            status              = "ok"
            lastAlertTime       = $null
            lastHealAttempt     = $null
            consecutiveFailures = 0
        }
    } else {
        # Degraded -- check dedup window
        $newFailures = $prevFailures + 1

        if (Should-SuppressAlert -State $alertState -CheckName $checkName) {
            $lastAlert = $alertState[$checkName].lastAlertTime
            Write-Info "Alert suppressed for $checkName (alerted at $lastAlert, within 2h dedup window; failure #$newFailures)"
            # Still increment failure count so we track drift
            $alertState[$checkName].consecutiveFailures = $newFailures
        } else {
            # Build a human-readable message per check
            $alertBody = switch ($checkName) {
                "containers"  {
                    $downList = if ($result.down) { $result.down -join ", " } else { "unknown" }
                    "Containers DOWN: $downList ($($result.total) total)"
                }
                "vpn"         { "VPN not connected to Mullvad. Check: docker compose logs gluetun" }
                "qbittorrent" { "qBittorrent unhealthy (status: $($result.healthStatus)). May need lockfile clear." }
                "disk"        { "Low disk space: $($result.freeGB) GB free of $($result.totalGB) GB on M:\" }
                "firewall"    { "Firewall task failed (exit code: $($result.taskResult)). Docker rules may be missing." }
                "sonarr-queue" { "$($result.stalledCount) downloads in warning state >4h. Run: rescue-downloads.ps1 -Rescue" }
                default       { "$checkName is degraded" }
            }

            Write-Warn "Sending ntfy alert for $checkName (failure #$newFailures)"
            Send-NtfyAlert -Service $checkName -Body $alertBody -Priority "default"

            $alertState[$checkName] = @{
                status              = "degraded"
                lastAlertTime       = $timestamp
                lastHealAttempt     = if ($prevEntry) { $prevEntry.lastHealAttempt } else { $null }
                consecutiveFailures = $newFailures
            }
        }
    }
}

# -- Save updated alert state --------------------------------------------------
try {
    Save-AlertState $alertState
    Write-Log "alert-state.json updated" "INFO"
} catch {
    Write-Log "Failed to write alert-state.json: $_" "WARN"
}

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
if (-not $anyDegraded) {
    Write-Host "  All checks healthy" -ForegroundColor Green
} else {
    $degradedNames = ($checks.GetEnumerator() | Where-Object { $_.Value.status -eq "degraded" } | ForEach-Object { $_.Key }) -join ", "
    Write-Host "  DEGRADED: $degradedNames" -ForegroundColor Red
}
Write-Host "==========================================" -ForegroundColor Cyan

Write-Log "===== END (overall: $overallStatus) =====" "INFO"

if ($anyDegraded) { exit 1 } else { exit 0 }
