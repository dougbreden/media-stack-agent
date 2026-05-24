# Media Stack — Usage Guide

How to use the stack day-to-day. For setup, troubleshooting, and infrastructure details see `README.md`.

---

## Accessing the Stack

All services are available on the local network and via Tailscale (when your device has Tailscale installed).

| Service | Local URL | What it does |
|---|---|---|
| **Homarr** (dashboard) | http://192.168.1.64:7575 | Tiles linking to all services |
| **Jellyfin** (watch) | http://192.168.1.64:8096 | Stream movies and TV |
| **Jellyseerr** (request) | http://192.168.1.64:5055 | Request new movies and TV shows |

Via Tailscale (from anywhere, e.g. cellular): replace `192.168.1.64` with `100.67.113.36`.

**Note:** On iOS, Mullvad VPN and Tailscale cannot both be active at once. Disable Mullvad before connecting via Tailscale.

---

## Requesting Content

1. Open **Jellyseerr** → http://192.168.1.64:5055
2. Search for any movie or TV show
3. Click **Request** → select quality (1080p is the default)
4. Done — content downloads automatically and appears in Jellyfin within minutes to an hour

**TV shows:** You can request an entire series or specific seasons. Sonarr monitors for new episodes automatically — once a show is added, future episodes appear as they release.

---

## Watching Content

**Desktop (browser):** http://192.168.1.64:8096 — works in any browser, direct play for most files.

**iOS — Jellyfin app (free):**
- Add server: `http://192.168.1.64:8096` (LAN) or `http://100.67.113.36:8096` (cellular via Tailscale)
- In app Settings → Max Streaming Bitrate → set to **Original** (otherwise the app re-encodes unnecessarily on top of the HLS stream)
- Seeking causes a 2–4 s blank screen — this is normal, not a bug (the app always uses HLS on iOS)

**iOS — Swiftfin (free, better for local use):**
- Use **Native (AVPlayer)** mode for direct play — fastest, no seek lag
- Built-in player uses HLS like the official app

**Apple TV / Infuse (if using Pro):**
- Infuse free: can browse the library but video playback on cellular requires Infuse Pro
- Infuse Pro: Settings → Playback → Streaming Quality → Cellular → set to a fixed bitrate to force server-side transcode at a predictable rate

---

## Accounts

| Account | For |
|---|---|
| `admin` / `idbeholdg` | Full access — Jellyfin, Jellyseerr, all admin UIs |
| the mobile account | Jellyfin only — 8 Mbps bitrate cap for mobile viewing |

---

## Content Notes

**Language preferences are automatic:**
- English audio is preferred (+300 score)
- Dual audio (English + Japanese) is preferred for content (+400 score)
- French, German, and other non-English-only releases are filtered out
- content is sourced from Nyaa.si (SubsPlease, Erai-raws, Judas groups preferred)

**Seeding:** Downloaded torrents continue seeding until they hit a 1:1 ratio, then pause automatically. This is normal — the files are still fully accessible in Jellyfin.

**Transcoding:** A background process (Tdarr) converts HEVC files to H.264 for better iOS compatibility. After Tdarr converts a file, Jellyfin rescans the library nightly — until then, HLS streaming of that specific file may fail (direct play still works). You can trigger an immediate rescan at: Dashboard → Libraries → (three dots) → Scan All Libraries.

---

## What Runs Automatically

| What | When |
|---|---|
| New episode monitoring (Sonarr) | Continuous |
| Docker image updates (Watchtower) | Nightly 3am |
| Jellyfin library scan | Nightly |
| Background HEVC→H264 conversion (Tdarr) | Continuous while stack is up |
| VPN (Mullvad via Gluetun) | Always on for downloads |

---

## If Something Looks Wrong

**Movie/show won't download after requesting:**
- Check Jellyseerr — it shows request status (Pending → Approved → Downloading)
- If stuck at "Pending", Sonarr/Radarr may not have found a matching release — can take up to 24h for automated searches

**Video won't play (spinning/error):**
- Try a different player (Swiftfin native player, or desktop browser)
- If desktop works but phone doesn't: check Tailscale is active and Mullvad is off on the phone
- If nothing plays: the stack may be down — check http://192.168.1.64:7575 (Homarr will show offline tiles)

**Stack appears down:**
- On the server PC, open PowerShell in `M:\Media` and run `docker compose up -d`
- The startup task usually handles this on reboot automatically

**Wrong audio language playing:**
- During playback in Jellyfin → gear icon → Audio → select English

