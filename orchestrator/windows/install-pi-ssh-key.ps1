#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Authorize the Pi orchestrator SSH public key on this Windows PC.

.PARAMETER PublicKey
  Ed25519 public key line (from Pi: sudo cat /root/.ssh/pc_wake.pub)

.PARAMETER User
  Windows account the Pi will SSH as (default: current user)
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $PublicKey,

    [string] $User = $env:USERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$userDir = Join-Path $env:USERPROFILE '.ssh'
$userKeys = Join-Path $userDir 'authorized_keys'

$keyLine = $PublicKey.Trim()
if ($keyLine -notmatch '^ssh-(ed25519|rsa|ecdsa) ') {
    throw "PublicKey does not look like an OpenSSH public key."
}

function Add-KeyFile {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    $existing = Get-Content $Path -ErrorAction SilentlyContinue
    if ($existing -contains $keyLine) {
        Write-Host "Key already present in $Path"
        return
    }
    Add-Content -Path $Path -Value $keyLine -Encoding utf8
    Write-Host "Added key to $Path" -ForegroundColor Green
}

# Prefer user authorized_keys (works with DefaultShell powershell + docker)
Add-KeyFile -Path $userKeys

# Fix permissions on user .ssh (OpenSSH is picky on Windows)
icacls $userDir /inheritance:r /grant "${User}:F" /grant 'SYSTEM:F' 2>$null | Out-Null
icacls $userKeys /inheritance:r /grant "${User}:F" /grant 'SYSTEM:F' 2>$null | Out-Null

Write-Host ""
Write-Host "Authorized. From Pi: ssh -i /root/.ssh/pc_wake ${User}@<pc-ip> hostname"
