<#
.SYNOPSIS
    Requeue Tdarr files in Universal libraries only.

.DESCRIPTION
    Clears Tdarr's TranscodeDecisionMaker state for selected files so the next
    scanFresh re-evaluates them with the current Universal flow.

    Scope is intentionally limited to:
      Movies: rUP5cniqB (/data/movies)
      TV:     nw7PJBmiV (/data/tv)

    This script never touches torrent/source archive paths and never touches
    future Premium 4K libraries.

.PARAMETER ErroredOnly
    Reset only files currently marked "Transcode error". This is the default.

.PARAMETER All
    Reset every previously evaluated Universal-library file. This can requeue a
    lot of work, so it requires -ConfirmAll.

.PARAMETER ConfirmAll
    Required with -All to make large resets explicit.

.PARAMETER DryRun
    Show how many files would be reset without changing the Tdarr database.
#>

param(
    [switch]$ErroredOnly,
    [switch]$All,
    [switch]$ConfirmAll,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$Tdarr       = "http://localhost:8265"
$Docker      = "docker.exe"
$Db          = "$StackDir\config\tdarr\server\Tdarr\DB2\SQL\database.db"

$UniversalLibraries = @(
    @{ id = "rUP5cniqB"; path = "/data/movies"; name = "Movies" },
    @{ id = "nw7PJBmiV"; path = "/data/tv";     name = "TV"     }
)

if (-not $ErroredOnly -and -not $All) {
    $ErroredOnly = $true
}

if ($All -and -not $ConfirmAll) {
    Write-Host "ERROR: -All requires -ConfirmAll." -ForegroundColor Red
    Write-Host "Use -ErroredOnly for the safe default, or add -ConfirmAll for a full Universal reset." -ForegroundColor Yellow
    exit 1
}

function Get-Sqlite3 {
    $sqlite3 = (Get-ChildItem "$env:TEMP\sqlite3" -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    if (-not $sqlite3) {
        Write-Host "Downloading sqlite3..." -ForegroundColor Gray
        $zip  = "$env:TEMP\sqlite-tools.zip"
        $dest = "$env:TEMP\sqlite3"
        Invoke-WebRequest "https://www.sqlite.org/2024/sqlite-tools-win-x64-3470200.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $dest -Force
        $sqlite3 = (Get-ChildItem $dest -Recurse -Filter "sqlite3.exe" | Select-Object -First 1).FullName
    }
    return $sqlite3
}

$where = "db IN ('rUP5cniqB', 'nw7PJBmiV')"
if ($ErroredOnly) {
    $where += " AND json_extract(json_data,'$.TranscodeDecisionMaker') = 'Transcode error'"
} else {
    $where += " AND json_extract(json_data,'$.TranscodeDecisionMaker') != ''"
}

$sqlite3 = Get-Sqlite3

$countSql = "SELECT count(*) FROM filejsondb WHERE $where;"
$countRaw = & $sqlite3 $Db $countSql 2>&1
if ($LASTEXITCODE -ne 0 -or -not (($countRaw | Select-Object -First 1) -match '^\d+$')) {
    Write-Host "ERROR: Could not query Tdarr database with sqlite3." -ForegroundColor Red
    Write-Host ($countRaw | Out-String) -ForegroundColor Red
    exit 1
}
$count = [int]($countRaw | Select-Object -First 1)

Write-Host ""
Write-Host "Tdarr Universal Reset" -ForegroundColor Cyan
Write-Host "  Mode  : $(if ($All) { 'All previously evaluated Universal files' } else { 'Errored Universal files only' })"
Write-Host "  Count : $count"

if ($DryRun) {
    Write-Host "  Dry run only; no database changes made." -ForegroundColor Yellow
    exit 0
}

if ($count -eq 0) {
    Write-Host "  Nothing to reset." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Stopping Tdarr..." -ForegroundColor Cyan
$stopOut = & $Docker compose -f $ComposeFile stop tdarr 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: docker compose stop returned exit $LASTEXITCODE (continuing)" -ForegroundColor DarkYellow
}

$sqlFile = "$env:TEMP\tdarr-reset-universal.sql"
[System.IO.File]::WriteAllText($sqlFile, @"
UPDATE filejsondb
SET json_data = json_set(json_data, '$.TranscodeDecisionMaker', '', '$.lastTranscodeDate', 0)
WHERE $where;

SELECT 'Files reset: ' || changes();
"@, [System.Text.UTF8Encoding]::new($false))

try {
    & $sqlite3 $Db ".read $sqlFile"
} finally {
    Write-Host "Starting Tdarr..." -ForegroundColor Cyan
    & $Docker compose -f $ComposeFile start tdarr 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: docker compose start returned exit $LASTEXITCODE" -ForegroundColor DarkYellow
    }
}

Start-Sleep -Seconds 12

Write-Host "Triggering fresh scans..." -ForegroundColor Cyan
foreach ($lib in $UniversalLibraries) {
    $body = "{`"data`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"scanConfig`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"arrayOrPath`":`"$($lib.path)`"}}}"
    Invoke-RestMethod -Method Post "$Tdarr/api/v2/scan-files" -Body $body -ContentType "application/json" | Out-Null
    Write-Host "  Scan triggered: $($lib.name) $($lib.path)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
