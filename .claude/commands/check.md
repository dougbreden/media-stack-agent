Run `M:\Media\scripts\library-report.ps1` using the PowerShell tool and interpret the output.

Report in this format:
- One line per library (Movies / TV) showing: container %, video codec %, missing AAC count, duplicate streams count
- A short "needs action" list: only items that require a script or manual step right now
- One sentence on what Tdarr is still working through (HEVC count + missing AAC count = what's in queue)

Keep the response under 20 lines. Do not reprint the full report output.

If there are non-MKV files or errored Tdarr files, suggest running `standardize-library.ps1`. If there are duplicate streams, suggest running `dedup-audio.ps1 -DryRun` first.
