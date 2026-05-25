<#
.SYNOPSIS
    Validate media library boundaries for Tdarr and private tracker safety.

.DESCRIPTION
    Read-only policy check for the long-term media layout:
      - Torrent downloads/source archive stay under M:\Media\data\torrents
      - Universal mutable libraries are M:\Media\data\movies and M:\Media\data\tv
      - Premium 4K libraries, if present, are separate and direct-play only
      - Tdarr only mounts universal mutable libraries, never torrents or 4K
      - qBittorrent private categories save into the torrent archive
#>

$ErrorActionPreference = "Continue"

$StackDir       = "M:\Media"
$ComposeFile    = "$StackDir\docker-compose.yml"
$CategoriesFile = "$StackDir\config\qbittorrent\qBittorrent\categories.json"
$Failures       = @()
$Warnings       = @()

function Write-OK   { param($msg) Write-Host "  OK   $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  WARN $msg" -ForegroundColor Yellow; $script:Warnings += $msg }
function Write-Fail { param($msg) Write-Host "  FAIL $msg" -ForegroundColor Red; $script:Failures += $msg }

function Get-ServiceBlock([string]$Content, [string]$ServiceName) {
    $pattern = "(?ms)^  $([regex]::Escape($ServiceName)):\r?\n(?<block>.*?)(?=^  [A-Za-z0-9_-]+:\r?\n|\z)"
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) { return $match.Groups["block"].Value }
    return $null
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Media Policy Check" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# -- Directory layout ---------------------------------------------------------
Write-Host "`n[1/4] Directory layout" -ForegroundColor Cyan
foreach ($path in @(
    "$StackDir\data\torrents",
    "$StackDir\data\movies",
    "$StackDir\data\tv"
)) {
    if (Test-Path $path) { Write-OK $path } else { Write-Fail "Missing required path: $path" }
}

foreach ($path in @(
    "$StackDir\data\movies-4k",
    "$StackDir\data\tv-4k"
)) {
    if (Test-Path $path) { Write-OK "$path (premium library)" } else { Write-Warn "$path not present yet (fine until premium 4K is added)" }
}

# -- Tdarr compose mounts -----------------------------------------------------
Write-Host "`n[2/4] Tdarr mounts" -ForegroundColor Cyan
if (-not (Test-Path $ComposeFile)) {
    Write-Fail "Missing compose file: $ComposeFile"
} else {
    $compose = Get-Content $ComposeFile -Raw
    $tdarr = Get-ServiceBlock $compose "tdarr"

    if (-not $tdarr) {
        Write-Fail "Could not find tdarr service in docker-compose.yml"
    } else {
        if ($tdarr -match "M:/Media/data/movies:/data/movies") { Write-OK "Tdarr mounts universal Movies library" } else { Write-Fail "Tdarr missing /data/movies mount" }
        if ($tdarr -match "M:/Media/data/tv:/data/tv") { Write-OK "Tdarr mounts universal TV library" } else { Write-Fail "Tdarr missing /data/tv mount" }

        if ($tdarr -match "data/torrents|/data/torrents") {
            Write-Fail "Tdarr must not mount the torrent/source archive"
        } else {
            Write-OK "Tdarr does not mount torrent/source archive"
        }

        if ($tdarr -match "movies-4k|tv-4k") {
            Write-Fail "Tdarr universal flow must not mount premium 4K libraries"
        } else {
            Write-OK "Tdarr does not mount premium 4K libraries"
        }

        if ($tdarr -match "M:/Media/data:/data") {
            Write-Fail "Tdarr must not mount the whole data tree"
        } else {
            Write-OK "Tdarr does not mount the whole data tree"
        }
    }
}

# -- qBittorrent private categories ------------------------------------------
Write-Host "`n[3/4] qBittorrent private categories" -ForegroundColor Cyan
if (-not (Test-Path $CategoriesFile)) {
    Write-Warn "Missing categories file: $CategoriesFile"
} else {
    try {
        $categories = Get-Content $CategoriesFile -Raw | ConvertFrom-Json
        $expected = @{
            "movies-private" = "/data/torrents/movies"
            "tv-private"     = "/data/torrents/tv"
        }

        foreach ($name in $expected.Keys) {
            $category = $categories.PSObject.Properties[$name].Value
            if (-not $category) {
                Write-Warn "Missing qBittorrent category: $name"
                continue
            }

            if ($category.save_path -eq $expected[$name]) {
                Write-OK "$name saves to $($category.save_path)"
            } elseif ($category.save_path -like "/data/torrents*") {
                Write-Warn "$name saves to $($category.save_path), expected $($expected[$name])"
            } else {
                Write-Fail "$name must save under /data/torrents, not $($category.save_path)"
            }
        }
    } catch {
        Write-Fail "Could not parse qBittorrent categories.json: $_"
    }
}

# -- Script guardrails --------------------------------------------------------
Write-Host "`n[4/4] Script guardrails" -ForegroundColor Cyan
$dedupScript = "$StackDir\scripts\dedup-audio.ps1"
$deployScript = "$StackDir\scripts\tdarr-deploy-universal-flow.ps1"
$resetScript = "$StackDir\scripts\tdarr-reset-universal-files.ps1"
$remuxScript = "$StackDir\scripts\remux-library-to-mkv.ps1"

if ((Test-Path $dedupScript) -and ((Get-Content $dedupScript -Raw) -match "AllowTorrentPaths")) {
    Write-OK "dedup-audio.ps1 has explicit torrent-path override guard"
} else {
    Write-Fail "dedup-audio.ps1 is missing torrent-path guard"
}

if ((Test-Path $deployScript) -and ((Get-Content $deployScript -Raw) -match "rUP5cniqB" -and (Get-Content $deployScript -Raw) -match "nw7PJBmiV")) {
    Write-OK "tdarr-deploy-universal-flow.ps1 scopes work to universal library IDs"
} else {
    Write-Fail "tdarr-deploy-universal-flow.ps1 does not appear scoped to universal library IDs"
}

if ((Test-Path $resetScript) -and ((Get-Content $resetScript -Raw) -match "ConfirmAll" -and (Get-Content $resetScript -Raw) -match "db IN \('rUP5cniqB', 'nw7PJBmiV'\)")) {
    Write-OK "tdarr-reset-universal-files.ps1 requires explicit full-reset confirmation"
} else {
    Write-Fail "tdarr-reset-universal-files.ps1 is missing scoped reset guardrails"
}

if ((Test-Path $remuxScript) -and ((Get-Content $remuxScript -Raw) -match "AllowTorrentPaths" -and (Get-Content $remuxScript -Raw) -match "Apply")) {
    Write-OK "remux-library-to-mkv.ps1 defaults to guarded dry-run mode"
} else {
    Write-Fail "remux-library-to-mkv.ps1 is missing dry-run/torrent guardrails"
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
if ($Failures.Count -eq 0) {
    Write-Host "  Policy check passed" -ForegroundColor Green
} else {
    Write-Host "  Policy check failed with $($Failures.Count) issue(s)" -ForegroundColor Red
}
if ($Warnings.Count -gt 0) {
    Write-Host "  Warnings: $($Warnings.Count)" -ForegroundColor Yellow
}
Write-Host "==========================================" -ForegroundColor Cyan

if ($Failures.Count -gt 0) { exit 1 }
