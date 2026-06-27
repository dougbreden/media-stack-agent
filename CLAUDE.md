# CLAUDE.md — Self-Hosted Media Stack

This is a fully automated self-hosted media pipeline at `M:\Media` running 13 Docker containers on Windows with Docker Desktop (WSL2 backend). See `docs/RUNBOOK.md` for the full human-readable runbook, `docs/LOG.md` for operational history, and `docs/USAGE.md` for end-user instructions. This file is for Claude Code context.

**User workflow:** Request in Jellyseerr → Sonarr/Radarr search → qBittorrent downloads (through Mullvad VPN) → imported and organised → appears in Jellyfin.

---

## Key Files

| File | Purpose |
|---|---|
| `M:\Media\docker-compose.yml` | All 13 container definitions — uses ${VARIABLE} references for secrets |
| `M:\Media\.env` | Secrets: WireGuard key + IP, Radarr + Sonarr API keys — never commit |
| `M:\Media\api-keys.md` | API keys for all services |
| `M:\Media\docs\RUNBOOK.md` | Full human runbook: setup steps, known issues, reproduction guide |
| `M:\Media\docs\LOG.md` | Chronological operations log: every fix and config decision |
| `M:\Media\docs\USAGE.md` | End-user guide: how to request content, client apps, accounts |
| `M:\Media\config\qbittorrent\qBittorrent\qBittorrent.conf` | qBittorrent settings (paths, seeding limits) |

---

## API Keys & Service URLs

Actual keys and passwords are in `M:\Media\api-keys.md` (gitignored — never commit).
Scripts load them via `. "$PSScriptRoot\config.ps1"` (also gitignored — see `scripts\config.ps1.example`).

| Service | URL | API Key |
|---|---|---|
| Radarr (movies) | http://localhost:7878 | see `api-keys.md` |
| Sonarr (TV) | http://localhost:8989 | see `api-keys.md` |
| Jellyseerr (requests) | http://localhost:5055 | see `api-keys.md` |
| Jellyfin (player) | http://localhost:8096 | see `api-keys.md` |
| Prowlarr (indexers) | http://localhost:9696 | — |
| qBittorrent | http://localhost:8080 | see `api-keys.md` |
| Homarr (dashboard) | http://localhost:7575 | see `api-keys.md` |
| Bazarr (subtitles) | http://localhost:6767 | see `api-keys.md` |
| Tdarr (transcoder) | http://localhost:8265 | see `api-keys.md` |

---

## Critical Networking Rules

- **qBittorrent's hostname is `gluetun`, not `qbittorrent`** — it shares Gluetun's network namespace via `network_mode: service:gluetun`. Radarr/Sonarr connect to it at `gluetun:8080`.
- All inter-container URLs use `http://` — no SSL inside Docker.
- After any `docker compose up -d gluetun` (config change or restart), always follow with `docker compose up -d qbittorrent` — a plain `restart` won't work because qBittorrent holds a reference to the old container ID.

---

## VPN — Gluetun / Mullvad WireGuard

- Netherlands exit, private key + assigned IP in `docker-compose.yml` under `gluetun`
- `AllowedIPs = 0.0.0.0/0` — all container traffic exits through Mullvad
- **No port forwarding** — Mullvad removed it. Seeding always shows "Stalled" in qBittorrent. This is normal and not a bug.
- **DNS:** Uses plain DNS, NOT DoT. Critical config in docker-compose.yml:
  ```yaml
  - DNS_UPSTREAM_RESOLVER_TYPE=plain
  - DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53
  - BLOCK_MALICIOUS=off
  - BLOCK_SURVEILLANCE=off
  - BLOCK_ADS=off
  ```
  DoT (the default) blocked torrent tracker domains even with BLOCK_*=off. Switching to plain 1.1.1.1 through the VPN tunnel fixed it. DNS traffic is still private (routed through Mullvad).

---

## Language Custom Formats (Sonarr + Radarr)

Both apps have identical custom formats applied to all quality profiles. `minFormatScore=0` on all profiles — anything scoring below 0 is rejected and stays "Missing".

| Format | ID (Sonarr) | ID (Radarr) | Score | Regex / Spec |
|---|---|---|---|---|
| Preferred Groups | 6 | 4 | +500 | `(?i)Yameii\|HakataRamen\|SubsPlease\|Erai-raws\|Judas\|LostYears\|Arg0` |
| Dual Audio | 5 | 3 | +400 | `(?i)\bDual[\.\s]?Audio\b\|DualAudio\|\bDual[\.\s]Multi\b` |
| Language: English | 3 | 2 | +300 | LanguageSpecification: English (id=1) |
| English Subs | 4 | — | +200 | `(?i)SubsPlease\|Erai-raws\|Judas\|Dual.Audio\|DualAudio\|English.Subbed` |
| Non-English | 2 | 1 | -10000 | See regex below |

Non-English regex (applied to release title):
```
(?i)VOSTFR|FRENCH|VFF|VFQ|TRUEFRENCH|GERMAN|DEUTSCH|SPANISH|ESPANOL|ITALIAN|PORTUGUESE|HEBREW|DUTCH|RUSSIAN|TURKISH|ARABIC|POLISH|(?<!dual[\s.]?)\bmulti\b
```

The `(?<!dual[\s.]?)\bmulti\b` matches any `multi` (case-insensitive under `(?i)`) **except** when directly preceded by `dual` or `dual.` / `dual `. This blocks French/German scene `MULTi` releases (e.g. NanDesuKa) while allowing `Dual Multi` releases (e.g. HakataRamen JP+EN dual audio).

**Do not use `(?-i:...)` inline flag to make `MULTi` case-sensitive** — Sonarr's regex engine does not honour inline case-flag changes, so that approach silently fails and lets non-English `MULTi` releases through.

---

## qBittorrent Seeding Config

File: `M:\Media\config\qbittorrent\qBittorrent\qBittorrent.conf`

```ini
Session\GlobalMaxRatioEnabled=false
Session\GlobalMaxSeedingMinutesEnabled=false
Session\ShareLimitAction=Stop
```

Global limits are **disabled** — per-category limits control behavior:

| Category | Ratio limit | Seeding time | Action |
|---|---|---|---|
| `movies` | 1.0 | unlimited | Stop (pause) |
| `tv` | 1.0 | unlimited | Stop (pause) |
| `movies-private` | unlimited | unlimited | Stop (pause) |
| `tv-private` | unlimited | unlimited | Stop (pause) |

**NEVER delete torrents** — always Stop/Pause. Files are hardlinked between `/data/torrents/` and the library (same inode, no extra disk space). Paused torrents preserve tracker peer history for ratio calculation.

**Download client routing in Radarr/Sonarr:**
- Public client "qBittorrent" (priority 1, no tags, `removeCompletedDownloads=true`) — public tracker downloads
- Private client "qBittorrent (Private)" (priority 2, tag=`private`, `removeCompletedDownloads=false`) — private tracker downloads
- In Prowlarr: tag private indexers with `private` → Radarr/Sonarr automatically routes to the private client

**To fix a qBittorrent lockfile crash loop** (starts then exits immediately):
```powershell
docker exec qbittorrent sh -c "rm -f /config/qBittorrent/lockfile /config/qBittorrent/ipc-socket"
docker compose up -d qbittorrent
```

---

## Key Settings Locations

| Setting | Where to find it |
|---|---|
| Jellyseerr default quality profile | Settings → Services → Radarr (or Sonarr) → pencil icon → Quality Profile dropdown. Stored in `config/jellyseerr/settings.json` as `radarr[].activeProfileId` (HD-1080p = 4). Stop container before editing file directly. |
| Radarr/Sonarr minimum custom format score | Settings → Quality Profiles → edit each profile → Minimum Custom Format Score → set to `0` |
| Jellyfin remote bitrate limit | Dashboard → Playback → Bandwidth Limits → Remote client bitrate limit → `0` (unlimited) |
| Jellyfin subtitle mode | Dashboard → Display → Subtitle Mode → Smart |
| Jellyfin LAN Networks / Known Proxies | Leave blank — Docker bridge (172.18.0.1) makes all traffic look local; these settings have no effect |
| iOS Jellyfin app streaming quality | In-app Settings → Max Streaming Bitrate → Original (prevents codec re-encoding on top of HLS remux) |
| Jellyfin hardware transcoding | Dashboard → Playback → Transcoding → Hardware acceleration → NVIDIA NVENC. Config lives in `config/jellyfin/encoding.xml`. GPU (RTX 4070 Ti) is passed through via `NVIDIA_VISIBLE_DEVICES=all` in docker-compose.yml; available as `/dev/dxg` (WSL2 path, not `/dev/nvidia*`). Verified: hevc_cuvid + h264_nvenc at ~20x realtime. |
| Infuse Pro streaming quality (cellular) | Infuse → Settings → Playback → Streaming Quality → Cellular → set a specific quality/bitrate rather than Auto to force server-side transcode at a predictable bitrate |

---

## Tdarr — Universal H264+AAC Transcoding

Tdarr runs background transcoding to standardise the entire library to H.264 video + AAC stereo audio for universal device compatibility. Server API is on port 8266, web UI on port 8265. Uses the same NVIDIA GPU passthrough as Jellyfin.

Tdarr only mounts the mutable library paths (`/data/movies` and `/data/tv`), not `/data/torrents`. Keep it that way. For private trackers, the torrent download copy must remain pristine for seeding; Tdarr may replace the library copy in place, which breaks the hardlink and leaves the original torrent inode untouched. Helper scripts that modify media should default to library paths only.

Run `M:\Media\scripts\check-media-policy.ps1` after any compose, qBittorrent category, Tdarr, or library-layout change. It is read-only and validates the key boundary: torrents are source/archive, `/data/movies` + `/data/tv` are mutable Universal libraries, and future `/data/movies-4k` + `/data/tv-4k` are Premium direct-play libraries.

**Library IDs:**
- Movies: `rUP5cniqB` (path `/data/movies`)
- TV: `nw7PJBmiV` (path `/data/tv`)

`tdarr-deploy-universal-flow.ps1` must only assign the flow to these two Universal IDs and must not reset files. `tdarr-reset-universal-files.ps1` is the only script that requeues file decisions, defaults to errored files only, and requires `-All -ConfirmAll` for a full Universal reset. Do not bulk-update every `librarysettingsjsondb` row or every `filejsondb` row once Premium 4K libraries exist.

MKV is the preferred container for both Universal and Premium layers. Existing library files can be migrated with `remux-library-to-mkv.ps1`, which is dry-run by default and uses stream copy only. Do not fold broad MKV migration into the Tdarr deploy script; it is a separate mutating operation and should remain explicit.

**Flow ID:** `N7tOvfd6i` (name: "Universal H264+AAC") — stored in SQLite `flowsjsondb` table (NOT accessible via cruddb API — must edit SQLite directly with Tdarr stopped).

**Flow logic (4 branches):**
| Video codec | Audio has AAC? | Action |
|---|---|---|
| H264 | Yes | Not required — already standardised |
| H264 | No | Copy video + add AAC stereo track (192k) |
| non-H264 (HEVC/AV1/VP9/etc.) | Yes | GPU encode to h264_nvenc, keep audio |
| non-H264 | No | GPU encode to h264_nvenc + add AAC stereo track |

**Key plugin sequence (non-H264 path):**
`inputFile` → `checkVideoCodec(h264)` → `ffmpegCommandStart` → `ffmpegCommandSetVideoEncoder` → `checkAudioCodec(aac)` → `ffmpegCommandCustomArguments` → `ffmpegCommandExecute` → `replaceOriginalFile`

**ffmpeg commands produced:**
```
# non-H264, no AAC (HEVC Main 10 typical case):
ffmpeg -i input.mkv -map 0:0 -c:0 h264_nvenc -qp 20 -preset p4 -map 0:1 -c:1 copy -map 0:1 -c:2 aac -ac 2 -b:a 192k -pix_fmt yuv420p output.mkv

# non-H264, already has AAC:
ffmpeg -i input.mkv -map 0:0 -c:0 h264_nvenc -qp 20 -preset p4 -map 0:1 -c:1 copy -pix_fmt yuv420p output.mkv

# H264, no AAC:
ffmpeg -i input.mkv -map 0:0 -c:0 copy -map 0:1 -c:1 copy -map 0:1 -c:2 aac -ac 2 -b:a 192k output.mkv
```

**Worker reads `k.inputsDB`, NOT `k.inputs`** — every plugin node in the flow JSON must have BOTH `inputs` and `inputsDB` fields with identical values. If `inputsDB` is missing, the worker reads plugin defaults (outputCodec=hevc, hardwareType=auto). This was the root bug that caused hevc_nvenc instead of h264_nvenc.

**Why `hardwareDecoding: "false"` on the encode path:** HEVC Main 10 sources have 10-bit pixel format (yuv420p10le). When `-hwaccel cuda` is active, GPU decoder outputs p010le which h264_nvenc rejects ("10 bit encode not supported"). CPU decode converts 10-bit to 8-bit; GPU then encodes via h264_nvenc.

**Why `-pix_fmt yuv420p`:** Forces 8-bit output. Without it, CPU decode of 10-bit HEVC can still pass p010le to h264_nvenc. Belt-and-suspenders fix.

**Why `checkAudioCodec` is placed after `ffmpegCommandSetVideoEncoder`:** The plugin reads `args.inputFileObj.ffProbeData.streams` (original file probe data), not the in-progress ffmpeg command state. Placement after the encoder plugin is safe.

**Why `ffmpegCommandExecute` runs even when `forceEncoding=false` (H264 copy path):** `ffmpegCommandCustomArguments` pushes to `overallOuputArguments`. The execute plugin sets `shouldProcess = true` when `overallOuputArguments.length > 0` (line ~173 of execute plugin). So any custom output argument guarantees execution.

**Flow is stored in SQLite, not via API.** To modify: stop Tdarr, use sqlite3 on `config/tdarr/server/Tdarr/DB2/SQL/database.db`, always use `.read <sqlfile>` to avoid `-c:N` flag parsing issues. Use single-quoted `@'...'@` PowerShell here-strings so `$.flowId` is not interpolated.

**Tdarr CRUD API pattern:**
```powershell
# Read all staged jobs
$r = Invoke-RestMethod -Method Post "http://localhost:8265/api/v2/cruddb" -ContentType "application/json" -Body '{"data":{"collection":"StagedJSONDB","mode":"getAll"}}'

# Valid collection names: StagedJSONDB, FileJSONDB, FlowsJSONDB, StagedJSONDB
# (NOT the library ID -- that causes 400 "must be equal to one of the allowed values")

# Check active worker status (shows current file + ffmpeg preset + percentage)
Invoke-RestMethod "http://localhost:8265/api/v2/get-nodes"

# Trigger fresh library scan (re-evaluates all files, including reset ones)
$body = '{"data":{"dbID":"rUP5cniqB","mode":"scanFresh","scanConfig":{"dbID":"rUP5cniqB","mode":"scanFresh","arrayOrPath":"/data/movies"}}}'
Invoke-RestMethod -Method Post "http://localhost:8265/api/v2/scan-files" -Body $body -ContentType "application/json"
# Use scanFresh not scanFindNew -- scanFindNew skips files with cleared TranscodeDecisionMaker

# Reset files for re-processing (e.g. after flow config change)
$body = '{"data":{"fileIds":["id1","id2"],"updatedObj":{"TranscodeDecisionMaker":"","lastTranscodeDate":0}}}'
Invoke-RestMethod -Method Post "http://localhost:8265/api/v2/bulk-update-files" -Body $body -ContentType "application/json"
```

**TranscodeDecisionMaker values:**
- `""` -- not yet evaluated (will be picked up on next scan)
- `"Not required"` -- file already meets the flow's requirements (H264+AAC), no processing needed
- `"Transcode success"` -- successfully processed
- `"Transcode error"` -- ffmpeg failed (check job report; common: 10-bit encode without -pix_fmt yuv420p)

---

## Common API Operations

**Trigger Jellyfin library scan:**
```powershell
Invoke-RestMethod -Method Post "http://localhost:8096/Library/Refresh?api_key=<jellyfin-key>"
```

**List Sonarr series with IDs:**
```powershell
Invoke-RestMethod "http://localhost:8989/api/v3/series?apikey=<sonarr-key>" | ForEach-Object { "$($_.id) $($_.title)" }
```

**Season search (better than episode search for completed seasons on public trackers):**
```powershell
$body = '{"name":"SeasonSearch","seriesId":2,"seasonNumber":1}'
Invoke-RestMethod -Method Post "http://localhost:8989/api/v3/command?apikey=<sonarr-key>" -Body $body -ContentType "application/json"
```

**Check missing episodes:**
```powershell
$eps = Invoke-RestMethod "http://localhost:8989/api/v3/episode?apikey=<sonarr-key>&seriesId=2&seasonNumber=1"
$eps | Where-Object { -not $_.hasFile } | Sort-Object episodeNumber | ForEach-Object { "E$($_.episodeNumber): $($_.title)" }
```

**Interactive release search (see scores and rejection reasons for a specific episode):**
```powershell
$releases = Invoke-RestMethod "http://localhost:8989/api/v3/release?apikey=<sonarr-key>&episodeId=<id>"
$releases | Sort-Object customFormatScore -Descending | Select-Object -First 10 | ForEach-Object {
    "$($_.customFormatScore) | rejected=$($_.rejected) | $($_.title.Substring(0,70))"
}
```

**Stack management:**
```powershell
cd M:\Media
docker compose up -d          # start / apply config changes
docker compose ps             # check all container statuses
docker compose restart        # restart all (use up -d for gluetun changes)
docker compose pull && docker compose up -d   # update all images
```

---

## Indexers (configured in Prowlarr)

Active: YTS, The Pirate Bay, EZTV, Nyaa.si, TorrentGalaxy (TGx), LimeTorrents
Disabled: 1337x (FlareSolverr can't bypass its current Cloudflare — re-test periodically)

content specifically requires Nyaa.si — SubsPlease and Erai-raws only publish there.

---

## Known Failure Modes

| Symptom | Likely Cause | Fix |
|---|---|---|
| qBittorrent trackers "Not Working" / "Operation not permitted" on ALL trackers | Gluetun firewall rules in bad state (often after Watchtower update) | `docker compose up -d --force-recreate gluetun && docker compose up -d qbittorrent` |
| All torrent speeds zero, Gluetun unhealthy, tun0 TX>0 but RX=0 (handshake sent, no reply) | Mullvad account expired -- WireGuard handshake silently fails because Mullvad rejects the key | Renew Mullvad subscription at mullvad.net. Force-recreate gluetun after account is active. |
| qBittorrent trackers "Not Working" / DNS resolution failures | Gluetun DNS set to DoT instead of plain | Check DNS config: must be plain not DoT |
| Torrent "Errored", speed drops to 0 | Save path wrong (`/downloads/` instead of `/data/torrents/`) | Fix qBittorrent.conf paths, restart container |
| Gluetun restart causes qBittorrent "no such container" | qBittorrent holds old Gluetun container ID | `docker compose up -d qbittorrent` after any Gluetun recreate |
| Sonarr grabs multi-language release (French/German/etc.) | Non-English custom format not catching it | Check format ID 2 (Sonarr) / 1 (Radarr) — regex must use `(?<!dual[\s.]?)\bmulti\b`, NOT `(?-i:MULTi)` (inline flags silently broken in Sonarr) |
| Individual episode searches return 0 downloads | Public trackers don't index old individual episodes | Use SeasonSearch command instead |
| All seeding torrents show "Stalled" | No port forwarding on Mullvad = no inbound connections | Expected — not a bug. Paused by category ratio limit or by Sonarr/Radarr on import |
| qBittorrent starts then exits immediately (crash loop) | Stale lockfile from prior crash | `docker exec qbittorrent sh -c "rm -f /config/qBittorrent/lockfile /config/qBittorrent/ipc-socket"` then `docker compose up -d qbittorrent` |
| Jellyfin plays wrong audio language | Jellyfin defaults to first audio track | During playback: gear icon → Audio → select English |
| Jellyfin auth works on desktop but fails on phone/TV ("invalid username or password") | Native Jellyfin Server install running alongside Docker, claiming remote connections on port 8096 | Kill `jellyfin.exe` + `Jellyfin.Windows.Tray.exe`, remove `JellyfinTray` from HKCU startup, uninstall "Jellyfin Server" from Apps |
| Infuse shows library on cellular but video won't play (spins then errors) | Infuse free tier blocks remote/cellular video streaming — Pro required | Use Jellyfin iOS app (free) or upgrade to Infuse Pro |
| Jellyfin iOS app has 2–4 s blank screen after every seek | WebView-based app always uses HLS; seeking restarts FFmpeg at the new position | Expected — not a bug. Set Max Streaming Bitrate → Original in app Settings to at least avoid unnecessary transcoding |
| Jellyseerr crash-loops with "Unexpected token '﻿'" in logs | `settings.json` was written with a UTF-8 BOM by PowerShell 5.1 `Set-Content -Encoding utf8` | Restore `settings.json` from backup zip; strip BOM with `[System.IO.File]::WriteAllBytes()`. **Never use `Set-Content -Encoding utf8` or `Out-File -Encoding utf8` on config JSON files** — always use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))` |
| Remote/cellular playback stutters or fails to start (Infuse/Swiftfin/Jellyfin iOS) | HEVC Main 10 files require transcoding; without GPU, software transcode is too slow | GPU passthrough in docker-compose.yml (`NVIDIA_VISIBLE_DEVICES=all`). Check with `docker exec jellyfin sh -c "ls /dev/dxg"` — WSL2 uses `/dev/dxg` not `/dev/nvidia*`. Verify NVENC: `docker exec jellyfin sh -c "/usr/lib/jellyfin-ffmpeg/ffmpeg -init_hw_device cuda=gpu:0 -f lavfi -i nullsrc -frames:v 1 -c:v h264_nvenc -f null -"` |
| Jellyfin GPU not accessible after `docker compose up` (no `/dev/nvidia*` inside container) | NVIDIA Container Runtime on WSL2 uses `/dev/dxg`, not `/dev/nvidia*`; missing `NVIDIA_VISIBLE_DEVICES` env var | Add `NVIDIA_VISIBLE_DEVICES=all` and `NVIDIA_DRIVER_CAPABILITIES=all` to jellyfin env in compose; capabilities must include `[gpu, video, compute]` |
| Tdarr encodes with hevc_nvenc instead of h264_nvenc | Worker reads `k.inputsDB` not `k.inputs`; flow plugins only had `inputs` fields, so defaults were used | Ensure every plugin node in the flow JSON has both `inputs` AND `inputsDB` with identical values |
| Tdarr job fails: "10 bit encode not supported" | h264_nvenc cannot encode 10-bit pixel formats; `-hwaccel cuda` decodes HEVC Main 10 to p010le which h264_nvenc rejects | Set `hardwareDecoding: "false"` in ffmpegCommandSetVideoEncoder plugin, AND add ffmpegCommandCustomArguments plugin with `outputArguments: "-pix_fmt yuv420p"` |
| Tdarr queue empty after resetting files | Used `scanFindNew` which only processes new/changed files, not files with cleared TranscodeDecisionMaker | Use `scanFresh` mode in the scan-files API — it re-evaluates all files in the library |
| Tdarr adds AAC to wrong stream on Blu-ray rips with 6+ streams | `-c:2 aac` in ffmpegCommandCustomArguments targets output stream index 2 (hardcoded), which already exists in multi-stream files; the intended new stream gets no explicit codec | Known limitation. File is still playable and has AAC somewhere. For 2-stream files (most TV/content downloads) the current approach is correct. Multi-stream Blu-ray rips are edge cases |
| Tdarr "Transcode error" files not re-queued after flow fix | Errored files stay in error state permanently; only files with TranscodeDecisionMaker="" are picked up by a fresh scan | Use bulk-update-files API to reset errored files to TranscodeDecisionMaker="". The Phase 2 restore script resets all errored files automatically |
