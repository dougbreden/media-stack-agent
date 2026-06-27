# media-stack-agent

A fully automated self-hosted media pipeline running 13 Docker containers on Windows, designed to be operated and maintained remotely by [Claude Code](https://claude.ai/code).

Request a movie or TV show → it downloads through a VPN → gets transcoded to H.264 → appears in Jellyfin on any device.

---

## Quickstart

### Prerequisites

- Windows 10/11 with Docker Desktop (WSL2 backend enabled)
- NVIDIA GPU with current drivers — NVENC is required for Jellyfin HLS transcoding and Tdarr background re-encoding
- Mullvad VPN subscription — generate a WireGuard keypair at mullvad.net
- ~2 TB+ storage on a **single volume** — the hardlink architecture (see below) requires the torrent source and library to share the same filesystem

### 1. Configure credentials

```powershell
copy .env.example .env
copy scripts\config.ps1.example scripts\config.ps1
```

Edit `.env` with your Mullvad WireGuard private key and assigned IP address.
Edit `scripts\config.ps1` with API keys for each service (generated during step 4).

### 2. Adjust volume paths

Open `docker-compose.yml` and update the bind mount host paths to match your storage layout. All media containers expect three shared roots:

| Container path | Purpose |
|---|---|
| `/data/torrents` | qBittorrent download target — source of truth, never modified |
| `/data/movies` | Radarr-managed movie library |
| `/data/tv` | Sonarr-managed TV library |

### 3. Start the stack

```powershell
cd M:\Media
docker compose up -d
docker compose ps   # all 13 containers should reach healthy within ~60s
```

### 4. Configure services

On first run the *arr apps need initial setup — download client connections, indexers, quality profiles, and language custom formats. See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the full step-by-step walkthrough.

### 5. Register scheduled tasks

```powershell
# Run as Administrator
.\scripts\setup-scheduled-tasks.ps1   # startup, VPN reset, nightly standardize
.\scripts\setup-firewall.ps1          # Docker firewall rules
```

### Agentic management

Once the stack is running, all routine operations — health checks, missing content searches, library compliance, VPN recovery — can be handled remotely via Claude Code. See the [Agentic Design](#agentic-design) section and [`docs/AGENTS.md`](docs/AGENTS.md) for the full field manual.

---

## Why this is hard

Most self-hosted media stack guides assume Linux. This runs on **Windows with Docker Desktop (WSL2 backend)**, which introduces a class of problems that don't exist on bare-metal Linux.

**VPN network namespace sharing.** qBittorrent runs inside Gluetun's network namespace (`network_mode: service:gluetun`), not its own. After any Gluetun restart, qBittorrent must be *recreated* — not restarted — because it holds a reference to the old container ID. A plain `docker compose restart` silently breaks torrent connectivity.

**Hardlink architecture.** Torrent files and library files share the same inode — no duplicate storage. Tdarr can replace a library file in-place (breaking the hardlink) while the torrent copy stays intact for seeding. This means torrents can never be deleted, only stopped. Deleting removes the shared inode.

**GPU passthrough on WSL2.** NVENC is exposed as `/dev/dxg` inside WSL2 containers, not `/dev/nvidia0` as every guide assumes. Both Jellyfin (live HLS transcoding) and Tdarr (background re-encoding) share the same RTX 4070 Ti through this path.

**Language filtering with regex edge cases.** Sonarr and Radarr use custom format scores to prefer English and dual-audio releases and reject non-English ones. The blocking regex requires a lookbehind (`(?<!dual[\s.]?)\bmulti\b`) to allow `Dual Multi` releases (HakataRamen JP+EN) while rejecting French scene `MULTi` releases. Sonarr's regex engine silently ignores inline case flags (`(?-i:...)`), so the standard PCRE fix fails here without any error.

**Tdarr flow storage.** The Universal H.264+AAC transcoding flow is stored in SQLite directly — not accessible via Tdarr's cruddb API. Every plugin node in the flow JSON must carry both `inputs` and `inputsDB` fields with identical values. If `inputsDB` is missing, the worker silently reads plugin defaults and encodes to HEVC instead of H.264.

**DNS through the VPN.** Gluetun's default DNS uses DNS-over-TLS, which blocks torrent tracker domains even with all block lists disabled. Plain DNS (`1.1.1.1:53`) routed through the Mullvad tunnel is required. Traffic remains private; the blocking behaviour simply doesn't occur.

---

## Architecture

```
User Request
    │
    ▼
Jellyseerr ─────────────────────────────── request UI
    │
    ├──► Radarr (movies)  ◄──► Prowlarr ◄──► Indexers (YTS, Nyaa, TPB, EZTV...)
    └──► Sonarr (TV)                          └── FlareSolverr (Cloudflare bypass)
              │
              ▼
         qBittorrent  ◄── network_mode: service:gluetun
              │               └── Gluetun / Mullvad WireGuard VPN
              │
              ▼
    /data/torrents/  (source — never modified)
              │
              │  hardlink (same inode, zero extra disk)
              ▼
    /data/movies/ + /data/tv/  (Universal library — mutable)
              │
              ├──► Tdarr          background HEVC/AV1 → H.264, adds AAC stereo
              ├──► Bazarr         subtitle download
              └──► Jellyfin       streaming server (NVENC HLS transcoding)

   Watchtower     nightly image updates
   Unpackerr      extracts compressed downloads
   Homarr         dashboard
```

**13 containers:** jellyfin, sonarr, radarr, prowlarr, jellyseerr, qbittorrent, gluetun, tdarr, bazarr, homarr, watchtower, unpackerr, flaresolverr.

### Library tiers

| Tier | Path | Standard | Processed by Tdarr |
|---|---|---|---|
| Universal | `/data/movies`, `/data/tv` | H.264 + MKV + AAC stereo | Yes |
| Premium 4K *(planned)* | `/data/movies-4k`, `/data/tv-4k` | HEVC direct-play | Never |

---

## Agentic design

This repo is built to be managed remotely by Claude Code. The full operational context — architecture decisions, known failure modes, recovery procedures, regex rationale — is encoded in `CLAUDE.md` so an agent can diagnose and fix issues without human-provided context.

As the stack evolves toward tighter agentic integration (automated remediation, scheduled agent runs, self-healing), this section will grow into a full operating manual. For now, see [`docs/AGENTS.md`](docs/AGENTS.md) for prime directives, escalation checklists, and agent operating constraints.

### Claude Code slash commands (`.claude/commands/`)

| Command | What it does |
|---|---|
| `/health` | Runs `maintain-stack.ps1` — checks disk, containers, VPN, downloads, firewall |
| `/check` | Runs `library-report.ps1` — reports codec/container compliance across the library |
| `/missing` | Runs `check-missing.ps1` — lists monitored content with no file, annotates likely causes |
| `/search <title>` | Looks up a title in Sonarr/Radarr, shows missing episodes, optionally triggers a search |

### Automation scripts (`scripts/`)

| Script | Purpose |
|---|---|
| `maintain-stack.ps1` | 7-step daily health check |
| `maintain-downloads.ps1` | Audit stalled and dangerous downloads |
| `standardize-library.ps1` | Dedup → Tdarr reset → MKV remux → fresh scan |
| `library-report.ps1` | Codec/container/AAC compliance report |
| `check-missing.ps1` | Report monitored content with no file |
| `check-media-policy.ps1` | Validate torrent/library boundary is intact |
| `setup-scheduled-tasks.ps1` | Register Windows scheduled tasks |
| `setup-firewall.ps1` | Apply Docker firewall rules |
| `fix-vpn.ps1` | Force-recreate VPN and torrent client |
| `remux-library-to-mkv.ps1` | Stream-copy non-MKV files to MKV |
| `dedup-audio.ps1` | Remove duplicate audio streams |
| `tdarr-deploy-universal-flow.ps1` | Deploy the H.264+AAC Tdarr flow via SQLite |
| `tdarr-reset-universal-files.ps1` | Requeue errored or all Tdarr files |
| `backup-config.ps1` | Archive container config directories |

---

## Docs

| Document | Purpose |
|---|---|
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Full setup guide, known failure modes, recovery procedures |
| [`docs/AGENTS.md`](docs/AGENTS.md) | Agent field manual: prime directives, constraints, escalation |
| [`docs/USAGE.md`](docs/USAGE.md) | End-user guide: requesting content, client apps, accounts |
| [`docs/STANDARDS.md`](docs/STANDARDS.md) | Library standards: codec, container, naming conventions |
| [`docs/LOG.md`](docs/LOG.md) | Operational history: every fix and config decision |
