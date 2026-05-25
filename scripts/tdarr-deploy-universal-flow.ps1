<#
.SYNOPSIS
    Deploy the Universal H264+AAC flow for universal libraries.

.DESCRIPTION
    Run this after any needed duplicate-audio cleanup with dedup-audio.ps1.

    What it does:
      1. Stops Tdarr (no-op if already stopped by dedup script)
      2. Updates flow N7tOvfd6i to the clean 2-branch Universal H264+AAC design:
           - H264 branch: copy video + ffmpegCommandEnsureAudioStream(en) +
             ffmpegCommandEnsureAudioStream(j) — adds AAC if missing, skips if present
           - non-H264 branch: GPU encode to h264_nvenc + -pix_fmt yuv420p +
             same two EnsureAudioStream nodes
           Both EnsureAudioStream nodes use built-in deduplication (no duplicate tracks)
           and dynamic {outputIndex} placeholders (no stream-index conflicts)
      3. Reverts the universal library flowIds back to N7tOvfd6i
      4. Deletes the temporary AddAACH264x flow
      5. Starts Tdarr and triggers fresh scans on both libraries

    After this script:
      - New and changed universal-library files go through the new flow
      - Files already standardised (H264 + AAC) are marked "Not required" — no duplicate tracks
      - HEVC/AV1/other files are queued for GPU conversion to H264 + AAC when they are scanned
      - English and Japanese AAC stereo tracks are both ensured on processed files

    This script does NOT reset existing Tdarr file decisions by default.
    Use tdarr-reset-universal-files.ps1 when you intentionally need to requeue
    existing files after a flow change.

    Private tracker / premium library safety:
      This script intentionally scopes changes to the universal library IDs only:
        Movies: rUP5cniqB (/data/movies)
        TV:     nw7PJBmiV (/data/tv)
      Do not point this flow at /data/torrents or future 4K premium libraries.
#>

$StackDir    = "M:\Media"
$ComposeFile = "$StackDir\docker-compose.yml"
$Tdarr       = "http://localhost:8265"
$Docker      = "docker.exe"
$UniversalLibraries = @(
    @{ id = "rUP5cniqB"; path = "/data/movies"; name = "Movies" },
    @{ id = "nw7PJBmiV"; path = "/data/tv";     name = "TV"     }
)

# -- Step 1: Stop Tdarr -------------------------------------------------------
Write-Host "[1/5] Stopping Tdarr..." -ForegroundColor Cyan
& $Docker compose -f $ComposeFile stop tdarr 2>&1 | Out-Null
Write-Host "  Stopped" -ForegroundColor Green

# -- Step 2: Locate sqlite3 ---------------------------------------------------
Write-Host "[2/5] Locating sqlite3..." -ForegroundColor Cyan
$sqlite3 = (Get-ChildItem "$env:TEMP\sqlite3" -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue).FullName
if (-not $sqlite3) {
    Write-Host "  Downloading sqlite3..." -ForegroundColor Gray
    $zip  = "$env:TEMP\sqlite-tools.zip"
    $dest = "$env:TEMP\sqlite3"
    Invoke-WebRequest "https://www.sqlite.org/2024/sqlite-tools-win-x64-3470200.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $dest -Force
    $sqlite3 = (Get-ChildItem $dest -Recurse -Filter "sqlite3.exe").FullName
}
Write-Host "  sqlite3: $sqlite3" -ForegroundColor Green

$db = "$StackDir\config\tdarr\server\Tdarr\DB2\SQL\database.db"

# -- Step 3: Update flow, assign universal libraries, delete temp flow --------
Write-Host "[3/5] Updating Tdarr database..." -ForegroundColor Cyan

# Flow JSON: 2-branch Universal H264+AAC
#   H264 branch (right):  Start -> SetVideoEncoder(copy) -> EnsureAudio(en) -> EnsureAudio(j) -> Execute -> Replace
#   non-H264 branch (left): Start -> SetVideoEncoder(nvenc,force) -> CustomArgs(-pix_fmt yuv420p) -> EnsureAudio(en) -> EnsureAudio(j) -> Execute -> Replace
# EnsureAudioStream uses {outputIndex} placeholders (no hardcoded stream indices) and
# has built-in deduplication (skips if AAC stereo already present for that language).
# Both inputs and inputsDB are set on every plugin node — worker reads inputsDB.
[System.IO.File]::WriteAllText("$env:TEMP\restore.sql", @'
UPDATE flowsjsondb
SET json_data = '{"_id":"N7tOvfd6i","name":"Universal H264+AAC","priority":0,"flowPlugins":[{"id":"n_input","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":50,"x":500},"pluginName":"inputFile","version":"1.0.0"},{"id":"n_vcheck","sourceRepo":"Community","inputs":{"codec":"h264"},"inputsDB":{"codec":"h264"},"position":{"y":180,"x":500},"pluginName":"checkVideoCodec","version":"1.0.0"},{"id":"n_h264_start","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":320,"x":800},"pluginName":"ffmpegCommandStart","version":"1.0.0"},{"id":"n_h264_enc","sourceRepo":"Community","inputs":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"false","hardwareDecoding":"false","forceEncoding":"false","ffmpegPresetEnabled":"false","ffmpegQualityEnabled":"false"},"inputsDB":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"false","hardwareDecoding":"false","forceEncoding":"false","ffmpegPresetEnabled":"false","ffmpegQualityEnabled":"false"},"position":{"y":460,"x":800},"pluginName":"ffmpegCommandSetVideoEncoder","version":"1.0.0"},{"id":"n_h264_aac_en","sourceRepo":"Community","inputs":{"audioEncoder":"aac","language":"en","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"inputsDB":{"audioEncoder":"aac","language":"en","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"position":{"y":600,"x":800},"pluginName":"ffmpegCommandEnsureAudioStream","version":"1.0.0"},{"id":"n_h264_aac_ja","sourceRepo":"Community","inputs":{"audioEncoder":"aac","language":"j","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"inputsDB":{"audioEncoder":"aac","language":"j","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"position":{"y":740,"x":800},"pluginName":"ffmpegCommandEnsureAudioStream","version":"1.0.0"},{"id":"n_hevc_start","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":320,"x":200},"pluginName":"ffmpegCommandStart","version":"1.0.0"},{"id":"n_hevc_enc","sourceRepo":"Community","inputs":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"true","hardwareDecoding":"false","forceEncoding":"true","ffmpegPresetEnabled":"true","ffmpegPreset":"fast","ffmpegQualityEnabled":"true","ffmpegQuality":"20"},"inputsDB":{"outputCodec":"h264","hardwareType":"nvenc","hardwareEncoding":"true","hardwareDecoding":"false","forceEncoding":"true","ffmpegPresetEnabled":"true","ffmpegPreset":"fast","ffmpegQualityEnabled":"true","ffmpegQuality":"20"},"position":{"y":460,"x":200},"pluginName":"ffmpegCommandSetVideoEncoder","version":"1.0.0"},{"id":"n_hevc_pix","sourceRepo":"Community","inputs":{"inputArguments":"","outputArguments":"-pix_fmt yuv420p"},"inputsDB":{"inputArguments":"","outputArguments":"-pix_fmt yuv420p"},"position":{"y":600,"x":200},"pluginName":"ffmpegCommandCustomArguments","version":"1.0.0"},{"id":"n_hevc_aac_en","sourceRepo":"Community","inputs":{"audioEncoder":"aac","language":"en","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"inputsDB":{"audioEncoder":"aac","language":"en","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"position":{"y":740,"x":200},"pluginName":"ffmpegCommandEnsureAudioStream","version":"1.0.0"},{"id":"n_hevc_aac_ja","sourceRepo":"Community","inputs":{"audioEncoder":"aac","language":"j","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"inputsDB":{"audioEncoder":"aac","language":"j","channels":"2","enableBitrate":"true","bitrate":"192k","enableSamplerate":"false","samplerate":"48k"},"position":{"y":880,"x":200},"pluginName":"ffmpegCommandEnsureAudioStream","version":"1.0.0"},{"id":"n_exec","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":1020,"x":500},"pluginName":"ffmpegCommandExecute","version":"1.0.0"},{"id":"n_replace","sourceRepo":"Community","inputs":{},"inputsDB":{},"position":{"y":1160,"x":500},"pluginName":"replaceOriginalFile","version":"1.0.0"}],"flowEdges":[{"source":"n_input","target":"n_vcheck","id":"e01","targetHandle":null,"sourceHandle":"1"},{"source":"n_vcheck","target":"n_h264_start","id":"e02","targetHandle":null,"sourceHandle":"1"},{"source":"n_vcheck","target":"n_hevc_start","id":"e03","targetHandle":null,"sourceHandle":"2"},{"source":"n_h264_start","target":"n_h264_enc","id":"e04","targetHandle":null,"sourceHandle":"1"},{"source":"n_h264_enc","target":"n_h264_aac_en","id":"e05","targetHandle":null,"sourceHandle":"1"},{"source":"n_h264_aac_en","target":"n_h264_aac_ja","id":"e06","targetHandle":null,"sourceHandle":"1"},{"source":"n_h264_aac_ja","target":"n_exec","id":"e07","targetHandle":null,"sourceHandle":"1"},{"source":"n_hevc_start","target":"n_hevc_enc","id":"e08","targetHandle":null,"sourceHandle":"1"},{"source":"n_hevc_enc","target":"n_hevc_pix","id":"e09","targetHandle":null,"sourceHandle":"1"},{"source":"n_hevc_pix","target":"n_hevc_aac_en","id":"e10","targetHandle":null,"sourceHandle":"1"},{"source":"n_hevc_aac_en","target":"n_hevc_aac_ja","id":"e11","targetHandle":null,"sourceHandle":"1"},{"source":"n_hevc_aac_ja","target":"n_exec","id":"e12","targetHandle":null,"sourceHandle":"1"},{"source":"n_exec","target":"n_replace","id":"e13","targetHandle":null,"sourceHandle":"1"}],"isUiLocked":false}',
    timestamp = strftime('%s','now')*1000
WHERE id = 'N7tOvfd6i';

UPDATE librarysettingsjsondb
SET json_data = json_set(json_data, '$.flowId', 'N7tOvfd6i'),
    timestamp = strftime('%s','now')*1000
WHERE id IN ('rUP5cniqB', 'nw7PJBmiV');

DELETE FROM flowsjsondb WHERE id = 'AddAACH264x';

SELECT 'flow: ' || id || '  ' || json_extract(json_data,'$.name') FROM flowsjsondb;
SELECT 'universal lib: ' || id || '  flowId=' || json_extract(json_data,'$.flowId')
  FROM librarysettingsjsondb
 WHERE id IN ('rUP5cniqB', 'nw7PJBmiV');
'@, [System.Text.UTF8Encoding]::new($false))

& $sqlite3 $db ".read $env:TEMP\restore.sql"
Write-Host "  Done" -ForegroundColor Green

# -- Step 4: Start Tdarr ------------------------------------------------------
Write-Host "[4/5] Starting Tdarr..." -ForegroundColor Cyan
& $Docker compose -f $ComposeFile start tdarr 2>&1 | Out-Null
Start-Sleep -Seconds 12
Write-Host "  Started" -ForegroundColor Green

# -- Step 5: Trigger fresh scan on both libraries -----------------------------
Write-Host "[5/5] Triggering fresh scans..." -ForegroundColor Cyan
foreach ($lib in $UniversalLibraries) {
    $body = "{`"data`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"scanConfig`":{`"dbID`":`"$($lib.id)`",`"mode`":`"scanFresh`",`"arrayOrPath`":`"$($lib.path)`"}}}"
    Invoke-RestMethod -Method Post "$Tdarr/api/v2/scan-files" -Body $body -ContentType "application/json" | Out-Null
    Write-Host "  Scan triggered: $($lib.path)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
Write-Host "  Flow:    Universal H264+AAC (2-branch, EnsureAudioStream, no index conflicts)" -ForegroundColor Cyan
Write-Host "  Monitor: http://localhost:8265" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Expected behaviour:" -ForegroundColor Gray
Write-Host "    H264 + AAC already       -> Not required (no processing)" -ForegroundColor Gray
Write-Host "    H264 + no AAC            -> copy video, add AAC stereo" -ForegroundColor Gray
Write-Host "    HEVC/AV1/other + AAC     -> GPU encode to H264, keep audio" -ForegroundColor Gray
Write-Host "    HEVC/AV1/other + no AAC  -> GPU encode to H264, add AAC stereo" -ForegroundColor Gray
