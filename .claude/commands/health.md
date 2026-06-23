Run `M:\Media\scripts\maintain-stack.ps1` using the PowerShell tool and interpret the output.

Report in this format:
- Disk: free GB / total GB, status
- Containers: X/Y healthy (list any that are down or unhealthy)
- VPN: connected or not
- qBittorrent: healthy or repaired
- Downloads: dead metaDL count, dangerous files count
- Standardize: ran or skipped (show stamp age)
- Firewall: OK or skipped (non-admin)

If any FAIL lines appear, explain what the failure means and what manual step is needed.
If fixes were applied automatically, confirm they succeeded.

Keep the response concise -- one line per section is enough when everything is healthy.
