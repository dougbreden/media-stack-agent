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

# =============================================================================
# 4. MediaStack-Firewall
#    On-demand, elevated: re-apply Docker firewall rules without UAC prompt.
#    Runs as SYSTEM so Start-ScheduledTask from any non-admin process
#    (including Claude Code) can trigger it without a UAC prompt.
# =============================================================================
$FwTaskName = "MediaStack-Firewall"
$FwScript   = "$ScriptDir\setup-firewall.ps1"

$fwAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File `"$FwScript`""
$fwSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$fwPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName $FwTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $FwTaskName -Action $fwAction -Settings $fwSettings -Principal $fwPrincipal -Force | Out-Null

# Grant Authenticated Users (standard accounts) the right to trigger this task.
# SYSTEM tasks have a restrictive default DACL that blocks non-admin callers.
# D:(A;;GRGX;;;AU) = Allow Authenticated Users Generic Read + Execute
# D:(A;;GA;;;BA)   = Allow Administrators full control
# D:(A;;GA;;;SY)   = Allow SYSTEM full control
$scheduler = New-Object -ComObject "Schedule.Service"
$scheduler.Connect()
$sddl = "D:(A;;GRGX;;;AU)(A;;GA;;;BA)(A;;GA;;;SY)"
$scheduler.GetFolder("\").GetTask($FwTaskName).SetSecurityDescriptor($sddl, 0)

Write-Host "Registered: $FwTaskName" -ForegroundColor Green
Write-Host "  Trigger : On-demand (Start-ScheduledTask from any process)" -ForegroundColor Gray
Write-Host "  RunLevel: Highest / SYSTEM (no UAC prompt)" -ForegroundColor Gray
Write-Host "  Script  : $FwScript" -ForegroundColor Gray

Write-Host ""
Write-Host "All tasks registered. To verify:" -ForegroundColor Yellow
Write-Host "  Get-ScheduledTask | Where-Object { `$_.TaskName -like 'MediaStack-*' }" -ForegroundColor Gray
