Scan /data/torrents for video files that Sonarr or Radarr can import but haven't yet.

Run the scan in dry-run mode:
```powershell
& "M:\Media\scripts\import-orphans.ps1" -All
```

Show the output including all confidence levels (high, low, unrecognised).

High-confidence items have exactly one episode/movie match with no rejections — safe to auto-import.
Low-confidence items need manual review in the Sonarr/Radarr UI (Wanted > Manual Import).
Unrecognised items have no match at all — likely wrongly named or not in the library.

If the user says to import (e.g. `/orphans import`), run:
```powershell
& "M:\Media\scripts\import-orphans.ps1" -Import
```

After import, Sonarr/Radarr will move files from /data/torrents to the library (hardlinked).
The torrent source file remains; only the library copy is created.

If files were imported, remind the user to check Jellyfin in a few minutes — it auto-scans
or use: `Invoke-RestMethod -Method Post "http://localhost:8096/Library/Refresh?api_key=<jellyfin-key>"`
