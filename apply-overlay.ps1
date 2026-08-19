#Requires -Version 5.1
<#
.SYNOPSIS
  After flashing, copy Pi-hole + NAS first-boot files onto the SD card boot partition.

.DESCRIPTION
  Auto-detects DietPi (dietpi.txt) or Raspberry Pi OS (cmdline.txt).
  DietPi: patches dietpi.txt and copies Automation_Custom_Script.sh.
  Raspberry Pi OS: prompts for username/password, writes cloud-init / first-boot files.

.EXAMPLE
  .\apply-overlay.ps1

.EXAMPLE
  .\apply-overlay.ps1 -User siddu -Password 'secret' -Hostname rpi
#>
[CmdletBinding()]
param(
    [string]$BootDrive,
    [string]$User,
    [string]$Password,
    [string]$Hostname = 'rpi'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Read-UnixText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Write-UnixText {
    param([string]$Path, [string]$Text)
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n")) { $normalized += "`n" }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8)
}

function ConvertTo-BashSingleQuoted {
    param([string]$Value)
    return ("'{0}'" -f ($Value -replace "'", "'\''"))
}

function ConvertTo-YamlSingleQuoted {
    param([string]$Value)
    return ("'{0}'" -f ($Value -replace "'", "''"))
}

function Get-BootVolume {
    param([string]$Hint)
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DeviceID -match '^[A-Z]:$' })
    if ($Hint) {
        $letter = $Hint.TrimEnd('\').TrimEnd(':')
        $root = "${letter}:\"
        $kind = $null
        if (Test-Path -LiteralPath (Join-Path $root 'dietpi.txt')) { $kind = 'dietpi' }
        elseif (Test-Path -LiteralPath (Join-Path $root 'cmdline.txt')) { $kind = 'raspios' }
        if ($kind) {
            return [pscustomobject]@{ Letter = $letter; Kind = $kind }
        }
        throw "Drive ${letter}: has neither dietpi.txt nor cmdline.txt. Wait until Windows remounts the boot partition."
    }
    $hits = @()
    foreach ($d in $disks) {
        $root = "$($d.DeviceID)\"
        $kind = $null
        if (Test-Path -LiteralPath (Join-Path $root 'dietpi.txt')) { $kind = 'dietpi' }
        elseif (Test-Path -LiteralPath (Join-Path $root 'cmdline.txt')) { $kind = 'raspios' }
        if ($kind) {
            $hits += [pscustomobject]@{ Letter = $d.DeviceID.TrimEnd(':'); Kind = $kind }
        }
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -eq 0) {
        throw 'No SD boot partition found (need dietpi.txt or cmdline.txt). Flash the OS, wait for Windows to remount the card, then rerun.'
    }
    throw ("Multiple boot partitions: {0}. Pass -BootDrive E" -f (($hits | ForEach-Object { "$($_.Letter):($($_.Kind))" }) -join ', '))
}

function Get-OverrideMap {
    param([string]$Path)
    $map = [ordered]@{}
    foreach ($raw in (Read-UnixText $Path) -split "`n") {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $map[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1)
    }
    return $map
}

function Set-DietPiKey {
    param([string]$Content, [string]$Key, [string]$Value)
    $escaped = [regex]::Escape($Key)
    $pattern = "(?m)^(#\s*)?${escaped}=.*$"
    $replacement = "${Key}=${Value}"
    $regex = New-Object System.Text.RegularExpressions.Regex $pattern
    if ($regex.IsMatch($Content)) {
        return $regex.Replace($Content, $replacement, 1)
    }
    if (-not $Content.EndsWith("`n")) { $Content += "`n" }
    return $Content + $replacement + "`n"
}

function Add-CloudRuncmd {
    param([string]$Content, [string]$Command)
    $item = "  - $Command"
    if ($Content -notmatch '(?m)^runcmd:\s*$') {
        if (-not $Content.EndsWith("`n")) { $Content += "`n" }
        return $Content + "runcmd:`n$item`n"
    }
    if ($Content -match [regex]::Escape($Command)) { return $Content }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split "`n", -1))
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^runcmd:\s*$') { $start = $i; break }
    }
    $insertAt = $start + 1
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*$' -or $line -match '^\s+-') { $insertAt = $i + 1; continue }
        if ($line -match '^#' -and $line -notmatch '^#cloud-config') { $insertAt = $i + 1; continue }
        break
    }
    $lines.Insert($insertAt, $item)
    return ($lines -join "`n")
}

function Invoke-DietPiOverlay {
    param([string]$Drive)
    $overridesPath = Join-Path $RepoRoot 'overlay\dietpi.overrides.txt'
    $scriptPath = Join-Path $RepoRoot 'overlay\Automation_Custom_Script.sh'
    if (-not (Test-Path -LiteralPath $overridesPath)) { throw "Missing $overridesPath" }
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptPath" }

    $dietpiTxt = "${Drive}:\dietpi.txt"
    Write-Host "Detected DietPi on ${Drive}:"
    Write-Host "Patching $dietpiTxt"
    $content = Read-UnixText $dietpiTxt
    $overrides = Get-OverrideMap $overridesPath
    foreach ($key in $overrides.Keys) {
        $content = Set-DietPiKey -Content $content -Key $key -Value $overrides[$key]
        Write-Host ("  {0}={1}" -f $key, $overrides[$key])
    }
    Write-UnixText -Path $dietpiTxt -Text $content
    Write-UnixText -Path "${Drive}:\Automation_Custom_Script.sh" -Text (Read-UnixText $scriptPath)
    Write-Host "Copied Automation_Custom_Script.sh"
    Write-Host ""
    Write-Host "Change AUTO_SETUP_GLOBAL_PASSWORD in dietpi.txt before first boot."
    Write-Host "Eject the card, Ethernet in, power on. After boot:"
    Write-Host '  .\set-pc-dns.ps1 -PiIP <pi-ip>'
}

function Read-RaspiOsIdentity {
    $name = $User
    if (-not $name) {
        $default = $env:USERNAME
        $entered = Read-Host "Username for SSH and NAS [$default]"
        $name = if ($entered) { $entered } else { $default }
    }
    $pw = $Password
    if (-not $pw) {
        $secure1 = Read-Host "Password (SSH, Samba, Pi-hole admin)" -AsSecureString
        $secure2 = Read-Host "Confirm password" -AsSecureString
        $bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
        $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
        try {
            $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
        }
        if ($p1 -ne $p2) { throw 'Passwords did not match.' }
        if ([string]::IsNullOrWhiteSpace($p1)) { throw 'Password cannot be empty.' }
        $pw = $p1
    }
    $hostName = $Hostname
    if (-not $PSBoundParameters.ContainsKey('Hostname')) {
        $enteredHost = Read-Host "Hostname [$Hostname]"
        if ($enteredHost) { $hostName = $enteredHost }
    }
    return [pscustomobject]@{ User = $name; Password = $pw; Hostname = $hostName }
}

function New-RaspiOsUserData {
    param($Identity)
    $u = ConvertTo-YamlSingleQuoted $Identity.User
    $p = ConvertTo-YamlSingleQuoted $Identity.Password
    $h = ConvertTo-YamlSingleQuoted $Identity.Hostname
    @"
#cloud-config
hostname: $h
manage_etc_hosts: true
timezone: Asia/Kolkata
keyboard:
  layout: us
enable_ssh: true
ssh_pwauth: true
users:
  - name: $u
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $p
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - bash /boot/firmware/pi-hole-nas-firstboot.sh
"@
}

function Invoke-RaspiOsOverlay {
    param([string]$Drive)
    $scriptPath = Join-Path $RepoRoot 'overlay-raspios\pi-hole-nas-firstboot.sh'
    $tomlPath = Join-Path $RepoRoot 'overlay-raspios\pihole.toml'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptPath" }
    if (-not (Test-Path -LiteralPath $tomlPath)) { throw "Missing $tomlPath" }

    Write-Host "Detected Raspberry Pi OS on ${Drive}:"
    $id = Read-RaspiOsIdentity
    Write-UnixText -Path "${Drive}:\pi-hole-nas-firstboot.sh" -Text (Read-UnixText $scriptPath)
    Write-UnixText -Path "${Drive}:\pihole.toml" -Text (Read-UnixText $tomlPath)

    $envText = @(
        "NAS_USER=$(ConvertTo-BashSingleQuoted $id.User)"
        "NAS_PASSWORD=$(ConvertTo-BashSingleQuoted $id.Password)"
        "HOSTNAME=$(ConvertTo-BashSingleQuoted $id.Hostname)"
    ) -join "`n"
    Write-UnixText -Path "${Drive}:\pi-hole-nas.env" -Text $envText

    $userDataPath = "${Drive}:\user-data"
    $hasCloudInit = Test-Path -LiteralPath $userDataPath
    $run = 'bash /boot/firmware/pi-hole-nas-firstboot.sh'

    if ($hasCloudInit) {
        $ud = Read-UnixText $userDataPath
        if ($ud -notmatch '(?m)^#cloud-config\s*$') {
            $ud = "#cloud-config`n" + $ud
        }
        if ($ud -notmatch '(?m)^hostname:') {
            $ud = $ud -replace '(?m)^#cloud-config\s*$', ("#cloud-config`nhostname: {0}`nmanage_etc_hosts: true" -f (ConvertTo-YamlSingleQuoted $id.Hostname))
        }
        if ($ud -notmatch '(?m)^timezone:') {
            $ud += "`ntimezone: Asia/Kolkata`n"
        }
        if ($ud -notmatch '(?m)^enable_ssh:') {
            $ud += "`nenable_ssh: true`nssh_pwauth: true`n"
        }
        if ($ud -notmatch '(?m)^\s*name:') {
            Write-Host "No user in user-data; adding $($id.User)"
            $ud += @"

users:
  - name: $(ConvertTo-YamlSingleQuoted $id.User)
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $(ConvertTo-YamlSingleQuoted $id.Password)
    sudo: ALL=(ALL) NOPASSWD:ALL
"@
        }
        else {
            Write-Host "Keeping existing Imager user. Samba/Pi-hole will use '$($id.User)' from the prompt (must match)."
        }
        $ud = Add-CloudRuncmd -Content $ud -Command $run
        Write-UnixText -Path $userDataPath -Text $ud
        Write-Host "Updated user-data"
    }
    else {
        Write-UnixText -Path $userDataPath -Text (New-RaspiOsUserData $id)
        Write-Host "Wrote user-data (cloud-init)"
        $cmdlinePath = "${Drive}:\cmdline.txt"
        if (Test-Path -LiteralPath $cmdlinePath) {
            $cmd = (Read-UnixText $cmdlinePath).Trim()
            if ($cmd -notmatch 'systemd.run=') {
                $firstrun = @'
#!/bin/bash
set +e
systemctl enable ssh
systemctl start ssh
SCRIPT=/boot/firmware/pi-hole-nas-firstboot.sh
[ -f "$SCRIPT" ] || SCRIPT=/boot/pi-hole-nas-firstboot.sh
[ -f "$SCRIPT" ] && bash "$SCRIPT"
rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [ -f "$f" ] && sed -i 's| systemd.run=[^ ]*||g; s| systemd.run_success_action=[^ ]*||g; s| systemd.unit=[^ ]*||g' "$f"
done
exit 0
'@
                Write-UnixText -Path "${Drive}:\firstrun.sh" -Text $firstrun
                $cmd = ($cmd + ' systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target').Trim()
                Write-UnixText -Path $cmdlinePath -Text $cmd
                Write-Host "Also installed Bookworm-style firstrun.sh (no cloud-init user-data was present)"
            }
        }
    }

    $sshMarker = "${Drive}:\ssh"
    if (-not (Test-Path -LiteralPath $sshMarker)) {
        [System.IO.File]::WriteAllBytes($sshMarker, [byte[]]@())
    }

    Write-Host ""
    Write-Host "Overlay applied for user '$($id.User)' hostname '$($id.Hostname)'."
    Write-Host "Eject the card, Ethernet in, power on (15-40 min). Then:"
    Write-Host "  ssh $($id.User)@<pi-ip>"
    Write-Host '  .\set-pc-dns.ps1 -PiIP <pi-ip>'
    Write-Host "NAS: \\$($id.Hostname)\share  (same username/password)"
}

$vol = Get-BootVolume -Hint $BootDrive
$letter = $vol.Letter
$kind = $vol.Kind

if ($kind -eq 'dietpi') {
    Invoke-DietPiOverlay -Drive $letter
}
else {
    Invoke-RaspiOsOverlay -Drive $letter
}
