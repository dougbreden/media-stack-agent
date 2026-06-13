#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up Windows Firewall rules so phones, TVs, and Tailscale can reach the media stack.

.DESCRIPTION
    Docker-published ports are forwarded to WSL2 by a relay process. Which process
    depends on the Windows version:
      Windows 11: wslrelay.exe  (C:\Program Files\WSL\wslrelay.exe)
      Windows 10: com.docker.backend.exe  (C:\Program Files\Docker\Docker\resources\)

    Windows Firewall does not automatically allow inbound connections from non-local
    networks (Tailscale, mobile data) to these relay processes, so this script adds
    explicit allow rules for whichever relay exists. It also disables any Docker Desktop
    block rules and adds named port rules as a redundant safety net.

    Run this script:
      - Once after a fresh Windows or Docker install
      - Again after Docker Desktop or Windows updates break remote access
      - Any time Tailscale or LAN access to any service stops working

    Must be run as Administrator. Right-click PowerShell -> Run as Administrator, then:
        M:\Media\scripts\setup-firewall.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "Media Stack Firewall Setup" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan

# -- Step 1: Allow the Docker port relay process (varies by Windows version) ---
# Windows 11 uses wslrelay.exe; Windows 10 uses com.docker.backend.exe.
# We add rules for whichever are present so the script works on both.
Write-Host "`n[1/3] Adding allow rules for Docker port relay process(es)..."

$relayProcesses = @(
    @{ Path = "C:\Program Files\WSL\wslrelay.exe";
       Name = "Media Stack - WSL Relay (wslrelay.exe)";
       Desc = "Windows 11 WSL2 port relay -- forwards Docker-published ports to LAN/Tailscale" },
    @{ Path = "C:\Program Files\Docker\Docker\resources\com.docker.backend.exe";
       Name = "Media Stack - Docker Backend (com.docker.backend.exe)";
       Desc = "Windows 10 Docker port relay -- forwards Docker-published ports to LAN/Tailscale" }
)

$relayFound = 0
foreach ($relay in $relayProcesses) {
    Remove-NetFirewallRule -DisplayName $relay.Name -ErrorAction SilentlyContinue
    if (Test-Path $relay.Path) {
        New-NetFirewallRule `
            -DisplayName  $relay.Name `
            -Description  $relay.Desc `
            -Direction    Inbound `
            -Action       Allow `
            -Program      $relay.Path `
            -Profile      Any `
            -Enabled      True | Out-Null
        Write-Host "  [OK] $($relay.Name)" -ForegroundColor Green
        $relayFound++
    } else {
        Write-Host "  [--] Not present: $([System.IO.Path]::GetFileName($relay.Path))" -ForegroundColor Gray
    }
}
if ($relayFound -eq 0) {
    Write-Host "  [WARN] Neither relay process found -- port rules below are the only protection" -ForegroundColor Yellow
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
    @{ Name = "Media Stack - Tdarr";        Port = 8265; Description = "Tdarr transcoder web UI" }
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
