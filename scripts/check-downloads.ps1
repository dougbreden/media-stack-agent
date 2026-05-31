<#
.SYNOPSIS
    Detect and clean up problematic downloads that Radarr/Sonarr miss.

.DESCRIPTION
    Radarr and Sonarr handle true failures automatically (autoRedownloadFailed=true).
    This script covers the gaps they cannot see:

    1. Dead metaDL -- qBittorrent reports these as "downloading" so Radarr/Sonarr never
       flag them as failed. If a torrent has been in metaDL state with 0 seeds for longer
       than -MetaDLDeadHours, it is removed from qBittorrent and blocklisted in
       Radarr/Sonarr so they immediately re-search for a working release.

    2. Dangerous files -- scans download directories for executable extensions
       (.exe .bat .cmd .msi .vbs .jar). These are always fake torrents. Removes the
       file, removes the torrent from qBittorrent, and blocklists in Radarr/Sonarr.

    3. Stalled at 0% -- reports (does not auto-delete) torrents that have been at 0%
       with 0 seeds for longer than -StalledDeadHours. These may be seasonal (e.g.
       Christmas movies in May) or truly dead -- a human should decide.

    Requires qBittorrent, Radarr, and Sonarr containers running.
    Safe to run from update.ps1 or as a scheduled task. Dry-run by default.

.PARAMETER DryRun
    Report problems without making any changes. Default: true.
    Pass -DryRun:$false to apply fixes.

.PARAMETER MetaDLDeadHours
    Hours a torrent must be in metaDL with 0 seeds before being treated as dead.
    Default: 2

.PARAMETER StalledDeadHours
    Hours a torrent must be stalled at 0% with 0 seeds before being reported.
    Default: 24

.EXAMPLE
    # Check what would be cleaned (default dry-run)
    .\check-downloads.ps1

    # Apply all fixes
    .\check-downloads.ps1 -DryRun:$false

    # Tighter threshold
    .\check-downloads.ps1 -DryRun:$false -MetaDLDeadHours 1
#>

param(
    [switch]$DryRun = $true,
    [int]$MetaDLDeadHours  = 2,
    [int]$StalledDeadHours = 24
)

$ErrorActionPreference = "Continue"

$qbBase     = "http://localhost:8080"
$radarrBase = "http://localhost:7878"
$sonarrBase = "http://localhost:8989"
$radarrKey  = "ffe2d5d77df04128b2027ea05aa4bc86"
$sonarrKey  = "ee46bcbfbdfe48e4b7863db24f6ecb25"

$dangerousExts = @(".exe", ".bat", ".cmd", ".msi", ".vbs", ".jar", ".scr", ".pif")
$downloadPaths = @("M:\Media\data\torrents")

if ($DryRun) {
    Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Yellow
}

# -- qBittorrent login --------------------------------------------------------
$qbSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
try {
    Invoke-RestMethod "$qbBase/api/v2/auth/login" -Method Post `
        -Body "username=admin&password=idbeholdg" -WebSession $qbSession | Out-Null
} catch {
    Write-Host "ERROR: Cannot reach qBittorrent at $qbBase" -ForegroundColor Red
    exit 1
}

$torrents = Invoke-RestMethod "$qbBase/api/v2/torrents/info?filter=all" -WebSession $qbSession
$now      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# -- Build Radarr + Sonarr queue maps: torrent hash -> queue record -----------
$radarrQueue = @{}
$sonarrQueue = @{}
try {
    $r = Invoke-RestMethod "$radarrBase/api/v3/queue?apikey=$radarrKey&pageSize=200"
    $r.records | Where-Object { $_.downloadId } |
        ForEach-Object { $radarrQueue[$_.downloadId.ToLower()] = $_ }
} catch { Write-Host "  WARN: Could not reach Radarr" -ForegroundColor DarkYellow }

try {
    $s = Invoke-RestMethod "$sonarrBase/api/v3/queue?apikey=$sonarrKey&pageSize=200"
    $s.records | Where-Object { $_.downloadId } |
        ForEach-Object { $sonarrQueue[$_.downloadId.ToLower()] = $_ }
} catch { Write-Host "  WARN: Could not reach Sonarr" -ForegroundColor DarkYellow }

# -- Blocklist in Radarr/Sonarr for a given hash, return true if found --------
function Invoke-Blocklist([string]$Hash) {
    $h       = $Hash.ToLower()
    $handled = $false

    if ($radarrQueue.ContainsKey($h)) {
        $id = $radarrQueue[$h].id
        Write-Host "    -> Radarr: blocklist queue item $id" -ForegroundColor Gray
        if (-not $DryRun) {
            try {
                Invoke-RestMethod "$radarrBase/api/v3/queue/$($id)?removeFromClient=false&blocklist=true" `
                    -Method Delete -Headers @{"X-Api-Key" = $radarrKey } | Out-Null
            } catch { Write-Host "    ERROR: Radarr blocklist: $_" -ForegroundColor Red }
        }
        $handled = $true
    }

    if ($sonarrQueue.ContainsKey($h)) {
        $id = $sonarrQueue[$h].id
        Write-Host "    -> Sonarr: blocklist queue item $id" -ForegroundColor Gray
        if (-not $DryRun) {
            try {
                Invoke-RestMethod "$sonarrBase/api/v3/queue/$($id)?removeFromClient=false&blocklist=true" `
                    -Method Delete -Headers @{"X-Api-Key" = $sonarrKey } | Out-Null
            } catch { Write-Host "    ERROR: Sonarr blocklist: $_" -ForegroundColor Red }
        }
        $handled = $true
    }

    if (-not $handled) {
        Write-Host "    -> Not in Radarr/Sonarr queue (orphaned torrent)" -ForegroundColor DarkYellow
    }
}

function Remove-FromQB([string]$Hash, [bool]$DeleteFiles) {
    if ($DryRun) { return }
    $df = if ($DeleteFiles) { "true" } else { "false" }
    Invoke-RestMethod "$qbBase/api/v2/torrents/delete" -Method Post `
        -Body "hashes=$Hash`&deleteFiles=$df" -WebSession $qbSession | Out-Null
}

# =============================================================================
# 1. Dead metaDL
# =============================================================================
Write-Host ""
Write-Host "=== 1. Dead metaDL (0 seeds, older than ${MetaDLDeadHours}h) ===" -ForegroundColor Cyan

$deadMeta = $torrents | Where-Object {
    $_.state -eq "metaDL" -and
    $_.num_seeds -eq 0 -and
    ($now - $_.added_on) -gt ($MetaDLDeadHours * 3600)
}

if ($deadMeta.Count -eq 0) {
    Write-Host "  None." -ForegroundColor Green
} else {
    foreach ($t in $deadMeta) {
        $ageH = [math]::Round(($now - $t.added_on) / 3600, 1)
        Write-Host "  DEAD [$($t.category)] ${ageH}h -- $($t.name)" -ForegroundColor Yellow
        Invoke-Blocklist -Hash $t.hash
        Write-Host "    -> Removing from qBittorrent (no files to delete)" -ForegroundColor Gray
        Remove-FromQB -Hash $t.hash -DeleteFiles $false
    }
}

# =============================================================================
# 2. Dangerous files in download directories
# =============================================================================
Write-Host ""
Write-Host "=== 2. Dangerous file extensions in download paths ===" -ForegroundColor Cyan

$dangerousFound = @()
foreach ($root in $downloadPaths) {
    if (-not (Test-Path $root)) { continue }
    $found = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $dangerousExts -contains $_.Extension.ToLower() }
    $dangerousFound += @($found)
}

if ($dangerousFound.Count -eq 0) {
    Write-Host "  None." -ForegroundColor Green
} else {
    foreach ($file in $dangerousFound) {
        $sizeMB = [math]::Round($file.Length / 1MB, 2)
        Write-Host "  DANGEROUS: $($file.FullName) ($sizeMB MB)" -ForegroundColor Red

        # Match to a torrent by content path
        $winBase = "M:\Media"
        $match = $torrents | Where-Object {
            $winPath = $_.content_path -replace "^/", "" -replace "/", "\"
            $winPath = $winBase + "\" + $winPath
            $file.FullName.StartsWith($winPath, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        if ($match) {
            Write-Host "    -> Torrent: $($match.name)" -ForegroundColor Gray
            Invoke-Blocklist -Hash $match.hash
            Write-Host "    -> Removing torrent from qBittorrent" -ForegroundColor Gray
            Remove-FromQB -Hash $match.hash -DeleteFiles $false
        } else {
            Write-Host "    -> No matching torrent found (file may be orphaned)" -ForegroundColor DarkYellow
        }

        Write-Host "    -> Deleting file" -ForegroundColor Gray
        if (-not $DryRun) {
            try {
                [System.IO.File]::Delete($file.FullName)
                Write-Host "    -> Deleted." -ForegroundColor Green
            } catch {
                Write-Host "    ERROR deleting $($file.FullName): $_" -ForegroundColor Red
            }
        }
    }
}

# =============================================================================
# 3. Stalled at 0% -- report only, human decides
# =============================================================================
Write-Host ""
Write-Host "=== 3. Stalled at 0% with 0 seeds for > ${StalledDeadHours}h (review only) ===" -ForegroundColor Cyan

$stalled = $torrents | Where-Object {
    $_.state -in @("stalledDL", "queuedDL") -and
    $_.progress -eq 0 -and
    $_.num_seeds -eq 0 -and
    ($now - $_.added_on) -gt ($StalledDeadHours * 3600)
}

if ($stalled.Count -eq 0) {
    Write-Host "  None." -ForegroundColor Green
} else {
    Write-Host "  These may be seasonal or dead releases. Delete from qBittorrent" -ForegroundColor Yellow
    Write-Host "  to let Radarr/Sonarr re-search for a working release." -ForegroundColor Yellow
    foreach ($t in $stalled) {
        $ageH = [math]::Round(($now - $t.added_on) / 3600, 0)
        Write-Host "  STALLED [$($t.category)] ${ageH}h -- $($t.name)" -ForegroundColor Yellow
    }
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Dead metaDL cleaned : $($deadMeta.Count)"   -ForegroundColor $(if ($deadMeta.Count -gt 0)     { "Yellow" } else { "Green" })
Write-Host "  Dangerous files     : $($dangerousFound.Count)" -ForegroundColor $(if ($dangerousFound.Count -gt 0) { "Red"    } else { "Green" })
Write-Host "  Stalled 0% (review) : $($stalled.Count)"   -ForegroundColor $(if ($stalled.Count -gt 0)      { "Yellow" } else { "Green" })
if ($DryRun -and ($deadMeta.Count -gt 0 -or $dangerousFound.Count -gt 0)) {
    Write-Host ""
    Write-Host "  Re-run with -DryRun:`$false to apply fixes." -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan
