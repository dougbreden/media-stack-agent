<#
.SYNOPSIS
    Comprehensive state report for all media libraries.

.DESCRIPTION
    Scans every file in all library directories and reports:
      - Video codec distribution (H264, HEVC, AV1, etc.)
      - Container format distribution (MKV, MP4, etc.)
      - Resolution distribution (4K, 1080p, 720p, SD)
      - Audio codec inventory and channel counts
      - Which files are missing an AAC track (not iOS-compatible without transcoding)
      - Which files have duplicate audio streams
      - Tier standard status:
          Universal libraries: H264 + AAC, 1080p-or-lower
          Premium 4K libraries: HEVC + MKV, 4K

    Results are cached so subsequent runs only re-probe files that have changed.
    First run probes every file via Jellyfin's ffprobe (may take several minutes
    for large libraries). Subsequent runs are near-instant.

    Requires Jellyfin container running (uses its bundled ffprobe).

.PARAMETER ClearCache
    Force re-probe all files, ignoring the cache.

.EXAMPLE
    .\library-report.ps1               # Normal run (uses cache)
    .\library-report.ps1 -ClearCache   # Full re-probe
#>

param([switch]$ClearCache)

$ErrorActionPreference = "Continue"
$Docker = "docker.exe"

$Libraries = @(
    [PSCustomObject]@{ Name = "Movies";    Tier = "Universal"; Path = "M:\Media\data\movies"    },
    [PSCustomObject]@{ Name = "TV Shows";  Tier = "Universal"; Path = "M:\Media\data\tv"        },
    [PSCustomObject]@{ Name = "4K Movies"; Tier = "Premium4K";  Path = "M:\Media\data\movies-4k" },
    [PSCustomObject]@{ Name = "4K TV";     Tier = "Premium4K";  Path = "M:\Media\data\tv-4k"     }
)

$CacheFile  = "M:\Media\library-report-cache.json"
$Extensions = "*.mkv","*.mp4","*.avi","*.m4v","*.ts","*.mov"

# -- Verify Jellyfin is reachable ---------------------------------------------
$jellyfinCheck = & $Docker exec jellyfin echo "ok" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Jellyfin container not running. Start the stack first." -ForegroundColor Red
    exit 1
}

# -- Load cache ---------------------------------------------------------------
$cache = @{}
if (-not $ClearCache -and (Test-Path $CacheFile)) {
    $cacheObj = Get-Content $CacheFile -Raw | ConvertFrom-Json
    $cacheObj.PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value }
}

# -- Helpers ------------------------------------------------------------------
function ConvertTo-DockerPath([string]$winPath) {
    "/" + ($winPath -replace [regex]::Escape("M:\Media\"), "") -replace "\\", "/"
}

function Get-ResolutionLabel([int]$width) {
    if     ($width -ge 3840) { "4K"    }
    elseif ($width -ge 1920) { "1080p" }
    elseif ($width -ge 1280) { "720p"  }
    elseif ($width -gt 0)    { "SD"    }
    else                     { "?"     }
}

function Format-Size([long]$bytes) {
    if     ($bytes -ge 1TB) { "{0:N1} TB" -f ($bytes / 1TB) }
    elseif ($bytes -ge 1GB) { "{0:N1} GB" -f ($bytes / 1GB) }
    else                    { "{0:N0} MB" -f ($bytes / 1MB) }
}

function Format-Pct([int]$n, [int]$total) {
    if ($total -eq 0) { "  -  " } else { "{0,3}%" -f [int]($n * 100 / $total) }
}

function Write-Sep([char]$c = '-', [int]$width = 72) {
    Write-Host ($c.ToString() * $width) -ForegroundColor DarkGray
}

function Test-LibraryStandard($entry, [string]$tier) {
    if ($tier -eq "Premium4K") {
        return ($entry.vcodec -eq "hevc" -and
                $entry.container -eq "mkv" -and
                [int]$entry.width -ge 3840)
    }

    return ($entry.vcodec -eq "h264" -and
            $entry.has_aac -and
            [int]$entry.width -le 1920)
}

function Get-StandardLabel([string]$tier) {
    if ($tier -eq "Premium4K") { return "4K HEVC + MKV" }
    return "H264 + AAC, <=1080p"
}

# -- Discover all files -------------------------------------------------------
$allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($lib in $Libraries) {
    if (-not (Test-Path $lib.Path)) { continue }
    $Extensions | ForEach-Object {
        Get-ChildItem $lib.Path -Recurse -Filter $_ -ErrorAction SilentlyContinue | ForEach-Object { $allFiles.Add($_) }
    }
}

$totalFiles = $allFiles.Count
$probed     = 0
$fromCache  = 0
$processed  = 0

# -- Probe / cache each file --------------------------------------------------
foreach ($file in $allFiles) {
    $processed++
    $cacheKey = ($file.FullName -replace "\\", "/")
    $pct      = [int]($processed / [Math]::Max($totalFiles, 1) * 100)

    $cached = $cache[$cacheKey]
    if ($cached -and
        [long]$cached.size     -eq $file.Length -and
        $cached.modified       -eq $file.LastWriteTimeUtc.ToString("o")) {
        $fromCache++
        continue
    }

    Write-Progress -Activity "Library Report" `
        -Status "Probing $processed/$totalFiles : $($file.Name)" `
        -PercentComplete $pct

    $dockerPath = ConvertTo-DockerPath $file.FullName
    $probeArgs  = @("exec", "jellyfin", "/usr/lib/jellyfin-ffmpeg/ffprobe",
        "-v", "quiet", "-print_format", "json",
        "-show_entries", "stream=index,codec_name,codec_type,channels,width,height:stream_tags=language",
        $dockerPath)
    $probeRaw = (& $Docker @probeArgs 2>$null) -join ""

    if (-not $probeRaw -or $probeRaw -notmatch '"streams"') { continue }
    $streams = ($probeRaw | ConvertFrom-Json).streams

    $video = @($streams | Where-Object { $_.codec_type -eq "video" }) | Select-Object -First 1
    $audio = @($streams | Where-Object { $_.codec_type -eq "audio" })

    # Duplicate detection
    $seen  = @{}
    $hasDup = $false
    foreach ($s in ($audio | Sort-Object { [int]$_.index })) {
        $lang = if ($s.tags -and $s.tags.language) { $s.tags.language.ToLower() } else { "und" }
        $sig  = "$($s.codec_name)|$($s.channels)|$lang"
        if ($seen.ContainsKey($sig)) { $hasDup = $true; break }
        $seen[$sig] = 1
    }

    $entry = [PSCustomObject]@{
        size      = $file.Length
        modified  = $file.LastWriteTimeUtc.ToString("o")
        container = $file.Extension.TrimStart(".").ToLower()
        vcodec    = if ($video) { $video.codec_name } else { "unknown" }
        width     = if ($video -and $video.width)  { [int]$video.width }  else { 0 }
        height    = if ($video -and $video.height) { [int]$video.height } else { 0 }
        astreams  = @($audio | ForEach-Object {
            $lang = if ($_.tags -and $_.tags.language) { $_.tags.language.ToLower() } else { "und" }
            [PSCustomObject]@{ codec = $_.codec_name; channels = [int]$_.channels; lang = $lang }
        })
        has_aac   = [bool]($audio | Where-Object { $_.codec_name -eq "aac" })
        has_dup   = $hasDup
    }

    $cache[$cacheKey] = $entry
    $probed++
}

Write-Progress -Activity "Library Report" -Completed

# -- Prune stale cache entries (files that no longer exist on disk) -----------
$activeKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $allFiles) {
    $null = $activeKeys.Add(($file.FullName -replace "\\", "/"))
}
$staleKeys = @($cache.Keys | Where-Object { -not $activeKeys.Contains($_) })
foreach ($k in $staleKeys) { $cache.Remove($k) }
if ($staleKeys.Count -gt 0) {
    Write-Host ("  Pruned {0} stale cache entries (deleted/moved files)" -f $staleKeys.Count) -ForegroundColor DarkGray
}

# -- Save cache ---------------------------------------------------------------
$cacheOut = [PSCustomObject]@{}
foreach ($kv in $cache.GetEnumerator()) {
    $cacheOut | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force
}
[System.IO.File]::WriteAllText($CacheFile,
    ($cacheOut | ConvertTo-Json -Depth 6),
    [System.Text.UTF8Encoding]::new($false))

# -- Build per-library data ---------------------------------------------------
function Get-LibStats($libPath, $tier) {
    $keys   = $cache.Keys | Where-Object { $_ -like ($libPath -replace "\\", "/") + "/*" }
    $entries = @($keys | ForEach-Object { $cache[$_] })
    if ($entries.Count -eq 0) { return $null }

    $totalSize  = ($entries | Measure-Object -Property size -Sum).Sum

    # Video codec counts
    $vcodecs = $entries | Group-Object vcodec | Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ name = $_.Name; count = $_.Count } }

    # Container counts
    $containers = $entries | Group-Object container | Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ name = $_.Name; count = $_.Count } }

    # Resolution counts
    $resCounts = @{ "4K" = 0; "1080p" = 0; "720p" = 0; "SD" = 0; "?" = 0 }
    $entries | ForEach-Object { $resCounts[(Get-ResolutionLabel $_.width)]++ }

    # Audio codec counts (across all streams in all files)
    $acodecCounts = @{}
    foreach ($e in $entries) {
        $e.astreams | ForEach-Object {
            if (-not $acodecCounts.ContainsKey($_.codec)) { $acodecCounts[$_.codec] = 0 }
            $acodecCounts[$_.codec]++
        }
    }

    # Files missing AAC, with duplicates
    $missingAac  = @($entries | Where-Object { -not $_.has_aac })
    $hasDups     = @($entries | Where-Object { $_.has_dup })
    $standardised = @($entries | Where-Object { Test-LibraryStandard $_ $tier })
    $nonMkv      = @($entries | Where-Object { $_.container -ne "mkv" })

    return [PSCustomObject]@{
        count        = $entries.Count
        totalSize    = $totalSize
        vcodecs      = $vcodecs
        containers   = $containers
        resCounts    = $resCounts
        acodecs      = $acodecCounts
        missingAac   = $missingAac
        hasDups      = $hasDups
        standardised = $standardised
        nonMkv       = $nonMkv
    }
}

# -- Print report -------------------------------------------------------------
$W = 72
Write-Host ""
Write-Sep '=' $W
Write-Host ("  MEDIA LIBRARY REPORT  --  " + (Get-Date -Format "yyyy-MM-dd HH:mm")) -ForegroundColor Cyan
Write-Sep '=' $W
$headerLine = "  Files: {0} total  |  Probed: {1} new  |  From cache: {2}" -f $totalFiles, $probed, $fromCache
if ($staleKeys.Count -gt 0) { $headerLine += "  |  Pruned stale: $($staleKeys.Count)" }
Write-Host $headerLine -ForegroundColor Gray
Write-Host ""

$overallTotal        = 0
$overallSize         = 0
$overallStandardised = 0
$overallMissingAac   = 0
$overallDups         = 0
$overallOutOfTier    = 0

foreach ($lib in $Libraries) {
    $libPathNorm = $lib.Path -replace "\\", "/"

    Write-Sep '-' $W
    if (-not (Test-Path $lib.Path)) {
        Write-Host ("  {0,-12}  {1}" -f $lib.Name.ToUpper(), $lib.Path) -ForegroundColor DarkGray
        Write-Host "  Directory not found -- will populate when library is added." -ForegroundColor DarkGray
        Write-Host ""
        continue
    }

    $s = Get-LibStats $lib.Path $lib.Tier
    if (-not $s -or $s.count -eq 0) {
        Write-Host ("  {0,-12}  {1}  (empty)" -f $lib.Name.ToUpper(), $lib.Path) -ForegroundColor DarkGray
        Write-Host ""
        continue
    }

    $overallTotal        += $s.count
    $overallSize         += $s.totalSize
    $overallStandardised += $s.standardised.Count
    if ($lib.Tier -eq "Universal") {
        $overallMissingAac += $s.missingAac.Count
    }
    $overallDups         += $s.hasDups.Count
    $overallOutOfTier    += ($s.count - $s.standardised.Count)

    Write-Host ("  {0}  |  {1} files  |  {2}" -f `
        $lib.Name.ToUpper(), $s.count, (Format-Size $s.totalSize)) -ForegroundColor White
    Write-Host ("  Tier: {0} ({1})" -f $lib.Tier, (Get-StandardLabel $lib.Tier)) -ForegroundColor Gray
    Write-Host "  $($lib.Path)" -ForegroundColor DarkGray
    Write-Host ""

    # Video codec
    Write-Host "  Video Codec" -ForegroundColor Cyan
    $s.vcodecs | ForEach-Object {
        $bar = "#" * [int]($_.count / $s.count * 30)
        Write-Host ("    {0,-10} {1,4}  {2}  {3}" -f `
            $_.name, $_.count, (Format-Pct $_.count $s.count), $bar)
    }

    # Container
    Write-Host ""
    Write-Host "  Container" -ForegroundColor Cyan
    $s.containers | ForEach-Object {
        Write-Host ("    {0,-8} {1,4}  {2}" -f $_.name, $_.count, (Format-Pct $_.count $s.count))
    }

    # Resolution
    Write-Host ""
    Write-Host "  Resolution" -ForegroundColor Cyan
    foreach ($r in "4K","1080p","720p","SD","?") {
        $n = $s.resCounts[$r]
        if ($n -gt 0) {
            Write-Host ("    {0,-8} {1,4}  {2}" -f $r, $n, (Format-Pct $n $s.count))
        }
    }

    # Audio
    Write-Host ""
    Write-Host "  Audio Codecs (stream count across all files)" -ForegroundColor Cyan
    $s.acodecs.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        Write-Host ("    {0,-10} {1,4} streams" -f $_.Key, $_.Value)
    }

    Write-Host ""
    Write-Host "  Audio Health" -ForegroundColor Cyan
    $dupColor = if ($s.hasDups.Count -gt 0) { "Yellow" } else { "Green" }
    if ($lib.Tier -eq "Universal") {
        $aacColor = if ($s.missingAac.Count -gt 0) { "Yellow" } else { "Green" }
        Write-Host ("    Has AAC (iOS-ok)  : {0} / {1}  {2}" -f `
            ($s.count - $s.missingAac.Count), $s.count, (Format-Pct ($s.count - $s.missingAac.Count) $s.count))
        Write-Host ("    Missing AAC       : {0}" -f $s.missingAac.Count) -ForegroundColor $aacColor
    } else {
        Write-Host "    AAC not required  : Premium 4K is direct-play only" -ForegroundColor DarkGray
    }
    Write-Host ("    Duplicate streams : {0}" -f $s.hasDups.Count) -ForegroundColor $dupColor

    if ($lib.Tier -eq "Universal" -and $s.missingAac.Count -gt 0 -and $s.missingAac.Count -le 20) {
        $missingPaths = $cache.Keys |
            Where-Object { $_ -like "$libPathNorm/*" -and -not $cache[$_].has_aac } |
            ForEach-Object { Split-Path ($_ -replace "/", "\") -Leaf }
        $missingPaths | Sort-Object | ForEach-Object { Write-Host "      - $_" -ForegroundColor Yellow }
    } elseif ($lib.Tier -eq "Universal" -and $s.missingAac.Count -gt 20) {
        Write-Host "      (run with -Verbose to list all)" -ForegroundColor DarkGray
    }

    if ($s.hasDups.Count -gt 0 -and $s.hasDups.Count -le 20) {
        $dupPaths = $cache.Keys |
            Where-Object { $_ -like "$libPathNorm/*" -and $cache[$_].has_dup } |
            ForEach-Object { Split-Path ($_ -replace "/", "\") -Leaf }
        $dupPaths | Sort-Object | ForEach-Object { Write-Host "      - $_" -ForegroundColor Yellow }
    }

    # Standardisation
    Write-Host ""
    Write-Host ("  Tier Standard ({0})" -f (Get-StandardLabel $lib.Tier)) -ForegroundColor Cyan
    $stdColor = if ($s.standardised.Count -eq $s.count) { "Green" } else { "Yellow" }
    Write-Host ("    Matches      : {0} / {1}  {2}" -f `
        $s.standardised.Count, $s.count, (Format-Pct $s.standardised.Count $s.count)) -ForegroundColor $stdColor
    $needsConv = $s.count - $s.standardised.Count
    if ($needsConv -gt 0) {
        $label = if ($lib.Tier -eq "Premium4K") { "Review" } else { "Needs Tdarr" }
        Write-Host ("    {0,-12} : {1} / {2}  {3}" -f `
            $label,
            $needsConv, $s.count, (Format-Pct $needsConv $s.count)) -ForegroundColor Yellow
    }

    if ($lib.Tier -eq "Universal" -and $s.nonMkv.Count -gt 0) {
        Write-Host ("    Non-MKV      : {0}" -f $s.nonMkv.Count) -ForegroundColor Yellow
    }

    Write-Host ""
}

# -- Overall summary ----------------------------------------------------------
Write-Sep '=' $W
Write-Host "  OVERALL SUMMARY" -ForegroundColor Cyan
Write-Sep '-' $W
if ($overallTotal -gt 0) {
    Write-Host ("  Total files      : {0}  ({1})" -f $overallTotal, (Format-Size $overallSize))
    Write-Host ("  Matches tier     : {0} / {1}  {2}" -f `
        $overallStandardised, $overallTotal, (Format-Pct $overallStandardised $overallTotal)) `
        -ForegroundColor $(if ($overallStandardised -eq $overallTotal) { "Green" } else { "Yellow" })
    Write-Host ("  Universal missing AAC : {0}" -f $overallMissingAac) `
        -ForegroundColor $(if ($overallMissingAac -eq 0) { "Green" } else { "Yellow" })
    Write-Host ("  Duplicate audio  : {0}" -f $overallDups) `
        -ForegroundColor $(if ($overallDups -eq 0) { "Green" } else { "Yellow" })
    Write-Host ("  Out of tier      : {0}" -f $overallOutOfTier) `
        -ForegroundColor $(if ($overallOutOfTier -eq 0) { "Green" } else { "Yellow" })
} else {
    Write-Host "  No media files found in any library." -ForegroundColor Yellow
}
Write-Sep '=' $W
Write-Host ""
if ($probed -gt 0) {
    Write-Host "  Cache updated: $CacheFile" -ForegroundColor DarkGray
}
