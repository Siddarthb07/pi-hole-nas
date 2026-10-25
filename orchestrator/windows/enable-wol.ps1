#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Enable Wake-on-LAN on the Windows PC trade_bot host.

.DESCRIPTION
  - Enables wake on magic packet on active Ethernet adapters
  - Disables Fast Startup (breaks reliable WOL on many boards)
  - Prints MAC addresses to paste into Pi orchestrator config

  Run once on the PC, then enable WOL in BIOS/UEFI if your board requires it.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Wake-on-LAN setup ===" -ForegroundColor Cyan

# Disable Fast Startup (hybrid shutdown prevents clean WOL)
$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$hybrid = Get-ItemProperty -Path $path -Name HiberbootEnabled -ErrorAction SilentlyContinue
if ($hybrid -and $hybrid.HiberbootEnabled -ne 0) {
    Set-ItemProperty -Path $path -Name HiberbootEnabled -Value 0
    Write-Host "Disabled Fast Startup (HiberbootEnabled=0). Reboot recommended."
} else {
    Write-Host "Fast Startup already off or not set."
}

$adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -or $_.MediaType -match '802.3' }
if (-not $adapters) {
    Write-Warning "No physical adapters found."
}

foreach ($nic in $adapters) {
    Write-Host ""
    Write-Host "Adapter: $($nic.Name)  MAC: $($nic.MacAddress)" -ForegroundColor Yellow
    try {
        Set-NetAdapterPowerManagement -Name $nic.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
        Write-Host "  WakeOnMagicPacket: Enabled"
    } catch {
        Write-Warning "  Could not set WakeOnMagicPacket via cmdlet: $_"
        Write-Host "  Try Device Manager → adapter → Power Management → Allow device to wake / Magic Packet."
    }
}

Write-Host ""
Write-Host "=== Paste into Pi /etc/pi-hole-nas-orchestrator.conf ===" -ForegroundColor Green
foreach ($nic in $adapters) {
    $mac = ($nic.MacAddress -replace '-', ':').ToLower()
    Write-Host "PC_MAC=`"$mac`"   # $($nic.Name)"
}
Write-Host ""
Write-Host "Also enable WOL in BIOS if wake from S5/shutdown does not work."
Write-Host "Test from Pi: wakeonlan <mac>   then ping PC_IP"
