<#
.SYNOPSIS
    Compatibility wrapper for the old Tdarr restore script name.

.DESCRIPTION
    The old restore script mixed flow deployment with a full file reset. That
    is now split into safer scripts:
      - tdarr-deploy-universal-flow.ps1 updates/assigns the Universal flow
      - tdarr-reset-universal-files.ps1 intentionally requeues Universal files
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DeployScript = Join-Path $ScriptDir "tdarr-deploy-universal-flow.ps1"

Write-Host "tdarr-restore-hevc-flow.ps1 has been replaced." -ForegroundColor Yellow
Write-Host "Running tdarr-deploy-universal-flow.ps1 only; no files will be reset." -ForegroundColor Yellow
Write-Host "Use tdarr-reset-universal-files.ps1 when you intentionally need to requeue files." -ForegroundColor Yellow
Write-Host ""

& $DeployScript
exit $LASTEXITCODE
