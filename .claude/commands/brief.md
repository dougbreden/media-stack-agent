Run a full live briefing of the media stack and proactively recommend what to do next.
This is the "start of session" command — Gandalf mode.

Steps (run in this order, show results as you go):

1. **Health probe** — Run `M:\Media\scripts\health-probe.ps1` and capture output.
   If any check is DEGRADED, flag it prominently.

2. **Download queue scan** — Run `M:\Media\scripts\rescue-downloads.ps1` (dry-run, no -Rescue flag).
   Report how many stalled items exist and name them.

3. **Recent autonomous repairs** — Read the last 3 entries from `M:\Media\logs\heal-<current-month>.log`.
   If the file doesn't exist, say no autonomous repairs this month.

4. **Sonarr wanted check** — Call the Sonarr API to count episodes that are missing and monitored:
   ```powershell
   . "M:\Media\scripts\config.ps1"
   $w = Invoke-RestMethod "http://localhost:8989/api/v3/wanted/missing?apikey=$sonarrKey&pageSize=1"
   Write-Host "Missing monitored episodes: $($w.totalRecords)"
   ```

5. **Disk space** — Read from health.json or re-check `Get-PSDrive M`.

Then produce a **Briefing** in this format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Media Stack Briefing — <date>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HEALTH       ✓ All 6 checks healthy   (or list degraded ones in red)
DISK         3486 GB free / 7452 GB
QUEUE        3 stalled downloads  ← /rescue to fix    (or ✓ Queue clean)
MISSING      14 monitored episodes not yet downloaded
LAST REPAIR  2026-06-28 02:15 — vpn → RECOVERED (or "None this month")

WHAT I'D DO NEXT
  1. Run /rescue — 3 TV episodes have been stuck for 7 days
  2. Check Sonarr wanted list — 14 missing episodes, some may need indexer changes
  (or: Nothing urgent. Stack looks healthy.)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

The "WHAT I'D DO NEXT" section is the most important part.
Be specific: name the shows, name the commands, give a reason.
If nothing needs doing, say so — don't invent work.

After showing the briefing, wait for the user to say what they want to do.
If they say "do it" or "fix it" or similar, execute the recommended actions.
