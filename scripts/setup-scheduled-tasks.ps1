<#
.SYNOPSIS
    Register all Windows scheduled tasks for the media stack.

.DESCRIPTION
    Creates three scheduled tasks. Safe to re-run -- unregisters and re-registers
    each task if it already exists. Must be run as Administrator.

    Tasks registered:
      MediaStack-Startup     -- At logon: wait for Docker, docker compose up -d
      MediaStack-VpnReset    -- Daily 02:00: force-recreate Gluetun (pre-Watchtower at 03:00)
      MediaStack-Standardize -- Daily 03:30: remux + dedup + Tdarr scan for new downloads

.NOTES
    Replaces: create-startup-task.ps1
#>

$ScriptDir = "M:\Media\scripts"
New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null

# =============================================================================
# 1. MediaStack-Startup
#    At logon: wait for Docker Desktop, then docker compose up -d
# =============================================================================
$TaskName = "MediaStack-Startup"
$Script   = "$ScriptDir\startup-stack.ps1"

if (-not (Test-Path $Script)) {
    Write-Host "  ERROR: $Script not found." -ForegroundColor Red
    exit 1
}
Write-Host "  Using: $Script" -ForegroundColor Gray

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File `"$Script`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Registered: $TaskName" -ForegroundColor Green
Write-Host "  Trigger : At logon for $($env:USERNAME)" -ForegroundColor Gray
Write-Host "  Script  : $Script" -ForegroundColor Gray

# =============================================================================
# 2. MediaStack-VpnReset
#    Daily 02:00: force-recreate Gluetun before Watchtower at 03:00
# =============================================================================
$VpnTaskName = "MediaStack-VpnReset"
$VpnScript   = "$ScriptDir\fix-vpn.ps1"

$vpnAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File `"$VpnScript`""
$vpnTrigger   = New-ScheduledTaskTrigger -Daily -At "02:00"
$vpnSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -StartWhenAvailable
$vpnPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $VpnTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $VpnTaskName -Action $vpnAction -Trigger $vpnTrigger -Settings $vpnSettings -Principal $vpnPrincipal -Force | Out-Null
Write-Host "Registered: $VpnTaskName" -ForegroundColor Green
Write-Host "  Trigger : Daily at 02:00 (before Watchtower at 03:00)" -ForegroundColor Gray
Write-Host "  Script  : $VpnScript" -ForegroundColor Gray

# =============================================================================
# 3. MediaStack-Standardize
#    Daily 03:30: dedup + Tdarr reset + remux + Tdarr scanFresh
#    Runs after Watchtower image pulls (03:00) so new container versions are live first
# =============================================================================
$StdTaskName = "MediaStack-Standardize"
$StdScript   = "$ScriptDir\standardize-library.ps1"

$stdAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File `"$StdScript`""
$stdTrigger   = New-ScheduledTaskTrigger -Daily -At "03:30"
$stdSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
$stdPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $StdTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $StdTaskName -Action $stdAction -Trigger $stdTrigger -Settings $stdSettings -Principal $stdPrincipal -Force | Out-Null
Write-Host "Registered: $StdTaskName" -ForegroundColor Green
Write-Host "  Trigger : Daily at 03:30 (after Watchtower at 03:00)" -ForegroundColor Gray
Write-Host "  Script  : $StdScript" -ForegroundColor Gray

Write-Host ""
Write-Host "All tasks registered. To verify:" -ForegroundColor Yellow
Write-Host "  Get-ScheduledTask | Where-Object { `$_.TaskName -like 'MediaStack-*' }" -ForegroundColor Gray
