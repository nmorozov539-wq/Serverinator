# ServerInator - client setup on Windows.
#
# UNTESTED: this has not run on a real Windows machine yet. It does run under
# PowerShell on Linux in the test suite (tests/test_client_setup_windows.sh).
#
# The VPS makes one client setup script per client, for bash. This reads the
# settings block at the top of that script (SI_ALIAS='...' and so on) and
# applies the same setup with Windows' built-in OpenSSH client: the key, the
# ssh config entries and the pinned host keys.
#
# Run in PowerShell, with the client's setup script next to this file:
#   powershell -ExecutionPolicy Bypass -File .\client-setup-windows.ps1 .\client-setup-laptop-PHONE.sh
# Needs the OpenSSH client (Settings > Apps > Optional features > OpenSSH Client).
#
# Kept to plain ASCII: PowerShell 5 reads a script without a BOM as ANSI.
param([Parameter(Mandatory = $true)][string]$SetupScript)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SetupScript)) { Write-Error "No such file: $SetupScript" }

# The settings block: one SI_NAME='value' per line. No value holds a quote.
$S = @{}
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $SetupScript).Path)) {
    if ($line -match "^SI_([A-Z0-9_]+)='([^']*)'$") { $S[$Matches[1]] = $Matches[2] }
}
foreach ($k in @('DEVICE', 'ALIAS', 'LABEL', 'PHONE_IP', 'PHONE_PORT', 'PHONE_USER', 'VPS_HOST', 'VPS_USER', 'KEY_MODE', 'KEY_NAME')) {
    if (-not $S.ContainsKey($k)) { Write-Error "$SetupScript is not a ServerInator client setup script (no SI_$k)" }
}
$Alias = $S['ALIAS']

Write-Host "Setting up SSH access to $($S['DEVICE']) (alias: $Alias)..."
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Warning 'ssh was not found. Install the OpenSSH Client: Settings > Apps > Optional features.'
}
$SshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path $SshDir | Out-Null

# Appends LINES to FILE (LF endings, no BOM), starting on a fresh line.
function Add-Lines([string]$File, [string[]]$Lines) {
    $prefix = ''
    if ((Test-Path $File) -and (Get-Item $File).Length -gt 0) {
        $last = [IO.File]::ReadAllBytes($File)[-1]
        if ($last -ne 10) { $prefix = "`n" }
    }
    [IO.File]::AppendAllText($File, $prefix + (($Lines -join "`n") + "`n"))
}
function Test-Line([string]$File, [string]$Line) {
    if (-not (Test-Path $File)) { return $false }
    foreach ($l in [IO.File]::ReadAllLines($File)) { if ($l -ceq $Line) { return $true } }
    return $false
}
# OpenSSH for Windows refuses a key that anyone but its owner can read.
function Protect-Key([string]$Path) {
    if ($IsLinux -or $IsMacOS) { chmod 600 $Path; return }
    $Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    icacls $Path /inheritance:r /grant:r "*${Sid}:F" | Out-Null
}
function Get-PubOf([string]$Path) {
    $p = (& ssh-keygen -y -f $Path 2>$null)
    if (-not $p) { return '' }
    $f = ([string]$p).Split(' ')
    return ($f[0] + ' ' + $f[1])
}

$Key = ''
switch ($S['KEY_MODE']) {
    'carried' {
        # The private key. The setup script is its only copy once fetched: keep it safe.
        $Key = Join-Path $SshDir $S['KEY_NAME']
        if (-not (Test-Path $Key)) {
            [IO.File]::WriteAllBytes($Key, [Convert]::FromBase64String($S['KEY_B64']))
            Protect-Key $Key
            [IO.File]::WriteAllText("$Key.pub", $S['KEY_PUB'] + "`n")
            Write-Host "Key installed: $Key"
        } else {
            Write-Host "Key already present: $Key - skipping"
        }
    }
    'own' {
        if ($S['KEY_EXPECTED']) {
            # This device's own key. The private key never left it.
            $Found = ''
            $Candidates = @(Join-Path $SshDir $S['KEY_NAME']) + @(Get-ChildItem -File $SshDir | Where-Object { $_.Name -notlike '*.pub' } | ForEach-Object { $_.FullName })
            foreach ($k in $Candidates) {
                if ((Test-Path $k) -and ((Get-PubOf $k) -ceq $S['KEY_EXPECTED'])) { $Found = $k; break }
            }
            if (-not $Found) {
                Write-Error "This setup is for the key $($S['KEY_FP']), and that key isn't in $SshDir. Run it on the device the key belongs to, or ask for a new setup."
            }
            $Key = $Found
            Write-Host "Using your key $Key"
        } else {
            # A key of this device's own; its private part never leaves the device.
            $Key = Join-Path $SshDir $S['KEY_NAME']
            if (-not (Test-Path $Key)) {
                # An empty passphrase: Windows PowerShell 5 drops a bare '' argument.
                $Empty = '""'
                if ((Get-Variable PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue) -and $PSNativeCommandArgumentPassing -ne 'Legacy') { $Empty = '' }
                & ssh-keygen -q -t ed25519 -N $Empty -C "serverinator:$($S['LABEL'])@$env:COMPUTERNAME" -f $Key
                if (-not (Test-Path $Key)) { Write-Error 'ssh-keygen did not make a key (is the OpenSSH Client installed?)' }
                Write-Host "Made a key for this device: $Key"
            }
        }
    }
}

# With a key of ours the jump to the VPS uses it too, in a block of its own;
# the VPS has a restricted entry for it. Without one, the jump uses the
# owner's own keys.
$Config = Join-Path $SshDir 'config'
$Jump = "$($S['VPS_USER'])@$($S['VPS_HOST'])"
if ($Key) { $Jump = "$Alias-jump" }

if (Test-Line $Config "Host $Alias") {
    Write-Host "Alias '$Alias' is already in $Config - skipping"
} else {
    $block = @('', "Host $Alias", "    HostName $($S['PHONE_IP'])", "    Port $($S['PHONE_PORT'])", "    User $($S['PHONE_USER'])")
    if ($Key) { $block += @("    IdentityFile $Key", '    IdentitiesOnly yes') }
    $block += "    ProxyJump $Jump"
    if ($S['PHONE_HOSTKEY']) { $block += "    HostKeyAlias $Alias" }
    $block += @('    ServerAliveInterval 60', '    ServerAliveCountMax 9999')
    Add-Lines $Config $block
    Write-Host "Alias '$Alias' added to $Config"
}

if ($Key) {
    if (Test-Line $Config "Host $Alias-jump") {
        Write-Host "Host $Alias-jump is already in $Config - skipping"
    } else {
        Add-Lines $Config @('', "Host $Alias-jump", "    HostName $($S['VPS_HOST'])", "    User $($S['VPS_USER'])", "    IdentityFile $Key", '    IdentitiesOnly yes', "    HostKeyAlias $($S['VPS_HOST'])")
        Write-Host "Host $Alias-jump (the hop through the VPS) added to $Config"
    }
}

# Host keys to pin: the phone's under the alias, the VPS's under its address.
$Known = Join-Path $SshDir 'known_hosts'
$Pins = @()
if ($S['PHONE_HOSTKEY']) { $Pins += "$Alias $($S['PHONE_HOSTKEY'])" }
if ($S['VPS_HOSTKEY']) { $Pins += "$($S['VPS_HOST']) $($S['VPS_HOSTKEY'])" }
foreach ($entry in $Pins) {
    if (-not (Test-Line $Known $entry)) {
        Add-Lines $Known @($entry)
        Write-Host "Pinned host key for $($entry.Split(' ')[0])"
    }
}

Write-Host ''
Write-Host "Done. Connect with:  ssh $Alias"
if ($S['KEY_MODE'] -eq 'own' -and -not $S['KEY_EXPECTED']) {
    Write-Host ''
    Write-Host 'Last step: approve this device. As root on the phone, or on the VPS:'
    Write-Host ("  si add-client $($S['LABEL']) --device $($S['DEVICE']) --pubkey '" + (Get-PubOf $Key) + "'")
    Write-Host "Until then, ssh $Alias is refused."
}
