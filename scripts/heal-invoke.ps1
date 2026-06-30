<#
.SYNOPSIS
    Phase 2 autonomous repair: invokes Claude Code headlessly to fix a failed service.

.DESCRIPTION
    Called by health-probe.ps1 (or a scheduled task) when a service is degraded.
    Steps:
      1. Circuit breaker  -- skip if this service was already healed < 2 hours ago
      2. Build context    -- read health.json + last 60 lines of automation log
      3. Invoke Claude    -- headless, 5-minute timeout, allowedTools whitelist
      4. Re-check service -- minimal verification that the specific check passed
      5. Write heal log   -- logs/heal-YYYY-MM.log (UTF-8 no BOM)
      6. Update alert-state.json -- lastHealAttempt, consecutiveFailures on success
      7. Send ntfy        -- success (low) / escalation (high) / still-degraded (default)

    Exit codes:
      0 = healed successfully or skipped (circuit breaker)
      1 = attempted but service still degraded
      2 = escalation required (Claude output contains "ESCALATE:")

.PARAMETER Service
    Which check failed. Must match a key from health-probe.ps1:
    containers, vpn, qbittorrent, disk, firewall.

.PARAMETER Description
    Optional human-readable context forwarded into the Claude prompt.

.NOTES
    Part of the agentic substrate (Phase 2).
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("containers","vpn","qbittorrent","disk","firewall","sonarr-queue")]
    [string]$Service,

    [string]$Description = ""
)

$ErrorActionPreference = "Continue"
$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$ScriptName  = "heal-invoke"

# -- Logging (same pattern as maintain-stack.ps1 / health-probe.ps1) -------------
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

# -- Config (ntfy + Anthropic key) -----------------------------------------------
$NtfyTopic   = $null
$AnthropicKey = $null
$configPath  = "$PSScriptRoot\config.ps1"
if (Test-Path $configPath) {
    try {
        . $configPath
    } catch {
        Write-Warn "config.ps1 load error: $_"
    }
} else {
    Write-Info "config.ps1 not found -- ntfy and Claude invocation disabled"
}

# -- ntfy alert function (identical to health-probe.ps1) -------------------------
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

# -- JSON helpers (no BOM, same as health-probe.ps1) -----------------------------
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

# -- Alert state helpers (same as health-probe.ps1) ------------------------------
$AlertStatePath = "$LogDir\alert-state.json"

function Get-AlertState {
    $raw = Read-JsonFile $AlertStatePath
    $ht  = @{}
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

# ============================================================================
$timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

Write-Log "===== START heal-invoke [$Service] =====" "INFO"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Media Stack Heal Invoke" -ForegroundColor Cyan
Write-Host "  Service : $Service" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# -- Guard: AnthropicKey required ------------------------------------------------
if (-not $AnthropicKey) {
    Write-Warn "AnthropicKey not set in config.ps1 -- cannot invoke Claude. Skipping heal."
    Write-Log "Skipped: AnthropicKey not configured" "WARN"
    exit 0
}

# -- 1. Circuit breaker ----------------------------------------------------------
Write-Host "`n[1/5] Circuit breaker check..." -ForegroundColor Cyan
$alertState = Get-AlertState

if ($alertState.ContainsKey($Service)) {
    $lastHeal = $alertState[$Service].lastHealAttempt
    if ($lastHeal) {
        try {
            $lastHealTime = [datetime]$lastHeal
            $ageHours     = ((Get-Date) - $lastHealTime).TotalHours
            if ($ageHours -lt 2) {
                Write-Info "Skipping heal -- attempted $([math]::Round($ageHours, 1))h ago (< 2h window) for $Service"
                Write-Log "Circuit breaker: heal suppressed for $Service (last attempt: $lastHeal)" "INFO"
                exit 0
            } else {
                Write-Info "Last heal attempt was $([math]::Round($ageHours, 1))h ago -- proceeding"
            }
        } catch {
            Write-Warn "Could not parse lastHealAttempt timestamp '$lastHeal': $_ -- proceeding"
        }
    } else {
        Write-Info "No prior heal attempt recorded for $Service -- proceeding"
    }
} else {
    Write-Info "No alert state entry for $Service -- proceeding"
}

# -- 2. Build Claude context -----------------------------------------------------
Write-Host "`n[2/5] Building Claude context..." -ForegroundColor Cyan

$healthJsonPath = "$LogDir\health.json"
$healthJson     = ""
if (Test-Path $healthJsonPath) {
    try {
        $healthJson = [System.IO.File]::ReadAllText($healthJsonPath, $Utf8NoBom)
    } catch {
        $healthJson = "(could not read health.json: $_)"
        Write-Warn "Could not read health.json: $_"
    }
} else {
    $healthJson = "(health.json not found)"
    Write-Warn "health.json not found at $healthJsonPath"
}

$logLines = ""
if (Test-Path $LogFile) {
    try {
        $logLines = (Get-Content $LogFile -Tail 60) -join "`n"
    } catch {
        $logLines = "(could not read log file: $_)"
        Write-Warn "Could not read log tail: $_"
    }
} else {
    $logLines = "(log file not found)"
}

$descriptionLine = if ($Description) { $Description } else { "(none provided)" }

$prompt = @"
You are performing autonomous repair of the media stack at M:\Media.

FAILED SERVICE: $Service
DESCRIPTION: $descriptionLine

CURRENT HEALTH STATE:
$healthJson

RECENT LOG (last 60 lines):
$logLines

Instructions:
1. Check the Known Failure Modes table in M:\Media\CLAUDE.md to identify the likely cause.
2. Run the appropriate repair script from M:\Media\scripts\ using the PowerShell tool.
3. Verify the service recovered (docker ps, docker inspect, etc.).
4. Output a 2-3 sentence summary: what you found, what you ran, whether it worked.
5. If you cannot determine the cause or the repair requires manual action, output "ESCALATE: <reason>" on its own line.
6. Do NOT run /health or /probe -- that creates a loop.
"@

Write-Log "Context built -- health.json length: $($healthJson.Length), log tail lines: $((Get-Content $LogFile -Tail 60 -ErrorAction SilentlyContinue).Count)" "INFO"

# -- 3. Invoke Claude (background job with 5-minute timeout) ----------------------
Write-Host "`n[3/5] Invoking Claude Code (timeout: 5 min)..." -ForegroundColor Cyan
Write-Log "Invoking claude for service: $Service" "INFO"

$env:ANTHROPIC_API_KEY = $AnthropicKey

$claudeOutput   = $null
$claudeExitCode = $null

$job = Start-Job -ScriptBlock {
    param($PromptText, $Dir)
    Push-Location $Dir
    $out      = & claude -p $PromptText --allowedTools "Read,Glob,Grep,PowerShell,Bash" --output-format text 2>&1
    $exitCode = $LASTEXITCODE
    Pop-Location
    return @{ Output = ($out -join "`n"); ExitCode = $exitCode }
} -ArgumentList $prompt, $StackDir

$completed = Wait-Job -Job $job -Timeout 300

if (-not $completed) {
    Write-Warn "Claude invocation timed out after 300 seconds"
    Write-Log "Claude timed out after 300s for service: $Service" "WARN"
    Stop-Job  -Job $job
    Remove-Job -Job $job
    $claudeOutput   = "TIMEOUT: claude did not respond within 5 minutes"
    $claudeExitCode = -1
} else {
    $result         = Receive-Job -Job $job
    Remove-Job -Job $job
    $claudeOutput   = $result.Output
    $claudeExitCode = $result.ExitCode
    Write-Log "Claude completed (exit $claudeExitCode), output length: $($claudeOutput.Length)" "INFO"
}

Write-Info "Claude output (first 300 chars): $($claudeOutput.Substring(0, [Math]::Min(300, $claudeOutput.Length)))"

# -- 4. Post-heal re-check -------------------------------------------------------
Write-Host "`n[4/5] Re-checking $Service..." -ForegroundColor Cyan

$recovered = $false
switch ($Service) {
    "vpn" {
        try {
            $raw     = docker exec gluetun wget -qO- https://am.i.mullvad.net/connected 2>&1
            $text    = ($raw | Where-Object { $_ -is [string] }) -join " "
            $recovered = $text -match "You are connected to Mullvad"
            Write-Log "VPN re-check: $text" "INFO"
        } catch {
            Write-Warn "VPN re-check error: $_"
            $recovered = $false
        }
    }
    "containers" {
        try {
            $ps  = docker compose -f $ComposeFile ps --format json 2>&1
            $bad = $ps | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
                   Where-Object { $_ -ne $null -and ($_.Status -notmatch "Up" -or $_.Status -match "unhealthy") }
            $recovered = ($bad.Count -eq 0)
            Write-Log "Containers re-check: $($bad.Count) still bad" "INFO"
        } catch {
            Write-Warn "Containers re-check error: $_"
            $recovered = $false
        }
    }
    "qbittorrent" {
        try {
            $h = docker inspect --format '{{.State.Health.Status}}' qbittorrent 2>&1
            $recovered = ($h -eq "healthy")
            Write-Log "qBittorrent re-check: $h" "INFO"
        } catch {
            Write-Warn "qBittorrent re-check error: $_"
            $recovered = $false
        }
    }
    "disk" {
        # Disk cannot self-heal; always escalate
        $recovered = $false
        Write-Info "Disk cannot self-heal -- escalation required"
    }
    "firewall" {
        try {
            $rules     = @(Get-NetFirewallRule -DisplayName "Media Stack -*" -ErrorAction SilentlyContinue)
            $recovered = ($rules.Count -ge 10)
            Write-Log "Firewall re-check: $($rules.Count) rules found" "INFO"
        } catch {
            Write-Warn "Firewall re-check error: $_"
            $recovered = $false
        }
    }
    "sonarr-queue" {
        # Recovered if warning-state items drop to <= 2
        try {
            $qNow2   = Get-Date
            $still   = @()
            if ($sonarrKey) {
                $sq = Invoke-RestMethod "http://localhost:8989/api/v3/queue?apikey=$sonarrKey&page=1&pageSize=500&includeUnknownSeriesItems=true" -TimeoutSec 15
                $still += @($sq.records | Where-Object {
                    $_.trackedDownloadStatus -eq "warning" -and
                    $_.status -ne "completed" -and $_.status -ne "delay" -and
                    $_.added -and ($qNow2 - [datetime]$_.added).TotalHours -gt 4
                })
            }
            if ($radarrKey) {
                $rq = Invoke-RestMethod "http://localhost:7878/api/v3/queue?apikey=$radarrKey&page=1&pageSize=500&includeUnknownMovieItems=true" -TimeoutSec 15
                $still += @($rq.records | Where-Object {
                    $_.trackedDownloadStatus -eq "warning" -and
                    $_.status -ne "completed" -and $_.status -ne "delay" -and
                    $_.added -and ($qNow2 - [datetime]$_.added).TotalHours -gt 4
                })
            }
            $recovered = ($still.Count -le 2)
            Write-Log "Sonarr-queue re-check: $($still.Count) still stalled" "INFO"
        } catch {
            Write-Warn "Sonarr-queue re-check error: $_"
            $recovered = $false
        }
    }
}

if ($recovered) {
    Write-OK "$Service recovered after heal"
} else {
    Write-Fail "$Service still degraded after heal attempt"
}

# -- 5. Write heal log entry -----------------------------------------------------
Write-Host "`n[5/5] Writing heal log..." -ForegroundColor Cyan
$healLogFile = "$LogDir\heal-$(Get-Date -Format 'yyyy-MM').log"
$resultLabel = if ($recovered) { "RECOVERED" } else { "STILL DEGRADED" }

$healEntry = @"
===== HEAL SESSION $timestamp =====
Service  : $Service
Trigger  : $descriptionLine
Claude   : $claudeOutput
Result   : $resultLabel
===========================================

"@

try {
    [System.IO.File]::AppendAllText($healLogFile, $healEntry, $Utf8NoBom)
    Write-Log "Heal log written to $healLogFile" "INFO"
} catch {
    Write-Warn "Failed to write heal log: $_"
}

# -- 6. Update alert-state.json --------------------------------------------------
$timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

if (-not $alertState.ContainsKey($Service)) {
    $alertState[$Service] = @{
        status              = "degraded"
        lastAlertTime       = $null
        lastHealAttempt     = $null
        consecutiveFailures = 0
    }
}

$alertState[$Service].lastHealAttempt = $timestamp

if ($recovered) {
    $alertState[$Service].consecutiveFailures = 0
    $alertState[$Service].status              = "ok"
}

try {
    Save-AlertState $alertState
    Write-Log "alert-state.json updated (lastHealAttempt=$timestamp, recovered=$recovered)" "INFO"
} catch {
    Write-Warn "Failed to write alert-state.json: $_"
}

# -- 7. Send ntfy notification ---------------------------------------------------
$isEscalation = $claudeOutput -match "ESCALATE:"

if ($recovered) {
    $shortOutput = $claudeOutput.Substring(0, [Math]::Min(200, $claudeOutput.Length))
    Send-NtfyAlert -Service $Service -Body "AUTO-HEALED: $Service restored by Claude. $shortOutput" -Priority "low"
} elseif ($isEscalation) {
    $reasonMatch = [regex]::Match($claudeOutput, "ESCALATE:(.*)")
    $reason      = if ($reasonMatch.Success) { $reasonMatch.Groups[1].Value.Trim() } else { "see heal log" }
    Send-NtfyAlert -Service $Service -Body "ESCALATION NEEDED: $reason" -Priority "high"
} else {
    Send-NtfyAlert -Service $Service -Body "Heal attempt for $Service failed. Claude ran but service still degraded. Check heal log." -Priority "default"
}

# -- Summary + exit code ---------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
if ($recovered) {
    Write-Host "  $Service RECOVERED" -ForegroundColor Green
} elseif ($isEscalation) {
    Write-Host "  ESCALATION REQUIRED for $Service" -ForegroundColor Red
} else {
    Write-Host "  $Service still degraded after heal attempt" -ForegroundColor Yellow
}
Write-Host "==========================================" -ForegroundColor Cyan

Write-Log "===== END heal-invoke [$Service] -- result: $resultLabel =====" "INFO"

if ($recovered)     { exit 0 }
if ($isEscalation)  { exit 2 }
exit 1
