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

New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null

if (-not (Test-Path $Script)) {
    Write-Host "  ERROR: $Script not found. Ensure startup-stack.ps1 exists before registering the task." -ForegroundColor Red
    exit 1
}
Write-Host "  Using existing: $Script" -ForegroundColor Gray

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

# ── Nightly Gluetun reset task ────────────────────────────────────────────────
# Gluetun's iptables killswitch can drift into a bad state after Windows
# hibernate/resume or a WireGuard tunnel hiccup, blocking all tracker UDP traffic.
# A nightly force-recreate at 2am (before Watchtower at 3am) keeps it clean.
$VpnResetTaskName = "MediaStack-VpnReset"
$VpnResetScript   = "$ScriptDir\fix-vpn.ps1"

$vpnAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$VpnResetScript`""

$vpnTrigger = New-ScheduledTaskTrigger -Daily -At "02:00"

$vpnSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -StartWhenAvailable

$vpnPrincipal = New-ScheduledTaskPrincipal `
    -UserId    $env:USERNAME `
    -LogonType Interactive `
    -RunLevel  Highest

Unregister-ScheduledTask -TaskName $VpnResetTaskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName  $VpnResetTaskName `
    -Action    $vpnAction `
    -Trigger   $vpnTrigger `
    -Settings  $vpnSettings `
    -Principal $vpnPrincipal `
    -Force | Out-Null

Write-Host "Registered scheduled task: $VpnResetTaskName" -ForegroundColor Green
Write-Host "  Trigger : Daily at 02:00 (before Watchtower at 03:00)" -ForegroundColor Gray
Write-Host "  Action  : Force-recreate Gluetun + clean qBittorrent lockfile" -ForegroundColor Gray
Write-Host "  Script  : $VpnResetScript" -ForegroundColor Gray
