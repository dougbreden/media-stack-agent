<#
.SYNOPSIS
    Detect dead/stalled downloads in Sonarr and Radarr queues and rescue them.

.DESCRIPTION
    1. Queries Sonarr and Radarr download queues for items that are:
         - In "warning" state (download client actively reporting problems), AND older than 4h
         - OR older than -StaleHours with <1% downloaded (started but never progressed)
    2. Dry-run mode: reports the dead items with age and status
    3. With -Rescue: removes each dead item (blocklist=true so it won't re-grab the same release),
       then triggers a new search for each affected series/movie
    4. With -Service: limit to Sonarr, Radarr, or Both (default Both)

    NEVER deletes torrent files. Only removes from the *-arr queue tracker.
    blocklist=true ensures Sonarr/Radarr remembers the bad release and picks the next-best.

.PARAMETER Rescue
    Actually remove dead items and trigger re-search. Default: dry-run.

.PARAMETER StaleHours
    Age threshold (hours) for a 0%-progress item to be flagged. Default: 12.
    Warning-status items are flagged after 4 hours regardless of this value.

.PARAMETER Service
    Which service to check: Sonarr, Radarr, or Both (default).

.EXAMPLE
    .\rescue-downloads.ps1                      # dry-run report
    .\rescue-downloads.ps1 -Rescue              # remove dead items + trigger re-searches
    .\rescue-downloads.ps1 -Rescue -Service Sonarr   # TV only
    .\rescue-downloads.ps1 -StaleHours 6 -Rescue     # lower threshold
#>

param(
    [switch]$Rescue,
    [int]$StaleHours = 12,
    [ValidateSet("Sonarr","Radarr","Both")]
    [string]$Service = "Both"
)

$ErrorActionPreference = "Continue"
$StackDir   = "M:\Media"
$ScriptName = "rescue-downloads"

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

. "$PSScriptRoot\config.ps1"

$sonarrBase = "http://localhost:8989/api/v3"
$radarrBase = "http://localhost:7878/api/v3"
$now        = Get-Date

Write-Log "===== START (Rescue=$Rescue, StaleHours=$StaleHours, Service=$Service) =====" "INFO"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Download Rescue Scanner" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
if ($Rescue) {
    Write-Host "  MODE: RESCUE (remove dead items + trigger re-search)" -ForegroundColor Yellow
} else {
    Write-Host "  MODE: DRY-RUN (pass -Rescue to act)" -ForegroundColor Gray
}
Write-Host "  Stale threshold: ${StaleHours}h, Warning threshold: 4h" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan

function Get-AllQueueRecords([string]$Base, [string]$ApiKey, [string]$ExtraParams) {
    $r = Invoke-RestMethod "$Base/queue?apikey=$ApiKey&page=1&pageSize=500&$ExtraParams" -TimeoutSec 30
    return @($r.records)
}

function Test-IsDeadItem([object]$Item) {
    if ($Item.status -eq "completed" -or $Item.status -eq "delay") { return $false }
    # Actively flagged by Sonarr/Radarr as warning AND old enough to be non-transient
    if ($Item.trackedDownloadStatus -eq "warning" -and $Item.added) {
        if (($now - [datetime]$Item.added).TotalHours -gt 4) { return $true }
    }
    # No progress after StaleHours (likely seeder-less torrent)
    if ($Item.added -and $Item.size -gt 0 -and $Item.sizeleft -gt 0) {
        $age    = ($now - [datetime]$Item.added).TotalHours
        $pctDL  = ($Item.size - $Item.sizeleft) / $Item.size
        if ($age -gt $StaleHours -and $pctDL -lt 0.01) { return $true }
    }
    return $false
}

$totalRemoved  = 0
$totalSearched = 0
$totalFailed   = 0

# ---- Sonarr ----
if ($Service -in "Sonarr","Both") {
    Write-Host "`n[Sonarr] Checking TV download queue..." -ForegroundColor Cyan
    try {
        $records    = @(Get-AllQueueRecords $sonarrBase $sonarrKey "includeUnknownSeriesItems=true")
        $dead       = @($records | Where-Object { Test-IsDeadItem $_ })

        if ($dead.Count -eq 0) {
            Write-OK "No stalled/dead TV downloads found ($($records.Count) total in queue)"
        } else {
            Write-Warn "$($dead.Count) dead/stalled item(s) out of $($records.Count) total:"
            $seriesForSearch = @{}
            foreach ($item in $dead) {
                $age    = if ($item.added) { [math]::Round(($now - [datetime]$item.added).TotalHours, 1) } else { "?" }
                $pct    = if ($item.size -gt 0) { [math]::Round(($item.size - $item.sizeleft) / $item.size * 100, 1) } else { 0 }
                $flag   = if ($item.trackedDownloadStatus -eq "warning") { "WARNING" } else { "STALE" }
                $title  = $item.title.Substring(0, [Math]::Min(65, $item.title.Length))
                Write-Warn "  [$flag] $title (${age}h old, ${pct}% complete)"

                if ($item.seriesId -gt 0) { $seriesForSearch[$item.seriesId] = $true }

                if ($Rescue) {
                    try {
                        $null = Invoke-RestMethod -Method Delete `
                            "$sonarrBase/queue/$($item.id)?apikey=$sonarrKey&blocklist=true&removeFromClient=false" `
                            -TimeoutSec 20
                        $short = $item.title.Substring(0, [Math]::Min(60, $item.title.Length))
                        Write-OK "  Removed from queue (blocklisted): ${short}..."
                        Write-Log "Sonarr: removed queue item $($item.id) (${short})" "INFO"
                        $totalRemoved++
                    } catch {
                        Write-Fail "  Failed to remove item $($item.id): $_"
                        Write-Log "Sonarr: remove failed for $($item.id): $_" "FAIL"
                        $totalFailed++
                    }
                }
            }

            if ($Rescue -and $seriesForSearch.Count -gt 0) {
                Write-Host "`n  Triggering new searches for $($seriesForSearch.Count) affected series..." -ForegroundColor Cyan
                foreach ($sid in $seriesForSearch.Keys) {
                    try {
                        $body  = @{ name = "SeriesSearch"; seriesId = $sid } | ConvertTo-Json
                        $cmd   = Invoke-RestMethod -Method Post "$sonarrBase/command?apikey=$sonarrKey" `
                                    -ContentType "application/json" -Body $body -TimeoutSec 20
                        Write-OK "  SeriesSearch queued for seriesId=$sid (command $($cmd.id))"
                        Write-Log "Sonarr: SeriesSearch triggered for seriesId=$sid" "INFO"
                        $totalSearched++
                    } catch {
                        Write-Fail "  SeriesSearch failed for seriesId=${sid}: $_"
                        Write-Log "Sonarr: SeriesSearch error for seriesId=${sid}: $_" "FAIL"
                        $totalFailed++
                    }
                }
            }
        }
    } catch {
        Write-Fail "Sonarr queue check error: $_"
        Write-Log "Sonarr queue check failed: $_" "FAIL"
    }
}

# ---- Radarr ----
if ($Service -in "Radarr","Both") {
    Write-Host "`n[Radarr] Checking Movie download queue..." -ForegroundColor Cyan
    try {
        $records = @(Get-AllQueueRecords $radarrBase $radarrKey "includeUnknownMovieItems=true")
        $dead    = @($records | Where-Object { Test-IsDeadItem $_ })

        if ($dead.Count -eq 0) {
            Write-OK "No stalled/dead Movie downloads found ($($records.Count) total in queue)"
        } else {
            Write-Warn "$($dead.Count) dead/stalled item(s) out of $($records.Count) total:"
            $moviesForSearch = @{}
            foreach ($item in $dead) {
                $age   = if ($item.added) { [math]::Round(($now - [datetime]$item.added).TotalHours, 1) } else { "?" }
                $pct   = if ($item.size -gt 0) { [math]::Round(($item.size - $item.sizeleft) / $item.size * 100, 1) } else { 0 }
                $flag  = if ($item.trackedDownloadStatus -eq "warning") { "WARNING" } else { "STALE" }
                $title = $item.title.Substring(0, [Math]::Min(65, $item.title.Length))
                Write-Warn "  [$flag] $title (${age}h old, ${pct}% complete)"

                if ($item.movieId -gt 0) { $moviesForSearch[$item.movieId] = $true }

                if ($Rescue) {
                    try {
                        $null = Invoke-RestMethod -Method Delete `
                            "$radarrBase/queue/$($item.id)?apikey=$radarrKey&blocklist=true&removeFromClient=false" `
                            -TimeoutSec 20
                        $short = $item.title.Substring(0, [Math]::Min(60, $item.title.Length))
                        Write-OK "  Removed from queue (blocklisted): ${short}..."
                        Write-Log "Radarr: removed queue item $($item.id) (${short})" "INFO"
                        $totalRemoved++
                    } catch {
                        Write-Fail "  Failed to remove item $($item.id): $_"
                        Write-Log "Radarr: remove failed for $($item.id): $_" "FAIL"
                        $totalFailed++
                    }
                }
            }

            if ($Rescue -and $moviesForSearch.Count -gt 0) {
                Write-Host "`n  Triggering new searches for $($moviesForSearch.Count) affected movies..." -ForegroundColor Cyan
                foreach ($mid in $moviesForSearch.Keys) {
                    try {
                        $body = @{ name = "MoviesSearch"; movieIds = @($mid) } | ConvertTo-Json -Depth 3
                        $cmd  = Invoke-RestMethod -Method Post "$radarrBase/command?apikey=$radarrKey" `
                                    -ContentType "application/json" -Body $body -TimeoutSec 20
                        Write-OK "  MoviesSearch queued for movieId=$mid (command $($cmd.id))"
                        Write-Log "Radarr: MoviesSearch triggered for movieId=$mid" "INFO"
                        $totalSearched++
                    } catch {
                        Write-Fail "  MoviesSearch failed for movieId=${mid}: $_"
                        Write-Log "Radarr: MoviesSearch error for movieId=${mid}: $_" "FAIL"
                        $totalFailed++
                    }
                }
            }
        }
    } catch {
        Write-Fail "Radarr queue check error: $_"
        Write-Log "Radarr queue check failed: $_" "FAIL"
    }
}

# ---- Summary ----
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Summary:"
Write-Host "    Removed from queue: $totalRemoved"
Write-Host "    Re-searches started: $totalSearched"
Write-Host "    Errors: $totalFailed"
if (-not $Rescue) {
    Write-Host "  Run with -Rescue to remove dead items and trigger re-searches" -ForegroundColor Gray
}
Write-Host "==========================================" -ForegroundColor Cyan

Write-Log "===== END (removed=$totalRemoved, searched=$totalSearched, failed=$totalFailed) =====" "INFO"

exit $(if ($totalFailed -gt 0) { 1 } else { 0 })
