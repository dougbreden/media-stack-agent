<#
.SYNOPSIS
    Ongoing maintenance: ensure Universal library files meet H264 + MKV + AAC standard.

.DESCRIPTION
    Runs four idempotent steps in order:

    1. dedup-audio.ps1                -- remove duplicate audio streams
    2. tdarr-reset-universal-files.ps1-- reset Tdarr errored files so they are re-evaluated
                                        (exits early with no disruption if 0 errored files)
    3. remux-library-to-mkv.ps1 -Apply-- convert any non-MKV imports to MKV (stream copy)
    4. Tdarr scanFresh                -- re-evaluate all library files so Tdarr picks up
                                        new MKV imports and encodes any remaining non-H264
                                        files to h264_nvenc

    Safe to run on a schedule. Each step skips files that already meet the requirement.
    Tdarr handles H264 encoding and AAC addition automatically; this script covers the
    gaps Tdarr cannot handle itself (containers and duplicate streams).

    Runs against Universal libraries only (data\movies, data\tv). Does not touch
    data\torrents or future Premium 4K libraries.

    Output goes to console and M:\Media\logs\automation-YYYY-MM.log.

.PARAMETER SkipDedup
    Skip the dedup-audio.ps1 step.

.PARAMETER SkipTdarrReset
    Skip the tdarr-reset-universal-files.ps1 step.

.PARAMETER SkipRemux
    Skip the remux-library-to-mkv.ps1 step.

.PARAMETER SkipScan
    Skip triggering the Tdarr scanFresh.

.EXAMPLE
    # Full run (all four steps)
    .\standardize-library.ps1

    # Remux + scan only (skip dedup and reset for speed on routine runs)
    .\standardize-library.ps1 -SkipDedup -SkipTdarrReset
#>

param(
    [switch]$SkipDedup,
    [switch]$SkipTdarrReset,
    [switch]$SkipRemux,
    [switch]$SkipScan
)

$ErrorActionPreference = "Continue"
$ScriptDir = "M:\Media\scripts"
$TdarrBase = "http://localhost:8265"

$ScriptName = "standardize-library"
$LogDir  = "M:\Media\logs"
$LogFile = "$LogDir\automation-$(Get-Date -Format 'yyyy-MM').log"
$null    = New-Item -ItemType Directory -Force -Path $LogDir

function Write-Log([string]$Msg, [string]$Level = "INFO") {
    $line = "{0} | {1,-5} | {2,-22} | {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $ScriptName, $Msg
    [System.IO.File]::AppendAllText($LogFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
}

$UniversalLibraries = @(
    @{ id = "rUP5cniqB"; path = "/data/movies"; name = "Movies" },
    @{ id = "nw7PJBmiV"; path = "/data/tv";     name = "TV"     }
)

$results = @{
    DedupFixed       = 0
    DedupErrors      = 0
    TdarrResetCount  = 0
    Remuxed          = 0
    RemuxFailed      = 0
    ScanOk           = $false
}

Write-Log "===== START =====" "INFO"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Library Standardization" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# -- Step 1: dedup-audio -------------------------------------------------------
if (-not $SkipDedup) {
    Write-Host ""
    Write-Host "[1/4] Dedup audio streams..." -ForegroundColor Cyan
    $dedupOut = & "$ScriptDir\dedup-audio.ps1" 2>&1
    $dedupOut | ForEach-Object { Write-Host "  $_" }

    $fixedLine  = $dedupOut | Where-Object { $_ -match "Fixed\s+:" } | Select-Object -Last 1
    $errorLine  = $dedupOut | Where-Object { $_ -match "Fix errors\s+:" } | Select-Object -Last 1
    if ($fixedLine  -match ":\s*(\d+)") { $results.DedupFixed  = [int]$Matches[1] }
    if ($errorLine  -match ":\s*(\d+)") { $results.DedupErrors = [int]$Matches[1] }
    Write-Log "Dedup: $($results.DedupFixed) fixed, $($results.DedupErrors) errors" "INFO"
} else {
    Write-Host ""
    Write-Host "[1/4] Dedup audio -- skipped" -ForegroundColor Gray
}

# -- Step 2: reset Tdarr errored files -----------------------------------------
if (-not $SkipTdarrReset) {
    Write-Host ""
    Write-Host "[2/4] Tdarr: reset errored files..." -ForegroundColor Cyan
    $resetOut = & "$ScriptDir\tdarr-reset-universal-files.ps1" 2>&1
    $resetOut | ForEach-Object { Write-Host "  $_" }

    $resetLine = $resetOut | Where-Object { $_ -match "errored files reset|No errored files" } | Select-Object -Last 1
    if ($resetLine -match "(\d+) errored files reset") { $results.TdarrResetCount = [int]$Matches[1] }
    Write-Log "Tdarr reset: $($results.TdarrResetCount) errored files cleared" "INFO"
} else {
    Write-Host ""
    Write-Host "[2/4] Tdarr reset -- skipped" -ForegroundColor Gray
}

# -- Step 3: remux to MKV ------------------------------------------------------
if (-not $SkipRemux) {
    Write-Host ""
    Write-Host "[3/4] Remux non-MKV files to MKV..." -ForegroundColor Cyan
    $remuxOut = & "$ScriptDir\remux-library-to-mkv.ps1" -Apply 2>&1
    $remuxOut | Where-Object { $_ -match "REMUXED|ERROR|Candidates|Remuxed|Failed|Skipped" } |
        ForEach-Object { Write-Host "  $_" }

    $remuxedLine = $remuxOut | Where-Object { $_ -match "Remuxed\s+:" } | Select-Object -Last 1
    $failedLine  = $remuxOut | Where-Object { $_ -match "Failed\s+:"  } | Select-Object -Last 1
    if ($remuxedLine -match ":\s*(\d+)") { $results.Remuxed     = [int]$Matches[1] }
    if ($failedLine  -match ":\s*(\d+)") { $results.RemuxFailed = [int]$Matches[1] }
    Write-Log "Remux: $($results.Remuxed) converted, $($results.RemuxFailed) failed" "INFO"
} else {
    Write-Host ""
    Write-Host "[3/4] Remux -- skipped" -ForegroundColor Gray
}

# -- Step 4: Tdarr scanFresh ---------------------------------------------------
if (-not $SkipScan) {
    Write-Host ""
    Write-Host "[4/4] Triggering Tdarr scanFresh..." -ForegroundColor Cyan
    $allOk = $true
    foreach ($lib in $UniversalLibraries) {
        try {
            $body = "{`"data`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"scanConfig`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"arrayOrPath`":`"$($lib.path)`"}}}"
            Invoke-RestMethod -Method Post "$TdarrBase/api/v2/scan-files" -Body $body -ContentType "application/json" | Out-Null
            Write-Host "  OK: $($lib.name) ($($lib.path))" -ForegroundColor Green
        } catch {
            Write-Host "  WARN: Could not trigger scan for $($lib.name): $_" -ForegroundColor Yellow
            $allOk = $false
        }
    }
    $results.ScanOk = $allOk
    Write-Log "Tdarr scan: $(if ($allOk) { 'triggered OK' } else { 'partial/failed' })" "INFO"
} else {
    Write-Host ""
    Write-Host "[4/4] Tdarr scan -- skipped" -ForegroundColor Gray
}

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Dedup fixed   : $($results.DedupFixed)" -ForegroundColor $(if ($results.DedupFixed -gt 0) { "Yellow" } else { "Green" })
if ($results.DedupErrors -gt 0) {
    Write-Host "  Dedup errors  : $($results.DedupErrors)" -ForegroundColor Red
}
Write-Host "  Tdarr reset   : $($results.TdarrResetCount) errored files cleared" -ForegroundColor $(if ($results.TdarrResetCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Remuxed       : $($results.Remuxed)" -ForegroundColor $(if ($results.Remuxed -gt 0) { "Yellow" } else { "Green" })
if ($results.RemuxFailed -gt 0) {
    Write-Host "  Remux failed  : $($results.RemuxFailed)" -ForegroundColor Red
}
if (-not $SkipScan) {
    Write-Host "  Tdarr scan    : $(if ($results.ScanOk) { 'triggered' } else { 'partial/failed' })" -ForegroundColor $(if ($results.ScanOk) { "Green" } else { "Yellow" })
}
Write-Host "==========================================" -ForegroundColor Cyan

Write-Log "===== END (dedup=$($results.DedupFixed), reset=$($results.TdarrResetCount), remux=$($results.Remuxed)) =====" "INFO"
