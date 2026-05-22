#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers a Windows scheduled task that starts the media stack on login.

.DESCRIPTION
    Creates a task that runs at user logon, waits for Docker Desktop to be ready
    (up to 2 minutes with retries), then runs docker compose up -d.

    Containers already have restart:unless-stopped, so this task is a safety net
    for cases where Docker Desktop itself restarted and containers didn't come back.

    Run once after a fresh Windows install or Docker Desktop reinstall.
    Must be run as Administrator.
#>

$TaskName  = "MediaStack-Startup"
$ScriptDir = "M:\Media\scripts"
$Script    = "$ScriptDir\startup-stack.ps1"

# ── Write the actual startup script ──────────────────────────────────────────
# Note: only writes startup-stack.ps1 if it does not already exist, to avoid
# overwriting manual edits. Delete startup-stack.ps1 first to force a rewrite.
New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null

if (-not (Test-Path $Script)) {
@'
# Wait for Docker Desktop to be ready (up to 2 minutes)
$attempts = 0
while ($attempts -lt 12) {
    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) { break }
    } catch {}
    Start-Sleep -Seconds 10
    $attempts++
}

if ($LASTEXITCODE -ne 0) {
    Write-EventLog -LogName Application -Source "MediaStack" -EventId 1001 -EntryType Error `
        -Message "MediaStack-Startup: Docker was not ready after 120 seconds. Stack not started." `
        -ErrorAction SilentlyContinue
    exit 1
}

docker compose -f "M:\Media\docker-compose.yml" up -d

# Refresh firewall after docker compose rebuilds its network bridge
& "M:\Media\scripts\setup-firewall.ps1"
'@ | Set-Content -Path $Script -Encoding UTF8
    Write-Host "  Written: $Script" -ForegroundColor Gray
} else {
    Write-Host "  Kept existing: $Script" -ForegroundColor Gray
}

# ── Register the scheduled task ───────────────────────────────────────────────
$action   = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$Script`""

$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId    $env:USERNAME `
    -LogonType Interactive `
    -RunLevel  Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Host "Registered scheduled task: $TaskName" -ForegroundColor Green
Write-Host "  Trigger : At logon for $($env:USERNAME)" -ForegroundColor Gray
Write-Host "  Action  : Wait for Docker, then docker compose up -d" -ForegroundColor Gray
Write-Host "  Script  : $Script" -ForegroundColor Gray
Write-Host "`nTo verify: Get-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Yellow
