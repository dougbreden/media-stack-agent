# Media Stack — Development Brief

This document summarises the development history, current architecture, scripts, diagnosed failure modes, and agentic design of this project. Intended as context for an external review.

---

## What This Is

A fully automated self-hosted media pipeline running on a single Windows 10 PC. The user requests a movie or TV show, the stack finds it, downloads it through a VPN, transcodes it to a universal format, and delivers it to any device via Jellyfin. The stack runs entirely in Docker Desktop with 13 containers on a WSL2 backend.

The project has evolved from a hand-managed stack into an agentic system: the repo, scripts, and documentation are structured so Claude Code can operate and repair it remotely with minimal human intervention.

**GitHub:** https://github.com/dougbreden/homelab-agent

---

## Hardware

- **OS:** Windows 10 Pro
- **GPU:** NVIDIA RTX 4070 Ti — used for NVENC transcoding in both Jellyfin and Tdarr
- **Storage:** 7.4 TB (M:\) for media; ~3.5 TB currently free
- **Docker:** Docker Desktop with WSL2 backend

---

## Tech Stack — 13 Containers

| Container | Image | Role |
|---|---|---|
| `jellyfin` | linuxserver/jellyfin | Streaming server; NVENC HLS transcoding |
| `sonarr` | linuxserver/sonarr | TV show automation |
| `radarr` | linuxserver/radarr | Movie automation |
| `prowlarr` | linuxserver/prowlarr | Indexer aggregator (YTS, Nyaa, TPB, EZTV, TGx) |
| `jellyseerr` | fallenbagel/jellyseerr | User-facing request UI |
| `qbittorrent` | linuxserver/qbittorrent | Torrent client (no network namespace of its own) |
| `gluetun` | qmcgaw/gluetun | Mullvad WireGuard VPN gateway |
| `tdarr` | haveagitgat/tdarr | Background HEVC→H264 transcoder |
| `bazarr` | linuxserver/bazarr | Subtitle downloader |
| `homarr` | ajnart/homarr | Dashboard |
| `watchtower` | containrrr/watchtower | Nightly image updater |
| `unpackerr` | golift/unpackerr | Extracts compressed downloads |
| `flaresolverr` | flaresolverr/flaresolverr | Cloudflare bypass for certain indexers |

### Key Networking Constraint

`qbittorrent` runs with `network_mode: service:gluetun` — it has no independent network namespace and shares Gluetun's. This means:
- After **any** Gluetun restart, `qbittorrent` must be **recreated** (not restarted), because it holds a reference to the old container ID
- All traffic from qBittorrent exits through Mullvad
- No port forwarding (Mullvad removed it) — seeding always shows "Stalled", which is normal

### GPU Passthrough (WSL2 Quirk)

NVIDIA NVENC on WSL2 is exposed as `/dev/dxg`, **not** `/dev/nvidia0`. Every guide assumes the latter. Both Jellyfin and Tdarr use the same GPU through this path via `NVIDIA_VISIBLE_DEVICES=all` and `NVIDIA_DRIVER_CAPABILITIES=all` in `docker-compose.yml`.

---

## Data Architecture

### Hardlink Layout

Torrent files and library files share the same inode (hardlink). No duplicate disk usage. Critical consequence: **torrents must never be deleted** — only stopped/paused. Deleting removes the inode and destroys the library copy.

```
/data/torrents/     ← qBittorrent downloads here (source, never modified)
      │
      │ hardlink (same inode)
      ▼
/data/movies/       ← Radarr-managed (mutable — Tdarr processes this)
/data/tv/           ← Sonarr-managed (mutable — Tdarr processes this)
```

### Library Tiers

| Tier | Path | Format Standard | Tdarr |
|---|---|---|---|
| Universal | `/data/movies`, `/data/tv` | H.264 + MKV + AAC stereo | Yes |
| Premium 4K (planned) | `/data/movies-4k`, `/data/tv-4k` | HEVC, direct-play only | Never |

Tdarr only mounts `/data/movies` and `/data/tv`. It **must never** be configured to touch `/data/torrents` or future 4K paths.

---

## Credential Pattern

Secrets are never committed. Two gitignored files carry all credentials:

- `.env` — WireGuard private key, assigned IP, Radarr/Sonarr API keys (used by `docker-compose.yml` via `${VARIABLE}` references)
- `scripts/config.ps1` — Full API keys for all services, qBittorrent login (dot-sourced by all scripts via `. "$PSScriptRoot\config.ps1"`)

Committed templates: `.env.example` and `scripts/config.ps1.example`.

---

## Scripts

All scripts live in `scripts/`. All credential-using scripts load `config.ps1` at the top. Logging goes to `logs/automation-YYYY-MM.log` via `[System.IO.File]::AppendAllText` (no BOM).

| Script | Purpose |
|---|---|
| `maintain-stack.ps1` | 7-step health check: disk, containers, VPN, qBittorrent, downloads, standardize, firewall |
| `maintain-downloads.ps1` | Audit dead metaDL, dangerous file extensions, stalled torrents |
| `standardize-library.ps1` | Dedup audio → reset Tdarr errors → remux to MKV → Tdarr scanFresh |
| `library-report.ps1` | Codec/container/AAC compliance report across both libraries |
| `check-missing.ps1` | List all monitored content with no file; optionally trigger searches |
| `check-media-policy.ps1` | Validate the torrent/library hardlink boundary is intact |
| `setup-scheduled-tasks.ps1` | Register all 4 Windows scheduled tasks (requires admin once) |
| `setup-firewall.ps1` | Apply Windows Firewall rules for all Docker container ports |
| `fix-vpn.ps1` | Force-recreate Gluetun + recreate qBittorrent |
| `startup-stack.ps1` | Wait for Docker Desktop, then `docker compose up -d` |
| `remux-library-to-mkv.ps1` | Stream-copy MP4/AVI/TS to MKV (dry-run by default) |
| `dedup-audio.ps1` | Remove duplicate audio streams from library files |
| `tdarr-deploy-universal-flow.ps1` | Deploy the Universal H264+AAC flow to Tdarr via SQLite |
| `tdarr-reset-universal-files.ps1` | Reset errored (default) or all Tdarr file decisions |
| `backup-config.ps1` | Archive container config directories |
| `update.ps1` | Full maintenance: pull images, rebuild VPN, health check, Jellyfin scan, prune, firewall |

### Scheduled Tasks (Windows Task Scheduler)

| Task | Schedule | What it runs |
|---|---|---|
| `MediaStack-Startup` | At logon | `startup-stack.ps1` |
| `MediaStack-VpnReset` | Daily 02:00 | `fix-vpn.ps1` |
| `MediaStack-Standardize` | Daily 03:30 | `standardize-library.ps1` |
| `MediaStack-Firewall` | On-demand (elevated) | `setup-firewall.ps1` |

`MediaStack-Firewall` is registered with `RunLevel Highest` and `LogonType S4U` so `Start-ScheduledTask` from a non-admin process (including Claude Code) triggers it elevated without a UAC prompt.

---

## Jellyfin Scheduled Tasks (Rescheduled)

Jellyfin's built-in task scheduler had two tasks configured at problematic intervals. Both were updated via the Jellyfin API:

| Task | Was | Now | Reason |
|---|---|---|---|
| Optimize database | Every 6 hours (interval) | Daily 06:00 | Ran at 21:27 nightly; SQLite VACUUM poisoned connection pool ~30 min later, blocking playback at 22:00 |
| Scan Media Library | Every 12 hours (interval, drifting) | Daily 04:00 | Fixed clock time; follows the 03:30 standardize run so Tdarr output is picked up consistently |

---

## Tdarr — Universal H264+AAC Flow

Tdarr runs background transcoding to standardise the library to H.264 + MKV + AAC stereo.

**Flow ID:** `N7tOvfd6i` (name: "Universal H264+AAC")

**Four branches:**

| Video | Audio has AAC? | Action |
|---|---|---|
| H264 | Yes | Skip — already compliant |
| H264 | No | Copy video + add AAC stereo 192k |
| non-H264 (HEVC/AV1/etc.) | Yes | GPU encode h264_nvenc, keep audio |
| non-H264 | No | GPU encode h264_nvenc + add AAC stereo |

**Critical implementation details:**

- Flow is stored in **SQLite** (`config/tdarr/.../database.db`), not accessible via the cruddb API
- Every plugin node must have both `inputs` AND `inputsDB` fields with identical values — missing `inputsDB` causes the worker to silently read defaults (causing the hevc_nvenc bug)
- `hardwareDecoding: "false"` is required: HEVC Main 10 sources are 10-bit (yuv420p10le); with `-hwaccel cuda`, GPU decoder outputs p010le which h264_nvenc rejects
- `-pix_fmt yuv420p` belt-and-suspenders fix to force 8-bit output

---

## Language Custom Formats (Sonarr + Radarr)

Both apps apply identical scoring to all quality profiles:

| Format | Score | Purpose |
|---|---|---|
| Preferred Groups | +500 | Yameii, HakataRamen, SubsPlease, Erai-raws, Judas, LostYears, Arg0 |
| Dual Audio | +400 | JP+EN dual audio |
| Language: English | +300 | English audio track |
| English Subs | +200 | Preferred subtitle release groups |
| Non-English | -10000 | Blocks French/German/etc. scene releases |

**Non-English regex critical note:**

The blocking regex uses `(?<!dual[\s.]?)\bmulti\b` to allow `Dual Multi` releases (e.g. HakataRamen JP+EN) while blocking French scene `MULTi` releases. Sonarr's regex engine silently ignores inline case flags (`(?-i:MULTi)`), so that approach fails without any error. The lookbehind is the only working solution.

---

## Failure Modes Diagnosed and Fixed (This Session)

### 1. DNS — Tracker Domains Blocked Through VPN

**Symptom:** All trackers show "Not Working" / DNS resolution failures.
**Cause:** Gluetun's default DNS uses DNS-over-TLS, which blocked torrent tracker domains even with `BLOCK_MALICIOUS=off`.
**Fix:** Set `DNS_UPSTREAM_RESOLVER_TYPE=plain` with `DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53` in `docker-compose.yml`. Traffic still routes through Mullvad; DoT blocking simply doesn't occur.

### 2. qBittorrent Crash Loop (Stale Lockfile)

**Symptom:** qBittorrent starts then immediately exits.
**Cause:** Stale `lockfile` and/or `ipc-socket` left in the config dir from a prior crash.
**Fix:** `docker exec qbittorrent sh -c "rm -f /config/qBittorrent/lockfile /config/qBittorrent/ipc-socket"` then `docker compose up -d qbittorrent`.

### 3. Non-English Releases Getting Through (MULTi)

**Symptom:** Sonarr/Radarr grabbed French or German `MULTi` releases.
**Cause:** Initial regex `(?-i:MULTi)` to make the match case-sensitive — Sonarr silently ignores inline flag changes.
**Fix:** Replaced with lookbehind `(?<!dual[\s.]?)\bmulti\b` under the global `(?i)` flag.

### 4. Tdarr Encoding to HEVC Instead of H264

**Symptom:** Worker produced hevc_nvenc output despite the flow being configured for h264_nvenc.
**Cause:** Flow plugin nodes only had `inputs` fields; worker reads `inputsDB`, which was absent, so it fell back to plugin defaults (outputCodec=hevc, hardwareType=auto).
**Fix:** Added `inputsDB` to every plugin node in the flow JSON with values identical to `inputs`. Updated via SQLite directly with Tdarr stopped.

### 5. Tdarr "10 bit encode not supported"

**Symptom:** Jobs failed for HEVC Main 10 source files.
**Cause:** With `-hwaccel cuda`, GPU decoder outputs p010le (10-bit); h264_nvenc cannot encode 10-bit.
**Fix:** Set `hardwareDecoding: "false"` in `ffmpegCommandSetVideoEncoder` (CPU decode converts 10-bit to 8-bit). Added `-pix_fmt yuv420p` via `ffmpegCommandCustomArguments` as belt-and-suspenders.

### 6. Tdarr Queue Empty After File Reset

**Symptom:** After resetting `TranscodeDecisionMaker` to `""`, fresh scan picked up nothing.
**Cause:** Used `scanFindNew` mode which only processes new/changed files, not files with a cleared decision.
**Fix:** Use `scanFresh` mode in the scan-files API — re-evaluates every file regardless of prior state.

### 7. Jellyseerr Crash Loop (UTF-8 BOM)

**Symptom:** Jellyseerr crash-looped with "Unexpected token '﻿'" in logs.
**Cause:** `settings.json` was written with a UTF-8 BOM by PowerShell 5.1's `Set-Content -Encoding utf8`.
**Fix:** All config JSON writes now use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))`. Never use `Set-Content -Encoding utf8` or `Out-File -Encoding utf8` on JSON config files.

### 8. Jellyfin Auth Working on Desktop But Failing on Phone

**Symptom:** Valid credentials rejected on iOS app.
**Cause:** A native Jellyfin Server installation was running alongside Docker, claiming remote connections on port 8096.
**Fix:** Kill `jellyfin.exe` + `Jellyfin.Windows.Tray.exe`, remove `JellyfinTray` from HKCU startup, uninstall "Jellyfin Server" from Windows Apps.

### 9. Sonarr `wanted/missing` API Returning Blank Series Titles

**Symptom:** `check-missing.ps1` showed all missing episodes under "Unknown (id=...)" or a single series with 742 episodes.
**Cause:** Sonarr's `/api/v3/wanted/missing` endpoint returns only `seriesId` in episode records, not an embedded `series` object.
**Fix:** Pre-fetch all series via `/api/v3/series`, build a `$seriesById` hashtable keyed by `$_.id`, join per episode using `$ep.seriesId`.

### 10. Jellyfin Phone Playback Failing (SQLite Error 5)

**Symptom:** Movies not starting on phone; user tested twice on different days at ~22:00, both times failed.
**Cause:** Jellyfin's "Optimize database" scheduled task was configured as an `IntervalTrigger` (every 6 hours), producing runs at 03:27, 09:27, 15:27, and **21:27** local time. The VACUUM operation completed cleanly but left Jellyfin's EF Core connection pool in a broken state. Stale connections expired ~30 minutes later, causing `SQLite Error 5: unable to delete/modify user-function due to active statements` on every subsequent `/Items` query — the exact path used when tapping a movie to play.
**Fix:** Changed "Optimize database" from `IntervalTrigger` (every 6 hours) to `DailyTrigger` at **06:00**. Also changed "Scan Media Library" from 12-hour interval to `DailyTrigger` at **04:00**. Both changes made via the Jellyfin API and verified persisted to `config/jellyfin/ScheduledTasks/*.js`.

### 11. Firewall Rules Silently Dropped After Docker Desktop Updates

**Symptom:** `maintain-stack.ps1` step 7 always skipped ("Not running as Administrator"), so firewall rules were never validated or repaired by the agent.
**Root Cause:** The firewall step required admin elevation that a non-admin Claude Code session can't provide via UAC.
**Fix (in progress):** Added `MediaStack-Firewall` scheduled task (`RunLevel Highest`, `LogonType S4U`) to `setup-scheduled-tasks.ps1`. Updated `maintain-stack.ps1` step 7 to call `Start-ScheduledTask "MediaStack-Firewall"` instead of directly invoking the script. Added `Start-ScheduledTask`, `Get-ScheduledTask`, `Get-ScheduledTaskInfo` to `.claude/settings.json` allow list. Task requires one-time admin registration via `setup-scheduled-tasks.ps1`.

---

## Agentic Design

### Claude Code Integration

`CLAUDE.md` at the repo root encodes the full operational context for an agent: every architectural constraint, known failure mode, regex rationale, and recovery procedure. An agent reading only that file has enough context to diagnose and fix the most common failures without human explanation.

### Slash Commands (`.claude/commands/`)

| Command | Action |
|---|---|
| `/health` | Run `maintain-stack.ps1`, report by section |
| `/check` | Run `library-report.ps1`, report compliance gaps |
| `/missing` | Run `check-missing.ps1`, annotate likely causes, suggest searches |
| `/search <title>` | Look up in Sonarr/Radarr, show gaps, optionally trigger search |

### `docs/AGENTS.md`

Prime directives for any agent operating the stack:
- Never delete torrents (hardlink inode)
- Never touch 4K library paths with Tdarr
- Never commit `.env`, `api-keys.md`, or `config.ps1`
- Never use `Set-Content -Encoding utf8` on JSON config files (BOM bug)
- Always recreate (not restart) qBittorrent after any Gluetun change
- Run `check-media-policy.ps1` after any compose, qBittorrent, or library-layout change

---

## Current Known Issues / Open Items

1. **`MediaStack-Firewall` task not yet registered** — `setup-scheduled-tasks.ps1` was updated but the task requires one manual elevated run to register. Until then, `maintain-stack.ps1` step 7 warns and skips.

2. **Stalled torrents (older TV series)** — Old releases with 0 seeds for 135+ hours. These torrents are using outdated individual-episode release formats; the content may be available as season packs on Nyaa under current groups (SubsPlease, Erai-raws). Action: delete stalled individual-episode torrents, let Sonarr re-search as season packs.

3. **One corrupt MP4 file** — Failing ffprobe and ffmpeg remux permanently. Isolated to that one file; stack is otherwise healthy.

4. **743 missing TV episodes** — Mostly older content unlikely to be on public indexers. Popular long-running TV series should be searchable via season pack commands.

5. **Jellyfin phone access not confirmed** — The SQLite fix was applied (task rescheduled) but the user hasn't re-tested since the fix was made. The phone-not-loading issue at the time of diagnosis was likely the firewall (maintain-stack couldn't check it without admin). Needs re-test.

---

## Repository Structure

```
M:\Media\
├── docker-compose.yml          # All 13 container definitions
├── .env                        # Gitignored — WireGuard + API keys
├── .env.example                # Committed template
├── CLAUDE.md                   # Agent operating context
├── README.md                   # Project overview + quickstart
├── update.ps1                  # Full maintenance script
├── scripts\
│   ├── config.ps1              # Gitignored — actual API keys
│   ├── config.ps1.example      # Committed template
│   └── *.ps1                   # All automation scripts
├── docs\
│   ├── RUNBOOK.md              # Full setup + troubleshooting guide
│   ├── AGENTS.md               # Agent prime directives
│   ├── USAGE.md                # End-user guide
│   ├── STANDARDS.md            # Library format standards
│   ├── LOG.md                  # Operational history
│   └── brief.md                # This document
├── logs\
│   └── .gitkeep                # Directory tracked; *.log gitignored
└── .claude\
    ├── settings.json           # Claude Code permissions
    └── commands\               # Slash command definitions
```
