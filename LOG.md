# Media Stack — Operations Log

Chronological record of setup decisions, fixes, and configuration changes.
For the full runbook see `RUNBOOK.md`. For day-to-day usage see `USAGE.md`.

---

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
| 2026-05-07 | Indexers section added to runbook | Documents minimal set, recommended full set, and private tracker path |
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
| 2026-05-22 | Tdarr added to stack | Container haveagitgat/tdarr on port 8265, GPU passthrough (same as Jellyfin). Libraries: movies (/data/movies) and tv (/data/tv). Flow "HEVC→H264" (id=N7tOvfd6i) created: checkVideoCodec → ffmpegCommandStart → ffmpegCommandSetVideoEncoder → ffmpegCommandCustomArguments → ffmpegCommandExecute → replaceOriginalFile. |
| 2026-05-23 | Tdarr flow encoder bug fixed | Root bug: Tdarr Node worker reads `k.inputsDB` not `k.inputs` from the flow config. Flow had only `inputs` fields, so the worker always read plugin defaults (outputCodec=hevc). Fixed by adding matching `inputsDB` fields to all flow plugins. |
| 2026-05-23 | Tdarr 10-bit HEVC support added | h264_nvenc cannot encode 10-bit (yuv420p10le/p010le). Fix: set hardwareDecoding=false (removes -hwaccel cuda so CPU handles 10-bit→8-bit), and added ffmpegCommandCustomArguments plugin with outputArguments="-pix_fmt yuv420p". Final ffmpeg command: h264_nvenc -qp 20 -preset p4 -pix_fmt yuv420p. |
| 2026-05-23 | 455 incorrectly encoded files reset | 17 files encoded with hevc_nvenc (pre-inputsDB fix) and 438 "Transcode error" files (10-bit failures) reset via bulk API. Both libraries scanFresh triggered. Queue re-populating at 542 fps GPU encode rate. |
| 2026-05-23 | Tdarr tile added to Homarr | Tdarr tile added to Homarr dashboard (port 8265). |
| 2026-05-23 | Jellyfin mobile user created | the mobile account created with 8 Mbps per-user bitrate cap. Allows cellular access without risk of saturating the uplink. |
| 2026-05-23 | iOS Mullvad + Tailscale conflict identified | iOS enforces one active VPN. Mullvad captures all traffic including 100.x.x.x, blocking Tailscale. Tailscale shows connected but all Tailscale IPs time out. Fix: disable Mullvad when using Tailscale on iOS. |
| 2026-05-23 | Jellyfin HLS broken for Tdarr-converted files | Jellyfin DB had stale HEVC codec info for files Tdarr converted to H.264. HLS requests applied hevc_mp4toannexb to H.264 streams → FFmpeg exited code 234. Direct play unaffected. Fix: library refresh. Diagnosed via `docker exec jellyfin ffmpeg ...` reproducing the exact failing command. |
| 2026-05-23 | Gluetun/qBittorrent startup hardened | Root cause of recurring tracker failures: Gluetun iptables state drifts bad after hibernate/Docker restart (not Watchtower — both containers excluded from auto-update). Fix applied in three places: (1) startup-stack.ps1 now force-recreates Gluetun on every boot and cleans qBittorrent lockfile before starting; (2) scripts/fix-vpn.ps1 created as one-shot manual recovery script; (3) nightly 2am scheduled task added via create-startup-task.ps1 to proactively reset before Watchtower's 3am run. |
| 2026-05-23 | update.ps1 overhauled | Comprehensive maintenance script: pulls images, applies updates, cleans lockfile, force-recreates Gluetun, waits for health checks (not fixed sleeps), verifies VPN tunnel via am.i.mullvad.net, checks qBittorrent for errored torrents, triggers Jellyfin library scan, prunes images, refreshes firewall. Failures accumulate and are reported in summary rather than aborting early. |
| 2026-05-23 | USAGE.md + LOG.md created | USAGE.md: simple end-user guide. LOG.md: status log extracted from RUNBOOK.md to keep the runbook focused on reference material. README.md renamed to RUNBOOK.md. |
| 2026-05-23 | Quality profile gap identified for classic/SD-only content | a show (1998) has no HD source on Nyaa.si — only DVD 480p/576p releases exist. HD-1080p quality profile rejected all releases (DVD not in allowed list). Solution: use a profile that includes DVD in the allowed list with 1080p as the cutoff — Sonarr grabs DVD immediately and upgrades automatically if HD appears. |
