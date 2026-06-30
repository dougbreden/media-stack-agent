Run `M:\Media\scripts\health-probe.ps1` using the PowerShell tool and report the results.

```powershell
& "M:\Media\scripts\health-probe.ps1"
```

After it completes, read `M:\Media\logs\health.json` and render the same dashboard format as `/status`.

Report any FAIL or WARN lines and what they mean. If the probe exits with code 1 (degraded), explain which checks failed and what the next step is (refer to the Known Failure Modes in CLAUDE.md).

Keep the response concise — one line per check, extra detail only for failures.
