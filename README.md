# Self-Hosted Media Stack — M:\Media

A fully automated movie and TV pipeline on Windows with Docker Desktop.
This document is a **runbook** — everything needed to reproduce this setup from scratch or hand it to someone else.

**Daily use is simple: Jellyseerr to request content, Jellyfin to watch it. Everything else runs invisibly in the background.**

---

## Credentials

| What | Value |
|---|---|
| All app web UI username | `admin` |
| All app web UI password | `idbeholdg` |
| WireGuard key name | REDACTED (created 2026-05-06) |
| WireGuard key + assigned IP | Stored in `docker-compose.yml` under the `gluetun` service |
| VPN server | Netherlands (Amsterdam) — switched from Singapore due to tracker IP blocking |

To regenerate the WireGuard key: mullvad.net → WireGuard keys → generate new key → download `.conf` file.
The `.conf` file contains `PrivateKey` and `Address` — update those in docker-compose.yml under `gluetun`, then:
```powershell
docker compose up -d gluetun
```

---

## Quick Reference — Service URLs

| Service | Local | Via Tailscale | Credentials |
|---|---|---|---|
| **Jellyfin** (watch) | http://localhost:8096 | http://100.67.113.36:8096 | admin / idbeholdg |
| **Jellyseerr** (request) | http://localhost:5055 | http://100.67.113.36:5055 | admin / idbeholdg |
| **Homarr** (dashboard) | http://localhost:7575 | http://100.67.113.36:7575 | admin / !GeosaT@42 |
| **Radarr** (movies) | http://localhost:7878 | http://100.67.113.36:7878 | admin / idbeholdg |
| **Sonarr** (TV) | http://localhost:8989 | http://100.67.113.36:8989 | admin / idbeholdg |
| **qBittorrent** (downloads) | http://localhost:8080 | http://100.67.113.36:8080 | admin / idbeholdg |
| **Prowlarr** (indexers) | http://localhost:9696 | http://100.67.113.36:9696 | admin / idbeholdg |
| **Bazarr** (subtitles) | http://localhost:6767 | http://100.67.113.36:6767 | admin / idbeholdg |
| **FlareSolverr** | http://localhost:8191 | — | no UI |
| **Gluetun** (VPN) | — | — | no UI |
| **Unpackerr** | — | — | no UI |
| **Watchtower** | — | — | no UI |

---

## Day-to-Day Usage

| Task | Where |
|---|---|
| Browse and request a movie or TV show | Jellyseerr — http://localhost:5055 |
| Watch content | Jellyfin Media Player app (desktop), Infuse app (iPhone, recommended), or Jellyfin app (phone) |
| Check download progress | qBittorrent — http://localhost:8080 |
| Monitor services at a glance | Homarr — http://localhost:7575 |
| Everything else | Runs automatically in the background |

You do not need to touch Radarr, Sonarr, Prowlarr, or any other app for normal use.

---

## Stack

| Container | Role | Port | UI |
|---|---|---|---|
| jellyfin | Media server | 8096 | http://localhost:8096 |
| jellyseerr | Request UI (browse & request) | 5055 | http://localhost:5055 |
| homarr | Dashboard — links to all services + live stats | 7575 | http://localhost:7575 |
| prowlarr | Torrent indexer manager | 9696 | http://localhost:9696 |
| flaresolverr | Cloudflare bypass for indexers | 8191 | (no UI — API only) |
| gluetun | VPN gateway (Mullvad WireGuard) | — | (no UI — network gateway) |
| radarr | Movie automation | 7878 | http://localhost:7878 |
| sonarr | TV automation | 8989 | http://localhost:8989 |
| qbittorrent | Torrent client (routes through gluetun) | 8080 | http://localhost:8080 |
| bazarr | Subtitle downloader | 6767 | http://localhost:6767 |
| unpackerr | Auto-extracts RAR/ZIP downloads | — | (no UI — background daemon) |
| watchtower | Auto-updates all container images nightly | — | (no UI — background daemon) |

**Total: 12 containers.** All have `restart: unless-stopped` — they come back automatically after crashes or reboots as long as Docker Desktop is running.

**Images:** linuxserver.io for all except jellyseerr (fallenbagel), flaresolverr, unpackerr, and gluetun (qmcgaw).
Docker Desktop on Windows runs Linux containers inside a WSL2 VM — linuxserver.io images are the standard choice regardless of host OS.

**VPN:** Gluetun runs Mullvad WireGuard. qBittorrent shares Gluetun's network stack via `network_mode: service:gluetun` — all torrent traffic exits through Mullvad Singapore. Mullvad removed SOCKS5 proxies, so Gluetun is the correct approach. Because qBittorrent has no independent network identity, other containers (Radarr, Sonarr) reach it via the hostname `gluetun`, not `qbittorrent`.

---

## Folder Structure

```
M:\Media\
├── docker-compose.yml          ← Container definitions — uses .env for secrets
├── .env                        ← WireGuard key, API keys — never commit this file
├── config\
│   ├── jellyfin\       ← Jellyfin app config & metadata
│   ├── radarr\         ← Radarr database & config
│   ├── sonarr\         ← Sonarr database & config
│   ├── prowlarr\       ← Prowlarr indexer config
│   ├── qbittorrent\    ← qBittorrent settings
│   ├── jellyseerr\     ← Jellyseerr config
│   ├── bazarr\         ← Bazarr subtitle config
│   ├── homarr\         ← Homarr board config (default.json), icons, and auth DB
│   └── unpackerr\      ← (reserved — Unpackerr is configured via env vars)
└── data\
    ├── movies\         ← Final movie library (Jellyfin reads here)
    ├── tv\             ← Final TV library (Jellyfin reads here)
    └── torrents\
        ├── movies\     ← Completed movie downloads (Radarr imports from here)
        ├── tv\         ← Completed TV downloads (Sonarr imports from here)
        └── incomplete\ ← In-progress downloads
```

### Why Radarr/Sonarr mount full /data

Radarr and Sonarr mount `M:/Media/data` as `/data` (not subdirectories).
From their perspective, `/data/torrents/movies` and `/data/movies` are on the same filesystem.
That's required for **hardlinks** — when importing a finished torrent, the file is hardlinked (not copied), so the library and seeding copy share the same inode. No double disk usage.

### Why qBittorrent has no ports or networks in the compose file

qBittorrent uses `network_mode: "service:gluetun"`, sharing Gluetun's entire network stack.
Ports must be declared on the gateway container (gluetun), not the app container.
qBittorrent cannot have a `networks:` key — it has no independent network identity.
Side effect: all other containers that need to connect to qBittorrent must use `gluetun` as the hostname, not `qbittorrent`.

---

## Known Issues & Gotchas

This section documents every non-obvious problem encountered during setup and operation. Intended to prevent repeating the same debugging when rebuilding or when an AI assistant is helping.

### VPN — Mullvad removed SOCKS5 proxies
Mullvad no longer offers SOCKS5 proxies. Any guide recommending qBittorrent → Connection → Proxy → SOCKS5 with a Mullvad host is outdated. The correct approach is Gluetun (a VPN gateway container). qBittorrent routes all traffic through Gluetun via `network_mode: service:gluetun`.

### qBittorrent hostname is `gluetun`, not `qbittorrent`
Because qBittorrent shares Gluetun's network stack, it has no independent Docker hostname. Any container that needs to reach qBittorrent (Radarr, Sonarr) must use `gluetun` as the host, port `8080`. Using `qbittorrent` will fail with a connection error.

### All internal container URLs use `http://` not `https://`
Containers on the Docker internal network have no SSL certificates. Always use `http://`. Using `https://` or a single slash (`http:/container`) will fail.

### Prowlarr — FlareSolverr tag must be set on BOTH the proxy and the indexer
Adding FlareSolverr as a proxy in Prowlarr is not enough. You must:
1. Add a tag (e.g. `flaresolverr`) to the FlareSolverr proxy entry
2. Add that same tag to each Cloudflare-protected indexer (EZTV, 1337x, etc.)
Without the tag on the indexer, FlareSolverr is never invoked and the indexer returns a Cloudflare block.

### Prowlarr — FlareSolverr periodically fails against specific indexers
FlareSolverr vs Cloudflare is an ongoing arms race. After a Cloudflare update, some indexers will return `403 Forbidden` even with FlareSolverr. Symptoms: indexer shows "unavailable due to failures" in Prowlarr/Sonarr/Radarr.
- First try: update FlareSolverr — `docker compose pull flaresolverr && docker compose up -d flaresolverr`
- If still failing: disable the indexer temporarily, re-enable after a future FlareSolverr update
- 1337x was disabled 2026-05-06 for this reason — re-test periodically
- Remaining indexers (YTS, TPB, EZTV) provide sufficient coverage in the meantime

### Radarr/Sonarr — hardlinks option hidden behind Show Advanced
The "Use Hardlinks instead of Copy" setting in Settings → Media Management is not visible by default. Click the **"Show Advanced"** toggle at the top right of the page to reveal it. Must be enabled or Radarr/Sonarr will copy files instead of hardlinking, using double the disk space.

### Radarr/Sonarr — default size limits block large releases
Quality profiles have per-format file size caps that default to conservative values (e.g. 9.6GB for 1080p). Releases larger than the cap show a warning and are skipped by automatic search. Fix: Settings → Quality → set max size to `0` (unlimited) for all 1080p and higher formats. With large storage this should always be unlimited.

### Radarr/Sonarr — automatic search not triggered by Jellyseerr by default
When Jellyseerr sends a request to Radarr/Sonarr, it adds the media as monitored but does not trigger an immediate search unless "Search Automatically" is enabled. Fix: Jellyseerr → Settings → Services → Radarr/Sonarr → edit server → enable **"Search Automatically"**.

### Stalled torrents — dead releases with zero seeders
Radarr/Sonarr's automatic search picks the best matching release but sometimes grabs one with no active seeders. Symptoms: qBittorrent shows the torrent as "Stalled" with 0 seeds and 0 peers.
Fix: delete the stalled torrent from qBittorrent (right-click → Delete → delete files), then in Radarr/Sonarr use **Interactive Search** on that item to manually pick a release that shows seeders > 0.
Interactive search is a troubleshooting tool — normal operation should be fully automatic once settings are correct.

### Unpackerr — crashes with API keys shorter than 32 characters
Unpackerr validates that API keys are exactly 32 characters and exits immediately if they're not. The placeholder value `changeme` causes a crash loop. Use 32 zeros (`00000000000000000000000000000000`) as a placeholder until real API keys are available from Radarr/Sonarr Settings → General.

### Jellyfin — NVIDIA GPU requires explicit passthrough in docker-compose.yml
Jellyfin does not automatically access the host GPU. The `deploy.resources.reservations` block must be present in the `jellyfin` service definition. After adding it, enable NVENC in Jellyfin: Dashboard → Playback → Transcoding → Hardware Acceleration: NVENC → enable all format checkboxes → Save.

### Jellyfin — initial library scan causes playback jitter
When a large library is added, Jellyfin generates thumbnails, chapter images, and metadata for every file. This is CPU/disk intensive and causes dropped frames during playback. Normal behaviour — wait for Dashboard → Scheduled Tasks to show idle before judging playback quality.

### Docker Desktop blocks all inbound connections to published container ports
Docker Desktop adds two `Inbound BLOCK` firewall rules for `com.docker.backend.exe` (TCP and UDP, all ports, Private+Public profiles) when it installs. Because `com.docker.backend.exe` is the process that owns Docker's port proxy — the thing that makes published container ports reachable — these block rules silently drop all inbound connections from external devices (phones, TVs, other machines on LAN or Tailscale). Connections from `localhost` are unaffected because loopback traffic bypasses Windows Firewall entirely.

**Symptoms:** Everything works in a browser on the same machine. Phones and TVs get "could not connect to server" even with Tailscale connected and a correct URL.

**Fix:** Run `M:\Media\scripts\setup-firewall.ps1` as Administrator. It disables the two Docker Desktop Backend block rules and adds explicit allow rules for every published port in the stack. Re-run it any time Docker Desktop updates and the problem comes back.

```powershell
# Right-click PowerShell → Run as Administrator
M:\Media\scripts\setup-firewall.ps1
```

The script is idempotent — safe to re-run at any time.

### Native Jellyfin Server install conflicts with Docker Jellyfin on port 8096
The Jellyfin Server native Windows installer is a separate package from Jellyfin Media Player. If both are installed, the native server auto-starts at boot (via `JellyfinTray` in HKCU startup) and silently claims port 8096 alongside Docker's port proxy — resulting in split behaviour: localhost connections hit Docker Jellyfin (works), while remote/Tailscale connections hit the native server (different database, different credentials → "invalid username and password").

Symptoms: Jellyfin works on the local machine but fails authentication on phones/TVs over Tailscale, even with correct credentials.

Fix:
1. Kill native server: open Task Manager → find `jellyfin.exe` (not `JellyfinMediaPlayer.exe`) → End Task, and `Jellyfin.Windows.Tray.exe` → End Task
2. Remove startup entry: `Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "JellyfinTray"`
3. **Uninstall**: Settings → Apps → "Jellyfin Server" → Uninstall. Do NOT uninstall "Jellyfin Media Player".

The Docker container is the only Jellyfin Server this stack needs. The native installer serves no purpose here.

### Jellyfin — use Jellyfin Media Player, not browser, for desktop playback
The browser uses an HTML Video Player that cannot efficiently hardware-decode HEVC Main 10, causing dropped frames even with NVENC enabled and Direct Play active. Jellyfin Media Player (the real desktop app with MPV engine) direct-plays HEVC natively with zero dropped frames. Download from jellyfin.org — make sure it is the desktop app, not a PWA/browser shortcut. The real app has an MPV player option and does not open a browser tab during playback.

### Jellyfin — phone and Roku use native apps, not browser PWA
The Jellyfin mobile browser PWA always transcodes HEVC. Install the native Jellyfin app from the App Store or Play Store — modern phones hardware-decode HEVC natively. For Roku, install the Jellyfin channel from the Roku Channel Store — if the Roku doesn't support HEVC, Jellyfin transcodes automatically via NVENC on the server.

### Bazarr — language profile is in Settings → Languages, not Sonarr/Radarr sections
The language profile default assignment is found in Settings → Languages → Languages Profiles section, not within the Sonarr or Radarr connection settings pages.

### Recreating Gluetun also requires recreating qBittorrent
When Gluetun is recreated (any `docker compose up -d gluetun` after a config change), it gets a new container ID. qBittorrent holds a reference to the old container ID for its network namespace and will fail to restart with error "No such container". Always follow a Gluetun recreate with:
```powershell
docker compose up -d qbittorrent
```
A simple `docker compose restart qbittorrent` will not work — it must be `up -d` to recreate it.

### Mullvad Singapore IP is heavily blocked by torrent tracker networks
The Singapore Mullvad exit IP was blocked by most torrent tracker networks, resulting in 0 peers even for torrents with 1500+ seeds. Switched to Netherlands (Amsterdam) which is consistently the least-blocked region for P2P traffic. Sweden is also a good alternative. To change server: update `SERVER_COUNTRIES=Netherlands` in docker-compose.yml under gluetun, then `docker compose up -d gluetun` followed by `docker compose up -d qbittorrent`. Same WireGuard key works across all Mullvad servers — no new key needed.

### Gluetun DNS blocks torrent tracker domains — BLOCK_*=off is not enough
Gluetun's default DoT (DNS-over-TLS) resolver filters tracker domains even when `BLOCK_MALICIOUS=off`, `BLOCK_SURVEILLANCE=off`, and `BLOCK_ADS=off` are all set. The BLOCK settings control hostname blocklists but not the DoT upstream itself. Symptoms: qBittorrent trackers show "Not Working", "Operation not permitted", or "Operation Cancelled" — downloads stall at 0 seeds even for healthy torrents with thousands of seeds. `nslookup <tracker> 127.0.0.1` returns REFUSED.

The complete fix requires switching from DoT to plain DNS **and** disabling the blocklists:
```yaml
- BLOCK_MALICIOUS=off
- BLOCK_SURVEILLANCE=off
- BLOCK_ADS=off
- DNS_UPSTREAM_RESOLVER_TYPE=plain
- DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53
```
Then: `docker compose up -d gluetun` followed by `docker compose up -d qbittorrent`.

Using plain `1.1.1.1:53` instead of DoT is still private — all DNS traffic routes through the Mullvad tunnel (AllowedIPs=0.0.0.0/0). The VPN kill switch remains fully active.

Do not attempt to use Mullvad's internal DNS (`10.64.0.1`) as the plain upstream — it creates a chicken-and-egg problem where the DNS server must be reachable before the tunnel healthcheck passes, but the tunnel must pass before the DNS server is reachable.

Deprecated env vars that do NOT work: `DOT=off` (causes a startup error in recent Gluetun versions), `DNS_KEEP_NAMESERVER=on` (does not prevent Gluetun from running its own DNS server).

### qBittorrent "Errored" / speed drops to 0 — save path misconfiguration
Symptoms: torrent downloads start (peers found, speed shows briefly), then show status "Errored" and speed drops to 0.
Root cause: the default save path in qBittorrent was set to `/downloads/` which does not exist in the container (the volume is mounted at `/data/torrents/`). qBittorrent cannot write the file → Permission denied error → "Errored" status. The VPN and peer connectivity are fine; it's a disk write failure.
Fix: in `M:\Media\config\qbittorrent\qBittorrent\qBittorrent.conf`, ensure:
```ini
Session\DefaultSavePath=/data/torrents/
Session\TempPath=/data/torrents/incomplete/
```
Also in `[Preferences]`:
```ini
Downloads\SavePath=/data/torrents/
Downloads\TempPath=/data/torrents/incomplete/
```
After editing, `docker restart qbittorrent`. Any already-queued torrents need their location changed: right-click in qBittorrent web UI → Set Location → `/data/torrents/`.
Note: `nc -zv` port tests from inside the container can give false timeouts — a timeout just means the TARGET HOST doesn't accept that port, not that Mullvad blocks it. Confirm VPN outbound connectivity with `wget -qO- https://ifconfig.me` (shows public Mullvad IP) and `wget -qO- http://example.com` (confirms port 80 works).

### Seeding always "Stalled" with Mullvad — expected, not a bug
Mullvad removed port forwarding. Without inbound connections, qBittorrent cannot upload to peers — all seeding shows as "Stalled" with 0 upload speed permanently. This is expected and not a bug.

For **public tracker** torrents this doesn't matter — ratio is unenforced, so there is no penalty. After import, Radarr/Sonarr remove the torrent via `removeCompletedDownloads=True` on the public client. The media file is safely hardlinked in the library.

For **private tracker** torrents you must seed. Without port forwarding you can still seed via outbound connections and uTP NAT traversal — just slower than with a forwarded port. To actually build ratio on private trackers, consider switching the VPN to ProtonVPN Plus (supports WireGuard port forwarding via Gluetun — see the Gluetun block in docker-compose.yml).

**Never delete public-tracker torrents while they're still seeding** — always pause them instead. The files are hardlinked (same inode as the library copy), so there is zero extra disk usage from keeping them. Deleting from qBittorrent only removes the inode reference in `/data/torrents/` and disconnects from the swarm.

Current config in `M:\Media\config\qbittorrent\qBittorrent\qBittorrent.conf`:
```ini
Session\GlobalMaxRatioEnabled=false
Session\GlobalMaxSeedingMinutesEnabled=false
Session\ShareLimitAction=Stop
```
Global limits are disabled. Per-category seeding rules in `categories.json` handle the actual logic — public categories pause at ratio 1:1, private categories seed indefinitely.

### Gluetun iptables rules go bad after Watchtower updates — all UDP trackers fail
After Watchtower auto-updates the Gluetun image, the container is replaced but its internal iptables rules are sometimes left in a broken state. Symptoms: all torrent trackers show "Not Working" or "Operation not permitted" for UDP traffic — downloads stall at 0 seeds even for torrents you know are healthy. TCP and HTTPS traffic through the VPN still work fine. This is distinct from the DNS issue (which causes "Name resolution" failures, not "Operation not permitted").

Fix: force-recreate Gluetun, then recreate qBittorrent:
```powershell
cd M:\Media
docker compose up -d --force-recreate gluetun
docker compose up -d qbittorrent
```
A plain `docker compose restart gluetun` is not sufficient — the container must be recreated to rebuild its iptables rules from scratch.

Prevention: The `com.centurylinklabs.watchtower.depends-on=qbittorrent` label on the Gluetun service tells Watchtower to restart qBittorrent whenever Gluetun is updated. This ensures qBittorrent's network namespace reference stays valid. But it does not prevent the iptables corruption itself — if iptables go bad after an update, the manual force-recreate above is still needed.

### Watchtower crashes with "client version too old" after Docker Desktop updates
Symptom: `docker logs watchtower` shows `Error response from daemon: client version 1.25 is too old. Minimum supported API version is 1.44`. Watchtower exits immediately and is in a permanent restart loop. This happens when Docker Desktop updates its minimum API version.

Fix: add `DOCKER_API_VERSION=1.44` to the Watchtower environment in `docker-compose.yml`:
```yaml
watchtower:
  environment:
    - DOCKER_API_VERSION=1.44
```
Then: `docker compose up -d watchtower`. The container will stay running and auto-updates will resume as scheduled.

### Non-English MULTi releases bypass language keyword filters
French/German/multi-language scene releases use `MULTi` (exact capitalisation) to indicate multiple audio tracks — most commonly French primary + original secondary. They do not include the word FRENCH or GERMAN in the title. A Non-English custom format that only checks for FRENCH, VOSTFR, etc. will not catch them — they score as clean English releases and get grabbed.

**Do not use `(?-i:MULTi)` to fix this.** The `(?-i:...)` inline flag to force case-sensitivity looks correct but Sonarr's regex engine silently ignores inline case-flag changes. The clause matches nothing, and non-English `MULTi` releases slip through as if the clause didn't exist.

Fix: use a negative lookbehind in the Non-English regex:
```
(?<!dual[\s.]?)\bmulti\b
```
See the Language Custom Formats section for the full regex and a detailed breakdown of how it works.

Verify the current Non-English regex: Sonarr → Settings → Custom Formats → Non-English → edit.

### Sonarr v4 uses Custom Formats for language, not Language Profiles
Sonarr v4 removed Language Profiles entirely. Language preference is now controlled via Custom Formats with scores. A quality profile with no custom formats will grab whatever release scores highest regardless of language. See the Language Custom Formats section in Configuration below.

### Episode searches often fail for completed seasons on public trackers
Public tracker indexers stop indexing old individual episode releases after a few months. Searching for a specific episode of a completed season typically returns 0 usable results. Use SeasonSearch (via Sonarr's UI or API) instead — season pack torrents are reliably indexed long after a season ends.

### WireGuard private key belongs in docker-compose.yml, not README
The `.conf` file downloaded from Mullvad contains the private key. Store it in docker-compose.yml under the gluetun service. Do not paste it into the README or any other plaintext document that might be shared.

### Infuse free version: cellular streaming blocked
Infuse (free tier) allows library browsing from any network but blocks actual video playback on cellular/remote connections — that feature requires Infuse Pro. Symptoms: library and metadata load fine on cellular, but hitting play spins until timeout and shows "an error occurred loading this content". No error message mentions the Pro requirement.

Use the **Jellyfin iOS app** (free, App Store) as an alternative. It works on cellular with no subscription. After installing: Settings → Max Streaming Bitrate → **Original** (otherwise Jellyfin transcodes video to a lower bitrate even when direct streaming would work). See next entry for known limitation.

### Jellyfin iOS app: HLS seek lag on cellular
The iOS Jellyfin app is WebView-based and always uses HLS for video delivery on iOS — it cannot do true direct play (serving the raw file over HTTP). Jellyfin runs a lightweight FFmpeg remux in the background, converting MP4 → 6-second fMP4 HLS segments without re-encoding the video or audio. This is "Direct Stream" mode, not transcoding.

Practical consequence: every seek restarts the FFmpeg process at the new position, causing 2–4 seconds of blank screen before playback resumes. This is expected and cannot be tuned away without changing the app itself.

Infuse Pro does true direct play (no FFmpeg step), making seeking near-instant — worth considering if seek lag is disruptive.

**Do not set Jellyfin LAN Networks or Known Proxies** to try to fix remote playback in this Docker setup. Docker's port proxy makes every connection (local and remote) appear to arrive from `172.18.0.1` (the Docker bridge gateway), so Jellyfin cannot distinguish local from cellular/Tailscale traffic and these settings have no effect.

---

## Reproduce This Setup

### Prerequisites

- Windows 10/11 with Docker Desktop installed (WSL2 backend)
- Docker Desktop → Settings → General → **"Start Docker Desktop when you log in"** — enable this so containers auto-start on reboot
- Drive M: available with sufficient space
- Mullvad VPN account with a WireGuard key generated — see Credentials section
- NVIDIA GPU (optional, for hardware-accelerated transcoding in Jellyfin)

### Steps

1. Create the folder structure at `M:\Media\`:
   ```powershell
   $folders = @(
     "M:\Media\config\jellyfin","M:\Media\config\radarr","M:\Media\config\sonarr",
     "M:\Media\config\prowlarr","M:\Media\config\qbittorrent","M:\Media\config\jellyseerr",
     "M:\Media\config\bazarr","M:\Media\config\unpackerr",
     "M:\Media\config\homarr","M:\Media\config\homarr\icons","M:\Media\config\homarr\auth",
     "M:\Media\data\torrents\movies","M:\Media\data\torrents\tv",
     "M:\Media\data\torrents\incomplete","M:\Media\data\movies","M:\Media\data\tv"
   )
   $folders | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ }
   ```
2. Place `docker-compose.yml` in `M:\Media\` using the template below, with your Mullvad WireGuard credentials filled in:

<details>
<summary>docker-compose.yml template (click to expand)</summary>

```yaml
networks:
  media-network:
    driver: bridge

services:

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/jellyfin:/config
      - M:/Media/data/movies:/data/movies
      - M:/Media/data/tv:/data/tv
    ports:
      - 8096:8096
    networks:
      - media-network
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    environment:
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/jellyseerr:/app/config
    ports:
      - 5055:5055
    networks:
      - media-network
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/prowlarr:/config
    ports:
      - 9696:9696
    networks:
      - media-network
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=America/Chicago
    ports:
      - 8191:8191
    networks:
      - media-network
    restart: unless-stopped

  # qBittorrent shares this container's network stack — all torrent traffic
  # exits through Mullvad. Ports for qBittorrent are declared here.
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=mullvad
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES}
      - SERVER_COUNTRIES=Netherlands
      - TZ=America/Chicago
      - BLOCK_MALICIOUS=off
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
      - DNS_UPSTREAM_RESOLVER_TYPE=plain
      - DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53
    ports:
      - 8080:8080      # qBittorrent web UI
      - 6881:6881      # torrent TCP
      - 6881:6881/udp  # torrent UDP
    networks:
      - media-network
    labels:
      - com.centurylinklabs.watchtower.depends-on=qbittorrent
    restart: unless-stopped

  # No ports or networks — shares gluetun's network stack entirely.
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
      - WEBUI_PORT=8080
    volumes:
      - M:/Media/config/qbittorrent:/config
      - M:/Media/data/torrents:/data/torrents
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/radarr:/config
      - M:/Media/data:/data
    ports:
      - 7878:7878
    networks:
      - media-network
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/sonarr:/config
      - M:/Media/data:/data
    ports:
      - 8989:8989
    networks:
      - media-network
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/bazarr:/config
      - M:/Media/data/movies:/data/movies
      - M:/Media/data/tv:/data/tv
    ports:
      - 6767:6767
    networks:
      - media-network
    restart: unless-stopped

  unpackerr:
    image: golift/unpackerr:latest
    container_name: unpackerr
    environment:
      - TZ=America/Chicago
      - UN_RADARR_0_URL=http://radarr:7878
      - UN_RADARR_0_API_KEY=${RADARR_API_KEY}
      - UN_SONARR_0_URL=http://sonarr:8989
      - UN_SONARR_0_API_KEY=${SONARR_API_KEY}
    volumes:
      - M:/Media/data/torrents:/data/torrents
    networks:
      - media-network
    restart: unless-stopped

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    environment:
      - TZ=America/Chicago
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_STOPPED=false
      - DOCKER_API_VERSION=1.44
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - media-network
    restart: unless-stopped

  homarr:
    image: ghcr.io/ajnart/homarr:latest
    container_name: homarr
    environment:
      - TZ=America/Chicago
    volumes:
      - M:/Media/config/homarr:/app/data/configs
      - M:/Media/config/homarr/icons:/app/public/icons
      - M:/Media/config/homarr/auth:/data
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - 7575:7575
    networks:
      - media-network
    restart: unless-stopped
```

**Create `.env`** (next to `docker-compose.yml`) with your actual secrets — never commit this file:
```
WIREGUARD_PRIVATE_KEY=<private key from Mullvad .conf file>
WIREGUARD_ADDRESSES=<address from Mullvad .conf file, e.g. 10.64.16.116/32>
RADARR_API_KEY=<radarr api key — fill in after step 3>
SONARR_API_KEY=<sonarr api key — fill in after step 4>
```

</details>

**Filling in credentials:** Download a WireGuard config from mullvad.net → WireGuard keys. The `.conf` file contains:
- `PrivateKey` → paste as `WIREGUARD_PRIVATE_KEY`
- `Address` → paste as `WIREGUARD_ADDRESSES` (use only the IPv4 address, e.g. `10.64.16.116/32`)

**Timezone:** replace `America/Chicago` with your timezone (e.g. `America/New_York`, `Europe/London`) in all services.

**No GPU?** Remove the entire `deploy:` block from the `jellyfin` service.
3. Start all containers:
   ```powershell
   cd M:\Media
   docker compose up -d
   ```
4. Verify all 12 containers are running:
   ```powershell
   docker compose ps
   ```
5. Configure apps in order (see Configuration section below)

---

## Configuration Order

Configure each app in this sequence — each depends on the previous.
All internal URLs use `http://` not `https://` — containers have no SSL certificates.

### 1. qBittorrent — http://localhost:8080

Get the temporary password from logs (changes every restart until you set a permanent one):
```powershell
docker logs qbittorrent
```
- Login: `admin` / temporary password from logs
- Set permanent password: Tools → Options → **Web UI** tab → change password → Save
- Set download paths: Tools → Options → **Downloads** tab:
  - Default save path: `/data/torrents/`
  - Keep incomplete (temp) folder at `/data/torrents/incomplete/`
- Add categories (right-click "All" in the left sidebar → Add category):
  - Name `movies` → save path: `/data/torrents/movies`
  - Name `tv` → save path: `/data/torrents/tv`
  - Name `movies-private` → save path: `/data/torrents/movies`
  - Name `tv-private` → save path: `/data/torrents/tv`
- **No proxy config needed** — VPN is handled at the network level by Gluetun

**Set seeding limits** (Tools → Options → BitTorrent tab):
- Disable global ratio limit and global seeding time limit — per-category rules handle this instead
- Share limit action: **Pause torrent** — **never use Remove**, files are hardlinked and removing the torrent disconnects you from the swarm permanently

**Set per-category seeding limits** (right-click each category → Edit category):

| Category | Ratio limit | Seeding time | Action |
|---|---|---|---|
| `movies` | 1.0 | unlimited | Pause |
| `tv` | 1.0 | unlimited | Pause |
| `movies-private` | unlimited | unlimited | Pause |
| `tv-private` | unlimited | unlimited | Pause |

Alternatively, edit `M:\Media\config\qbittorrent\qBittorrent\qBittorrent.conf` and `categories.json` directly after first run:

In `qBittorrent.conf` under `[BitTorrent]`:
```ini
Session\GlobalMaxRatioEnabled=false
Session\GlobalMaxSeedingMinutesEnabled=false
Session\ShareLimitAction=Stop
```

In `categories.json` (alongside `qBittorrent.conf`):
```json
{
    "movies":          {"save_path":"/data/torrents/movies","ratio_limit":1.0,"seeding_time_limit":-1,"share_limit_action":"Stop"},
    "tv":              {"save_path":"/data/torrents/tv","ratio_limit":1.0,"seeding_time_limit":-1,"share_limit_action":"Stop"},
    "movies-private":  {"save_path":"/data/torrents/movies","ratio_limit":-1.0,"seeding_time_limit":-1,"share_limit_action":"Stop"},
    "tv-private":      {"save_path":"/data/torrents/tv","ratio_limit":-1.0,"seeding_time_limit":-1,"share_limit_action":"Stop"}
}
```
(`ratio_limit=-1` = unlimited; `seeding_time_limit=-1` = unlimited; edit the file while qBittorrent is stopped, then start it).

### 2. Prowlarr — http://localhost:9696

First-run: set up authentication → Forms / admin / `idbeholdg`

**Add FlareSolverr proxy first — before any indexers:**
- Settings → Indexers → Add Proxy → FlareSolverr
  - URL: `http://flaresolverr:8191`
  - **Tags: add `flaresolverr`** — this tag is how you assign it to specific indexers later
  - Test → Save

**Add indexers** (Indexers → Add Indexer):
- **YTS** — movies, no extra config needed, Test → Save
- **The Pirate Bay** — general, no extra config needed, Test → Save
- **EZTV** — TV shows, Cloudflare-protected → add `flaresolverr` tag → Test → Save
- **Nyaa.si** — content (essential — all SubsPlease/Erai-raws releases originate here), no extra config needed, Test → Save
- **TorrentGalaxy (TGx)** — general, especially strong for TV, no extra config needed, Test → Save
- **LimeTorrents** — general backup coverage, no extra config needed, Test → Save
- **1337x** — general, Cloudflare-protected → add `flaresolverr` tag → Test → Save (disable if it fails — FlareSolverr periodically loses against Cloudflare; re-enable after a FlareSolverr update)
- Rule: if any indexer fails with a Cloudflare error, add the `flaresolverr` tag and retest

**Connect Radarr and Sonarr** (Settings → Apps → Add Application):
- Radarr: Prowlarr Server `http://prowlarr:9696`, Radarr Server `http://radarr:7878`, API key from Radarr Settings → General
- Sonarr: Prowlarr Server `http://prowlarr:9696`, Sonarr Server `http://sonarr:8989`, API key from Sonarr Settings → General

### 3. Radarr — http://localhost:7878

First-run: set up authentication → Forms / admin / `idbeholdg`

- Settings → **Media Management**:
  - Click **"Show Advanced"** toggle (top right of page) — this reveals the hardlinks option
  - "Use Hardlinks instead of Copy": **checked**
  - Root Folders → Add `/data/movies`
- Settings → **Download Clients** → + → qBittorrent (public):
  - Host: `gluetun` **(NOT `qbittorrent` — qBittorrent has no independent hostname)**
  - Port: `8080`
  - Category: `movies`
  - `Remove Completed Downloads`: **checked** (removes from qBittorrent after import — public trackers, no ratio needed)
  - Test → Save
- Settings → **Download Clients** → + → qBittorrent (private):
  - Host: `gluetun`, Port: `8080`, Category: `movies-private`
  - `Remove Completed Downloads`: **unchecked** — keeps torrent seeding after import for ratio
  - **Tags: add `private`** — this is how Radarr routes private tracker releases to this client
  - Test → Save
- Settings → **Quality**:
  - For every quality entry (720p, 1080p, 2160p, etc.) set **Max size to `0`** (unlimited)
  - Default caps block large releases silently — 0 means no limit
- Settings → **Quality Profiles** → edit each profile:
  - Set **Minimum Custom Format Score** to `0` — this causes any release scoring below 0 (i.e. all Non-English releases) to be permanently rejected. Without this, the Non-English custom format scores count but nothing is actually blocked.
- Settings → **Connect** → + → **Emby / Jellyfin** (listed as "MediaBrowser"):
  - Host: `jellyfin`, Port: `8096`
  - API key: from Jellyfin Dashboard → API Keys → + (create one, label it "Radarr")
  - **Enable "Update Library"** checkbox
  - Test → Save
  - This makes Radarr notify Jellyfin to scan immediately after every import — without it you must manually trigger scans
- Copy the **API key** from Settings → General (needed for Prowlarr, Jellyseerr, Unpackerr)

### 4. Sonarr — http://localhost:8989

First-run: set up authentication → Forms / admin / `idbeholdg`

- Settings → **Media Management**:
  - Click **"Show Advanced"** toggle (top right of page)
  - "Use Hardlinks instead of Copy": **checked**
  - Root Folders → Add `/data/tv`
- Settings → **Download Clients** → + → qBittorrent (public):
  - Host: `gluetun` **(NOT `qbittorrent`)**
  - Port: `8080`, Category: `tv`
  - `Remove Completed Downloads`: **checked**
  - Test → Save
- Settings → **Download Clients** → + → qBittorrent (private):
  - Host: `gluetun`, Port: `8080`, Category: `tv-private`
  - `Remove Completed Downloads`: **unchecked**
  - **Tags: add `private`**
  - Test → Save
- Settings → **Quality**:
  - For every quality entry set **Max size to `0`** (unlimited) — same reason as Radarr
- Settings → **Quality Profiles** → edit each profile:
  - Set **Minimum Custom Format Score** to `0` — same reason as Radarr
- Settings → **Connect** → + → **Emby / Jellyfin** (listed as "MediaBrowser"):
  - Host: `jellyfin`, Port: `8096`
  - API key: from Jellyfin Dashboard → API Keys → + (create one, label it "Sonarr")
  - **Enable "Update Library"** checkbox
  - Test → Save
- Copy the **API key** from Settings → General

### 5. Unpackerr — update API keys in .env

After getting both API keys, edit `M:\Media\.env`:
```
RADARR_API_KEY=<radarr api key>
SONARR_API_KEY=<sonarr api key>
```
`docker-compose.yml` already references these as `${RADARR_API_KEY}` and `${SONARR_API_KEY}` — Docker Compose reads `.env` automatically. Then apply:
```powershell
docker compose up -d unpackerr
```
Note: the placeholder `00000000000000000000000000000000` (32 zeros) is used before real keys are available — Unpackerr requires a 32-character key and will crash-loop on shorter values like `changeme`.

**The `.env` file also stores the Mullvad WireGuard private key and assigned IP.** Never commit it to git — it is listed in `.gitignore`.

### 6. Bazarr — http://localhost:6767

First-run: set up authentication → Forms / admin / `idbeholdg`

- Settings → **Sonarr**:
  - Toggle enabled
  - Hostname: `sonarr`, Port: `8989`, API key from Sonarr
  - Test → Save
- Settings → **Radarr**:
  - Toggle enabled
  - Hostname: `radarr`, Port: `7878`, API key from Radarr
  - Test → Save
- Settings → **Languages**:
  - Scroll down to **Languages Profiles** → Add New Profile
  - Name: `English`, add English as the language → Save
  - The default profile assignment is also in this section (not in the Sonarr/Radarr sections)
- Settings → **Providers** → add subtitle sources:
  - **YIFY Subtitles** — no account needed, pairs well with YTS downloads
  - **Podnapisi** — no account needed, good general database
  - **OpenSubtitles.com** — free account required, largest database — recommended

### 7. Jellyfin — http://localhost:8096

First-run wizard:
- Set display language and server name
- Create admin account: `admin` / `idbeholdg`
- Add media libraries:
  - Content type **Movies** → folder `/data/movies`
  - Content type **Shows** → folder `/data/tv`
- Set metadata language (English / United States)
- Finish wizard

**Enable NVIDIA hardware acceleration** (prevents jitter during transcoding):
- Dashboard → **Playback** → **Transcoding**
- Hardware acceleration: **NVENC (NVIDIA)**
- Enable all available encode/decode format checkboxes (H.264, H.265/HEVC, AV1, etc.)
- Check **"Allow encoding in HEVC format"** — without this, HEVC downloads get transcoded to h264, causing lag on devices that could otherwise direct-play HEVC
- Check **"Enable HDR tone mapping"** — required for HDR/HDR10 content to display correctly instead of washed out
- Save

Note: The Jellyfin container has NVIDIA GPU passthrough configured in `docker-compose.yml` via the `deploy.resources.reservations` block. This requires NVIDIA drivers with WSL2 GPU support (standard on modern NVIDIA drivers).

**iOS Jellyfin app — set Max Streaming Bitrate to Original:**
If using the Jellyfin app on iPhone (Settings gear → Max Streaming Bitrate), set it to **Original**. The default cap forces Jellyfin to transcode video to a lower bitrate even when the file could be direct-streamed unchanged. At "Original", Jellyfin remuxes the video into HLS segments without re-encoding the codec, which is much faster and preserves quality.

**Set default subtitle mode** (prevents needing to manually toggle subtitles on every video):
- Dashboard → **Display**
- Subtitle Mode: **Smart** — subtitles appear automatically only when the audio track is in a non-preferred language (e.g. Japanese content). For English audio content, subtitles stay off.
- Save

Or set via API:
```powershell
$body = Invoke-RestMethod "http://localhost:8096/System/Configuration?api_key=f21e09ab3bc44eef9d50445aca69bf4e"
$body.SubtitleMode = "Smart"
Invoke-RestMethod -Method Post "http://localhost:8096/System/Configuration?api_key=f21e09ab3bc44eef9d50445aca69bf4e" -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 10)
```

**Set remote bitrate limit to unlimited:**
- Dashboard → **Playback** → scroll to **Bandwidth Limits**
- Remote client bitrate limit: **`0`** (zero = unlimited)
- Default is 10 Mbps — too low for high-quality HEVC encodes and causes unnecessary transcoding for remote clients even when they could direct-play

**Leave LAN Networks and Known Proxies blank:**
- Dashboard → **Networking** — do not fill in "LAN Networks" or "Known Proxies"
- Docker's port proxy makes every connection (local WiFi and remote Tailscale alike) arrive at Jellyfin from `172.18.0.1` (the Docker bridge gateway). Jellyfin cannot distinguish local from remote traffic, so these settings have no effect and adding them only causes confusion.

Note: The initial library scan after adding movies generates thumbnails and metadata for every file — this is CPU/disk intensive and will cause playback jitter until it completes. Wait for Dashboard → Scheduled Tasks to show idle before testing playback quality.

### 8. Jellyseerr — http://localhost:5055

- Sign in with Jellyfin:
  - Jellyfin URL: `http://jellyfin:8096`
  - Username: `admin`, Password: `idbeholdg`
- Sync Jellyfin users → Continue
- Confirm libraries detected → Continue
- Add Radarr:
  - Default server: checked
  - Hostname: `radarr`, Port: `7878`
  - API key from Radarr Settings → General
  - Test → set **Quality Profile: HD-1080p**, Root Folder: `/data/movies` → Save
  - **Enable "Search Automatically"** — without this Jellyseerr adds to Radarr but never triggers a search
- Add Sonarr:
  - Default server: checked
  - Hostname: `sonarr`, Port: `8989`
  - API key from Sonarr Settings → General
  - Test → set **Quality Profile: HD-1080p**, Root Folder: `/data/tv` → Save
  - **Enable "Search Automatically"** — same reason as above

**To change the default quality profile later** (without re-running setup):
Settings → Services → Radarr → click the **pencil icon** on the server → Quality Profile dropdown → select the desired profile → Save. Repeat for Sonarr. This sets the pre-selected default when users open the request dialog — they can still override it per request.

The default profile is stored in `M:\Media\config\jellyseerr\settings.json` under `radarr[].activeProfileId` and `sonarr[].activeProfileId`, matching the numeric profile IDs from Radarr/Sonarr (HD-1080p = 4 in both apps). Stop Jellyseerr before editing the file directly, then restart.

### 9. Homarr — http://localhost:7575

Homarr is the dashboard that shows live status for all services and provides one-click links. The board config is pre-configured and stored in `M:\Media\config\homarr\default.json` — it is automatically loaded when the container starts.

First-run: navigate to http://localhost:7575
- Click **"Create an account"** — Homarr requires an admin account on first launch
- Username: `admin`, pick a strong password (Homarr enforces mixed case + numbers)
- Log in

**The board is already configured** (apps + widgets) if `config\homarr\default.json` is in place from a previous install. If rebuilding from scratch, you will need to re-create the board manually:

- Click **"Add a tile" → App** for each service (Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, qBittorrent, Bazarr)
- For qBittorrent: set internal URL to `http://gluetun:8080` and external URL to `http://localhost:8080` — qBittorrent has no independent hostname
- Add integrations with API keys to enable live stats widgets (torrent progress, Sonarr/Radarr upcoming, etc.)

Homarr configuration is persisted in two places:
- `M:\Media\config\homarr\default.json` — board layout and app/widget tiles
- `M:\Media\config\homarr\auth\db.sqlite` — user accounts (admin password)

Both are mounted as volumes, so they survive container restarts and updates.

### 10. Firewall Setup (required for LAN + Tailscale access)

Run the firewall setup script as Administrator. Required once after a fresh setup, and again any time Docker Desktop updates and remote access breaks.

```powershell
# Right-click PowerShell → Run as Administrator
M:\Media\scripts\setup-firewall.ps1
```

This does two things:
1. Disables Docker Desktop's blanket block rules for `com.docker.backend.exe`
2. Adds named allow rules for every published port (Jellyfin 8096, Jellyseerr 5055, Radarr 7878, Sonarr 8989, Prowlarr 9696, qBittorrent 8080, Bazarr 6767, FlareSolverr 8191, Homarr 7575)

Skip this step and phones/TVs will get "could not connect" even though everything works on localhost.

### 11. Language Custom Formats — Sonarr and Radarr

This is the most important part of the configuration for getting clean English content. Sonarr and Radarr v4 use a **Custom Format scoring system** instead of Language Profiles. Every candidate release gets a numeric score. Releases below the minimum threshold are permanently rejected. This section explains the full system, all the regexes, and the reasoning behind every decision.

---

#### How the scoring system works

When Sonarr/Radarr finds a release, it checks every custom format against the release title (and some formats check parsed metadata like language tags). It adds up all the scores from matching formats. Then:

- If the score is **below the minimum** (configured per quality profile) → the release is **rejected** and never downloaded
- If the score is **at or above the minimum** → the release is eligible, and the **highest-scoring eligible release** wins

We set the minimum to **0** in every profile. The Non-English format scores **-10000**, which is so far below 0 that no amount of other positive scores can compensate. Any release that triggers it is mathematically eliminated.

---

#### The custom formats

| Format | ID Sonarr | ID Radarr | Score | What it matches |
|---|---|---|---|---|
| **Non-English** | 2 | 1 | -10000 | French/German/etc. keywords + standalone `multi` |
| **Language: English** | 3 | 2 | +300 | Parsed language metadata = English |
| **English Subs** | 4 | — | +200 | Known English-sub content release groups |
| **Dual Audio** | 5 | 3 | +400 | JP+EN dual-audio releases |
| **Preferred Groups** | 6 | 4 | +500 | Known-good trusted release groups |

**Score priority ladder (highest wins):**

| What gets grabbed | Score |
|---|---|
| Preferred group + dual audio (e.g. HakataRamen) | +500 + +400 + +300 = +1200 |
| Preferred group + English dub (e.g. Yameii) | +500 + +300 = +800 |
| Preferred group + English subs (e.g. SubsPlease) | +500 + +200 + +300 = +1000 |
| Unknown group + dual audio | +400 + +300 = +700 |
| Unknown group + English dub/subs | +300 |
| Non-English release | -10000 → **rejected** |

The +500 Preferred Groups bonus means that even if a trusted group's release appears later than an unknown group's release, Sonarr will upgrade to it automatically.

---

#### Non-English regex — full breakdown

This is the most complex format and the one most likely to need maintenance.

**Current regex (exact string stored in Sonarr/Radarr):**
```
(?i)VOSTFR|FRENCH|VFF|VFQ|TRUEFRENCH|GERMAN|DEUTSCH|SPANISH|ESPANOL|ITALIAN|PORTUGUESE|HEBREW|DUTCH|RUSSIAN|TURKISH|ARABIC|POLISH|(?<!dual[\s.]?)\bmulti\b
```

**Breaking it down token by token:**

`(?i)` — Sets the **entire regex to case-insensitive** from this point forward. `french`, `FRENCH`, `French` all match equally. Every subsequent token benefits from this.

`VOSTFR` — French subtitle convention: *Version Originale Sous-Titrée Française*. A French-subtitled release where the audio is still the original language. Common in French scene releases.

`FRENCH` — Explicit French audio label. The most common French scene marker.

`VFF` — *Version Française Francophone*. French-dubbed with Quebec/Canadian French. Less common but still present in the scene.

`VFQ` — *Version Française du Québec*. Quebec French dub specifically.

`TRUEFRENCH` — French dub using standard continental French (as opposed to VFQ). Some French scene groups distinguish these.

`GERMAN` / `DEUTSCH` — German audio labels. German scene groups use both.

`SPANISH` / `ESPANOL` — Spanish audio labels. Note: does not catch `ESP` (abbreviation used by some groups — a known gap).

`ITALIAN`, `PORTUGUESE`, `HEBREW`, `DUTCH`, `RUSSIAN`, `TURKISH`, `ARABIC`, `POLISH` — other language scene labels.

`|` — The pipe character is the regex **alternation operator** — it means "OR". The regex matches if ANY of the alternatives match anywhere in the release title.

---

**The hard part: `(?<!dual[\s.]?)\bmulti\b`**

This is a **negative lookbehind with a word boundary**, and it's the most nuanced piece. Here's what each component means:

`(?<!...)` — This is a **negative lookbehind assertion**. It says: "match only if the text immediately before this position does NOT match the pattern inside". It doesn't consume any characters — it just checks what's behind. Think of it as a guard that blocks the match under certain conditions.

`dual` — The literal text to look for behind the current match position. Because we're inside `(?i)` mode, this matches `Dual`, `DUAL`, `dual` equally.

`[\s.]?` — A **character class** followed by `?` (zero or one):
- `\s` matches any whitespace character (space, tab, etc.)
- `.` inside a character class is a **literal dot** (not the regex wildcard) — it matches the period character
- `?` makes the whole `[\s.]` optional — so it matches "Dual Multi" (space), "Dual.Multi" (dot), or "DualMulti" (nothing between them)

So `(?<!dual[\s.]?)` reads as: **"only proceed if the text immediately before is NOT 'dual' optionally followed by a space or dot"**.

`\b` — A **word boundary**. Matches the position between a word character (`a-z`, `A-Z`, `0-9`, `_`) and a non-word character (space, dash, bracket, etc.). It has zero width — it matches a position, not a character. The `\b` before `multi` ensures we don't accidentally match "multimedia" or "multitrack".

`multi` — The literal text, case-insensitive because of the leading `(?i)`.

`\b` (second one) — Word boundary after `multi`, ensuring we match the whole word and not a prefix of a longer word.

**Putting it together:** `(?<!dual[\s.]?)\bmulti\b` matches the word `multi` (any case, standing alone) **unless** it is immediately preceded by `dual` (with optional space or dot separator).

**Why this matters — the two kinds of `Multi`:**

| Release | Title contains | What it means | Should block? |
|---|---|---|---|
| French scene | `...MULTi 1080p WEB...` | French + original audio (e.g. NanDesuKa E23 — 9 audio languages) | **Yes** |
| Japanese dual-audio | `...Dual Multi[HakataRamen]` | Japanese + English dual audio | **No** |

The lookbehind lets "Dual Multi" pass (HakataRamen-style releases are JP+EN, exactly what we want) while blocking standalone "MULTi" (French/German scene convention).

**Why NOT use `(?-i:MULTi)` (the original approach):**

The intent was to make only the `MULTi` token case-sensitive — matching French scene's exact capitalisation (M-U-L-T-lowercase-i) while ignoring HakataRamen's `Multi` (capital M, rest lowercase). This inline flag to disable case-sensitivity within a group is valid .NET regex syntax, and it's what the Sonarr documentation examples show.

In practice, Sonarr's regex engine silently ignores the `(?-i:...)` flag change. The clause effectively becomes non-functional — it matches nothing. This was confirmed empirically: a NanDesuKa release with `MULTi` in the title scored +300 (Language: English only) instead of -9700, meaning the Non-English format never fired. The lookbehind approach avoids this entirely by not relying on any Sonarr-internal behaviour — it's plain structural regex evaluated against the title string.

---

#### Dual Audio regex — breakdown

```
(?i)\bDual[\.\s]?Audio\b|\bDualAudio\b|\bDual[\.\s]Multi\b
```

- `\bDual[\.\s]?Audio\b` — matches "Dual Audio", "Dual.Audio", "DualAudio" (the `?` makes the separator optional)
- `\bDualAudio\b` — redundant with above but explicit for clarity
- `\bDual[\.\s]Multi\b` — matches "Dual Multi" and "Dual.Multi" — the HakataRamen/NanDesuKa DUAL convention for JP+EN releases

Note: `[\.\s]` inside a character class — the `.` is literal (not wildcard), matching an actual period. `\s` matches whitespace.

---

#### English Subs regex — breakdown

```
(?i)SubsPlease|Erai-raws|Judas|Dual.Audio|DualAudio|English.Subbed
```

Matches known English-subtitle content release groups. The `.` between words here is the **regex wildcard** (matches any character) — "Dual.Audio" matches "Dual Audio", "Dual-Audio", "DualXAudio", etc. It's slightly imprecise but works fine in practice since the only realistic match is the intended one.

---

#### Preferred Groups regex

```
(?i)Yameii|HakataRamen|SubsPlease|Erai-raws|Judas|LostYears|Arg0
```

These are release groups confirmed to consistently produce clean English content for content:

| Group | Type | Source |
|---|---|---|
| **Yameii** | English dub | Crunchyroll WEB-DL |
| **HakataRamen** | JP+EN dual audio | Hulu |
| **SubsPlease** | English subs | CR/Funi simulcast |
| **Erai-raws** | English subs + multiple | Multiple sources |
| **Judas** | English subs | Various |
| **LostYears** | Dual audio | Various |
| **Arg0** | Dual audio | Various |

The +500 score means any release from these groups beats any unknown release regardless of other factors. If a preferred group's release appears after an unknown group's release is already downloaded, Sonarr/Radarr will upgrade automatically.

---

**Create the formats** (Settings → Custom Formats → + for each):

| Format Name | Type | Score | Regex / Spec |
|---|---|---|---|
| **Non-English** | Release Title | -10000 | See full regex above |
| **Language: English** | Language | +300 | Language = English |
| **English Subs** | Release Title | +200 | See regex above |
| **Dual Audio** | Release Title | +400 | See regex above |
| **Preferred Groups** | Release Title | +500 | See regex above |

Non-English regex (copy exactly):
```
(?i)VOSTFR|FRENCH|VFF|VFQ|TRUEFRENCH|GERMAN|DEUTSCH|SPANISH|ESPANOL|ITALIAN|PORTUGUESE|HEBREW|DUTCH|RUSSIAN|TURKISH|ARABIC|POLISH|(?<!dual[\s.]?)\bmulti\b
```

English Subs regex:
```
(?i)SubsPlease|Erai-raws|Judas|Dual.Audio|DualAudio|English.Subbed
```

Dual Audio regex:
```
(?i)\bDual[\.\s]?Audio\b|\bDualAudio\b|\bDual[\.\s]Multi\b
```

Preferred Groups regex:
```
(?i)Yameii|HakataRamen|SubsPlease|Erai-raws|Judas|LostYears|Arg0
```

**Apply scores to quality profiles** (Settings → Quality Profiles → edit each profile):
- Set each format's score as listed above
- Leave **Minimum Custom Format Score at 0** — this rejects anything scoring below 0 (i.e. all Non-English releases)
- Do this for every profile in both Radarr and Sonarr

**If no acceptable release exists:** the item stays "Missing" indefinitely. It will not fall back to a non-English release. This is intentional — a missing item is better than a wrongly-dubbed one.

### 12. Import Existing Movie Library (optional)

Copy movies into `M:\Media\data\movies\` first (Radarr can only see paths inside the container).
Then in Radarr → Movies → **Import Existing Movies** → path `/data/movies`:
- Green = matched, click Import
- "Existing" = already in library, skip
- Red/Missing = file not found or copy still in progress, skip and re-request later

TV shows: skip import, request fresh via Jellyseerr — show imports are unreliable with inconsistent naming.

After import, trigger a Jellyfin library scan:
- Dashboard → Libraries → Movies → ⋮ → **Scan Library Files**

---

## Indexers

Prowlarr is the single place to manage all torrent indexers. Add an indexer once in Prowlarr and it automatically syncs to Radarr, Sonarr, and any other connected app — no need to configure indexers in each app separately.

For any indexer that blocks automated scrapers with Cloudflare, add the `flaresolverr` tag to both the FlareSolverr proxy entry and the indexer itself (see Known Issues section).

---

### Minimal Working Set

The smallest set that covers everyday content. All public — no account required.

| Indexer | Content | Notes |
|---|---|---|
| **YTS** | Movies | Small x265 files, consistent quality, movie-only |
| **The Pirate Bay** | General | Oldest public tracker, broad but inconsistent quality |
| **EZTV** | TV shows | Dedicated TV tracker, good episode coverage |
| **Nyaa.si** | content | Essential for any content — this is where all content releases originate |

Without Nyaa, content requests in Sonarr will fail or grab poor-quality re-uploads from TPB/EZTV. Add it even if you only plan to watch content occasionally.

---

### Recommended Full Set

Adding these on top of the minimal set significantly improves TV hit rates and gives better release quality for everything.

| Indexer | Content | Notes |
|---|---|---|
| **TorrentGalaxy (TGx)** | General (TV especially strong) | Best public tracker for TV — proper scene releases, well-maintained |
| **LimeTorrents** | General | Solid backup coverage, good when others miss something |
| **1337x** | General (TV especially strong) | Excellent TV and movie coverage — Cloudflare-protected, needs FlareSolverr tag. Currently disabled (2026-05-06) pending a FlareSolverr update that can bypass it — re-test periodically |

With this full set (YTS + TPB + EZTV + Nyaa + TGx + LimeTorrents + 1337x when re-enabled), automatic searches will find almost everything for both movies and TV without manual intervention.

---

### Private Trackers

Private trackers require membership. They are strictly better than public trackers in every measurable way:

- **Quality** — strict release standards, no re-encoded garbage
- **Speed** — content available within hours of air/release, not days
- **Reliability** — 10:1+ seeder ratios, staff remove dead torrents
- **Completeness** — entire back-catalogues, not just popular recent content

The tradeoff: you must maintain an upload/download ratio to keep your account active. Seed what you download.

#### The Trackers Worth Having

| Tracker | Focus | Why It Matters |
|---|---|---|
| **BroadcastTheNet (BTN)** | TV shows | Gold standard for TV — every show, every season, every episode, proper scene naming |
| **PassThePopcorn (PTP)** | Movies | Gold standard for movies — same deal as BTN but for film |
| **HDBits** | HD movies + TV | Elite-tier HD content, extremely strict quality standards |
| **TorrentLeech (TL)** | General | Excellent general tracker, good for building ratio history |
| **IPTorrents (IPT)** | General | More accessible than BTN/PTP, good day-to-day use |
| **Redacted (RED)** | Music | Gold standard for music (not relevant to this media stack but worth knowing) |

BTN for TV and PTP for movies are the end goals. Everything else is a stepping stone.

#### How Membership Works

**Invites** are the primary route for elite trackers. An existing member vouches for you and sends a one-time invite link. You cannot buy or request invites — they come from relationships built in the community.

**Open registration** periods happen occasionally — a tracker opens sign-ups for a few hours or days with no invite needed. These are announced with very little notice.

**Applications** are accepted by some trackers. You submit your tracker history (accounts on other sites, ratio proofs) and are accepted or rejected based on standing.

#### Where to Watch and How to Get Started

| Resource | What It's For |
|---|---|
| **r/OpenSignups** (Reddit) | Real-time announcements when any tracker opens registration — set up alerts for tracker names |
| **r/trackers** (Reddit) | Community discussion, guides, questions — read rules carefully, invites cannot be requested publicly |
| **IRC** | Most trackers have IRC channels — lurking and participating builds relationships that eventually lead to invites |

**Realistic path from zero:**

1. **IPTorrents** — The most accessible starting point. Occasionally sells memberships directly (watch r/OpenSignups). No invite needed during open windows. Start here.
2. **TorrentLeech** — Also has periodic open registration windows. Good general tracker, respected ratio history.
3. **Build ratio** — Seed everything you download for at least 6–12 months. A good ratio on TL or IPT is the proof-of-reliability that elite tracker members look for before inviting someone.
4. **BTN / PTP** — After demonstrating good standing elsewhere, you become eligible to receive invites from members. These are the end goals for TV and movies respectively. There is no shortcut.

HDBits is effectively invite-only from existing HDBits members and is not a realistic target without already knowing someone inside.

#### Adding Private Trackers in Prowlarr

Most major private trackers are supported in Prowlarr's indexer database. To add one:
1. Prowlarr → Indexers → Add Indexer → search for the tracker name
2. Enter your account credentials or the RSS/API key from the tracker's profile page
3. **Tags: add `private`** to the indexer — this is the key step for routing
4. Test → Save
5. Prowlarr → Settings → Apps → click sync — it propagates to Radarr and Sonarr automatically

**How routing works:** When Prowlarr sends a result tagged `private` to Radarr/Sonarr, those apps route it to whichever download client also has the `private` tag — that's the "qBittorrent (Private)" client configured in steps 3 and 4 above. That client uses the `movies-private` / `tv-private` category, which has unlimited seeding and `removeCompletedDownloads=false`. The torrent stays in qBittorrent indefinitely for ratio building. Public results (no tag) continue going to the standard qBittorrent client.

No changes needed in Radarr or Sonarr when adding a new indexer — Prowlarr handles the sync.

---

## Accessing From Other Devices

### Local network (same WiFi)
Replace `localhost` with the machine's local IP: `192.168.1.64`
- Jellyfin: `http://192.168.1.64:8096`
- Jellyseerr: `http://192.168.1.64:5055`

### Remote access (anywhere — Tailscale)
Tailscale is installed on this machine (IP: `100.67.113.36`).
Install Tailscale on any other device, log in with the same account, and use:
- Jellyfin: `http://100.67.113.36:8096`
- Jellyseerr: `http://100.67.113.36:5055`

### Recommended clients

| Device | Jellyfin | Jellyseerr |
|---|---|---|
| Windows desktop | **Jellyfin Media Player** app (direct plays HEVC/h264 natively via MPV, no transcoding) | Browser or PWA (install from address bar) |
| iPhone (recommended) | **Infuse** app (best iOS player — direct plays HEVC without lag, smooth HDR) | Add to Home Screen from browser (PWA) |
| iPhone (Jellyfin native) | **Jellyfin** app from App Store — works, but set streaming quality to **Max** for HEVC content or it will transcode | Add to Home Screen from browser (PWA) |
| Android | **Jellyfin** app from Play Store | Add to Home Screen from browser (PWA) |
| Browser | Works, but transcodes more formats — more GPU load on server | Fully supported |

**Infuse vs Jellyfin iOS app:** Infuse direct-plays HEVC natively with zero lag and excellent HDR support. The Jellyfin iOS app can also direct-play HEVC but requires setting streaming bitrate to **Max** in the app settings, otherwise it transcodes and may lag. For subtitle control in Infuse, options are On / Forced Only / Off (no Smart mode); use **Forced Only** for English content and toggle manually for non-English. The Jellyfin iOS app respects the server's Smart subtitle setting.

---

## Maintenance

**Check container status:**
```powershell
docker compose ps
```

**View logs for a specific container:**
```powershell
docker logs <container-name>
# e.g. docker logs gluetun
```

**Update all containers to latest images (manual):**
```powershell
cd M:\Media
docker compose pull
docker compose up -d
```

**Automatic updates — Watchtower:**
A Watchtower container runs in the stack and automatically pulls new images and restarts updated containers every night at 3 AM. No manual action needed for routine updates.

Key Watchtower configuration in `docker-compose.yml`:
- `WATCHTOWER_SCHEDULE=0 0 3 * * *` — runs at 3 AM daily
- `WATCHTOWER_CLEANUP=true` — deletes old images automatically
- `DOCKER_API_VERSION=1.44` — required to prevent crash loop after Docker Desktop updates (without this, Watchtower exits with "client version too old" error)

Gluetun and qBittorrent both have `com.centurylinklabs.watchtower.enable=false` — Watchtower does **not** auto-update these two containers. This is intentional: Gluetun must be recreated (not restarted) after an image update, and qBittorrent must then be re-attached to the new Gluetun container. Watchtower cannot do this sequence automatically. Update them manually when needed:
```powershell
docker compose pull gluetun qbittorrent
docker compose up -d --force-recreate gluetun
docker compose up -d qbittorrent
```

To check what Watchtower last did:
```powershell
docker logs watchtower --tail 50
```

To trigger an immediate update check (instead of waiting for 3 AM):
```powershell
docker exec watchtower /watchtower --run-once
```

Watchtower is configured with `WATCHTOWER_CLEANUP=true` so old images are deleted automatically — disk space won't accumulate. If a container update breaks something, roll back with:
```powershell
# Example: roll back Sonarr to the previous image
docker compose pull sonarr   # pulls latest again if you want to re-update
# Or pin a specific version in docker-compose.yml: image: lscr.io/linuxserver/sonarr:4.0.0
```

**Restart the entire stack:**
```powershell
docker compose restart
```

**Restart a single container:**
```powershell
docker compose up -d <service-name>
# e.g. docker compose up -d gluetun
```

**If the machine reboots:** Docker Desktop starts automatically (if auto-start is enabled in settings), and all containers come back on their own via `restart: unless-stopped`.

---

## Migrate to New Machine

Use this when moving the stack to a new hard drive or new computer with all settings preserved. This is faster than a full "Reproduce This Setup" because it restores the config databases instead of reconfiguring every app from scratch.

**Before you move:** run the backup script on the old machine to snapshot the config:
```powershell
M:\Media\scripts\backup-config.ps1
```
This creates `M:\Media\backups\config-backup-YYYY-MM-DD_HHMM.zip` (~500 MB compressed). Copy that zip and your `.env` file to external storage — these two items are everything the stack needs besides the compose file.

**On the new machine:**

1. **Install prerequisites:**
   - Docker Desktop (WSL2 backend) — enable "Start Docker Desktop when you log in" in settings
   - NVIDIA drivers (if GPU present) — required for Jellyfin NVENC transcoding
   - Tailscale — log in with the same account for remote access

2. **Create the folder structure:**
   ```powershell
   $folders = @(
     "M:\Media\config\jellyfin","M:\Media\config\radarr","M:\Media\config\sonarr",
     "M:\Media\config\prowlarr","M:\Media\config\qbittorrent","M:\Media\config\jellyseerr",
     "M:\Media\config\bazarr","M:\Media\config\unpackerr",
     "M:\Media\config\homarr","M:\Media\config\homarr\icons","M:\Media\config\homarr\auth",
     "M:\Media\data\torrents\movies","M:\Media\data\torrents\tv",
     "M:\Media\data\torrents\incomplete","M:\Media\data\movies","M:\Media\data\tv",
     "M:\Media\backups"
   )
   $folders | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ }
   ```

3. **Clone the repo and restore secrets:**
   ```powershell
   git clone <your-repo-url> M:\Media-repo
   # Then copy docker-compose.yml, scripts\, update.ps1, .gitignore to M:\Media\
   # Copy your backed-up .env to M:\Media\.env
   ```
   Or if no remote repo yet, just copy the files from the old machine.

4. **Restore config from backup:**
   ```powershell
   Expand-Archive "path\to\config-backup-YYYY-MM-DD_HHMM.zip" -DestinationPath "M:\Media"
   ```
   This unpacks `config\` directly into `M:\Media\` — all app databases and settings land in the right place.

5. **Start the stack:**
   ```powershell
   cd M:\Media
   docker compose up -d
   ```
   All 12 containers start with their existing databases and configuration.

6. **Set up firewall and auto-start (run as Administrator):**
   ```powershell
   M:\Media\scripts\setup-firewall.ps1
   M:\Media\scripts\create-startup-task.ps1
   ```

7. **Verify:** open http://localhost:8096 (Jellyfin), http://localhost:5055 (Jellyseerr), http://localhost:7575 (Homarr). Library and settings should all be present.

**If the media drive letter changes** (e.g. was M: on old machine, now E:): update the volume paths in `docker-compose.yml` before step 5. All paths are at the top of each service's `volumes:` block.

---

## Status Log

| Date | Action | Notes |
|---|---|---|
| 2026-05-06 | Created folder structure | All 13 folders under config\ and data\ |
| 2026-05-06 | Created docker-compose.yml | 10 services including gluetun for Mullvad VPN |
| 2026-05-06 | docker compose up -d | All 10 containers running and stable |
| 2026-05-06 | VPN approach: Gluetun | Mullvad removed SOCKS5 — switched to Gluetun WireGuard container |
| 2026-05-06 | Gluetun connected | Singapore exit IP confirmed via Mullvad node (x.x.x.x) |
| 2026-05-06 | qBittorrent configured | Password set, categories created, no proxy needed |
| 2026-05-06 | Prowlarr configured | FlareSolverr proxy (tagged), 4 indexers, Radarr + Sonarr apps connected |
| 2026-05-06 | Radarr configured | Hardlinks on, root /data/movies, download client via gluetun:8080 |
| 2026-05-06 | Sonarr configured | Hardlinks on, root /data/tv, download client via gluetun:8080 |
| 2026-05-06 | Unpackerr live | Real Radarr + Sonarr API keys set, connected to both |
| 2026-05-06 | Bazarr configured | Sonarr + Radarr connected, English profile, YIFY + Podnapisi + OpenSubtitles |
| 2026-05-06 | Jellyfin configured | Libraries /data/movies + /data/tv, NVENC hardware acceleration enabled |
| 2026-05-06 | Jellyseerr configured | Jellyfin + Radarr + Sonarr connected, quality profile: Any |
| 2026-05-06 | Existing movies imported | TinyMediaManager movies imported via Radarr, unmatched deleted for re-requesting |
| 2026-05-06 | TV shows skipped | Starting fresh — request via Jellyseerr going forward |
| 2026-05-06 | Stack fully operational | End-to-end pipeline working, Jellyfin Media Player installed |
| 2026-05-06 | Quality size limits fixed | Set max size to 0 (unlimited) in Radarr and Sonarr quality settings |
| 2026-05-06 | 1337x disabled | FlareSolverr cannot bypass Cloudflare on 1337x — re-test after future FlareSolverr updates |
| 2026-05-06 | Jellyseerr search automatically | Enabled on both Radarr and Sonarr connections so requests trigger immediate search |
| 2026-05-07 | qBittorrent save path fixed | Default path was `/downloads/` (doesn't exist); corrected to `/data/torrents/` in qBittorrent.conf. VPN and peers were fine — it was a disk write error causing "Errored" status |
| 2026-05-07 | VPN confirmed healthy | Public IP confirmed x.x.x.x (Mullvad Netherlands). HTTP/HTTPS/DNS outbound all working through VPN tunnel |
| 2026-05-07 | Nyaa.si added | Added to Prowlarr for content — required for a show and all shows |
| 2026-05-07 | Indexers section added to README | Documents minimal set, recommended full set, and private tracker path |
| 2026-05-07 | Jellyfin auto-refresh wired up | Radarr and Sonarr both connected to Jellyfin via API key — library updates instantly on import, no manual scan needed |
| 2026-05-09 | Language custom formats added | Sonarr and Radarr: Non-English (-10000), Language:English (+300), English Subs (+200, SubsPlease/Erai-raws/etc). French MULTi a show episodes deleted and re-search triggered for SubsPlease replacements |
| 2026-05-09 | Gluetun DNS fixed (tracker blocking) | Switched from DoT to plain DNS: added DNS_UPSTREAM_RESOLVER_TYPE=plain and DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53. BLOCK_*=off alone was not sufficient — DoT upstream itself was filtering tracker domains |
| 2026-05-09 | Non-English format patched for MULTi | Added (?-i:\bMULTi\b) to Non-English regex (case-sensitive match for French scene convention). Previous regex missed KAF/MULTi packs that don't contain "FRENCH" in the title |
| 2026-05-09 | Dual Audio custom format added | Sonarr (id=5) and Radarr (id=3): +400 score. Matches Dual.Audio, DualAudio, Dual Multi. English dub now preferred over English sub when available |
| 2026-05-09 | qBittorrent seeding limits set | GlobalMaxRatio=1, GlobalMaxSeedingMinutes=30, ShareLimitAction=Remove. Ratio never triggers (no port forwarding = no upload); 30-min timer is the real cleanup mechanism |
| 2026-05-10 | a show S01 complete | All 28 episodes downloaded. Season pack search found Yameii [English Dub][CR WEB-DL 1080p] for missing episodes. Individual episode searches on public trackers returned 0 usable results — SeasonSearch command was required |
| 2026-05-18 | Non-English regex fixed | Replaced broken `(?-i:MULTi)` (inline case flag silently ignored by Sonarr) with `(?<!dual[\s.]?)\bmulti\b` (negative lookbehind). NanDesuKa MULTi E23 (9 audio languages) was grabbed incorrectly — removed, replaced with Yameii English Dub. New regex confirmed: NanDesuKa MULTi scores -9700, HakataRamen Dual Multi unaffected |
| 2026-05-18 | Preferred Groups format added | Sonarr (id=6) and Radarr (id=4): +500 score. Groups: Yameii, HakataRamen, SubsPlease, Erai-raws, Judas, LostYears, Arg0. Creates a score gap so trusted groups always beat unknown groups and trigger automatic upgrades |
| 2026-05-19 | Native Jellyfin Server conflict fixed | Native jellyfin.exe (C:\Program Files\Jellyfin\Server) was running alongside Docker Jellyfin, both on port 8096. Remote/Tailscale connections were hitting the native server (wrong credentials). Stopped processes, removed JellyfinTray HKCU startup entry. Uninstall "Jellyfin Server" from Apps to permanently resolve — keep "Jellyfin Media Player" |
| 2026-05-20 | Gluetun iptables corruption fixed | All UDP torrent trackers failing with "Operation not permitted" after Watchtower update. DNS was fine (already plain). Fix: docker compose up -d --force-recreate gluetun && docker compose up -d qbittorrent. Added watchtower depends-on label to gluetun so future updates auto-restart qbittorrent |
| 2026-05-20 | Watchtower crash loop fixed | "client version 1.25 too old" crash loop after Docker Desktop update. Fix: added DOCKER_API_VERSION=1.44 to watchtower environment. Watchtower 1.7.1 running, scheduled 3 AM |
| 2026-05-20 | a movie REMUX dead seeder removed | 49GB REMUX stuck at 19.8% with 0 seeds. Deleted from queue with blocklist=true. Radarr auto-grabbed YTS 1080p (24 seeds, 7 MB/s) |
| 2026-05-20 | a show S1 complete | All 28 S1 episodes downloaded after Gluetun UDP fix restored tracker connectivity. S2 actively airing |
| 2026-05-20 | Secrets moved to .env | WireGuard key, WireGuard address, Radarr API key, Sonarr API key moved from docker-compose.yml to .env. docker-compose.yml now uses ${VARIABLE} references. .gitignore updated |
| 2026-05-20 | Homarr dashboard added | New container on port 7575. Board pre-configured: 8 app tiles (Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, qBittorrent, Bazarr, Homarr) + 4 widgets (clock, Sonarr upcoming, Radarr upcoming, torrent status). API keys pre-loaded. Config at M:\Media\config\homarr\ |
| 2026-05-20 | Jellyfin HEVC encoding enabled | AllowHevcEncoding and EnableTonemapping enabled via API. Previously HEVC downloads forced a slow h264 transcode causing lag on iPhone |
| 2026-05-20 | Infuse identified as best iOS player | Direct-plays HEVC natively with no lag. Jellyfin iOS app also works at Max bitrate setting |
| 2026-05-20 | Jellyfin Smart subtitle mode enabled | SubtitleMode=Smart: auto-shows English subs for non-English audio, no subs for English audio. No more manual toggling |
| 2026-05-20 | Firewall script updated | Added Homarr port 7575 to setup-firewall.ps1 |
| 2026-05-21 | Private tracker seeding configured | Global ratio/seeding limits disabled. ShareLimitAction=Stop (pause, never delete). Per-category rules: movies/tv pause at ratio 1:1; movies-private/tv-private seed indefinitely |
| 2026-05-21 | Private categories created | movies-private and tv-private categories added to qBittorrent with save paths matching hardlink directories |
| 2026-05-21 | Private download clients added | Radarr and Sonarr: added "qBittorrent (Private)" client (category=movies-private/tv-private, removeCompleted=false, tag=private). Prowlarr: tag private indexers with `private` to auto-route via this client |
| 2026-05-21 | qBittorrent lockfile crash loop fixed | Stale /config/qBittorrent/lockfile (dated May 20 16:10) was preventing startup. Removed via docker exec, container healthy |
| 2026-05-22 | Infuse free cellular limitation confirmed | Infuse free allows library browsing on cellular but blocks video playback — Pro required for remote streaming. No error message surfaces this. |
| 2026-05-22 | Jellyfin iOS app adopted for cellular | Free alternative to Infuse Pro. Works on cellular via Tailscale. Max Streaming Bitrate must be set to Original in app settings or Jellyfin transcodes video unnecessarily. |
| 2026-05-22 | iOS HLS seek lag documented | Jellyfin iOS app (WebView) always remuxes to HLS — direct play not possible on iOS. Seeking restarts FFmpeg, causing 2–4 s blank screen. Expected behavior, not a bug. |
| 2026-05-22 | LAN Networks / Known Proxies left null | Docker bridge (172.18.0.1) makes all connections appear local to Jellyfin regardless of origin. These settings have no effect in this Docker setup and should remain unset. |
| 2026-05-22 | Remote bitrate limit removed | Set to 0 (unlimited) via Jellyfin API. At 2.1 Mbps HEVC the previous 10 Mbps limit was harmless but misleading. |
