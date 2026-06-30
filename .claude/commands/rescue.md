Identify and rescue dead/stalled downloads from the Sonarr and Radarr queues.

Run a dry-run first to show what's stalled:
```powershell
& "M:\Media\scripts\rescue-downloads.ps1"
```

Show the output. If the user confirms they want to rescue (remove dead items and trigger re-search), run:
```powershell
& "M:\Media\scripts\rescue-downloads.ps1" -Rescue
```

If the user specifies a service (e.g. `/rescue Sonarr`), add `-Service Sonarr` or `-Service Radarr`.

If the user specifies a shorter stale threshold (e.g. `/rescue 6h`), parse the number and add `-StaleHours 6`.

After rescue completes:
- Report how many items were removed and how many re-searches were triggered
- Mention that blocklist=true prevents the same dead releases from being re-grabbed
- Suggest running `/orphans` if there may be unimported files in /data/torrents

Exit code 0 = success, 1 = some removals failed (check automation log).
