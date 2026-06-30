Read `M:\Media\logs\health.json` and render the current stack health as a dashboard.

If the file does not exist, say so and suggest running `/probe` to generate it.

Check the `timestamp` field. If it is more than 30 minutes old, warn that the data may be stale (probe may not be running).

Render in this format:

```
Stack Health — <timestamp>   [HEALTHY / DEGRADED]

  containers  OK   13/13 up
  vpn         OK   185.195.x.x
  qbittorrent OK
  disk        OK   3542 GB free / 7452 GB
  firewall    OK   12 rules
```

Use green for OK checks and red for degraded ones. List any `down` containers by name.
If `status` is `degraded`, end with a bold line: **Run `/probe` for live details.**

Keep the response to the dashboard block only — no extra explanation unless something is degraded.
