# AGENTS.md — Codex Context for Media Stack

This repo is a Windows Docker Desktop media stack at `M:\Media`. It is operated through PowerShell scripts and Docker Compose. For full human setup details read `RUNBOOK.md`; for chronological history read `LOG.md`; for Claude-oriented context read `CLAUDE.md`.

## Prime Directive

Protect private tracker integrity. Torrent downloads are the source/archive layer and must stay byte-for-byte pristine.

- `M:\Media\data\torrents` is the source/archive tree. Do not modify, remux, dedup, transcode, rename, or delete files there unless the user explicitly asks and understands the seeding impact.
- `M:\Media\data\movies` and `M:\Media\data\tv` are mutable Universal libraries.
- Future `M:\Media\data\movies-4k` and `M:\Media\data\tv-4k` are Premium 4K direct-play libraries.
- Tdarr Universal work must only touch `/data/movies` and `/data/tv`.

Run this read-only guard after compose, qBittorrent category, Tdarr, or library-layout changes:

```powershell
M:\Media\scripts\check-media-policy.ps1
```

## Current Stack Shape

- 13 containers in `docker-compose.yml`.
- qBittorrent uses `network_mode: service:gluetun`; internal hostname is `gluetun`, not `qbittorrent`.
- Gluetun and qBittorrent are excluded from Watchtower.
- After recreating Gluetun, recreate/start qBittorrent with `docker compose up -d qbittorrent`.
- Tdarr mounts only:
  - `M:/Media/data/movies:/data/movies`
  - `M:/Media/data/tv:/data/tv`
  - `M:/Media/data/tdarr_cache:/temp`

## Tdarr Maintenance Scripts

- `tdarr-deploy-universal-flow.ps1`: deploys/assigns the Universal H264+AAC flow. It must not reset file decisions.
- `tdarr-reset-universal-files.ps1`: requeues Universal files. Default is errored files only; full reset requires `-All -ConfirmAll`.
- `tdarr-restore-hevc-flow.ps1`: compatibility wrapper for the old name; deploys only.
- `library-report.ps1`: read-only tier report.
  - Universal target: `H264 + AAC, <=1080p`
  - Premium 4K target: `4K HEVC + MKV`
- `dedup-audio.ps1`: mutating duplicate-audio repair. Defaults to library paths and refuses torrent paths unless `-AllowTorrentPaths`.
- `remux-library-to-mkv.ps1`: mutating MKV remux. Dry-run by default; stream copy only; refuses torrent paths unless `-AllowTorrentPaths`.

## Git And Editing Notes

- Keep commits small and operationally named, matching existing style.
- Do not commit `.env`, `api-keys.md`, `config/`, `data/`, backups, or generated cache files.
- Use `apply_patch` for manual edits.
- Prefer read-only checks before mutating scripts.
- PowerShell scripts are the primary automation surface; validate syntax with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$files=@("M:\Media\scripts\check-media-policy.ps1","M:\Media\scripts\library-report.ps1"); foreach ($f in $files) { $tokens=$null; $errs=$null; [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs) | Out-Null; if ($errs.Count) { $errs | Format-List; exit 1 } }'
```

## When In Doubt

If a proposed change touches Tdarr, qBittorrent categories, Radarr/Sonarr import paths, or media file mutation, first ask:

1. Does this preserve `data\torrents` untouched?
2. Is this Universal-library-only, or Premium-4K-only?
3. Is the operation read-only by default?
4. Is there an explicit scary flag for broad mutations?
