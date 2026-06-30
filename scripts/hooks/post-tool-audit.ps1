<#
.SYNOPSIS
    Claude Code PostToolUse hook — appends every Bash/PowerShell command to the audit log.

.DESCRIPTION
    Invoked by Claude Code after each Bash or PowerShell tool call.
    Receives a JSON object on stdin with fields: tool_name, tool_input, tool_response.
    Appends a single line to logs/claude-audit.log (UTF-8 no BOM).

    Format: <ISO timestamp> | <tool_name> | <command (first 300 chars)>
#>
$raw = [Console]::In.ReadToEnd()
try {
    $d        = $raw | ConvertFrom-Json
    $toolName = if ($d.tool_name) { $d.tool_name } else { "Unknown" }
    $cmd      = if ($d.tool_input -and $d.tool_input.command) {
        ($d.tool_input.command -replace "\r?\n", " ").Trim()
    } else { "[no command]" }
    if ($cmd.Length -gt 300) { $cmd = $cmd.Substring(0, 300) + "..." }
    $line = "{0} | {1,-15} | {2}" -f (Get-Date -Format "o"), $toolName, $cmd
} catch {
    $errMsg = ($raw -replace "\r?\n", " ")
    if ($errMsg.Length -gt 200) { $errMsg = $errMsg.Substring(0, 200) }
    $line = "{0} | PARSE_ERROR    | {1}" -f (Get-Date -Format "o"), $errMsg
}

$logPath = "M:\Media\logs\claude-audit.log"
$null    = New-Item -ItemType Directory -Force -Path (Split-Path $logPath)
[System.IO.File]::AppendAllText($logPath, $line + "`n", [System.Text.UTF8Encoding]::new($false))
