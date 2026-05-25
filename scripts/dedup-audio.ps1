<#
.SYNOPSIS
    Detect and remove duplicate audio streams from library media files.

.DESCRIPTION
    Scans media files under the configured library roots and removes audio
    streams that are exact duplicates of an earlier stream in the same file.
    A duplicate is defined as two audio streams sharing the same codec, channel
    count, and language tag. The stream with the lowest global index is kept;
    all later matches are removed via fast copy remux (no re-encoding).

    Catches any source of duplication: Tdarr flow bugs, manual ffmpeg mistakes,
    muxer errors, etc.

    Requires Jellyfin container running (uses its bundled ffprobe and ffmpeg).
    Does not require Tdarr to be running or stopped.

.PARAMETER MediaRoot
    One or more library directories containing media files. Defaults to the
    mutable library paths only:
      M:\Media\data\movies
      M:\Media\data\tv
      M:\Media\data\movies-4k
      M:\Media\data\tv-4k

    The torrent download tree is blocked by default so private tracker source
    files stay pristine.

.PARAMETER AllowTorrentPaths
    Allow scanning under M:\Media\data\torrents. Use only for deliberate manual
    repair of non-seeding files; this can break private tracker torrents.

.PARAMETER DryRun
    Report duplicates without making any changes to files.

.EXAMPLE
    # Check what would be removed without touching anything
    .\dedup-audio.ps1 -DryRun

    # Fix duplicates in library directories only
    .\dedup-audio.ps1

    # Fix a specific subtree
    .\dedup-audio.ps1 -MediaRoot "M:\Media\data\movies"
#>

param(
    [string[]]$MediaRoot = @(
        "M:\Media\data\movies",
        "M:\Media\data\tv",
        "M:\Media\data\movies-4k",
        "M:\Media\data\tv-4k"
    ),
    [switch]$DryRun,
    [switch]$AllowTorrentPaths
)

$ErrorActionPreference = "Continue"
$Docker = "docker.exe"

if ($DryRun) {
    Write-Host "[DRY RUN] No files will be modified." -ForegroundColor Yellow
}

# -- Safety guard -------------------------------------------------------------
$TorrentRoot = [System.IO.Path]::GetFullPath("M:\Media\data\torrents").TrimEnd("\") + "\"

function Test-IsUnderPath([string]$Path, [string]$Root) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    return ($full + "\").StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)
}

if (-not $AllowTorrentPaths) {
    foreach ($root in $MediaRoot) {
        if (Test-IsUnderPath $root $TorrentRoot) {
            Write-Host "ERROR: Refusing to scan torrent download path: $root" -ForegroundColor Red
            Write-Host "Torrent files must stay pristine for seeding/private trackers." -ForegroundColor Red
            Write-Host "Use library paths such as M:\Media\data\movies or pass -AllowTorrentPaths only for deliberate manual repair." -ForegroundColor Yellow
            exit 1
        }
    }
}

# -- Discover media files -----------------------------------------------------
Write-Host "Scanning media files..." -ForegroundColor Cyan
$extensions = "*.mkv", "*.mp4", "*.avi", "*.m4v", "*.ts", "*.mov"
$allFiles   = foreach ($root in $MediaRoot) {
    if (Test-Path $root) {
        Write-Host "  $root" -ForegroundColor Gray
        $extensions | ForEach-Object { Get-ChildItem $root -Recurse -Filter $_ -ErrorAction SilentlyContinue }
    }
}
$allFiles   = @($allFiles | Sort-Object FullName)
if (-not $AllowTorrentPaths) {
    $beforeFilter = $allFiles.Count
    $allFiles = @($allFiles | Where-Object { -not (Test-IsUnderPath $_.FullName $TorrentRoot) })
    $filtered = $beforeFilter - $allFiles.Count
    if ($filtered -gt 0) {
        Write-Host "  Skipped $filtered file(s) under M:\Media\data\torrents" -ForegroundColor Yellow
    }
}
Write-Host "  Found $($allFiles.Count) files" -ForegroundColor Gray

# Path helpers: Windows host <-> Jellyfin container (/data mount)
function ConvertTo-DockerPath([string]$winPath) {
    ("/" + ($winPath -replace [regex]::Escape("M:\Media\"), "") -replace "\\", "/")
}
function ConvertTo-WinPath([string]$dockerPath) {
    ("M:\Media\" + ($dockerPath.TrimStart("/") -replace "/", "\"))
}

# -- Probe and deduplicate each file ------------------------------------------
$checked      = 0
$alreadyClean = 0
$withDups     = 0
$fixed        = 0
$skipped      = @()
$failed       = @()

foreach ($file in $allFiles) {
    $checked++
    $pct        = [int](($checked / [Math]::Max($allFiles.Count, 1)) * 100)
    $leaf       = $file.Name
    $dockerPath = ConvertTo-DockerPath $file.FullName
    Write-Progress -Activity "Dedup audio" -Status "$checked/$($allFiles.Count): $leaf" -PercentComplete $pct

    # Probe all audio streams (returns global stream indices)
    $probeArgs = @("exec", "jellyfin", "/usr/lib/jellyfin-ffmpeg/ffprobe",
        "-v", "quiet", "-print_format", "json", "-show_streams", "-select_streams", "a",
        $dockerPath)
    $probeRaw = (& $Docker @probeArgs 2>$null) -join ""

    if (-not $probeRaw -or $probeRaw -notmatch '"streams"') {
        Write-Host "  SKIP (probe failed): $leaf" -ForegroundColor Yellow
        $skipped += $file.FullName
        continue
    }

    $audioStreams = ($probeRaw | ConvertFrom-Json).streams
    if (-not $audioStreams -or $audioStreams.Count -eq 0) {
        $alreadyClean++
        continue
    }

    # Build duplicate list: group by (codec, channels, language); keep lowest index per group
    $seen            = @{}  # signature -> first global index seen
    $indicesToRemove = @()

    foreach ($s in ($audioStreams | Sort-Object { [int]$_.index })) {
        $lang = if ($s.tags -and $s.tags.language) { $s.tags.language.ToLower() } else { "und" }
        $sig  = "$($s.codec_name)|$($s.channels)|$lang"

        if ($seen.ContainsKey($sig)) {
            $indicesToRemove += [int]$s.index
        } else {
            $seen[$sig] = [int]$s.index
        }
    }

    if ($indicesToRemove.Count -eq 0) {
        $alreadyClean++
        continue
    }

    $withDups++
    $removeList = $indicesToRemove -join ", "
    Write-Host "  DUP: $leaf  (stream(s) $removeList to remove)" -ForegroundColor Yellow

    # Show what's being removed
    foreach ($s in ($audioStreams | Where-Object { [int]$_.index -in $indicesToRemove })) {
        $lang = if ($s.tags -and $s.tags.language) { $s.tags.language } else { "und" }
        Write-Host "    [-] stream $($s.index): $($s.codec_name) $($s.channels)ch lang=$lang" -ForegroundColor Gray
    }

    if ($DryRun) { continue }

    # Build temp path
    $ext = $file.Extension.TrimStart(".")
    if (-not $ext) {
        Write-Host "    SKIP: cannot determine file extension" -ForegroundColor Yellow
        $failed += $file.FullName
        continue
    }
    $tempDockerPath = $dockerPath -replace "\.$ext$", ".dedup.$ext"
    $winTemp        = ConvertTo-WinPath $tempDockerPath

    # ffmpeg: copy all streams, negate duplicate indices
    $ffmpegArgs = @("exec", "jellyfin", "/usr/lib/jellyfin-ffmpeg/ffmpeg",
        "-y", "-i", $dockerPath, "-map", "0")
    foreach ($idx in $indicesToRemove) {
        $ffmpegArgs += @("-map", "-0:$idx")
    }
    $ffmpegArgs += @("-c", "copy", $tempDockerPath)

    & $Docker @ffmpegArgs 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "    ERROR: ffmpeg failed (exit $LASTEXITCODE)" -ForegroundColor Red
        $failed += $file.FullName
        continue
    }

    try {
        Move-Item $winTemp $file.FullName -Force -ErrorAction Stop
        Write-Host "    FIXED: $leaf" -ForegroundColor Green
        $fixed++
    } catch {
        Write-Host "    ERROR moving temp file: $_" -ForegroundColor Red
        $failed += $file.FullName
    }
}

Write-Progress -Activity "Dedup audio" -Completed

# -- Summary ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Files checked : $checked" -ForegroundColor Cyan
Write-Host "  Already clean : $alreadyClean" -ForegroundColor Green
Write-Host "  With dups     : $withDups" -ForegroundColor $(if ($withDups -gt 0) { "Yellow" } else { "Green" })
if (-not $DryRun) {
    Write-Host "  Fixed         : $fixed" -ForegroundColor Green
}
if ($failed.Count -gt 0) {
    Write-Host "  Fix errors    : $($failed.Count)" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
} else {
    Write-Host "  Fix errors    : 0" -ForegroundColor Green
}
if ($skipped.Count -gt 0) {
    Write-Host "  Probe skipped : $($skipped.Count) (locked/in-use files -- normal if Tdarr is running)" -ForegroundColor DarkGray
}
if ($DryRun -and $withDups -gt 0) {
    Write-Host ""
    Write-Host "  Re-run without -DryRun to apply fixes." -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan
