<#
.SYNOPSIS
    Scan /data/torrents for video files that Sonarr/Radarr can import, and optionally import them.

.DESCRIPTION
    Uses Sonarr's and Radarr's manualimport API endpoints to:
      1. Discover video files in the torrent download directory that match known series/movies
      2. Report them grouped by confidence (high = auto-importable, low = ambiguous, none = unrecognised)
      3. With -Import: auto-import high-confidence TV matches via Sonarr, movies via Radarr

    High confidence = exactly 1 episode/movie match, no rejection reasons.
    Low confidence  = parsed but multiple matches or has rejections.
    Unrecognised    = Sonarr/Radarr couldn't identify the file at all.

    Dry-run by default. Use -Import to actually import.
    Torrent files are never deleted -- only the library copy is created.

.PARAMETER Import
    Actually import high-confidence matches. Default: dry-run (display only).

.PARAMETER All
    Also show low-confidence and unrecognised files. Default: only high-confidence.

.PARAMETER TvFolder
    Container-internal path for Sonarr to scan. Default: /data/torrents/tv
    Use /data/torrents to scan everything (slow -- 876+ files).

.PARAMETER MovieFolder
    Container-internal path for Radarr to scan. Default: /data/torrents/movies
    Use /data/torrents to scan everything (slow -- 876+ files).

.EXAMPLE
    .\import-orphans.ps1                              # scan tv+movies subfolders, dry-run
    .\import-orphans.ps1 -Import                      # import high-confidence matches
    .\import-orphans.ps1 -All                         # show all files including unrecognised
    .\import-orphans.ps1 -TvFolder /data/torrents     # scan root (slow, catches a show S01EP01 style)
    .\import-orphans.ps1 -TvFolder /data/torrents/Some.Show.S01   # specific show
#>

param(
    [switch]$Import,
    [switch]$All,
    [string]$TvFolder    = "/data/torrents/tv",
    [string]$MovieFolder = "/data/torrents/movies"
)

$ErrorActionPreference = "Continue"
$StackDir   = "M:\Media"
$ScriptName = "import-orphans"

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

Write-Log "===== START (Import=$Import, All=$All) =====" "INFO"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Orphan Import Scanner" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
if ($Import) {
    Write-Host "  MODE: IMPORT (will import high-confidence matches)" -ForegroundColor Yellow
} else {
    Write-Host "  MODE: DRY-RUN (pass -Import to actually import)" -ForegroundColor Gray
}
Write-Host "==========================================" -ForegroundColor Cyan

$totalImported = 0
$totalFailed   = 0

# ---- Sonarr: TV scan ----
Write-Host "`n[Sonarr] Scanning $TvFolder for TV matches..." -ForegroundColor Cyan

$sonarrCandidates = @()
try {
    $encodedFolder    = [Uri]::EscapeDataString($TvFolder)
    $uri              = "$sonarrBase/manualimport?apikey=$sonarrKey&folder=$encodedFolder&filterExistingFiles=true"
    $sonarrCandidates = @(Invoke-RestMethod $uri -TimeoutSec 300)
    Write-Info "Sonarr parsed $($sonarrCandidates.Count) files from $TvFolder"
} catch {
    Write-Fail "Sonarr manualimport API error: $_"
    Write-Log "Sonarr manualimport API failed: $_" "FAIL"
}

$sonarrHigh = @($sonarrCandidates | Where-Object {
    $_.episodes -and $_.episodes.Count -eq 1 -and
    $_.episodes[0].id -gt 0 -and
    (-not $_.rejections -or $_.rejections.Count -eq 0)
})
$sonarrLow  = @($sonarrCandidates | Where-Object {
    ($_.episodes -and $_.episodes.Count -gt 0) -and $_ -notin $sonarrHigh
})
$sonarrNone = @($sonarrCandidates | Where-Object {
    -not $_.episodes -or $_.episodes.Count -eq 0
})

Write-Host "  High confidence (auto-importable): $($sonarrHigh.Count)" -ForegroundColor Green
Write-Host "  Low confidence  (review needed):   $($sonarrLow.Count)"  -ForegroundColor Yellow
Write-Host "  Unrecognised    (no match found):  $($sonarrNone.Count)"  -ForegroundColor Red

if ($sonarrHigh.Count -gt 0) {
    Write-Host "`n  High-confidence TV matches:"
    foreach ($item in $sonarrHigh) {
        $ep     = $item.episodes[0]
        $series = if ($ep.series) { $ep.series.title } else { "seriesId=$($ep.seriesId)" }
        $epNum  = "S$($ep.seasonNumber.ToString('00'))E$($ep.episodeNumber.ToString('00'))"
        Write-Host "    $epNum  $series  --  $(Split-Path $item.path -Leaf)" -ForegroundColor Green
    }
}

if ($All) {
    if ($sonarrLow.Count -gt 0) {
        Write-Host "`n  Low-confidence TV (review in Sonarr UI > Wanted > Manual Import):"
        foreach ($item in $sonarrLow) {
            $rejStr = if ($item.rejections) { ($item.rejections.reason -join "; ") } else { "none" }
            Write-Host "    $(Split-Path $item.path -Leaf)  -- rejections: $rejStr" -ForegroundColor Yellow
        }
    }
    if ($sonarrNone.Count -gt 0) {
        Write-Host "`n  Unrecognised TV files (filename doesn't match any known series):"
        foreach ($item in $sonarrNone) {
            $name = if ($item.path) { Split-Path $item.path -Leaf } else { $item.relativePath }
            Write-Host "    $name" -ForegroundColor Red
        }
    }
}

if ($Import -and $sonarrHigh.Count -gt 0) {
    Write-Host "`n  Importing $($sonarrHigh.Count) high-confidence TV files..." -ForegroundColor Cyan
    $importBatch = @($sonarrHigh | ForEach-Object {
        $ep = $_.episodes[0]
        @{
            path                  = $_.path
            seriesId              = $ep.seriesId
            episodeIds            = @($ep.id)
            quality               = $_.quality
            languages             = $_.languages
            releaseGroup          = if ($_.releaseGroup) { $_.releaseGroup } else { "" }
            downloadId            = $null
            indexerFlags          = if ($_.indexerFlags) { $_.indexerFlags } else { 0 }
            disableReleasePushing = $false
        }
    })
    try {
        $body   = $importBatch | ConvertTo-Json -Depth 10 -AsArray
        $null   = Invoke-RestMethod -Method Post "$sonarrBase/manualimport?apikey=$sonarrKey" `
                    -ContentType "application/json" -Body $body -TimeoutSec 60
        Write-OK "Sonarr import command sent ($($importBatch.Count) files)"
        Write-Log "Sonarr import: sent $($importBatch.Count) high-confidence items" "INFO"
        $totalImported += $importBatch.Count
    } catch {
        Write-Fail "Sonarr import POST failed: $_"
        Write-Log "Sonarr import POST error: $_" "FAIL"
        $totalFailed += $importBatch.Count
    }
}

# ---- Radarr: Movie scan ----
Write-Host "`n[Radarr] Scanning $MovieFolder for Movie matches..." -ForegroundColor Cyan

$radarrCandidates = @()
try {
    $encodedFolder    = [Uri]::EscapeDataString($MovieFolder)
    $uri              = "$radarrBase/manualimport?apikey=$radarrKey&folder=$encodedFolder&filterExistingFiles=true"
    $radarrCandidates = @(Invoke-RestMethod $uri -TimeoutSec 300)
    Write-Info "Radarr parsed $($radarrCandidates.Count) files from $MovieFolder"
} catch {
    Write-Fail "Radarr manualimport API error: $_"
    Write-Log "Radarr manualimport API failed: $_" "FAIL"
}

$radarrHigh = @($radarrCandidates | Where-Object {
    $_.movie -and $_.movie.id -gt 0 -and
    (-not $_.rejections -or $_.rejections.Count -eq 0)
})
$radarrLow  = @($radarrCandidates | Where-Object {
    $_.movie -and $_.movie.id -gt 0 -and $_ -notin $radarrHigh
})
$radarrNone = @($radarrCandidates | Where-Object {
    -not $_.movie -or $_.movie.id -le 0
})

Write-Host "  High confidence (auto-importable): $($radarrHigh.Count)" -ForegroundColor Green
Write-Host "  Low confidence  (review needed):   $($radarrLow.Count)"  -ForegroundColor Yellow
Write-Host "  Unrecognised    (no match found):  $($radarrNone.Count)"  -ForegroundColor Red

if ($radarrHigh.Count -gt 0) {
    Write-Host "`n  High-confidence Movie matches:"
    foreach ($item in $radarrHigh) {
        $title = if ($item.movie) { "$($item.movie.title) ($($item.movie.year))" } else { "unknown movie" }
        Write-Host "    $title  --  $(Split-Path $item.path -Leaf)" -ForegroundColor Green
    }
}

if ($All) {
    if ($radarrLow.Count -gt 0) {
        Write-Host "`n  Low-confidence Movies (review in Radarr UI > Wanted > Manual Import):"
        foreach ($item in $radarrLow) {
            $rejStr = if ($item.rejections) { ($item.rejections.reason -join "; ") } else { "none" }
            Write-Host "    $(Split-Path $item.path -Leaf)  -- rejections: $rejStr" -ForegroundColor Yellow
        }
    }
    if ($radarrNone.Count -gt 0) {
        Write-Host "`n  Unrecognised Movie files:"
        foreach ($item in $radarrNone) {
            $name = if ($item.path) { Split-Path $item.path -Leaf } else { $item.relativePath }
            Write-Host "    $name" -ForegroundColor Red
        }
    }
}

if ($Import -and $radarrHigh.Count -gt 0) {
    Write-Host "`n  Importing $($radarrHigh.Count) high-confidence Movie files..." -ForegroundColor Cyan
    $importBatch = @($radarrHigh | ForEach-Object {
        @{
            path         = $_.path
            movieId      = $_.movie.id
            quality      = $_.quality
            languages    = $_.languages
            releaseGroup = if ($_.releaseGroup) { $_.releaseGroup } else { "" }
            downloadId   = $null
            indexerFlags = if ($_.indexerFlags) { $_.indexerFlags } else { 0 }
        }
    })
    try {
        $body = $importBatch | ConvertTo-Json -Depth 10 -AsArray
        $null = Invoke-RestMethod -Method Post "$radarrBase/manualimport?apikey=$radarrKey" `
                    -ContentType "application/json" -Body $body -TimeoutSec 60
        Write-OK "Radarr import command sent ($($importBatch.Count) files)"
        Write-Log "Radarr import: sent $($importBatch.Count) high-confidence items" "INFO"
        $totalImported += $importBatch.Count
    } catch {
        Write-Fail "Radarr import POST failed: $_"
        Write-Log "Radarr import POST error: $_" "FAIL"
        $totalFailed += $importBatch.Count
    }
}

# ---- Summary ----
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
$sonarrTotal = $sonarrHigh.Count + $sonarrLow.Count + $sonarrNone.Count
$radarrTotal = $radarrHigh.Count + $radarrLow.Count + $radarrNone.Count
Write-Host "  Sonarr ($TvFolder): $($sonarrHigh.Count)/$sonarrTotal auto-importable TV files"
Write-Host "  Radarr ($MovieFolder): $($radarrHigh.Count)/$radarrTotal auto-importable Movie files"

if ($Import) {
    $color = if ($totalFailed -gt 0) { "Red" } else { "Green" }
    Write-Host "  Imported: $totalImported   Failed: $totalFailed" -ForegroundColor $color
} else {
    Write-Host "  Run with -Import to import high-confidence matches" -ForegroundColor Gray
}
Write-Host "==========================================" -ForegroundColor Cyan

Write-Log "===== END (sonarrHigh=$($sonarrHigh.Count), radarrHigh=$($radarrHigh.Count), imported=$totalImported, failed=$totalFailed) =====" "INFO"

exit $(if ($totalFailed -gt 0) { 1 } else { 0 })
