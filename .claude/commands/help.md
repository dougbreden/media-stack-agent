List everything Claude can do in this media stack repo.

Read the `.claude/commands/` directory and list every `.md` file as an available skill. Then summarise each skill in one line based on its contents.

Format the output as:

```
Media Stack — available skills
───────────────────────────────────────────────────────
STATUS & HEALTH
  /status   Read the last health.json snapshot as a dashboard (instant, no live calls)
  /probe    Run the health probe right now and update health.json
  /brief    Full live briefing: probe + queue + recent repairs + what to do next  ← start here

REPAIR & RESCUE
  /heal     Trigger autonomous Claude repair for a specific service (e.g. /heal vpn)
  /rescue   Scan for dead/stalled downloads and remove them + re-search
  /orphans  Scan /data/torrents for files that weren't imported into Sonarr/Radarr

HISTORY & AUDIT
  /audit    Show recent autonomous heal sessions and Claude tool call log

───────────────────────────────────────────────────────
QUICK REFERENCE
  Ask Claude anything in plain English — it reads CLAUDE.md on every session.
  Examples:
    "What's wrong with the stack?"           → runs /probe or reads /status
    "Nothing is downloading"                 → checks VPN, queue, qBittorrent
    "Show me what episodes are missing"     → queries Sonarr API directly
    "Fix it"                                → runs appropriate repair script

  Key files (you don't need to know these — just ask):
    CLAUDE.md          everything about the stack: scripts, APIs, failure modes
    docs/RUNBOOK.md    full human setup and troubleshooting guide
    logs/health.json   latest probe output (machine-readable)
    logs/heal-*.log    history of every autonomous repair session
```

If the user seems lost or unsure, add this note:
  "You never need to memorise commands. Just describe what you want and Claude will
   figure out which script or API call to use — CLAUDE.md has everything loaded."
