#Requires -Version 5.1
<#
.SYNOPSIS
  Point this Windows PC at the Pi-hole DNS, or revert to automatic/router DNS.

.DESCRIPTION
  Does not change the router. Only this PC is filtered.
  Do not set a second public DNS: Windows may skip Pi-hole and ads will leak.

.EXAMPLE
  .\set-pc-dns.ps1 -PiIP 192.168.0.50

.EXAMPLE
  .\set-pc-dns.ps1 -Revert
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$PiIP,

    [Parameter(ParameterSetName = 'Revert')]
    [switch]$Revert,

    [string]$Adapter
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $id
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'Run this in an elevated PowerShell (Run as administrator).'
}

$skip = 'Loopback|Virtual|Hyper-V|vEthernet|WSL|Bluetooth|TAP-Windows|VPN|Pseudo|WAN Miniport|Teredo|isatap|Microsoft Wi-Fi Direct'

function Get-TargetAdapters {
    param([string]$Name)
    $up = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    if ($Name) {
        $match = $up | Where-Object { $_.Name -eq $Name -or $_.InterfaceDescription -eq $Name }
        if (-not $match) { throw "No Up adapter named '$Name'. Use Get-NetAdapter to list names." }
        return @($match)
    }
    $physical = $up | Where-Object {
        $_.HardwareInterface -and $_.InterfaceDescription -notmatch $skip -and $_.Name -notmatch $skip
    }
    if (-not $physical) {
        throw 'No physical Ethernet/Wi-Fi adapter is Up. Pass -Adapter with the name from Get-NetAdapter.'
    }
    return @($physical)
}

$targets = Get-TargetAdapters -Name $Adapter
foreach ($nic in $targets) {
    if ($Revert) {
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses
        Write-Host ("Reverted DNS on {0} (ifIndex {1})" -f $nic.Name, $nic.ifIndex)
    }
    else {
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $PiIP
        Write-Host ("Set DNS on {0} to {1}" -f $nic.Name, $PiIP)
    }
}

Clear-DnsClientCache
Write-Host 'DNS cache flushed.'
if (-not $Revert) {
    Write-Host "Pi-hole admin: http://$PiIP/admin"
    Write-Host 'Turn off Windows / Chrome / Edge Secure DNS or ads will still load. See SETUP.md step 7.'
}
