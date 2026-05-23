# CLAUDE.md — Self-Hosted Media Stack

This is a fully automated self-hosted media pipeline at `M:\Media` running 12 Docker containers on Windows with Docker Desktop (WSL2 backend). See `README.md` for the human-readable runbook. This file is for Claude Code context.

**User workflow:** Request in Jellyseerr → Sonarr/Radarr search → qBittorrent downloads (through Mullvad VPN) → imported and organised → appears in Jellyfin.

---

## Key Files

| File | Purpose |
|---|---|
| `M:\Media\docker-compose.yml` | All 13 container definitions — uses ${VARIABLE} references for secrets |
| `M:\Media\.env` | Secrets: WireGuard key + IP, Radarr + Sonarr API keys — never commit |
| `M:\Media\api-keys.md` | API keys for all services |
| `M:\Media\README.md` | Full human runbook: setup steps, known issues, status log |
| `M:\Media\config\qbittorrent\qBittorrent\qBittorrent.conf` | qBittorrent settings (paths, seeding limits) |

---

## API Keys & Service URLs

| Service | URL | API Key |
|---|---|---|
| Radarr (movies) | http://localhost:7878 | `ffe2d5d77df04128b2027ea05aa4bc86` |
| Sonarr (TV) | http://localhost:8989 | `ee46bcbfbdfe48e4b7863db24f6ecb25` |
| Jellyseerr (requests) | http://localhost:5055 | `4a6b7ee0cac2430eb4335fbf4c520593` |
| Jellyfin (player) | http://localhost:8096 | `f21e09ab3bc44eef9d50445aca69bf4e` |
| Prowlarr (indexers) | http://localhost:9696 | — |
| qBittorrent | http://localhost:8080 | admin / idbeholdg |
| Homarr (dashboard) | http://localhost:7575 | admin / !GeosaT@42 |
| Bazarr (subtitles) | http://localhost:6767 | admin / idbeholdg |
| Tdarr (transcoder) | http://localhost:8265 | admin / idbeholdg |

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

## Tdarr — HEVC→H264 Transcoding

Tdarr runs background transcoding to convert HEVC files to H.264 for iOS direct-play. Server API is on port 8266, web UI on port 8265. Uses the same NVIDIA GPU passthrough as Jellyfin.

**Library IDs:**
- Movies: `rUP5cniqB` (path `/data/movies`)
- TV: `nw7PJBmiV` (path `/data/tv`)

**Flow ID:** `N7tOvfd6i` (name: "HEVC→H264") — stored in FlowsJSONDB collection.

**Worker reads `k.inputsDB`, NOT `k.inputs`** — this is the critical non-obvious fact. Every plugin node in the flow JSON must have BOTH `inputs` and `inputsDB` fields with identical values. If `inputsDB` is missing, the worker reads plugin defaults instead (outputCodec=hevc, hardwareType=auto). This was the root bug that caused hevc_nvenc to be used instead of h264_nvenc.

**Final ffmpeg command produced by the flow:**
```
ffmpeg -i input.mkv -map 0:0 -c:0 h264_nvenc -qp 20 -preset p4 -map 0:1 -c:1 copy -pix_fmt yuv420p output.mkv
```

**Why `hardwareDecoding: "false"`:** HEVC Main 10 sources have 10-bit pixel format (yuv420p10le / p010le). When `-hwaccel cuda` is active, the GPU decoder outputs p010le frames, which h264_nvenc rejects with "10 bit encode not supported". Setting hardwareDecoding=false removes -hwaccel cuda — the CPU decodes and converts 10-bit→8-bit, then the GPU encodes via h264_nvenc.

**Why `-pix_fmt yuv420p`:** Explicitly forces 8-bit output. Without it, CPU decode of 10-bit HEVC may pass p010le to h264_nvenc even without -hwaccel. Belt-and-suspenders fix that ensures 10-bit sources always produce 8-bit H.264.

**Tdarr CRUD API pattern:**
```powershell
# Read all staged jobs
$r = Invoke-RestMethod -Method Post "http://localhost:8265/api/v2/cruddb" -ContentType "application/json" -Body '{"data":{"collection":"StagedJSONDB","mode":"getAll"}}'

# Valid collection names: StagedJSONDB, FileJSONDB, FlowsJSONDB, StagedJSONDB
# (NOT the library ID — that causes 400 "must be equal to one of the allowed values")

# Check active worker status (shows current file + ffmpeg preset + percentage)
Invoke-RestMethod "http://localhost:8265/api/v2/get-nodes"

# Trigger fresh library scan (re-evaluates all files, including reset ones)
$body = '{"data":{"dbID":"rUP5cniqB","mode":"scanFresh","scanConfig":{"dbID":"rUP5cniqB","mode":"scanFresh","arrayOrPath":"/data/movies"}}}'
Invoke-RestMethod -Method Post "http://localhost:8265/api/v2/scan-files" -Body $body -ContentType "application/json"
# Use scanFresh not scanFindNew — scanFindNew skips files with cleared TranscodeDecisionMaker

# Reset files for re-processing (e.g. after flow config change)
$body = '{"data":{"fileIds":["id1","id2"],"updatedObj":{"TranscodeDecisionMaker":"","lastTranscodeDate":0}}}'
Invoke-RestMethod -Method Post "http://localhost:8265/api/v2/bulk-update-files" -Body $body -ContentType "application/json"
```

**TranscodeDecisionMaker values:**
- `""` — not yet evaluated (will be picked up on next scan)
- `"Not required"` — file was not HEVC, flow passed through without encoding
- `"Transcode success"` — successfully re-encoded to H.264
- `"Transcode error"` — ffmpeg failed (check job report for error; common: 10-bit encode without -pix_fmt yuv420p)

---

## Common API Operations

**Trigger Jellyfin library scan:**
```powershell
Invoke-RestMethod -Method Post "http://localhost:8096/Library/Refresh?api_key=f21e09ab3bc44eef9d50445aca69bf4e"
```

**List Sonarr series with IDs:**
```powershell
Invoke-RestMethod "http://localhost:8989/api/v3/series?apikey=ee46bcbfbdfe48e4b7863db24f6ecb25" | ForEach-Object { "$($_.id) $($_.title)" }
```

**Season search (better than episode search for completed seasons on public trackers):**
```powershell
$body = '{"name":"SeasonSearch","seriesId":2,"seasonNumber":1}'
Invoke-RestMethod -Method Post "http://localhost:8989/api/v3/command?apikey=ee46bcbfbdfe48e4b7863db24f6ecb25" -Body $body -ContentType "application/json"
```

**Check missing episodes:**
```powershell
$eps = Invoke-RestMethod "http://localhost:8989/api/v3/episode?apikey=ee46bcbfbdfe48e4b7863db24f6ecb25&seriesId=2&seasonNumber=1"
$eps | Where-Object { -not $_.hasFile } | Sort-Object episodeNumber | ForEach-Object { "E$($_.episodeNumber): $($_.title)" }
```

**Interactive release search (see scores and rejection reasons for a specific episode):**
```powershell
$releases = Invoke-RestMethod "http://localhost:8989/api/v3/release?apikey=ee46bcbfbdfe48e4b7863db24f6ecb25&episodeId=<id>"
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
