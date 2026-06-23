<#
.SYNOPSIS
    Report monitored movies and TV episodes that have no file in Radarr/Sonarr.

.DESCRIPTION
    Queries the Radarr and Sonarr APIs for content that is monitored but has no
    downloaded file. Groups TV results by series. Does NOT trigger searches by
    default -- read-only.

    Common reasons content stays Missing:
      - Not indexed on any active Prowlarr indexer (old/obscure titles)
      - Custom format score below 0 (Non-English -10000 blocks the release silently)
      - Quality cutoff already met by a lower-quality file
      - Content not actually monitored in Sonarr/Radarr

    To see WHY a specific episode has no results, use the Interactive Search button
    inside Sonarr/Radarr UI -- it shows every release, its score, and rejection reason.

.PARAMETER TriggerSearch
    After reporting, trigger season searches in Sonarr for all series with missing
    episodes, and movie searches in Radarr for all missing movies.
    Use with caution -- floods Prowlarr with simultaneous queries.

.PARAMETER SonarrOnly
    Report TV missing content only.

.PARAMETER RadarrOnly
    Report movie missing content only.

.EXAMPLE
    # Read-only report of all missing monitored content
    .\check-missing.ps1

    # Report + trigger searches for everything missing
    .\check-missing.ps1 -TriggerSearch

    # TV only
    .\check-missing.ps1 -SonarrOnly
#>

param(
    [switch]$TriggerSearch,
    [switch]$SonarrOnly,
    [switch]$RadarrOnly
)

$ErrorActionPreference = "Continue"

$radarrBase = "http://localhost:7878"
$sonarrBase = "http://localhost:8989"
$radarrKey  = "ffe2d5d77df04128b2027ea05aa4bc86"
$sonarrKey  = "ee46bcbfbdfe48e4b7863db24f6ecb25"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Missing Monitored Content" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# =============================================================================
# RADARR -- missing movies
# =============================================================================
$missingMovies = @()
if (-not $SonarrOnly) {
    Write-Host ""
    Write-Host "--- MOVIES (Radarr) ---" -ForegroundColor Cyan
    try {
        $page    = 1
        $pageSize = 250
        do {
            $r = Invoke-RestMethod "$radarrBase/api/v3/wanted/missing?apikey=$radarrKey&sortKey=title&page=$page&pageSize=$pageSize"
            $missingMovies += $r.records
            $page++
        } while ($missingMovies.Count -lt $r.totalRecords -and $r.records.Count -gt 0)

        if ($missingMovies.Count -eq 0) {
            Write-Host "  None -- all monitored movies have files." -ForegroundColor Green
        } else {
            $missingMovies | Sort-Object title | ForEach-Object {
                $age = if ($_.added) {
                    $d = [datetime]$_.added
                    "$([math]::Round(((Get-Date) - $d).TotalDays))d ago"
                } else { "unknown age" }
                Write-Host ("  {0,-55} ({1})" -f $_.title, $age) -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "  Total missing movies: $($missingMovies.Count)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR: Cannot reach Radarr -- $_" -ForegroundColor Red
    }
}

# =============================================================================
# SONARR -- missing episodes, grouped by series
# =============================================================================
$missingEpisodes = @()
$seriesGroups    = @{}
if (-not $RadarrOnly) {
    Write-Host ""
    Write-Host "--- TV SHOWS (Sonarr) ---" -ForegroundColor Cyan
    try {
        # Build series lookup (wanted/missing only returns seriesId, not embedded series object)
        $allSeries   = Invoke-RestMethod "$sonarrBase/api/v3/series?apikey=$sonarrKey"
        $seriesById  = @{}
        $allSeries | ForEach-Object { $seriesById[$_.id] = $_ }

        $page    = 1
        $pageSize = 250
        do {
            $s = Invoke-RestMethod "$sonarrBase/api/v3/wanted/missing?apikey=$sonarrKey&sortKey=series.title&page=$page&pageSize=$pageSize"
            $missingEpisodes += $s.records
            $page++
        } while ($missingEpisodes.Count -lt $s.totalRecords -and $s.records.Count -gt 0)

        if ($missingEpisodes.Count -eq 0) {
            Write-Host "  None -- all monitored episodes have files." -ForegroundColor Green
        } else {
            # Group by series using the lookup
            foreach ($ep in $missingEpisodes) {
                $sid    = $ep.seriesId
                $series = $seriesById[$sid]
                $stitle = if ($series) { $series.title } else { "Unknown (id=$sid)" }
                $key    = "$sid"
                if (-not $seriesGroups.ContainsKey($key)) {
                    $seriesGroups[$key] = @{ title = $stitle; seriesId = $sid; seasons = @{}; episodes = @() }
                }
                $seriesGroups[$key].episodes += $ep
                $sn = "S{0:D2}" -f $ep.seasonNumber
                if (-not $seriesGroups[$key].seasons.ContainsKey($sn)) {
                    $seriesGroups[$key].seasons[$sn] = 0
                }
                $seriesGroups[$key].seasons[$sn]++
            }

            $seriesGroups.Values | Sort-Object title | ForEach-Object {
                $seasonSummary = ($_.seasons.GetEnumerator() | Sort-Object Name | ForEach-Object {
                    "$($_.Name): $($_.Value) ep"
                }) -join ", "
                $totalEp = $_.episodes.Count
                Write-Host ("  {0,-45} {1,4} ep  [{2}]" -f $_.title, $totalEp, $seasonSummary) -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "  Total missing episodes: $($missingEpisodes.Count) across $($seriesGroups.Count) series" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR: Cannot reach Sonarr -- $_" -ForegroundColor Red
    }
}

# =============================================================================
# Optionally trigger searches
# =============================================================================
if ($TriggerSearch) {
    Write-Host ""
    Write-Host "--- TRIGGERING SEARCHES ---" -ForegroundColor Cyan
    Write-Host "  WARNING: This sends simultaneous queries to all Prowlarr indexers." -ForegroundColor Yellow

    if (-not $SonarrOnly -and $missingMovies.Count -gt 0) {
        Write-Host ""
        Write-Host "  Radarr: searching for $($missingMovies.Count) missing movies..." -ForegroundColor Cyan
        foreach ($movie in $missingMovies) {
            try {
                $body = "{`"name`":`"MoviesSearch`",`"movieIds`":[$($movie.id)]}"
                Invoke-RestMethod -Method Post "$radarrBase/api/v3/command?apikey=$radarrKey" -Body $body -ContentType "application/json" | Out-Null
                Write-Host "    OK: $($movie.title)" -ForegroundColor Green
            } catch {
                Write-Host "    FAIL: $($movie.title) -- $_" -ForegroundColor Red
            }
        }
    }

    if (-not $RadarrOnly -and $seriesGroups.Count -gt 0) {
        Write-Host ""
        Write-Host "  Sonarr: triggering season searches for $($seriesGroups.Count) series..." -ForegroundColor Cyan
        foreach ($s in $seriesGroups.Values) {
            foreach ($seasonKey in $s.seasons.Keys) {
                $seasonNum = [int]($seasonKey -replace "S0*", "")
                try {
                    $body = "{`"name`":`"SeasonSearch`",`"seriesId`":$($s.seriesId),`"seasonNumber`":$seasonNum}"
                    Invoke-RestMethod -Method Post "$sonarrBase/api/v3/command?apikey=$sonarrKey" -Body $body -ContentType "application/json" | Out-Null
                    Write-Host "    OK: $($s.title) $seasonKey" -ForegroundColor Green
                } catch {
                    Write-Host "    FAIL: $($s.title) $seasonKey -- $_" -ForegroundColor Red
                }
            }
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if (-not $TriggerSearch -and ($missingMovies.Count -gt 0 -or $missingEpisodes.Count -gt 0)) {
    Write-Host "  Re-run with -TriggerSearch to kick off searches." -ForegroundColor Gray
    Write-Host "  For individual release rejection details, use the" -ForegroundColor Gray
    Write-Host "  Interactive Search button in the Sonarr/Radarr UI." -ForegroundColor Gray
}
Write-Host "========================================" -ForegroundColor Cyan
