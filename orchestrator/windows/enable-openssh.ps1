#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Enable OpenSSH Server so the Pi can run docker compose after WOL.

.DESCRIPTION
  Installs OpenSSH Server (Windows capability), starts sshd, opens firewall.
  The Pi orchestrator SSHs in and runs: docker compose up -d in trade_bot.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== OpenSSH Server setup ===" -ForegroundColor Cyan

$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
    Write-Host "Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
} else {
    Write-Host "OpenSSH Server already installed."
}

Start-Service sshd -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Automatic

# Firewall rule (usually added by installer; ensure present)
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Host "Added firewall rule for TCP 22."
}

$authDir = Join-Path $env:ProgramData 'ssh'
if (-not (Test-Path $authDir)) { New-Item -ItemType Directory -Path $authDir -Force | Out-Null }

Write-Host ""
Write-Host "sshd status:" -ForegroundColor Green
Get-Service sshd | Format-Table Status, StartType, Name

Write-Host ""
Write-Host "Next: run install-pi-ssh-key.ps1 with the public key printed by Pi orchestrator/install.sh"
Write-Host "Test from Pi: ssh -i /root/.ssh/pc_wake $env:USERNAME@<pc-ip> hostname"
