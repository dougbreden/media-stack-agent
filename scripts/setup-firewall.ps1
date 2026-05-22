#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up Windows Firewall rules so phones, TVs, and Tailscale can reach the media stack.

.DESCRIPTION
    On Windows 11 with WSL2, Docker-published ports are forwarded by wslrelay.exe
    (C:\Program Files\WSL\wslrelay.exe). Windows Firewall does not automatically
    allow inbound connections to this process from non-local networks (Tailscale,
    mobile data, etc.) unless explicitly permitted.

    This script:
      1. Adds an application-level allow rule for wslrelay.exe (covers all ports,
         all profiles -- the same thing Windows creates when you click Allow on
         the firewall prompt)
      2. Disables any Docker Desktop Backend block rules if they exist
      3. Adds named port-specific allow rules as a redundant safety net

    Run this script:
      - Once after a fresh Windows or WSL install
      - Again if Docker/WSL updates and remote access stops working
      - If Tailscale or LAN access to any service suddenly stops working

    Must be run as Administrator. Right-click PowerShell -> Run as Administrator, then:
        M:\Media\scripts\setup-firewall.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "Media Stack Firewall Setup" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan

# -- Step 1: Allow wslrelay.exe (the actual WSL2 port proxy) ------------------
# On Windows 11, Docker-published ports are owned by wslrelay.exe. Without this
# rule, inbound connections from Tailscale and other non-local sources are blocked
# even though the ports are bound to 0.0.0.0.
Write-Host "`n[1/3] Adding allow rule for wslrelay.exe (WSL2 port relay)..."

$wslRelayPath = "C:\Program Files\WSL\wslrelay.exe"
$wslRuleName  = "Media Stack - WSL Relay (wslrelay.exe)"

Remove-NetFirewallRule -DisplayName $wslRuleName -ErrorAction SilentlyContinue

if (Test-Path $wslRelayPath) {
    New-NetFirewallRule `
        -DisplayName  $wslRuleName `
        -Description  "Allows WSL2 relay to accept inbound connections from LAN and Tailscale for Docker-published ports" `
        -Direction    Inbound `
        -Action       Allow `
        -Program      $wslRelayPath `
        -Profile      Any `
        -Enabled      True | Out-Null
    Write-Host "  [OK] wslrelay.exe allow rule added" -ForegroundColor Green
} else {
    Write-Host "  [WARN] wslrelay.exe not found at $wslRelayPath" -ForegroundColor Yellow
}

# -- Step 2: Disable Docker Desktop block rules if present --------------------
Write-Host "`n[2/3] Checking for Docker Desktop Backend block rules..."

$dockerRules = Get-NetFirewallRule -DisplayName "Docker Desktop Backend" -ErrorAction SilentlyContinue
if ($dockerRules) {
    $dockerRules | Disable-NetFirewallRule
    Write-Host "  Disabled $($dockerRules.Count) Docker Desktop Backend block rule(s)" -ForegroundColor Green
} else {
    Write-Host "  None found (clean)" -ForegroundColor Gray
}

# -- Step 3: Add named port-specific allow rules (redundant safety net) -------
Write-Host "`n[3/3] Adding port-specific allow rules..."

$portRules = @(
    @{ Name = "Media Stack - Jellyfin";     Port = 8096; Description = "Jellyfin media server" }
    @{ Name = "Media Stack - Jellyseerr";   Port = 5055; Description = "Jellyseerr request UI" }
    @{ Name = "Media Stack - Radarr";       Port = 7878; Description = "Radarr movie automation" }
    @{ Name = "Media Stack - Sonarr";       Port = 8989; Description = "Sonarr TV automation" }
    @{ Name = "Media Stack - Prowlarr";     Port = 9696; Description = "Prowlarr indexer manager" }
    @{ Name = "Media Stack - qBittorrent";  Port = 8080; Description = "qBittorrent web UI" }
    @{ Name = "Media Stack - Bazarr";       Port = 6767; Description = "Bazarr subtitle manager" }
    @{ Name = "Media Stack - FlareSolverr"; Port = 8191; Description = "FlareSolverr Cloudflare bypass" }
    @{ Name = "Media Stack - Homarr";       Port = 7575; Description = "Homarr dashboard" }
)

foreach ($rule in $portRules) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName  $rule.Name `
        -Description  $rule.Description `
        -Direction    Inbound `
        -Action       Allow `
        -Protocol     TCP `
        -LocalPort    $rule.Port `
        -Profile      Any `
        -Enabled      True | Out-Null
    Write-Host "  [OK] $($rule.Name) (port $($rule.Port))" -ForegroundColor Green
}

# -- Summary ------------------------------------------------------------------
Write-Host "`nDone. Active Media Stack rules:" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName "Media Stack -*" | ForEach-Object {
    $pf = $_ | Get-NetFirewallPortFilter
    $af = $_ | Get-NetFirewallApplicationFilter

    if ($pf.LocalPort -and $pf.LocalPort -ne "Any") {
        $portStr = "port $($pf.LocalPort)"
    } else {
        $portStr = "all ports"
    }

    if ($af.Program -and $af.Program -ne "Any") {
        $progStr = " [$($af.Program | Split-Path -Leaf)]"
    } else {
        $progStr = ""
    }

    "  $($_.DisplayName): $portStr$progStr"
}

Write-Host "`nTailscale and LAN access should now work. Re-run this script if access breaks again." -ForegroundColor Yellow
