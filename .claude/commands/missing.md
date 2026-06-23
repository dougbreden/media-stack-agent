Run `M:\Media\scripts\check-missing.ps1` using the PowerShell tool and interpret the output.

For each series or movie that has been missing for more than 14 days, briefly note the most likely reason it isn't downloading (choose from: not indexed on public trackers, custom format score rejection, quality cutoff already met, or content not yet aired).

Shows missing from Nyaa.si (SubsPlease/Erai-raws don't carry it) should be flagged separately -- those need a manual torrent search or a private tracker.

After showing the summary, ask the user:
1. Whether to trigger searches now (`-TriggerSearch` flag)
2. Whether they want to investigate a specific title's rejection reasons (use Sonarr/Radarr interactive release search API for that)

If $ARGUMENTS is provided, treat it as a series or movie name to look up specifically rather than running the full report.
