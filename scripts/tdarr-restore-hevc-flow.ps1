<#
.SYNOPSIS
    Phase 2 of the AAC backfill: upgrade the main flow to Universal H264+AAC,
    revert libraries to it, and re-queue all HEVC files.

.DESCRIPTION
    Run this AFTER the "Add AAC to H264" pass is complete (queue empty, worker idle).

    What it does:
      1. Stops Tdarr
      2. Upgrades N7tOvfd6i to the comprehensive "Universal H264+AAC" flow:
             - H264 + already has AAC  -> Not required
             - H264 + no AAC           -> copy video + add AAC stereo track
             - non-H264 (HEVC/AV1/...) + has AAC -> GPU encode to H264
             - non-H264 + no AAC       -> GPU encode to H264 + add AAC stereo track
      3. Reverts both library flowIds back to N7tOvfd6i
      4. Deletes the temporary AddAACH264x flow
      5. Restarts Tdarr
      6. Resets HEVC files (marked Not required during Phase 1) for re-processing
      7. Triggers a fresh scan on both libraries

    After this script, every new download is automatically standardised to
    H264 + AAC regardless of original codec, with no duplicate AAC tracks added.
#>

$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$Tdarr       = "http://localhost:8265"

# -- Step 1: Stop Tdarr -------------------------------------------------------
Write-Host "[1/6] Stopping Tdarr..." -ForegroundColor Cyan
docker compose -f $ComposeFile stop tdarr 2>&1 | Out-Null
Write-Host "  Stopped" -ForegroundColor Green

# -- Step 2: Locate sqlite3 (download if session was rebooted) ----------------
Write-Host "[2/6] Locating sqlite3..." -ForegroundColor Cyan
$sqlite3 = (Get-ChildItem "$env:TEMP\sqlite3" -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue).FullName
if (-not $sqlite3) {
    Write-Host "  Downloading sqlite3..." -ForegroundColor Gray
    $zip  = "$env:TEMP\sqlite-tools.zip"
    $dest = "$env:TEMP\sqlite3"
    Invoke-WebRequest "https://www.sqlite.org/2024/sqlite-tools-win-x64-3470200.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $dest -Force
    $sqlite3 = (Get-ChildItem $dest -Recurse -Filter "sqlite3.exe").FullName
}
Write-Host "  sqlite3 at $sqlite3" -ForegroundColor Green

$db = "$StackDir\config\tdarr\server\Tdarr\DB2\SQL\database.db"

# -- Step 3: Update main flow + revert libraries + delete temp flow -----------
Write-Host "[3/6] Updating Tdarr flow and library settings in SQLite..." -ForegroundColor Cyan

[System.IO.File]::WriteAllText("$env:TEMP\restore.sql", @'
UPDATE flowsjsondb
SET json_data = '{"_id":"N7tOvfd6i","name":"Universal H264+AAC","priority":0,"flowPlugins":[{"id":"n_input","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":50,"x":500},"pluginName":"inputFile","version":"1.0.0"},{"id":"n_vcheck","sourceRepo":"Community","inputs":{"codec":"h264"},"inputsDB":{"codec":"h264"},"position":{"y":180,"x":500},"pluginName":"checkVideoCodec","version":"1.0.0"},{"id":"n_acheck1","sourceRepo":"Community","inputs":{"codec":"aac","checkBitrate":"false","greaterThan":"50000","lessThan":"1000000"},"inputsDB":{"codec":"aac","checkBitrate":"false","greaterThan":"50000","lessThan":"1000000"},"position":{"y":320,"x":800},"pluginName":"checkAudioCodec","version":"1.0.0"},{"id":"n_start1","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":460,"x":800},"pluginName":"ffmpegCommandStart","version":"1.0.0"},{"id":"n_enc1","sourceRepo":"Community","inputs":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"false","hardwareDecoding":"false","forceEncoding":"false","ffmpegPresetEnabled":"false","ffmpegQualityEnabled":"false"},"inputsDB":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"false","hardwareDecoding":"false","forceEncoding":"false","ffmpegPresetEnabled":"false","ffmpegQualityEnabled":"false"},"position":{"y":580,"x":800},"pluginName":"ffmpegCommandSetVideoEncoder","version":"1.0.0"},{"id":"n_args1","sourceRepo":"Community","inputs":{"inputArguments":"","outputArguments":"-map 0:1 -c:2 aac -ac 2 -b:a 192k"},"inputsDB":{"inputArguments":"","outputArguments":"-map 0:1 -c:2 aac -ac 2 -b:a 192k"},"position":{"y":700,"x":800},"pluginName":"ffmpegCommandCustomArguments","version":"1.0.0"},{"id":"n_exec1","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":820,"x":800},"pluginName":"ffmpegCommandExecute","version":"1.0.0"},{"id":"n_start2","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":320,"x":200},"pluginName":"ffmpegCommandStart","version":"1.0.0"},{"id":"n_enc2","sourceRepo":"Community","inputs":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"true","hardwareDecoding":"false","forceEncoding":"true","ffmpegPresetEnabled":"true","ffmpegPreset":"fast","ffmpegQualityEnabled":"true","ffmpegQuality":"20"},"inputsDB":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"true","hardwareDecoding":"false","forceEncoding":"true","ffmpegPresetEnabled":"true","ffmpegPreset":"fast","ffmpegQualityEnabled":"true","ffmpegQuality":"20"},"position":{"y":460,"x":200},"pluginName":"ffmpegCommandSetVideoEncoder","version":"1.0.0"},{"id":"n_acheck2","sourceRepo":"Community","inputs":{"codec":"aac","checkBitrate":"false","greaterThan":"50000","lessThan":"1000000"},"inputsDB":{"codec":"aac","checkBitrate":"false","greaterThan":"50000","lessThan":"1000000"},"position":{"y":580,"x":200},"pluginName":"checkAudioCodec","version":"1.0.0"},{"id":"n_args2a","sourceRepo":"Community","inputs":{"inputArguments":"","outputArguments":"-pix_fmt yuv420p"},"inputsDB":{"inputArguments":"","outputArguments":"-pix_fmt yuv420p"},"position":{"y":700,"x":50},"pluginName":"ffmpegCommandCustomArguments","version":"1.0.0"},{"id":"n_exec2a","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":820,"x":50},"pluginName":"ffmpegCommandExecute","version":"1.0.0"},{"id":"n_args2b","sourceRepo":"Community","inputs":{"inputArguments":"","outputArguments":"-map 0:1 -c:2 aac -ac 2 -b:a 192k -pix_fmt yuv420p"},"inputsDB":{"inputArguments":"","outputArguments":"-map 0:1 -c:2 aac -ac 2 -b:a 192k -pix_fmt yuv420p"},"position":{"y":700,"x":350},"pluginName":"ffmpegCommandCustomArguments","version":"1.0.0"},{"id":"n_exec2b","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":820,"x":350},"pluginName":"ffmpegCommandExecute","version":"1.0.0"},{"id":"n_replace","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":960,"x":500},"pluginName":"replaceOriginalFile","version":"1.0.0"}],"flowEdges":[{"target":"n_vcheck","source":"n_input","id":"e1","targetHandle":null,"sourceHandle":"1"},{"target":"n_acheck1","source":"n_vcheck","id":"e2","targetHandle":null,"sourceHandle":"1"},{"target":"n_start2","source":"n_vcheck","id":"e3","targetHandle":null,"sourceHandle":"2"},{"target":"n_replace","source":"n_acheck1","id":"e4","targetHandle":null,"sourceHandle":"1"},{"target":"n_start1","source":"n_acheck1","id":"e5","targetHandle":null,"sourceHandle":"2"},{"target":"n_enc1","source":"n_start1","id":"e6","targetHandle":null,"sourceHandle":"1"},{"target":"n_args1","source":"n_enc1","id":"e7","targetHandle":null,"sourceHandle":"1"},{"target":"n_exec1","source":"n_args1","id":"e8","targetHandle":null,"sourceHandle":"1"},{"target":"n_replace","source":"n_exec1","id":"e9","targetHandle":null,"sourceHandle":"1"},{"target":"n_enc2","source":"n_start2","id":"e10","targetHandle":null,"sourceHandle":"1"},{"target":"n_acheck2","source":"n_enc2","id":"e11","targetHandle":null,"sourceHandle":"1"},{"target":"n_args2a","source":"n_acheck2","id":"e12","targetHandle":null,"sourceHandle":"1"},{"target":"n_args2b","source":"n_acheck2","id":"e13","targetHandle":null,"sourceHandle":"2"},{"target":"n_exec2a","source":"n_args2a","id":"e14","targetHandle":null,"sourceHandle":"1"},{"target":"n_exec2b","source":"n_args2b","id":"e15","targetHandle":null,"sourceHandle":"1"},{"target":"n_replace","source":"n_exec2a","id":"e16","targetHandle":null,"sourceHandle":"1"},{"target":"n_replace","source":"n_exec2b","id":"e17","targetHandle":null,"sourceHandle":"1"}],"isUiLocked":false}',
    timestamp = strftime('%s','now')*1000
WHERE id = 'N7tOvfd6i';

UPDATE librarysettingsjsondb
SET json_data = json_set(json_data, '$.flowId', 'N7tOvfd6i'),
    timestamp = strftime('%s','now')*1000;

DELETE FROM flowsjsondb WHERE id = 'AddAACH264x';

SELECT 'flow:', id, json_extract(json_data,'$.name') FROM flowsjsondb;
SELECT 'lib:', id, json_extract(json_data,'$.flowId') FROM librarysettingsjsondb;
'@, [System.Text.UTF8Encoding]::new($false))

& $sqlite3 $db ".read $env:TEMP\restore.sql"
Write-Host "  Done" -ForegroundColor Green

# -- Step 4: Start Tdarr ------------------------------------------------------
Write-Host "[4/6] Starting Tdarr..." -ForegroundColor Cyan
docker compose -f $ComposeFile start tdarr 2>&1 | Out-Null
Start-Sleep -Seconds 12
Write-Host "  Started" -ForegroundColor Green

# -- Step 5: Reset all files that need reprocessing ---------------------------
# Resets:
#   - "Not required" -- was skipped by AddAACH264x (HEVC, AV1, etc.)
#   - "Transcode error" -- failed jobs that need a retry
# Does NOT reset "Transcode success" (H264+AAC from Phase 1 are already correct).
Write-Host "[5/6] Resetting files for re-processing..." -ForegroundColor Cyan

[System.IO.File]::WriteAllText("$env:TEMP\getids.sql", @'
SELECT json_extract(json_data,'$._id')
FROM filejsondb
WHERE json_extract(json_data,'$.TranscodeDecisionMaker') IN ('Not required','Transcode error');
'@, [System.Text.UTF8Encoding]::new($false))

$resetIds = & $sqlite3 $db ".read $env:TEMP\getids.sql"
Write-Host "  Found $($resetIds.Count) files to reset" -ForegroundColor Gray

if ($resetIds.Count -gt 0) {
    $idsJson = ($resetIds | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ","
    $body = "{`"data`":{`"fileIds`":[$idsJson],`"updatedObj`":{`"TranscodeDecisionMaker`":`"`",`"lastTranscodeDate`":0}}}"
    $r = Invoke-RestMethod -Method Post "$Tdarr/api/v2/bulk-update-files" -Body $body -ContentType "application/json"
    Write-Host "  Reset complete: $($r | ConvertTo-Json -Compress)" -ForegroundColor Green
} else {
    Write-Host "  No files to reset" -ForegroundColor Yellow
}

# -- Step 6: Trigger fresh scan -----------------------------------------------
Write-Host "[6/6] Triggering fresh scan on both libraries..." -ForegroundColor Cyan
foreach ($lib in @(@{id="rUP5cniqB";path="/data/movies"}, @{id="nw7PJBmiV";path="/data/tv"})) {
    $body = "{`"data`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"scanConfig`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"arrayOrPath`":`"$($lib.path)`"}}}"
    Invoke-RestMethod -Method Post "$Tdarr/api/v2/scan-files" -Body $body -ContentType "application/json" | Out-Null
    Write-Host "  Scan triggered: $($lib.path)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Phase 2 complete." -ForegroundColor Cyan
Write-Host "  - Main flow upgraded to Universal H264+AAC (handles HEVC, H264, AV1, anything)" -ForegroundColor Cyan
Write-Host "  - HEVC files reset and queued for conversion" -ForegroundColor Cyan
Write-Host "  - H264+AAC files will be skipped (Not required) - no duplicate tracks" -ForegroundColor Cyan
Write-Host "  Monitor: http://localhost:8265" -ForegroundColor Yellow
