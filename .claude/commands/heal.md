Manually trigger a Claude autonomous repair session for a specific service.

Usage: `/heal <service>` where service is one of: `containers`, `vpn`, `qbittorrent`, `disk`, `firewall`, `sonarr-queue`

Run:
```powershell
& "M:\Media\scripts\heal-invoke.ps1" -Service "$input" -Description "Manual trigger from /heal"
```

Replace `$input` with the service name provided after `/heal`.

If no service is specified, read `M:\Media\logs\health.json` and suggest which degraded service to heal, then ask the user to confirm with `/heal <service>`.

After the script completes:
- Show the exit code (0 = healed/skipped, 1 = still degraded, 2 = escalation required)
- If the heal log was updated, show the last `===== HEAL SESSION =====` block from `M:\Media\logs\heal-<current month>.log`
- Summarize what Claude did and whether the service recovered
