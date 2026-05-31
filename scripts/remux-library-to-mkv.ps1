<#
.SYNOPSIS
    Remux library media files to MKV without re-encoding.

.DESCRIPTION
    Converts non-MKV files in mutable library paths to MKV using stream copy:
      ffmpeg -map 0 -c copy

    This is a container migration only. Video/audio/subtitle streams are not
    re-encoded. The default mode is read-only; pass -Apply to modify files.

    By default, only Universal libraries are scanned:
      M:\Media\data\movies
      M:\Media\data\tv

    The torrent/source archive is blocked unless -AllowTorrentPaths is passed.
    Premium 4K libraries are skipped unless -IncludePremium4K is passed.

.PARAMETER Apply
    Actually remux files. Without this switch the script only reports candidates.

.PARAMETER IncludePremium4K
    Include M:\Media\data\movies-4k and M:\Media\data\tv-4k.

.PARAMETER MediaRoot
    Override the default library roots.

.PARAMETER AllowTorrentPaths
    Allow scanning under M:\Media\data\torrents. Use only for deliberate manual
    repair of non-seeding files; this can break private tracker torrents.
#>

param(
    [switch]$Apply,
    [switch]$IncludePremium4K,
    [string[]]$MediaRoot,
    [switch]$AllowTorrentPaths
)

$ErrorActionPreference = "Continue"
$Docker = "docker.exe"
$StackRoot = "M:\Media"
$TorrentRoot = [System.IO.Path]::GetFullPath("$StackRoot\data\torrents").TrimEnd("\") + "\"

if (-not $MediaRoot -or $MediaRoot.Count -eq 0) {
    $MediaRoot = @(
        "$StackRoot\data\movies",
        "$StackRoot\data\tv"
    )

    if ($IncludePremium4K) {
        $MediaRoot += @(
            "$StackRoot\data\movies-4k",
            "$StackRoot\data\tv-4k"
        )
    }
}

function Test-IsUnderPath([string]$Path, [string]$Root) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    return ($full + "\").StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-DockerPath([string]$winPath) {
    ("/" + ($winPath -replace [regex]::Escape("M:\Media\"), "") -replace "\\", "/")
}

function ConvertTo-WinPath([string]$dockerPath) {
    ("M:\Media\" + ($dockerPath.TrimStart("/") -replace "/", "\"))
}

foreach ($root in $MediaRoot) {
    if (-not $AllowTorrentPaths -and (Test-IsUnderPath $root $TorrentRoot)) {
        Write-Host "ERROR: Refusing to scan torrent download path: $root" -ForegroundColor Red
        Write-Host "Torrent files must stay pristine for seeding/private trackers." -ForegroundColor Red
        exit 1
    }
}

if (-not $Apply) {
    Write-Host "[DRY RUN] No files will be modified. Re-run with -Apply to remux." -ForegroundColor Yellow
}

$jellyfinCheck = & $Docker exec jellyfin echo "ok" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Jellyfin container not running. Start the stack first." -ForegroundColor Red
    exit 1
}

$extensions = "*.mp4", "*.m4v", "*.avi", "*.ts", "*.mov", "*.webm", "*.wmv", "*.mpg", "*.mpeg", "*.m2ts"
$allFiles = foreach ($root in $MediaRoot) {
    if (Test-Path $root) {
        Write-Host "Scanning $root" -ForegroundColor Cyan
        $extensions | ForEach-Object { Get-ChildItem $root -Recurse -Filter $_ -ErrorAction SilentlyContinue }
    }
}

$candidates = @($allFiles | Sort-Object FullName | Where-Object {
    $_.Extension.ToLowerInvariant() -ne ".mkv" -and
    ($AllowTorrentPaths -or -not (Test-IsUnderPath $_.FullName $TorrentRoot))
})

Write-Host ""
Write-Host "MKV remux candidates: $($candidates.Count)" -ForegroundColor Cyan

$checked = 0
$remuxed = 0
$skipped = 0
$failed = @()

foreach ($file in $candidates) {
    $checked++
    $pct = [int](($checked / [Math]::Max($candidates.Count, 1)) * 100)
    Write-Progress -Activity "Remux to MKV" -Status "$checked/$($candidates.Count): $($file.Name)" -PercentComplete $pct

    $target = [System.IO.Path]::ChangeExtension($file.FullName, ".mkv")
    if (Test-Path -LiteralPath $target) {
        Write-Host "  SKIP target exists: $target" -ForegroundColor Yellow
        $skipped++
        continue
    }

    Write-Host "  $($file.FullName)" -ForegroundColor Gray
    if (-not $Apply) { continue }

    $dockerInput = ConvertTo-DockerPath $file.FullName
    $dockerTemp = ConvertTo-DockerPath ([System.IO.Path]::ChangeExtension($file.FullName, ".remuxing.mkv"))
    $winTemp = ConvertTo-WinPath $dockerTemp

    # If a valid temp file already exists from a previous run, skip ffmpeg
    if (-not (Test-Path -LiteralPath $winTemp)) {
        $ffmpegArgs = @(
            "exec", "jellyfin", "/usr/lib/jellyfin-ffmpeg/ffmpeg",
            "-y", "-i", $dockerInput,
            "-map", "0",
            "-map", "-0:d",          # exclude data streams (gpmd/timecode/bin_data -- not MKV-compatible)
            "-c", "copy",
            $dockerTemp
        )
        & $Docker @ffmpegArgs 2>$null | Out-Null
    }

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $winTemp)) {
        Write-Host "    ERROR: ffmpeg remux failed" -ForegroundColor Red
        Remove-Item -LiteralPath $winTemp -ErrorAction SilentlyContinue
        $failed += $file.FullName
        continue
    }

    try {
        Move-Item -LiteralPath $winTemp -Destination $target -Force -ErrorAction Stop
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        Write-Host "    REMUXED: $target" -ForegroundColor Green
        $remuxed++
    } catch {
        Write-Host "    ERROR replacing file: $_" -ForegroundColor Red
        $failed += $file.FullName
    }
}

Write-Progress -Activity "Remux to MKV" -Completed

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Candidates : $($candidates.Count)"
Write-Host "  Skipped    : $skipped"
if ($Apply) {
    Write-Host "  Remuxed    : $remuxed" -ForegroundColor Green
    Write-Host "  Failed     : $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Red" })
} else {
    Write-Host "  Dry run    : re-run with -Apply to remux" -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan

if ($failed.Count -gt 0) { exit 1 }
