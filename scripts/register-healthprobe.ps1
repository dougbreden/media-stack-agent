# Quick standalone registration of MediaStack-HealthProbe only.
# Run from an elevated (Admin) PowerShell.

$ScriptDir    = "M:\Media\scripts"
$ProbeScript  = "$ScriptDir\health-probe.ps1"
$TaskName     = "MediaStack-HealthProbe"

if (-not (Test-Path $ProbeScript)) {
    Write-Error "Not found: $ProbeScript"
    exit 1
}

$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
                 -RepetitionInterval (New-TimeSpan -Minutes 15) `
                 -RepetitionDuration (New-TimeSpan -Days 9999)
$action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                 -Argument "-NonInteractive -WindowStyle Hidden -File `"$ProbeScript`""
$settings  = New-ScheduledTaskSettingsSet `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
                 -MultipleInstances IgnoreNew `
                 -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal `
                 -UserId "DESKTOP-OPTIMUS\Xardaz" `
                 -LogonType Interactive `
                 -RunLevel Limited

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Registered: $TaskName" -ForegroundColor Green
Write-Host "  User   : $($env:USERNAME)"  -ForegroundColor Gray
Write-Host "  Script : $ProbeScript"      -ForegroundColor Gray
Write-Host "  Trigger: Every 15 minutes"  -ForegroundColor Gray

# Verify
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    Write-Host "Verified OK — State: $($t.State)" -ForegroundColor Green
} else {
    Write-Host "VERIFICATION FAILED — task not found after registration" -ForegroundColor Red
}
