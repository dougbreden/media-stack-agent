Show recent autonomous repair sessions from the heal log.

Read `M:\Media\logs\heal-<current month>.log` (e.g. `heal-2026-06.log`). If the file does not exist, say so and explain that no autonomous repairs have been attempted yet.

Show the last 5 `===== HEAL SESSION =====` blocks in reverse chronological order (most recent first).

For each session, format as:

```
[2026-06-28 10:15]  vpn  →  RECOVERED
  Claude: Ran fix-vpn.ps1. Gluetun force-recreated. VPN connected at 185.195.x.x.
```

After the sessions, show a one-line summary:
- Total sessions this month
- Services healed / escalated / still degraded

If the user asks about a specific service, filter to only that service's sessions.

Also check `M:\Media\logs\claude-audit.log` if it exists — show the last 10 lines as a separate section titled "Recent Claude tool calls (audit trail)".
