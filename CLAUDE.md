# CLAUDE.md — Self-Hosted Media Stack

This is a fully automated self-hosted media pipeline at `M:\Media` running 12 Docker containers on Windows with Docker Desktop (WSL2 backend). See `README.md` for the human-readable runbook. This file is for Claude Code context.

**User workflow:** Request in Jellyseerr → Sonarr/Radarr search → qBittorrent downloads (through Mullvad VPN) → imported and organised → appears in Jellyfin.

---

## Key Files

| File | Purpose |
|---|---|
| `M:\Media\docker-compose.yml` | All 12 container definitions — uses ${VARIABLE} references for secrets |
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
