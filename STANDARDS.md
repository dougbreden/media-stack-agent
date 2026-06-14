# Media Library Standards

This document defines the required format for every file in each library tier.
Scripts and Tdarr automation enforce these standards automatically.
Run `scripts\standardize-library.ps1` to bring any library into compliance.

---

## Universal Library (non-4K)

**Paths:** `M:\Media\data\movies` | `M:\Media\data\tv`

| Property | Required | Notes |
|---|---|---|
| Container | **MKV** | Stream copy only — no re-encoding |
| Video codec | **H264** (AVC) | GPU-encoded via h264_nvenc if source is HEVC/AV1/VP9 |
| Video depth | **8-bit** | 10-bit sources are converted (-pix_fmt yuv420p) |
| Resolution | ≤ 1080p | 4K files belong in the Premium library |
| Audio — required | **AAC stereo, 192k** | Language: English (en). Added by Tdarr if absent |
| Audio — optional | Any surround track | AC3/DTS/EAC3/TrueHD kept via -map 0; not touched |
| Audio — Japanese | AAC stereo, 192k | Added for dual-audio content releases (lang=j) |
| Subtitles | Passed through | No modification |
| Duplicate streams | None | Signature: codec+channels+language must be unique |

**What "standardized" means for this tier:**
A file is fully standardized when it is MKV + H264 + has at least one AAC stereo track
with no duplicate audio streams. Surround tracks alongside AAC are correct and expected.

---

## Premium 4K Library (future)

**Paths:** `M:\Media\data\movies-4k` | `M:\Media\data\tv-4k`

| Property | Required | Notes |
|---|---|---|
| Container | **MKV** | |
| Video codec | **HEVC** (H265) | Direct-play on Apple TV, Infuse Pro, Plex HEVC clients |
| Video depth | 10-bit preferred | Preserves HDR signal path |
| Resolution | **4K (2160p)** | 1080p files belong in the Universal library |
| HDR | HDR10 or Dolby Vision | Preserved via stream copy — never tone-mapped |
| Audio — required | **Lossless or lossy surround** | TrueHD Atmos / DTS-HD MA / EAC3 Atmos preferred |
| Audio — fallback | AAC stereo, 192k | For clients that cannot decode lossless surround |
| Tdarr | **Not processed** | Premium files must not be transcoded. Tdarr is scoped to Universal libraries only. |

**Clients that can direct-play this tier:**
- Infuse Pro (Apple TV / iOS) — HEVC + TrueHD Atmos hardware decode
- Jellyfin Media Player (desktop, MPV engine) — HEVC + passthrough to AV receiver
- Plex with a compatible client + GPU passthrough server

---

## How Standardization Is Enforced

### Automatic (ongoing)

| Tool | What it does | Frequency |
|---|---|---|
| **Tdarr** | Encodes HEVC/AV1 → H264; adds AAC if missing | Continuous — picks up every new import |
| **check-stack.ps1** | Calls standardize-library.ps1 | On every boot (once tasks are registered) |
| **standardize-library.ps1** | Runs dedup + remux + Tdarr scan | Daily (gated by `.standardize-last-run` stamp) |

### Manual (on demand)

```powershell
# Full standardization pass (dedup + remux + Tdarr scan)
M:\Media\scripts\standardize-library.ps1

# Check current compliance across all libraries
M:\Media\scripts\library-report.ps1

# Remove duplicate audio streams only
M:\Media\scripts\dedup-audio.ps1 -DryRun   # preview
M:\Media\scripts\dedup-audio.ps1            # apply

# Convert non-MKV files to MKV (stream copy, no re-encode)
M:\Media\scripts\remux-library-to-mkv.ps1          # dry-run
M:\Media\scripts\remux-library-to-mkv.ps1 -Apply   # apply

# Reset Tdarr errored files and re-queue them
M:\Media\scripts\tdarr-reset-universal-files.ps1

# Full Tdarr reset (after flow changes — requeues everything)
M:\Media\scripts\tdarr-reset-universal-files.ps1 -All -ConfirmAll
```

### Tdarr flow: Universal H264+AAC

Flow ID `N7tOvfd6i` — two branches based on video codec:

```
Is video H264?
  YES → copy video stream | EnsureAudioStream(en AAC 2ch 192k) | EnsureAudioStream(j AAC 2ch 192k)
  NO  → h264_nvenc (-qp 20 -preset p4 -pix_fmt yuv420p) | EnsureAudioStream(en) | EnsureAudioStream(j)
```

EnsureAudioStream is idempotent: it only adds a track if no matching AAC+language track exists.
All other streams (surround audio, subtitles) are preserved via `-map 0`.

---

## Identifying Non-Standard Files

`library-report.ps1` output to look for:

| Field | Good | Needs action |
|---|---|---|
| Video Codec | 100% h264 | Any hevc / av1 / vp9 → Tdarr queue |
| Container | 100% mkv | Any mp4 / avi / ts → remux-library-to-mkv.ps1 |
| Missing AAC | 0 | Any > 0 → Tdarr (check for errors with tdarr-reset-universal-files.ps1) |
| Duplicate streams | 0 | Any > 0 → dedup-audio.ps1 |
| Tier Standard | 100% | Anything < 100% → run standardize-library.ps1 |

---

## Notes

- **Tdarr never touches Premium 4K libraries.** The deploy script is scoped to library IDs
  `rUP5cniqB` (movies) and `nw7PJBmiV` (tv) only.
- **Torrent paths are never modified.** All scripts refuse `M:\Media\data\torrents` by default
  to protect private tracker hardlinks.
- **MKV is the only container.** Even when a file is already H264+AAC in MP4, it gets
  remuxed to MKV (stream copy, no quality loss) for consistency and subtitle compatibility.
- **The a movie** (`Journey to Big Water (2002).mp4`) is a permanently corrupt file.
  It fails every probe and remux attempt. Delete and re-request via Jellyseerr if needed.
