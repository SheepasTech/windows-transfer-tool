<#
.SYNOPSIS
  Windows Transfer Tool - staged PC-to-PC migration over the local network.

.DESCRIPTION
  OLD PC  (-Mode Source)       S1 Preflight > S2 Export > S3 Share > S4 Pair > S5 Wait > S6 Cleanup
  NEW PC  (-Mode Destination)  D1 Preflight > D2 Bind > D3 Select > D4 Files > D5 Apps > D6 Settings > D7 Finish

  Four ways to get the data across (-Transport, chosen on the old PC):
    Drive            No network at all: the old PC copies the chosen parts to a flash drive or
                     external SSD with robocopy, you carry it over, the new PC copies them off
                     again. Only a drive that contains a folder named WTT-Transfer is ever used.
                     Prepare one with -PrepareDrive D: (or create the folder yourself).
    Ftps  (default)  FTP over TLS with a self-signed certificate. The old PC runs a small read-only
                     server (lib\WttFtp.cs) with a random one-time password; no Windows account of
                     any kind is involved. The new PC checks the certificate fingerprint.
    Ftp              The same without encryption (only for a LAN you fully trust).
    Smb              The old PC's admin share. Stage S3 creates a disposable local administrator
                     account for the sign-in (shown in S4, deleted in S6); -UseOwnAccount uses
                     your own account instead.
  The new PC detects which one it should use (-Transport Auto, the default there): a plugged-in
  transfer drive first, then the old PC's FTP(S) service, then SMB.

  Normally started by bootstrap.ps1 (see README.md). Direct use from an elevated PowerShell:
    .\Migrate-Windows.ps1 -Mode Source                    old PC, FTPS
    .\Migrate-Windows.ps1 -Mode Source -Transport Smb     old PC, SMB with a temporary account
    .\Migrate-Windows.ps1 -PrepareDrive D:                one time: make external drive D: a transfer drive
    .\Migrate-Windows.ps1 -Mode Source -Transport Drive   old PC, copy to the transfer drive
    .\Migrate-Windows.ps1 -Mode Destination -DryRun       new PC, preview only
    .\Migrate-Windows.ps1 -Mode Destination               new PC
    .\Migrate-Windows.ps1 -Cleanup                        old PC, if stage S6 never ran

  Process graphs: docs/process.md   Caveats: docs/caveats.md   Doing it by hand: docs/manual.md
#>
[CmdletBinding()]
Param(
    [ValidateSet('Source','Destination','Target')][string]$Mode,   # Target = old name for Destination
    [string]$OldPCIP,                        # NEW PC: skip the IP prompt
    [string]$PairCode,                       # NEW PC: skip the pairing-code prompt
    [string[]]$Select,                       # NEW PC: skip the menu: 'All' or item keys (f_docs,s_taskbar,...)
    [switch]$Yes,                            # NEW PC: do not ask "Proceed?" / "clean up?"
    [switch]$DryRun,                         # NEW PC: show what would happen, change nothing
    [switch]$Cleanup,                        # OLD PC: revert sharing and delete the export
    [switch]$InitCredentials,                # NEW PC: generate credentials.json
    [switch]$NoSave,                         # NEW PC: never offer to save credentials
    [switch]$UseOwnAccount,                  # OLD PC, Smb only: sign in with your own Windows account instead of a disposable temp one
    [ValidateSet('Auto','Ftps','Ftp','Smb','Drive')][string]$Transport = 'Auto',   # OLD PC: Auto = Ftps. NEW PC: Auto = a transfer drive if one is plugged in, else detect what the old PC offers
    [string]$Drive,                          # Drive transport, both PCs: use this drive letter (it must contain the WTT-Transfer folder)
    [string]$PrepareDrive,                   # make this external drive letter a transfer drive (creates the empty WTT-Transfer folder) and exit
    [ValidateRange(1,65535)][int]$FtpPort = 2121,                          # both PCs: control port of the FTP(S) service
    [string]$Fingerprint,                    # NEW PC, Ftps: expected certificate SHA-256 (first 32+ hex digits) instead of confirming by eye
    [string]$CredentialFile = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'credentials.json' } else { Join-Path (Get-Location) 'credentials.json' }),
    [int]$Threads = 8,                       # robocopy threads
    [string]$RunId                           # set by the bootstrap so its windows and the tool log into one folder
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '0.2.0'
$ExportDir   = 'C:\MigrationExport'
$CV          = 'HKCU\Software\Microsoft\Windows\CurrentVersion'
$FwGroup     = '@FirewallAPI.dll,-28502'     # firewall rule group "File and Printer Sharing"
$PolicyKey   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$FtpUser     = 'wtt'
$FtpPasvLow  = 52100                         # passive data ports of the FTP(S) service: 52100-52150
$FtpPasvHigh = 52150
$FtpRuleName = 'WindowsTransferTool-temporary'   # inbound firewall rule, removed in S6
$DriveDirName = 'WTT-Transfer'               # the folder that makes an external drive a transfer drive; nothing outside it is ever touched
$StageNames  = @('Files','Apps','Settings')  # order of the destination work stages D4, D5, D6
if ($Mode -eq 'Target') { $Mode = 'Destination' }

# =============================================================================
# CATALOG - everything the menu offers. Copies are relative to the user profile.
#   Stage    : Files (D4) | Apps (D5) | Settings (D6)
#   Known    : a Windows known folder (follows OneDrive redirection)
#   Copies   : folders/files robocopied from the old profile (same relative path on the new one)
#   Reg      : registry keys exported on the old PC and imported on the new one
#   Explorer : needs Explorer stopped while importing so it does not overwrite the values
#   Default  : $false = unticked by default
# =============================================================================
$Catalog = @(
 @{Key='f_desk';  Stage='Files'; Group='Personal files'; Label='Desktop';   Known='Desktop';   Desc='Files, folders and shortcuts on your desktop'}
 @{Key='f_docs';  Stage='Files'; Group='Personal files'; Label='Documents'; Known='Documents'; Desc='Documents folder (includes PowerShell profile, Outlook files, etc.)'}
 @{Key='f_pics';  Stage='Files'; Group='Personal files'; Label='Pictures';  Known='Pictures';  Desc='Pictures folder'}
 @{Key='f_vids';  Stage='Files'; Group='Personal files'; Label='Videos';    Known='Videos';    Desc='Videos folder'}
 @{Key='f_music'; Stage='Files'; Group='Personal files'; Label='Music';     Known='Music';     Desc='Music folder'}
 @{Key='f_dl';    Stage='Files'; Group='Personal files'; Label='Downloads'; Known='Downloads'; Desc='Downloads folder (often the biggest one)'}
 @{Key='f_other'; Stage='Files'; Group='Personal files'; Label='Favorites, Links, Contacts, Saved Games, Searches'
   Desc='Smaller profile folders'
   Copies=@(@{Src='Favorites'},@{Src='Links'},@{Src='Contacts'},@{Src='Saved Games'},@{Src='Searches'})}

 @{Key='a_winget'; Stage='Apps'; Group='Apps and app data'; Label='Reinstall apps with winget'; Default=$false
   Desc='Installs every app on the old PC that winget knows (can take a long time). A CSV of all installed programs is saved for the rest.'}
 @{Key='d_browsers'; Stage='Apps'; Group='Apps and app data'; Label='Browser bookmarks (Chrome, Edge, Firefox)'
   Desc='Closes browsers. Chrome/Edge: bookmarks of the Default profile only. Firefox: whole profile (includes saved logins).'
   Kill=@('chrome','msedge','firefox')
   Copies=@(@{Src='AppData\Local\Google\Chrome\User Data\Default';Files=@('Bookmarks')},
            @{Src='AppData\Local\Microsoft\Edge\User Data\Default';Files=@('Bookmarks')},
            @{Src='AppData\Roaming\Mozilla\Firefox'})}
 @{Key='d_terminal'; Stage='Apps'; Group='Apps and app data'; Label='Windows Terminal settings'
   Desc='settings.json (profiles, colors, key bindings)'
   Copies=@(@{Src='AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState';Files=@('settings.json')},
            @{Src='AppData\Local\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState';Files=@('settings.json')})}
 @{Key='d_vscode'; Stage='Apps'; Group='Apps and app data'; Label='VS Code settings, snippets and extensions'
   Desc='User settings, keybindings, snippets; extensions are reinstalled if the code command exists'
   Copies=@(@{Src='AppData\Roaming\Code\User';XD=@('globalStorage','workspaceStorage','History')})}
 @{Key='d_dev'; Stage='Apps'; Group='Apps and app data'; Label='Developer config (.gitconfig, .ssh, .aws, .kube, ...)'; Default=$false
   Desc='Contains private keys and credentials - only transfer over a network you trust'
   Copies=@(@{Src='.';Files=@('.gitconfig','.npmrc','.condarc','.gitignore_global')},
            @{Src='.ssh'},@{Src='.aws'},@{Src='.azure'},@{Src='.kube'},@{Src='.config'})}
 @{Key='d_office'; Stage='Apps'; Group='Apps and app data'; Label='Office: signatures, templates, custom dictionary'
   Desc='Outlook signatures, Word/Excel templates, spelling dictionary'
   Copies=@(@{Src='AppData\Roaming\Microsoft\Signatures'},@{Src='AppData\Roaming\Microsoft\Templates'},@{Src='AppData\Roaming\Microsoft\UProof'})}
 @{Key='d_sticky'; Stage='Apps'; Group='Apps and app data'; Label='Sticky Notes'
   Desc='Copies the Sticky Notes database'
   Kill=@('Microsoft.Notes')
   Copies=@(@{Src='AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'})}

 @{Key='s_appear'; Stage='Settings'; Group='Windows settings'; Label='Appearance: theme, dark mode, colors, cursors, wallpaper'
   Desc='Display scaling is NOT copied, so the new screen keeps its own DPI'
   Explorer=$true; Drop='^"(LogPixels|Win8DpiScaling|DpiScalingVer|AppliedDPI)"='
   Reg=@('HKCU\Control Panel\Colors','HKCU\Control Panel\Cursors','HKCU\Control Panel\Desktop',
         "$CV\Themes","$CV\Explorer\Accent",'HKCU\Software\Microsoft\Windows\DWM')}
 @{Key='s_taskbar'; Stage='Settings'; Group='Windows settings'; Label='Taskbar, Start menu and File Explorer options'
   Desc='Pinned apps, taskbar position/behavior, Start pins (Win11), Start menu shortcuts, Quick Access, hidden files/extensions. Install apps first.'
   Explorer=$true
   Copies=@(@{Src='AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned'},
            @{Src='AppData\Roaming\Microsoft\Windows\Start Menu'},
            @{Src='AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState';Files=@('start2.bin')},
            @{Src='AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations';Files=@('f01b4d95cf55d32a.automaticDestinations-ms')})
   Reg=@("$CV\Explorer\StuckRects3","$CV\Explorer\Taskband","$CV\Explorer\Advanced","$CV\Explorer\CabinetState","$CV\Search")}
 @{Key='s_icons'; Stage='Settings'; Group='Windows settings'; Label='Desktop icon positions and folder view settings (best effort)'
   Desc='Restores icon layout and per-folder view modes; layout may shift if screen resolution differs'
   Explorer=$true
   Reg=@('HKCU\Software\Microsoft\Windows\Shell\Bags','HKCU\Software\Microsoft\Windows\Shell\BagMRU',
         'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags',
         'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU')}
 @{Key='s_input'; Stage='Settings'; Group='Windows settings'; Label='Mouse, touchpad, keyboard, sounds, accessibility'
   Desc='Pointer speed, touchpad gestures, key repeat, sound scheme, accessibility options'
   Reg=@('HKCU\Control Panel\Mouse','HKCU\Control Panel\Keyboard','HKCU\Control Panel\Sound','HKCU\Control Panel\Accessibility',
         "$CV\PrecisionTouchPad")}
 @{Key='s_region'; Stage='Settings'; Group='Windows settings'; Label='Language, keyboard layouts and regional formats'
   Desc='Date/time/number formats and input methods'
   Reg=@('HKCU\Control Panel\International','HKCU\Keyboard Layout','HKCU\Software\Microsoft\Input')}
 @{Key='s_env'; Stage='Settings'; Group='Windows settings'; Label='User environment variables'
   Desc='Imported into the new profile. A variable with the same name (including Path) is replaced, not merged.'
   Reg=@('HKCU\Environment')}
 @{Key='s_net'; Stage='Settings'; Group='Windows settings'; Label='Mapped network drives and network printers'
   Desc='Drive letters and printer connections; credentials are not copied'
   Reg=@('HKCU\Network','HKCU\Printers\Connections')}
 @{Key='s_fonts'; Stage='Settings'; Group='Windows settings'; Label='Fonts installed for your user'
   Desc='Per-user fonts only (not system-wide fonts)'
   Copies=@(@{Src='AppData\Local\Microsoft\Windows\Fonts'})
   Reg=@('HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts')}
 @{Key='s_wifi'; Stage='Settings'; Group='Windows settings'; Label='Saved Wi-Fi networks and passwords'
   Desc='Needs administrator rights'}
 @{Key='s_power'; Stage='Settings'; Group='Windows settings'; Label='Active power plan'
   Desc='Hardware-specific; leave off if the laptops differ a lot'; Default=$false}
)

# =============================================================================
# Helpers
# =============================================================================
function Write-Step($m)  { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn($m)  { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Stage($Code, $Title) { Write-Host ''; Write-Host ('==== {0}  {1} ====' -f $Code, $Title) -ForegroundColor Magenta }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run a native command without stderr tripping $ErrorActionPreference='Stop'. Returns the exit code.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$Show)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($Show) { & $Exe @Arguments 2>&1 | Out-Host } else { & $Exe @Arguments 2>&1 | Out-Null }
    } finally { $ErrorActionPreference = $old }
    return $LASTEXITCODE
}

function Get-IPv4Addresses {
    @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254)' } |
        Select-Object IPAddress, InterfaceAlias)
}
function Get-IPv4List { Get-IPv4Addresses | ForEach-Object { '{0}  ({1})' -f $_.IPAddress, $_.InterfaceAlias } }

# SHA-256 of "salt:code" - used so the pairing code itself is never written to disk.
function Get-PairHash([string]$Salt, [string]$Code) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $Salt, $Code)))
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLower()
    } finally { $sha.Dispose() }
}

# Keep the PC from sleeping while the tool runs (best effort; released at the end).
function Set-KeepAwake([bool]$On) {
    try {
        if (-not ('WttPower' -as [type])) {
            Add-Type -Namespace '' -Name 'WttPower' -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' | Out-Null
        }
        if ($On) { [void][WttPower]::SetThreadExecutionState(0x80000003) } else { [void][WttPower]::SetThreadExecutionState(0x80000000) }
    } catch {}
}

# The user who owns Explorer in this session = the person actually signed in.
# Differs from $env:USERNAME when a standard user elevated with another admin's password.
function Get-ConsoleUserName {
    try {
        $sid = (Get-Process -Id $PID).SessionId
        $p = Get-Process explorer -IncludeUserName -ErrorAction Stop | Where-Object { $_.SessionId -eq $sid } | Select-Object -First 1
        if ($p -and $p.UserName) { return ($p.UserName -split '\\')[-1] }
    } catch {}
    return $null
}
function Assert-SignedInUser {
    $c = Get-ConsoleUserName
    if ($c -and $c -ne $env:USERNAME) {
        throw "This window runs as '$env:USERNAME' but the signed-in user is '$c'. Sign in as '$c' and elevate with that account, otherwise the wrong profile is migrated."
    }
}

function Test-OneDrivePath([string]$Path) { return [bool]($Path -and $Path -match '\\OneDrive') }

# =============================================================================
# FTP / FTPS helpers - the transport itself (server, client, mirror) is lib\WttFtp.cs,
# compiled on first use. Both PCs need the lib folder next to this script.
# =============================================================================
function Import-WttFtp {
    if ('Wtt.FtpServer' -as [type]) { return }
    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $cs = Join-Path $dir 'lib\WttFtp.cs'
    if (-not (Test-Path -LiteralPath $cs)) { throw "lib\WttFtp.cs not found ($cs). Run the bootstrap one-liner again, or copy the whole folder - not just Migrate-Windows.ps1." }
    Add-Type -TypeDefinition (Get-Content -LiteralPath $cs -Raw) -Language CSharp
}

# 16 characters from an alphabet without look-alikes (no 0/O, no 1/I): 80 bits, shown as XXXX-XXXX-XXXX-XXXX.
function New-FtpPassword {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'      # 32 symbols, so a random byte maps to one without bias
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (-join ($bytes | ForEach-Object { $alphabet[$_ % 32] }))
}
# Secrets shown on screen are recorded here and replaced by a SHA-256 prefix in the saved debug log (Hide-LogSecrets).
$script:LogSecrets = @()
function Protect-LogSecret { param([string]$Shown, [string[]]$Also = @()); foreach ($s in @($Shown) + $Also) { if ($s) { $script:LogSecrets += $s } }; return $Shown }
function Format-FtpPassword([string]$Pw) { return ($Pw -replace '(.{4})(?=.)', '$1-') }
function ConvertFrom-TypedFtpPassword([string]$Typed) { return (($Typed -replace '[\s-]', '').ToUpperInvariant()) }
# First 32 hex digits (128 bits) in groups of four - short enough to compare by eye.
function Format-Fingerprint([string]$Hex) { return (($Hex.Substring(0, 32)) -replace '(.{4})(?=.)', '$1 ') }

# Inbound rule for the control port and the passive range; the old PC's own firewall otherwise drops the new PC.
function Open-FtpFirewall {
    Remove-NetFirewallRule -Name $FtpRuleName -ErrorAction SilentlyContinue
    [void](New-NetFirewallRule -Name $FtpRuleName -DisplayName 'Windows Transfer Tool (temporary, removed when the transfer ends)' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort @([string]$FtpPort, "$FtpPasvLow-$FtpPasvHigh") `
        -Profile Any -RemoteAddress LocalSubnet)
}
function Limit-FtpFirewallTo([string]$Ip) { Set-NetFirewallRule -Name $FtpRuleName -RemoteAddress $Ip -ErrorAction SilentlyContinue }
function Close-FtpFirewall { Remove-NetFirewallRule -Name $FtpRuleName -ErrorAction SilentlyContinue }

# =============================================================================
# External drive helpers (-Transport Drive). The rules that keep this safe:
#   * only external volumes are looked at: removable, or on a USB bus; never the system drive
#   * a drive is only ever used if it already has a folder named WTT-Transfer in its root
#     (you create it, or -PrepareDrive does after you name the drive)
#   * everything is written, read and deleted inside that folder - nowhere else on the drive
# =============================================================================
function Test-FtpTransport { return ($script:Transport -in 'Ftps', 'Ftp') }
function Test-Interactive { return (-not [Console]::IsInputRedirected) }                       # can we ask questions?
function Get-DriveFree($Vol) { return (New-Object System.IO.DriveInfo $Vol.Root).AvailableFreeSpace }   # fresh value, the drive may have changed

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# Every ready local volume except the system drive and network drives. External = removable media, or a disk on a USB bus
# (external SSDs and hard drives report as fixed disks, so the bus type is what identifies them).
function Get-LocalVolumes {
    $sys = $env:SystemDrive.TrimEnd(':').ToUpper()
    $usb = @{}
    try {
        foreach ($d in @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -eq 'USB' })) {
            foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
                if ($p.DriveLetter) { $usb[([string]$p.DriveLetter).ToUpper()] = $d.FriendlyName }
            }
        }
    } catch {}
    $list = @()
    foreach ($v in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        $letter = $v.DeviceID.TrimEnd(':').ToUpper()
        if ($letter -eq $sys) { continue }
        if ($v.DriveType -ne 2 -and $v.DriveType -ne 3) { continue }       # removable or fixed; not network, optical or RAM
        if (-not $v.Size) { continue }                                     # empty card-reader slot
        $list += [pscustomobject]@{
            Letter = $letter; Root = ($letter + ':\'); Label = $v.VolumeName; FileSystem = $v.FileSystem
            Size = [int64]$v.Size; Free = [int64]$v.FreeSpace
            External = ($v.DriveType -eq 2 -or $usb.ContainsKey($letter)); Device = $usb[$letter]
        }
    }
    return $list
}
function Get-ExternalDrives { return @(Get-LocalVolumes | Where-Object { $_.External }) }

function Get-TransferDir([string]$Root) { return (Join-Path $Root $DriveDirName) }

# True only if the marker folder exists, is a real folder, and is not a junction or link leading somewhere else.
function Test-TransferMarker([string]$Root) {
    try {
        $i = Get-Item -LiteralPath (Get-TransferDir $Root) -Force -ErrorAction Stop
        return [bool]($i.PSIsContainer -and -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
    } catch { return $false }
}

# transfer.json is written by the old PC: who, when, which file items were copied, and whether it finished.
function Get-TransferInfo([string]$Root) {
    $f = Join-Path (Get-TransferDir $Root) 'transfer.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } catch { return $null }
}
function Save-TransferInfo($Info) { $Info | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:DriveWtt 'transfer.json') -Encoding UTF8 }

# Throws unless $Path is strictly inside the WTT-Transfer folder of the drive in use. Called before every delete.
function Assert-InsideTransferDir([string]$Path) {
    if (-not $script:DriveWtt) { throw 'Internal error: no transfer drive has been selected.' }
    $base = [IO.Path]::GetFullPath($script:DriveWtt).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    if ($full.Length -le $base.Length -or -not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to touch '$Path': it is not inside $($script:DriveWtt)."
    }
}

# Empties the WTT-Transfer folder (the folder itself stays, so the drive stays prepared). Refuses if anything inside is a
# junction or link: older Windows PowerShell can follow those when deleting recursively.
function Clear-TransferDir {
    $links = @(Get-ChildItem -LiteralPath $script:DriveWtt -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count -gt 0) { throw "Not deleting: $($links[0].FullName) is a link. Remove it by hand and run again." }
    foreach ($c in @(Get-ChildItem -LiteralPath $script:DriveWtt -Force)) {
        Assert-InsideTransferDir $c.FullName
        Remove-Item -LiteralPath $c.FullName -Recurse -Force
    }
}

# Size of a folder (or of named files in it) as robocopy would copy it, measured with a list-only robocopy run.
function Get-FolderBytes {
    param([string]$Path, [string[]]$Files, [string[]]$XD)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $a = @($Path.TrimEnd('\'), (Join-Path ([IO.Path]::GetTempPath()) 'wtt-measure-nothing'))
    if ($Files) { $a += $Files } else { $a += '/E'; $a += '/XF'; $a += 'desktop.ini'; $a += 'Thumbs.db' }
    $a += '/L', '/XJ', '/BYTES', '/NFL', '/NDL', '/NJH', '/NP', '/R:0', '/W:0'
    if ($XD) { $a += '/XD'; $a += $XD }
    try {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = (& robocopy @a 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
        if ($out -match '(?m)^\s*Bytes :\s+\d+\s+(\d+)') { return [int64]$Matches[1] }
    } catch {}
    return [int64]0
}

# Bytes the file-copy parts of one catalog item would put on the drive.
function Get-ItemBytes($it, $Known) {
    [int64]$sum = 0
    if ($it.Known -and $Known[$it.Known]) { $sum += Get-FolderBytes -Path $Known[$it.Known] }
    foreach ($c in @($it.Copies)) { if ($c) { $sum += Get-FolderBytes -Path (Join-Rel $env:USERPROFILE $c.Src) -Files $c.Files -XD $c.XD } }
    return $sum
}

# Makes an external drive a transfer drive: creates the empty WTT-Transfer folder in its root and nothing else.
function Initialize-TransferDrive([string]$Letter) {
    $want = $Letter.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
    $vol = Get-LocalVolumes | Where-Object { $_.Letter -eq $want } | Select-Object -First 1
    if (-not $vol) { throw "Drive ${want}: was not found. It must be ready, local, and not the system drive." }
    if (-not $vol.External -and $Drive -notmatch "^${want}:?\\?$") { throw "Drive ${want}: is not an external (USB or removable) drive according to Windows, so it is not offered. If it really is one, run again with -Drive ${want}: -PrepareDrive ${want}:" }
    $dir = Get-TransferDir $vol.Root
    if (Test-Path -LiteralPath $dir) {
        if (-not (Test-TransferMarker $vol.Root)) { throw "$dir exists but is not a plain folder (it is a link or a file). Remove it first." }
        Write-Ok "$dir already exists: drive ${want}: is a transfer drive."
    } else {
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'README.txt') -Encoding ASCII -Value @(
            'Windows Transfer Tool - transfer folder',
            '',
            'The tool only ever reads, writes and deletes inside this folder. Files outside it on this drive are never touched.',
            'Delete this folder to stop the drive from being offered as a transfer drive.',
            'While a transfer is on the drive it holds copies of personal files and saved Wi-Fi passwords in clear text.')
        Write-Ok "Created $dir. Only this folder will be used on drive ${want}:."
    }
    return $vol
}

# Picks the drive to use. Returns the volume object, or $null if the user backs out.
#   Source      : a drive that has the WTT-Transfer folder; offers to create it on a drive you name if none has one.
#   Destination : a drive that has the folder AND a transfer.json from the old PC; waits for you to plug it in.
function Select-TransferDrive {
    param([ValidateSet('Source', 'Destination')][string]$Purpose)
    while ($true) {
        $vols = @(Get-LocalVolumes)
        if ($Drive) {
            $want = $Drive.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
            $cands = @($vols | Where-Object { $_.Letter -eq $want })
            if ($cands.Count -eq 0) { throw "Drive ${want}: was not found. It must be ready, local, and not the system drive." }
            if (-not $cands[0].External) { Write-Warn "Windows does not report ${want}: as an external drive; using it only because you named it." }
        } else {
            $cands = @($vols | Where-Object { $_.External })
        }
        $marked = @($cands | Where-Object { Test-TransferMarker $_.Root })
        # @( ) matters: Windows PowerShell 5.1 turns a one-element result into a bare object, and .Count / [0] then misbehave
        $usable = @(if ($Purpose -eq 'Destination') { $marked | Where-Object { Get-TransferInfo $_.Root } } else { $marked })

        if ($usable.Count -eq 1) { return $usable[0] }
        if ($usable.Count -gt 1) {
            Write-Host 'More than one transfer drive is plugged in:' -ForegroundColor White
            for ($i = 0; $i -lt $usable.Count; $i++) {
                $u = $usable[$i]; $t = Get-TransferInfo $u.Root
                Write-Host ('  {0}) {1}:  {2}  {3}  {4}{5}' -f ($i + 1), $u.Letter, $u.Label, (Format-Bytes $u.Size), $u.Device, $(if ($t) { "  - from $($t.ComputerName), $($t.StartedAt)" } else { '' }))
            }
            $n = Read-Host '  Which one? (number, or quit)'
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $usable.Count) { return $usable[[int]$n - 1] }
            return $null
        }

        # nothing usable yet: explain what was seen and what to do
        Write-Host ''
        if ($cands.Count -eq 0) {
            Write-Host '  No external drive (USB stick, external SSD or hard drive) is plugged in.' -ForegroundColor Yellow
        } else {
            Write-Host '  External drives found:' -ForegroundColor White
            foreach ($c in $cands) {
                $has = if (Test-TransferMarker $c.Root) { "has $DriveDirName" } else { "no $DriveDirName folder" }
                Write-Host ('    {0}:  {1}  {2}  {3}  free {4}  [{5}]' -f $c.Letter, $c.Label, $c.FileSystem, (Format-Bytes $c.Size), (Format-Bytes $c.Free), $has)
            }
        }
        $msg = if ($Purpose -eq 'Destination') { "No drive with a finished transfer was found. Run the tool on the old PC with -Transport Drive first, then plug that drive in here." }
               else { "A drive is only used if it contains a folder named $DriveDirName in its root." }
        Write-Host "  $msg" -ForegroundColor Yellow
        if (-not (Test-Interactive)) { throw $msg }

        if ($Purpose -eq 'Source' -and $cands.Count -gt 0) {
            Write-Host "  To use one of them, type its drive letter: this creates an empty folder named $DriveDirName in its root and touches nothing else." -ForegroundColor White
            $ans = (Read-Host '  Drive letter (Enter = look again, or type quit)').Trim()
            if ($ans -match '^(quit|exit)$') { return $null }          # a word, not "Q": Q is also a possible drive letter
            if ($ans -match '^[A-Za-z]:?\\?$') {
                $letter = $ans.Substring(0, 1).ToUpper()
                if ($cands | Where-Object { $_.Letter -eq $letter }) { [void](Initialize-TransferDrive $letter) }
                else { Write-Warn "${letter}: is not one of the external drives listed above." }
            }
        } else {
            $ans = (Read-Host '  Plug the drive in, then press Enter to look again (or type quit)').Trim()
            if ($ans -match '^(quit|exit|q)$') { return $null }
        }
    }
}

# =============================================================================
# Credentials file (credentials.json - git-ignored, generated on demand)
#   The password is encrypted with Windows DPAPI: only the same Windows user on
#   the same PC can decrypt it. Copying the file to another machine will not work.
# =============================================================================
function New-CredentialFile {
    param([string]$Path, [string]$IP, [pscredential]$Cred)
    [ordered]@{
        _comment = 'Generated by Migrate-Windows.ps1. Password is DPAPI-encrypted for this Windows user on this PC only. Never commit this file.'
        OldPCIP  = $IP
        Username = $Cred.UserName
        Password = ($Cred.Password | ConvertFrom-SecureString)
    } | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
    [void](Invoke-Native icacls @($Path, '/inheritance:r', '/grant:r', ('{0}:(R,W)' -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)))
}

function Read-CredentialFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if (-not $j.Username -or -not $j.Password) { return $null }
        $sec = $j.Password | ConvertTo-SecureString
        return @{ IP = $j.OldPCIP; Cred = (New-Object System.Management.Automation.PSCredential($j.Username, $sec)) }
    } catch {
        Write-Warn "Could not read $Path ($($_.Exception.Message)). Delete it and re-run -InitCredentials."
        return $null
    }
}

function Start-InitCredentials {
    Write-Host "Creating $CredentialFile" -ForegroundColor White
    $ip = Read-Host 'IP address of the OLD PC'
    $cred = Get-Credential -Message 'Sign-in for the OLD PC. Normally the temporary account shown on the old PC in stage S4 (it is different every run, so saving it here only helps for a single run started very soon). Local account: user name. Microsoft account: e-mail address.'
    New-CredentialFile -Path $CredentialFile -IP $ip -Cred $cred
    Write-Ok 'Saved. This file is git-ignored; the password can only be decrypted by you on this PC.'
}

# =============================================================================
# SOURCE MODE (old PC) - S1 Preflight, S2 Export, S3 Share, S4 Pair, S5 Wait, S6 Cleanup
# =============================================================================
function Save-PrepState($State) { $State | ConvertTo-Json -Depth 5 | Set-Content -Path "$ExportDir\prep-state.json" -Encoding UTF8 }

# A disposable local administrator account, used only to authenticate the SMB connection, so the
# new PC never needs the real sign-in (and its Microsoft-account password, which you may not have
# at all - e.g. after a password reset, or on a work PC where someone else holds that password).
# It is deleted again in S6 Cleanup. -UseOwnAccount skips all of this and uses the signed-in account instead.
function New-TransferAccount {
    $name = 'WTT-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%'
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    $sec = ConvertTo-SecureString $pw -AsPlainText -Force
    New-LocalUser -Name $name -Password $sec -FullName 'Windows Transfer Tool (temporary)' -Description 'Created by Migrate-Windows.ps1 for one transfer. Safe to delete.' -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Add-LocalGroupMember -Group 'Administrators' -Member $name
    # Keep it off the normal sign-in screen; it only needs to work over the network.
    try { New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SpecialAccounts\UserList' -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null } catch {}
    return @{ Name = $name; Password = $pw }
}

function Remove-TransferAccount([string]$Name) {
    if (-not $Name) { return }
    try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SpecialAccounts\UserList' -Name $Name -ErrorAction SilentlyContinue } catch {}
    try { Remove-LocalUser -Name $Name -ErrorAction Stop } catch { Write-Warn "Could not remove temporary account '$Name' ($($_.Exception.Message)). Remove it by hand: Computer Management > Local Users." }
}

function Enable-Sharing {
    param([string]$TransferAccount)
    $state = @{ Rules = @(); PublicIfaces = @(); Policy = $null; ServerStarted = $false; BoundTo = $null; TransferAccount = $TransferAccount }
    $svc = Get-Service LanmanServer -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Start-Service LanmanServer; $state.ServerStarted = $true }
    foreach ($r in @(Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue)) {
        $ra = @()
        try { $ra = @(($r | Get-NetFirewallAddressFilter -ErrorAction Stop).RemoteAddress) } catch {}
        $state.Rules += @{ Name = $r.Name; Enabled = [string]$r.Enabled; RemoteAddress = $ra }
    }
    Set-NetFirewallRule -Group $FwGroup -Enabled True -ErrorAction SilentlyContinue
    foreach ($p in @(Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public')) {
        $state.PublicIfaces += $p.InterfaceIndex
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
    }
    $cur = Get-ItemProperty $PolicyKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
    if ($cur) { $state.Policy = $cur.LocalAccountTokenFilterPolicy }
    Set-ItemProperty $PolicyKey -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
    Save-PrepState $state
    return $state
}

# After pairing: only the new PC's address may reach the sharing ports.
function Limit-SharingTo([string]$Ip, $State) {
    $n = 0
    foreach ($r in @(Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue)) {
        try { Set-NetFirewallRule -Name $r.Name -RemoteAddress $Ip -ErrorAction Stop; $n++ } catch {}
    }
    if ($State) { $State.BoundTo = $Ip; Save-PrepState $State }
    return $n
}

# FTP / FTPS variant of S3: start the read-only service and open its ports. Nothing about SMB, sharing,
# network profiles or Windows accounts is touched. Returns the running server and what to show on screen.
function Start-FtpService {
    param([string]$Mode, $Known)
    Import-WttFtp
    $password = New-FtpPassword
    $cert = $null
    if ($Mode -eq 'Ftps') { $cert = [Wtt.FtpUtil]::CreateSelfSigned($env:COMPUTERNAME, 2) }
    $server = New-Object Wtt.FtpServer ([Net.IPAddress]::Any), $FtpPort, $FtpPasvLow, $FtpPasvHigh, $FtpUser, $password, $cert
    $server.AddRoot('pkg', $ExportDir)
    $server.AddRoot('profile', $env:USERPROFILE)
    foreach ($k in $Known.Keys) { if (Test-Path -LiteralPath $Known[$k]) { $server.AddRoot("known-$k", $Known[$k]) } }
    $server.Hide('/pkg/prep-state.json')
    $server.AllowUpload('/pkg/bound.json'); $server.AllowUpload('/pkg/done.json')
    # Record what must be undone before changing anything, so -Cleanup still works if this window dies.
    $state = @{ Transport = $Mode; FirewallRule = $FtpRuleName; BoundTo = $null }
    Save-PrepState $state
    Open-FtpFirewall
    try { $server.Start() }
    catch {
        $msg = $_.Exception.Message
        $server.Dispose()
        throw "Could not start the $Mode service on port $FtpPort ($msg). Is another program using that port? Try -FtpPort <other port> on both PCs."
    }
    $fp = $null; if ($cert) { $fp = [Wtt.FtpUtil]::Sha256Hex($cert.RawData) }
    return @{ Server = $server; Password = $password; Fingerprint = $fp; State = $state }
}

# Which address logged in? The server saw it directly; the new PC's own list is only the fallback.
function Resolve-BoundIPFtp($Bound, $Server) {
    $claimed = @($Bound.IPs | Where-Object { $_ })
    if ($Server.LastLoginIp) { return [string]$Server.LastLoginIp }
    if ($claimed.Count -gt 0) { return $claimed[0] }
    return $null
}

function Restore-Sharing {
    $f = "$ExportDir\prep-state.json"
    if (-not (Test-Path $f)) { Write-Warn 'No saved sharing state found; nothing to revert.'; return }
    $s = Get-Content $f -Raw | ConvertFrom-Json
    if ($s.Transport -in 'Ftp','Ftps') { Close-FtpFirewall; return }
    foreach ($r in @($s.Rules)) {
        $ra = @($r.RemoteAddress | Where-Object { $_ })
        if ($ra.Count -gt 0) { Set-NetFirewallRule -Name $r.Name -Enabled $r.Enabled -RemoteAddress $ra -ErrorAction SilentlyContinue }
        else { Set-NetFirewallRule -Name $r.Name -Enabled $r.Enabled -ErrorAction SilentlyContinue }
    }
    foreach ($i in @($s.PublicIfaces)) { Set-NetConnectionProfile -InterfaceIndex $i -NetworkCategory Public -ErrorAction SilentlyContinue }
    if ($null -eq $s.Policy) { Remove-ItemProperty $PolicyKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $PolicyKey -Name LocalAccountTokenFilterPolicy -Value $s.Policy -Type DWord }
    if ($s.ServerStarted) { Stop-Service LanmanServer -Force -ErrorAction SilentlyContinue }
    if ($s.TransferAccount) { Remove-TransferAccount $s.TransferAccount }
}

function Start-SourceCleanup {
    Write-Stage 'S6' 'Cleanup'
    Write-Step 'Reverting sharing changes and deleting the export...'
    Restore-Sharing
    if (Test-Path $ExportDir) { Remove-Item $ExportDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok 'Old PC is back to its original state.'
}

# Writes pair.json (salt + hash only) and returns the code to show on screen.
function New-PairFile {
    $code = '{0:D6}' -f (Get-Random -Minimum 0 -Maximum 1000000)
    $salt = [guid]::NewGuid().ToString('N')
    $pair = [ordered]@{
        SessionId = [guid]::NewGuid().ToString('N'); Salt = $salt; PairHash = (Get-PairHash $salt $code)
        ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME; CreatedAt = (Get-Date).ToString('s'); ToolVersion = $ToolVersion
    }
    $pair | ConvertTo-Json | Set-Content "$ExportDir\pair.json" -Encoding UTF8
    return @{ Code = $code; SessionId = $pair.SessionId }
}

# Polls for a JSON marker written by the new PC. Returns the parsed object, or $null if the user pressed Enter/Q/Esc.
function Wait-ForMarker([string]$Path, [string]$SessionId, [string]$Hint) {
    Write-Host $Hint -ForegroundColor DarkGray
    $dots = 0
    while ($true) {
        if (Test-Path -LiteralPath $Path) {
            try {
                $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
                if ($o.SessionId -eq $SessionId) { Write-Host ''; return $o }
            } catch {}
        }
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -in 'Enter','Q','Escape') { Write-Host ''; return $null }
            }
        } catch {}
        Start-Sleep -Seconds 2
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        $dots++; if ($dots % 40 -eq 0) { Write-Host '' }
    }
}

# Which address did the new PC connect from? Prefer what the SMB server saw; fall back to what the new PC reported.
function Resolve-BoundIP($Bound) {
    $claimed = @($Bound.IPs | Where-Object { $_ })
    try {
        $sessions = @(Get-SmbSession -ErrorAction Stop)
        $hit = $sessions | Where-Object { $claimed -contains $_.ClientComputerName } | Select-Object -First 1
        if (-not $hit) { $hit = $sessions | Select-Object -First 1 }
        if ($hit -and $hit.ClientComputerName -match '^\d+\.\d+\.\d+\.\d+$') { return $hit.ClientComputerName }
    } catch {}
    if ($claimed.Count -gt 0) { return $claimed[0] }
    return $null
}

# Known folder locations of the signed-in user (follows OneDrive and other redirection).
function Get-KnownFolders {
    # Known folder locations (follows OneDrive redirection)
    $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $names = [ordered]@{ Desktop='Desktop'; Documents='Personal'; Pictures='My Pictures'; Videos='My Video'; Music='My Music'; Downloads='{374DE290-123F-4565-9164-39C4925E467B}' }
    $known = @{}
    foreach ($k in $names.Keys) {
        $v = $usf.($names[$k])
        if ($v) { $known[$k] = [Environment]::ExpandEnvironmentVariables($v) } else { $known[$k] = Join-Path $env:USERPROFILE $k }
    }
    return $known
}

# Writes the settings package: manifest, registry exports, Wi-Fi profiles, app lists, power plan, wallpaper.
# Every transfer method uses it: $Dir is C:\MigrationExport for the network ones and WTT-Transfer\pkg on a drive.
function Write-ExportPackage {
    param([string]$Dir, $Known)
    if ($Transport -eq 'Drive') { Assert-InsideTransferDir $Dir }
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    New-Item -ItemType Directory -Force "$Dir\reg" | Out-Null

    $wall = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper
    if (-not $wall) { $wall = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper' }
    $wallFile = $null
    if ($wall -and (Test-Path -LiteralPath $wall)) {
        $ext = [IO.Path]::GetExtension($wall); if (-not $ext) { $ext = '.jpg' }
        $wallFile = "wallpaper$ext"
        Copy-Item -LiteralPath $wall "$Dir\$wallFile" -Force -ErrorAction SilentlyContinue
    }
    [ordered]@{
        ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME; Profile = $env:USERPROFILE
        OS = (Get-CimInstance Win32_OperatingSystem).Caption; ExportedAt = (Get-Date).ToString('s'); ToolVersion = $ToolVersion
        KnownFolders = $known; Wallpaper = $wall; WallpaperFile = $wallFile
    } | ConvertTo-Json -Depth 4 | Set-Content "$Dir\manifest.json" -Encoding UTF8

    Write-Step 'Registry settings'
    foreach ($it in ($Catalog | Where-Object { $_.Reg })) {
        $regDir = "$Dir\reg\$($it.Key)"; New-Item -ItemType Directory -Force $regDir | Out-Null     # not $dir: variable names are case-insensitive
        $n = 0
        foreach ($k in $it.Reg) {
            $n++
            [void](Invoke-Native reg @('export', $k, ('{0}\{1:D2}.reg' -f $regDir, $n), '/y'))   # missing keys are fine
        }
    }

    Write-Step 'Wi-Fi profiles'
    New-Item -ItemType Directory -Force "$Dir\wifi" | Out-Null
    [void](Invoke-Native netsh @('wlan','export','profile','key=clear',"folder=$Dir\wifi"))

    Write-Step 'Installed-apps list'
    $paths = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 } |
        Select-Object DisplayName, DisplayVersion, Publisher | Sort-Object DisplayName -Unique |
        Export-Csv "$Dir\apps-report.csv" -NoTypeInformation -Encoding UTF8
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        [void](Invoke-Native winget @('export','-o',"$Dir\apps.json",'--accept-source-agreements'))
    } else { Write-Warn 'winget not found on this PC; app reinstall list skipped.' }
    if (Get-Command code -ErrorAction SilentlyContinue) {
        [void](Invoke-Native cmd @('/c', "code --list-extensions > `"$Dir\vscode-extensions.txt`""))
    }

    Write-Step 'Power plan'
    $m = powercfg /getactivescheme
    if ($m -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') {
        [void](Invoke-Native powercfg @('/export',"$Dir\power.pow",$Matches[1]))
    }
    Write-Ok "Export written to $Dir"
}

# =============================================================================
# DRIVE TRANSPORT, old PC - S1 Preflight, S2 Choose the drive, S3 Select, S4 Copy, S5 Finish
# robocopy writes only inside <drive>\WTT-Transfer: package in pkg, files in data, logs in logs, status in transfer.json.
# =============================================================================
# One file-copy catalog item (known folder and/or profile folders) onto the drive.
function Invoke-DriveCopyItem($it, $Known) {
    Write-Step $it.Label
    $script:Rank = 0; $script:DidWork = $false; $script:Notes = New-Object System.Collections.ArrayList
    try {
        if ($it.Kill) { Write-Warn ('Close {0} on this PC for a complete copy.' -f ($it.Kill -join ', ')) }
        if ($it.Known -and $Known[$it.Known]) {
            $dst = Join-Path $script:DriveData "known-$($it.Known)"
            Assert-InsideTransferDir $dst
            Copy-Spec -SrcPath $Known[$it.Known] -DstPath $dst -Label $it.Label
        }
        foreach ($c in @($it.Copies)) {
            if (-not $c) { continue }
            $dst = Join-Rel (Join-Path $script:DriveData 'profile') $c.Src
            Assert-InsideTransferDir $dst
            Copy-Spec -SrcPath (Join-Rel $env:USERPROFILE $c.Src) -DstPath $dst -Files $c.Files -XD $c.XD -Label $c.Src
        }
    } catch { Mark 3 $_.Exception.Message }
    $status = switch ($script:Rank) { 0 { if ($script:DidWork) { 'OK' } else { 'SKIPPED' } } 1 { 'SKIPPED' } 2 { 'WARN' } default { 'FAILED' } }
    $color = switch ($status) { 'OK' { 'Green' } 'SKIPPED' { 'DarkGray' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('    {0} {1}' -f $status, ($script:Notes -join '; ')) -ForegroundColor $color
    return [pscustomobject]@{ Key = $it.Key; Stage = $it.Stage; Item = $it.Label; Status = $status; Notes = ($script:Notes -join '; ') }
}

function Start-DriveSourceMode {
    Write-Stage 'S1' 'Preflight (old PC)'
    if (-not (Test-Admin)) { throw 'Run this in an elevated PowerShell (Run as administrator), signed in as the user you are migrating.' }
    Assert-SignedInUser
    Set-KeepAwake $true
    try {
        Write-Host ("Copying for user '{0}' ({1}); transfer method: DRIVE (no network)" -f $env:USERNAME, $env:USERPROFILE) -ForegroundColor White
        $known = Get-KnownFolders
        $od = @($known.Keys | Where-Object { Test-OneDrivePath $known[$_] })
        if ($od.Count -gt 0) { Write-Warn ("In OneDrive on this PC: {0}. Files that are online-only are downloaded while they are copied; if the new PC signs in to the same OneDrive, untick those and let OneDrive sync them (docs/caveats.md)." -f ($od -join ', ')) }
        Write-Ok 'Preflight passed.'

        # ---- S2: which drive
        Write-Stage 'S2' 'Choose the transfer drive'
        $vol = Select-TransferDrive -Purpose Source
        if (-not $vol) { Write-Host 'No drive chosen. Nothing was changed.'; return }
        $script:DriveWtt = Get-TransferDir $vol.Root
        $script:DriveData = Join-Path $script:DriveWtt 'data'
        $script:RoboFat = ($vol.FileSystem -ne 'NTFS')
        Write-Ok ('Using drive {0}: {1} ({2}, {3}, {4} free). Only the folder {5} on it will be used.' -f $vol.Letter, $vol.Label, $vol.FileSystem, (Format-Bytes $vol.Size), (Format-Bytes $vol.Free), $DriveDirName)
        if ($vol.FileSystem -eq 'FAT32') { Write-Warn 'FAT32 cannot hold a single file larger than 4 GB; such files will fail to copy. Formatting the drive as exFAT or NTFS avoids that.' }

        $existing = Get-TransferInfo $vol.Root
        $continue = $false; $replace = $false
        if ($existing) {
            $mine = ($existing.ComputerName -eq $env:COMPUTERNAME -and $existing.UserName -eq $env:USERNAME)
            Write-Host ('  The drive already holds a transfer from {0} (user {1}), started {2}, status: {3}.' -f $existing.ComputerName, $existing.UserName, $existing.StartedAt, $existing.Status) -ForegroundColor Yellow
            if ($mine -and $existing.Status -ne 'complete') {
                if ((Read-Host '  It was not finished. Continue it? Files already copied are skipped. (Y/n)') -notmatch '^n') { $continue = $true }
            }
            if (-not $continue) {
                if ((Read-Host "  Delete it and start again? Only the contents of $($script:DriveWtt) are deleted. (y/N)") -notmatch '^y') { Write-Host 'Left the drive as it was.'; return }
                $replace = $true
            }
        }

        # ---- S3: what to copy
        Write-Stage 'S3' 'Select what to copy'
        $fileItems = @($Catalog | Where-Object { $_.Known -or $_.Copies })
        Write-Step 'Measuring the folders (list-only, nothing is copied yet)'
        $sizes = @{}
        foreach ($it in $fileItems) { Write-Progress -Activity 'Measuring' -Status $it.Label; $sizes[$it.Key] = Get-ItemBytes $it $known }
        Write-Progress -Activity 'Measuring' -Completed
        $menu = @(foreach ($it in $fileItems) { $e = $it.Clone(); $e.Label = '{0}  [{1}]' -f $it.Label, (Format-Bytes $sizes[$it.Key]); $e })
        $reuse = [int64]0
        if ($continue -or $replace) { $reuse = Get-FolderBytes -Path $script:DriveData }      # space that will be reused or freed
        while ($true) {
            if ($Select) {
                $keys = if ($Select -contains 'All') { @($menu | ForEach-Object { $_.Key }) } else { @($Select | Where-Object { $k = $_; @($menu | Where-Object { $_.Key -eq $k }).Count -gt 0 }) }
            } else {
                $keys = Show-Menu -Items $menu -Title ' WINDOWS TRANSFER - choose what to copy to the drive (sizes in brackets)'
            }
            if ($null -eq $keys) { Write-Host 'Cancelled. Nothing was changed.'; return }
            [int64]$total = 0
            foreach ($k in @($keys)) { $total += $sizes[$k] }
            $free = Get-DriveFree $vol
            $need = $total + [int64]($total * 0.02) + 300MB
            if ($need -le ($free + $reuse)) { break }
            Write-Warn ('The selection needs about {0} but the drive has {1} free. Untick something.' -f (Format-Bytes $need), (Format-Bytes ($free + $reuse)))
            if ($Select -or -not (Test-Interactive)) { throw 'Not enough space on the drive for the selected items.' }
            [void](Read-Host '  Press Enter to choose again')
        }
        $keys = @($keys)
        Write-Host ''
        if ($keys.Count -eq 0) { Write-Host 'No files selected: the drive will only get the settings package.' -ForegroundColor White }
        else {
            Write-Host ('Will copy {0} item(s), about {1}, to drive {2}:' -f $keys.Count, (Format-Bytes $total), $vol.Letter) -ForegroundColor White
            foreach ($k in $keys) { Write-Host ('  - {0}' -f ($menu | Where-Object { $_.Key -eq $k }).Label) }
        }
        Write-Host 'The drive also gets the settings package: registry exports, saved Wi-Fi networks (passwords in clear text) and the installed-apps list.' -ForegroundColor White
        if ($DryRun) { Write-Warn 'DRY RUN - nothing was written to the drive.'; return }
        if (-not $Yes) { if ((Read-Host "`nProceed? (Y/n)") -match '^n') { Write-Host 'Nothing was changed.'; return } }

        # ---- S4: copy
        Write-Stage 'S4' 'Copy to the drive'
        if ($replace) { Write-Step 'Removing the old transfer from the drive'; Clear-TransferDir }
        foreach ($sub in 'pkg', 'data', 'logs') { New-Item -ItemType Directory -Force (Join-Path $script:DriveWtt $sub) | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:RoboLog = Join-Path $script:DriveWtt "logs\robocopy-$stamp.log"
        $info = [ordered]@{
            Tool = 'WindowsTransferTool'; ToolVersion = $ToolVersion; Status = 'incomplete'
            ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME; Profile = $env:USERPROFILE
            StartedAt = (Get-Date).ToString('s'); FinishedAt = $null; FileItems = @(); Results = @()
        }
        Save-TransferInfo $info
        Write-ExportPackage -Dir (Join-Path $script:DriveWtt 'pkg') -Known $known
        $results = @()
        foreach ($k in $keys) {
            $cat = $Catalog | Where-Object { $_.Key -eq $k } | Select-Object -First 1
            $results += Invoke-DriveCopyItem $cat $known
        }

        # ---- S5: finish
        Write-Stage 'S5' 'Finish'
        $info.FileItems = @($results | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'WARN' } | ForEach-Object { $_.Key })
        $info.Results = @($results | ForEach-Object { [ordered]@{ Key = $_.Key; Status = $_.Status; Notes = $_.Notes } })
        $info.Status = 'complete'; $info.FinishedAt = (Get-Date).ToString('s')
        Save-TransferInfo $info
        try { Write-VolumeCache -DriveLetter $vol.Letter -ErrorAction Stop } catch {}        # push cached writes to the drive
        if ($results.Count -gt 0) { $results | Format-Table -Property Item, Status, Notes -AutoSize -Wrap | Out-Host }
        $bad = @($results | Where-Object { $_.Status -eq 'WARN' -or $_.Status -eq 'FAILED' }).Count
        if ($bad -gt 0) { Write-Warn "$bad item(s) had problems; the log on the drive (logs folder) names every file that failed." }
        Write-Ok ('Done. Now eject drive {0}: with "Safely Remove Hardware" in the taskbar, plug it into the NEW PC and start the tool there.' -f $vol.Letter)
        Write-Host '   The drive holds copies of your files and your saved Wi-Fi passwords in clear text: keep it with you, and delete the transfer folder when you are done.' -ForegroundColor DarkGray
    }
    finally { Set-KeepAwake $false }
}

# =============================================================================
# DRIVE TRANSPORT, new PC - helpers used by Start-DestinationMode
# =============================================================================
# 'Drive' if this run should read from a transfer drive, otherwise $null (use the network).
function Resolve-DriveChoice {
    if ($Transport -eq 'Drive' -or $Drive) { return 'Drive' }
    if ($Transport -ne 'Auto') { return $null }           # Ftps, Ftp or Smb was asked for explicitly
    $found = @(Get-ExternalDrives | Where-Object { (Test-TransferMarker $_.Root) -and (Get-TransferInfo $_.Root) })
    if ($found.Count -eq 0) { return $null }
    $t = Get-TransferInfo $found[0].Root
    Write-Host ''
    Write-Host ('  Found a transfer drive: {0}: {1}, written by {2} (user {3}), started {4}.' -f $found[0].Letter, $found[0].Label, $t.ComputerName, $t.UserName, $t.StartedAt) -ForegroundColor Green
    if ($Yes) { return 'Drive' }
    if ((Read-Host '  Use it? (Y/n - n looks for the old PC on the network instead)') -match '^n') { return $null }
    return 'Drive'
}

function Connect-TransferDrive {
    $vol = Select-TransferDrive -Purpose Destination
    if (-not $vol) { throw 'No transfer drive chosen.' }
    $info = Get-TransferInfo $vol.Root
    $script:DriveVolume = $vol
    $script:DriveWtt = Get-TransferDir $vol.Root
    $script:DriveData = Join-Path $script:DriveWtt 'data'
    $script:Pkg = Join-Path $script:DriveWtt 'pkg'
    $script:RoboFat = ($vol.FileSystem -ne 'NTFS')
    $script:Transfer = $info
    if ($info.Status -ne 'complete') {
        Write-Warn 'The copy on this drive was never finished (the old PC was interrupted), so files may be missing.'
        if ((Read-Host '  Use it anyway? (y/N)') -notmatch '^y') { throw 'Stopped: the transfer on the drive is not finished. Run the old PC step again.' }
    }
    if ($info.ComputerName -eq $env:COMPUTERNAME) {
        Write-Warn "This drive was written by a PC with this PC's name ($($env:COMPUTERNAME)). Make sure you are on the NEW PC."
        if ((Read-Host '  Continue? (y/N)') -notmatch '^y') { throw 'Stopped.' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:Pkg 'manifest.json'))) { throw "No settings package found in $($script:Pkg). Run the old PC step again." }
    Write-Ok ('Using drive {0}: ({1}, {2}) with the transfer from {3}, user {4}, finished {5}.' -f $vol.Letter, $vol.Label, $vol.FileSystem, $info.ComputerName, $info.UserName, $info.FinishedAt)
}

# The menu on the new PC only offers file items that were actually copied to the drive.
function Get-DriveMenuItems {
    $have = @($script:Transfer.FileItems)
    return @($Catalog | Where-Object { (-not ($_.Known -or $_.Copies)) -or ($have -contains $_.Key) })
}

function Invoke-ClearTransferDriveOffer {
    Write-Host ''
    Write-Warn ('Drive {0}: still holds copies of your files and the old PC''s saved Wi-Fi passwords in clear text.' -f $script:DriveVolume.Letter)
    if ((Read-Host "Delete everything inside $($script:DriveWtt) now? The drive stays prepared and nothing else on it is touched. (y/N)") -match '^y') {
        try { Clear-TransferDir; Write-Ok 'The transfer folder is empty.' } catch { Write-Warn $_.Exception.Message }
    } else {
        Write-Host '  Left as it is. Delete the contents of the folder yourself once you have checked the new PC.' -ForegroundColor Gray
    }
}

function Start-SourceMode {
    Write-Stage 'S1' 'Preflight (old PC)'
    if (-not (Test-Admin)) { throw 'Run this in an elevated PowerShell (Run as administrator), signed in as the user you are migrating.' }
    Assert-SignedInUser
    Set-KeepAwake $true
    $transport = if ($Transport -eq 'Auto') { 'Ftps' } else { $Transport }
    $ftp = $null
    Write-Host ("Exporting settings for user '{0}' ({1}); transfer method: {2}" -f $env:USERNAME, $env:USERPROFILE, $transport.ToUpper()) -ForegroundColor White

    $known = Get-KnownFolders
    $od = @($known.Keys | Where-Object { Test-OneDrivePath $known[$_] })
    if ($od.Count -gt 0) { Write-Warn ("In OneDrive on this PC: {0}. If the new PC signs in to the same OneDrive, untick those and let OneDrive sync them (docs/caveats.md)." -f ($od -join ', ')) }
    Write-Ok 'Preflight passed.'

    try {
        Write-Stage 'S2' 'Export settings'
        Write-ExportPackage -Dir $ExportDir -Known $known

        $account = $null; $state = $null
        if ($transport -eq 'Smb') {
            Write-Stage 'S3' 'Open sharing (temporary - reverted in S6)'
            if (-not $UseOwnAccount) {
                Write-Step 'Creating a temporary account just for this transfer'
                $account = New-TransferAccount
            }
            $state = Enable-Sharing -TransferAccount $(if ($account) { $account.Name })
            Write-Ok 'File and printer sharing is open for the transfer.'
        } else {
            Write-Stage 'S3' ('Start the {0} service (temporary - removed in S6)' -f $transport.ToUpper())
            $ftp = Start-FtpService -Mode $transport -Known $known
            $state = $ftp.State
            Write-Ok ('{0} service listening on port {1}: read-only, one random password, firewall opened for the local subnet only.' -f $transport.ToUpper(), $FtpPort)
        }

        Write-Stage 'S4' 'Pair with the new PC'
        $pair = New-PairFile
        Write-Host ''
        Write-Host '   On the NEW PC run the bootstrap one-liner from the README, or:  .\Migrate-Windows.ps1 -Mode Destination' -ForegroundColor White
        Write-Host '   Address(es) of this PC:' -ForegroundColor White
        Get-IPv4List | ForEach-Object { Write-Host "     $_" -ForegroundColor White }
        if ($ftp) { Write-Host ('   Port:           {0}{1}' -f $FtpPort, $(if ($FtpPort -ne 2121) { "   (add -FtpPort $FtpPort on the new PC)" } else { '' })) -ForegroundColor White }
        [void](Protect-LogSecret ("{0} {1}" -f $pair.Code.Substring(0, 3), $pair.Code.Substring(3)) $pair.Code)
        Write-Host ('   Pairing code:   {0} {1}' -f $pair.Code.Substring(0, 3), $pair.Code.Substring(3)) -ForegroundColor Green
        if ($ftp) {
            Write-Host ('   Password:       {0}' -f (Protect-LogSecret (Format-FtpPassword $ftp.Password) $ftp.Password)) -ForegroundColor Green
            if ($ftp.Fingerprint) {
                Write-Host ('   Fingerprint:    {0}' -f (Format-Fingerprint $ftp.Fingerprint)) -ForegroundColor Green
                Write-Host '   The new PC shows the certificate fingerprint it sees; confirm it matches this one.' -ForegroundColor DarkGray
            } else {
                Write-Warn 'Plain FTP: nothing is encrypted, including the password. Only use it on a network you fully trust.'
            }
            Write-Host '   The service is read-only, locks after 5 wrong passwords and is removed automatically when this finishes.' -ForegroundColor DarkGray
        } elseif ($account) {
            Write-Host '   Sign in there with this temporary account (not your Microsoft account):' -ForegroundColor White
            Write-Host ('     User name:  {0}' -f $account.Name) -ForegroundColor Green
            Write-Host ('     Password:   {0}' -f (Protect-LogSecret $account.Password)) -ForegroundColor Green
            Write-Host '   It is deleted automatically when this finishes - it is not your sign-in account and grants no access beyond this transfer.' -ForegroundColor DarkGray
        } else {
            Write-Host "   Sign in there with this PC's user name and password ($env:USERNAME)." -ForegroundColor White
            Write-Host "   (Microsoft account? use the account's e-mail address as the user name.)"
        }
        Write-Host ''
        $bound = Wait-ForMarker -Path "$ExportDir\bound.json" -SessionId $pair.SessionId -Hint 'Waiting for the new PC to connect...  (Enter or Q cancels and reverts everything)'
        if (-not $bound) { Write-Warn 'Cancelled.'; return }
        if ($ftp) {
            $ip = Resolve-BoundIPFtp $bound $ftp.Server
            if ($ip) {
                $ftp.Server.AllowOnly($ip)
                Limit-FtpFirewallTo $ip
                $state.BoundTo = $ip; Save-PrepState $state
                Write-Ok ('Bound to {0} at {1} (user {2}). The service now accepts that address only.' -f $bound.ComputerName, $ip, $bound.UserName)
            } else {
                Write-Warn ('Bound to {0} (user {1}) but its address could not be determined; the service stays open to the local subnet.' -f $bound.ComputerName, $bound.UserName)
            }
        } else {
            $ip = Resolve-BoundIP $bound
            if ($ip) {
                $n = Limit-SharingTo $ip $state
                Write-Ok ('Bound to {0} at {1} (user {2}). Sharing is now limited to that address ({3} firewall rules scoped).' -f $bound.ComputerName, $ip, $bound.UserName, $n)
            } else {
                Write-Warn ('Bound to {0} (user {1}) but its address could not be determined; sharing stays open to the local network.' -f $bound.ComputerName, $bound.UserName)
            }
        }

        Write-Stage 'S5' 'Wait for the transfer'
        $done = Wait-ForMarker -Path "$ExportDir\done.json" -SessionId $pair.SessionId -Hint 'Leave this window open. It cleans up by itself when the new PC reports it is done.  (Enter finishes early)'
        if ($done) { Write-Ok ('New PC finished at {0}: {1}' -f $done.FinishedAt, $done.Summary) }
        if ($ftp) { Write-Host ('   The service delivered {0} files, {1:N1} MB.' -f $ftp.Server.FilesServed, ($ftp.Server.BytesServed / 1MB)) -ForegroundColor Gray }
    }
    catch { Write-Warn "Stopped: $($_.Exception.Message)" }
    finally {
        Set-KeepAwake $false
        if ($ftp) { try { $ftp.Server.Dispose() } catch {} }     # stop listening and drop the certificate before the export goes
        Start-SourceCleanup
    }
}

# =============================================================================
# Menu
# =============================================================================
function Show-Menu {
    param($Items, [string]$Title = ' WINDOWS TRANSFER - choose what to bring over from the old PC')
    $sel = @{}
    foreach ($i in $Items) { $sel[$i.Key] = ($i.Default -ne $false) }

    if ([Console]::IsInputRedirected -or $Host.Name -match 'ISE') {
        for ($n = 0; $n -lt $Items.Count; $n++) { Write-Host ('{0,2}. [{1}] {2}' -f ($n+1), $(if ($sel[$Items[$n].Key]) {'x'} else {' '}), $Items[$n].Label) }
        $a = Read-Host 'Numbers to toggle (comma separated), or Enter to accept'
        foreach ($x in ($a -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) { $k = $Items[[int]$x - 1].Key; $sel[$k] = -not $sel[$k] }
        return @($Items | Where-Object { $sel[$_.Key] } | ForEach-Object { $_.Key })
    }

    # Row model: group headers + items
    $rows = New-Object System.Collections.ArrayList
    $last = $null
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].Group -ne $last) { [void]$rows.Add(@{ Type = 'H'; Text = $Items[$i].Group }); $last = $Items[$i].Group }
        [void]$rows.Add(@{ Type = 'I'; Index = $i })
    }

    $pos = 0; $top = 0
    $oldVis = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    Clear-Host
    try {
        while ($true) {
            $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
            $view = [Math]::Max(5, $h - 7)
            $prow = 0
            for ($r = 0; $r -lt $rows.Count; $r++) { if ($rows[$r].Type -eq 'I' -and $rows[$r].Index -eq $pos) { $prow = $r; break } }
            if ($prow -lt $top) { $top = $prow }
            if ($prow -ge $top + $view) { $top = $prow - $view + 1 }
            if ($prow -le 1) { $top = 0 }

            $emit = {
                param($text, $fg, $bg)
                if ($text.Length -gt $w - 1) { $text = $text.Substring(0, $w - 1) }
                $text = $text.PadRight($w - 1)
                if ($bg) { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg } else { Write-Host $text -ForegroundColor $fg }
            }

            [Console]::SetCursorPosition(0, 0)
            & $emit $Title 'White' $null
            & $emit ' Up/Down move   Space toggle   G toggle group   A all   N none   Enter start   Q quit' 'DarkGray' $null
            & $emit '' 'Gray' $null
            for ($v = 0; $v -lt $view; $v++) {
                $r = $top + $v
                if ($r -ge $rows.Count) { & $emit '' 'Gray' $null; continue }
                $row = $rows[$r]
                if ($row.Type -eq 'H') {
                    $g = $Items[($rows[$r + 1]).Index].Group
                    $grp = @($Items | Where-Object { $_.Group -eq $g })
                    $cnt = @($grp | Where-Object { $sel[$_.Key] }).Count
                    & $emit ("  -- $g ($cnt/$($grp.Count)) --") 'Cyan' $null
                } else {
                    $it = $Items[$row.Index]
                    $mark = if ($sel[$it.Key]) { 'x' } else { ' ' }
                    $line = '   [{0}] {1}' -f $mark, $it.Label
                    if ($row.Index -eq $pos) { & $emit ('  >' + $line.Substring(2)) 'Black' 'White' }
                    else { & $emit $line $(if ($sel[$it.Key]) { 'Green' } else { 'Gray' }) $null }
                }
            }
            & $emit '' 'Gray' $null
            & $emit (' ' + $Items[$pos].Desc) 'Yellow' $null
            $total = @($Items | Where-Object { $sel[$_.Key] }).Count
            & $emit (" Selected: $total of $($Items.Count)") 'White' $null

            $k = [Console]::ReadKey($true)
            switch ($k.Key.ToString()) {
                'UpArrow'   { if ($pos -gt 0) { $pos-- } }
                'DownArrow' { if ($pos -lt $Items.Count - 1) { $pos++ } }
                'PageUp'    { $pos = [Math]::Max(0, $pos - 8) }
                'PageDown'  { $pos = [Math]::Min($Items.Count - 1, $pos + 8) }
                'Home'      { $pos = 0 }
                'End'       { $pos = $Items.Count - 1 }
                'Spacebar'  { $sel[$Items[$pos].Key] = -not $sel[$Items[$pos].Key] }
                'A'         { foreach ($i in $Items) { $sel[$i.Key] = $true } }
                'N'         { foreach ($i in $Items) { $sel[$i.Key] = $false } }
                'G'         {
                    $g = $Items[$pos].Group
                    $grp = @($Items | Where-Object { $_.Group -eq $g })
                    $newVal = -not (@($grp | Where-Object { -not $sel[$_.Key] }).Count -eq 0)
                    foreach ($i in $grp) { $sel[$i.Key] = $newVal }
                }
                'Enter'     { return @($Items | Where-Object { $sel[$_.Key] } | ForEach-Object { $_.Key }) }
                'Q'         { return $null }
                'Escape'    { return $null }
            }
        }
    } finally {
        [Console]::CursorVisible = $oldVis
        Clear-Host
    }
}

# =============================================================================
# DESTINATION MODE (new PC) - D1 Preflight, D2 Bind, D3 Select, D4 Files, D5 Apps, D6 Settings, D7 Finish
# =============================================================================
function ConvertTo-Unc([string]$Path) {
    if ($Path -match '^([A-Za-z]):\\?(.*)$') { return ('\\{0}\{1}$\{2}' -f $script:IP, $Matches[1], $Matches[2]) }
    return $null
}

function Join-Rel([string]$Base, [string]$Rel) { if ($Rel -eq '.') { $Base } else { Join-Path $Base $Rel } }

function Get-TargetKnown([string]$Name) {
    switch ($Name) {
        'Desktop'   { [Environment]::GetFolderPath('Desktop') }
        'Documents' { [Environment]::GetFolderPath('MyDocuments') }
        'Pictures'  { [Environment]::GetFolderPath('MyPictures') }
        'Videos'    { [Environment]::GetFolderPath('MyVideos') }
        'Music'     { [Environment]::GetFolderPath('MyMusic') }
        'Downloads' {
            $p = $null
            try { $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
            if ($p) { $p } else { Join-Path $script:NewProfile 'Downloads' }
        }
    }
}

# =============================================================================
# winget reinstall: one separate winget process per app, each with its own log, so one crash or hang
# cannot stop the rest. Up to $WingetParallel run at once; apps that failed are retried once, one at a time
# (parallel installs can collide on the Windows Installer lock). Logs: <LogDir>\winget\<app id>.log
# =============================================================================
# Reads one app's winget output (stdout + stderr files) and says what happened and why, in plain words.
# Returns Ok, Retry (worth trying again) and Reason. Order matters: the most specific causes come first.
function Get-WingetOutcome {
    param($Code, [string]$LogFile, [bool]$TimedOut)
    $text = ''
    foreach ($f in @($LogFile, "$LogFile.err")) { if ($f -and (Test-Path -LiteralPath $f)) { try { $text += (Get-Content -LiteralPath $f -Raw -ErrorAction Stop) + "`n" } catch {} } }
    # winget redraws spinners and progress bars; keep only the lines a person would read
    $lines = @($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^[\s\-\\|/]+$' -and $_ -notmatch ('[' + [char]0x2588 + [char]0x2592 + ']') -and $_ -notmatch '^\d+(\.\d+)?\s*[KMG]B\s*/' })
    $tail = @($lines | Select-Object -Last 3)
    $hex = if ($null -ne $Code) { '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Code), 0) } else { 'unknown' }
    $r = @{ Ok = $false; Retry = $false; Reason = ''; Tail = $tail; Hex = $hex }
    if ($TimedOut)                                        { $r.Reason = 'timed out and was stopped - it was most likely waiting on a prompt (source or package agreement) or a hung installer'; return $r }
    if ($text -match '(?i)successfully installed')         { $r.Ok = $true; $r.Reason = 'installed'; return $r }
    if ($text -match '(?i)already installed|no available upgrade|no newer package versions|existing package already installed') { $r.Ok = $true; $r.Reason = 'already installed on this PC'; return $r }
    if ($Code -eq 0)                                      { $r.Ok = $true; $r.Reason = 'installed'; return $r }
    if ($text -match '(?i)hash does not match')            { $r.Reason = "the vendor's installer no longer matches winget's checksum (the package is out of date and cannot be overridden as admin) - install it from the vendor's site"; return $r }
    if ($text -match '(?i)no package found|no installed package found') { $r.Reason = 'winget has no package with this id any more'; return $r }
    if ($text -match '(?i)agreements?.*(accept|required)|do you agree|\[Y\] Yes|\(Y/N\)') { $r.Reason = 'winget wanted an agreement to be accepted'; $r.Retry = $true; return $r }
    if ($text -match '(?i)another installation is already in progress|1618') { $r.Reason = 'Windows Installer was busy with another install'; $r.Retry = $true; return $r }
    if ($text -match '(?i)installer failed with exit code:\s*(\d+)') { $r.Reason = "the app's own installer failed (installer exit code $($Matches[1]))"; $r.Retry = $true; return $r }
    if ($text -match '(?i)download.*(fail|error)|failed when|could not connect|network|timed? ?out|0x8a150008') { $r.Reason = 'the download failed (network or the vendor server)'; $r.Retry = $true; return $r }
    if ($text -match '(?i)requires.*(restart|reboot)|reboot')  { $r.Ok = $true; $r.Reason = 'installed - a restart is needed to finish'; return $r }
    $r.Reason = "winget failed with code $hex"; $r.Retry = $true
    return $r
}

function Install-WingetApps {
    param([string]$ListFile, [int]$Parallel = 3, [int]$TimeoutMin = 15)
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) { throw 'winget not found' }
    $apps = @()
    try {
        $j = Get-Content -LiteralPath $ListFile -Raw | ConvertFrom-Json
        foreach ($s in @($j.Sources)) { foreach ($p in @($s.Packages)) { if ($p.PackageIdentifier) { $apps += [pscustomobject]@{ Id = [string]$p.PackageIdentifier; Source = [string]$s.SourceDetails.Name } } } }
    } catch { throw "Could not read the winget list ${ListFile}: $($_.Exception.Message)" }
    $apps = @($apps | Sort-Object Id -Unique)
    if ($apps.Count -eq 0) { Write-Warn 'The winget list is empty.'; return @() }

    $wgLog = Join-Path $script:LogDir 'winget'
    try { New-Item -ItemType Directory -Force $wgLog | Out-Null } catch { Write-Warn "Could not create $wgLog ($($_.Exception.Message)); winget output will not be saved." ; $wgLog = $null }
    # Accept the source agreements once, up front, so no install sits waiting on that prompt.
    try { [void](Invoke-Native $winget @('source', 'update', '--accept-source-agreements', '--disable-interactivity')) } catch {}

    $start = {
        param($app)
        $safe = ($app.Id -replace '[^\w.\-]', '_')
        $wargs = @('install', '--id', $app.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($app.Source) { $wargs += @('--source', $app.Source) }
        $o = @{ FilePath = $winget; ArgumentList = $wargs; PassThru = $true; WindowStyle = 'Hidden' }
        $app | Add-Member -NotePropertyName Log -NotePropertyValue $null -Force
        if ($wgLog) {
            $app.Log = Join-Path $wgLog ('{0}-{1}.log' -f $safe, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
            $o.RedirectStandardOutput = $app.Log; $o.RedirectStandardError = "$($app.Log).err"
        }
        try {
            $p = Start-Process @o
            $null = $p.Handle          # keep the process handle: without it ExitCode comes back empty once the process has ended
            $app | Add-Member -NotePropertyName Proc -NotePropertyValue $p -Force
            $app | Add-Member -NotePropertyName StartError -NotePropertyValue $null -Force
        } catch {
            $app | Add-Member -NotePropertyName Proc -NotePropertyValue $null -Force
            $app | Add-Member -NotePropertyName StartError -NotePropertyValue $_.Exception.Message -Force
        }
    }

    $results = @{}
    function Wait-Batch([object[]]$Running) {
        foreach ($a in $Running) {
            if (-not $a.Proc) { $results[$a.Id] = @{ Ok = $false; Retry = $false; Reason = "could not start winget: $($a.StartError)"; Tail = @(); Hex = 'n/a'; Log = $a.Log }; continue }
            $timedOut = -not $a.Proc.WaitForExit($TimeoutMin * 60000)
            if ($timedOut) { try { Stop-Process -Id $a.Proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
            else { try { $a.Proc.WaitForExit(); $a.Proc.Refresh() } catch {} }
            $code = if ($timedOut) { $null } else { try { $a.Proc.ExitCode } catch { $null } }
            $o = Get-WingetOutcome -Code $code -LogFile $a.Log -TimedOut $timedOut
            $o.Log = $a.Log; $o.Code = $code
            $results[$a.Id] = $o
        }
    }
    # What the person sees for each app: the cause in words, plus winget's own last lines when it failed.
    function Show-Outcome($a, [string]$Prefix = '') {
        $r = $results[$a.Id]
        Write-Host ('        {0}{1}: {2}' -f $Prefix, $a.Id, $r.Reason) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Yellow' })
        if (-not $r.Ok) {
            foreach ($l in $r.Tail) { Write-Host ('            winget: {0}' -f $l) -ForegroundColor DarkGray }
            if ($r.Log) { Write-Host ('            log: {0}' -f $r.Log) -ForegroundColor DarkGray }
        }
    }

    Write-Step ("Installing {0} app(s) with winget, up to {1} at a time, one separate process each. Logs: {2}" -f $apps.Count, $Parallel, $(if ($wgLog) { $wgLog } else { '(not saved)' }))
    $i = 0
    for ($off = 0; $off -lt $apps.Count; $off += $Parallel) {
        $batch = @($apps[$off..([Math]::Min($off + $Parallel, $apps.Count) - 1)])
        foreach ($a in $batch) { $i++; Write-Host ('    [{0}/{1}] {2}' -f $i, $apps.Count, $a.Id) -ForegroundColor Gray; & $start $a }
        Wait-Batch $batch
        foreach ($a in $batch) { Show-Outcome $a }
    }
    # Only causes that can change are retried (installer busy, network, prompt). A checksum mismatch or a missing package will not.
    $retry = @($apps | Where-Object { $r = $results[$_.Id]; -not $r.Ok -and $r.Retry })
    if ($retry.Count -gt 0) {
        Write-Step ("Retrying {0} app(s) that failed for a reason that may be temporary, one at a time" -f $retry.Count)
        foreach ($a in $retry) { & $start $a; Wait-Batch @($a); Show-Outcome $a 'retry: ' }
    }
    return @($apps | ForEach-Object { $r = $results[$_.Id]; [pscustomobject]@{ Id = $_.Id; Ok = [bool]$r.Ok; Note = $r.Reason; Log = $r.Log } })
}

function Mark([int]$Rank, [string]$Text) {
    if ($Rank -gt $script:Rank) { $script:Rank = $Rank }
    if ($Text) { [void]$script:Notes.Add($Text) }
}

# Connect to the old PC's admin share. The password never goes on a command line.
# Tries the user name as typed, then the forms Windows usually wants (IP\user, MicrosoftAccount\email).
function Connect-OldPC([string]$Share, [pscredential]$Cred) {
    $u = $Cred.UserName
    if ($u -match '\\')  { $names = @($u) }
    elseif ($u -match '@') { $names = @($u, "MicrosoftAccount\$u") }
    else { $names = @("$($script:IP)\$u", $u) }
    $plain = $Cred.GetNetworkCredential().Password
    $errs = @()
    Disconnect-OldPC $Share
    foreach ($n in $names) {
        try {
            New-SmbMapping -RemotePath $Share -UserName $n -Password $plain -Persistent $false -ErrorAction Stop | Out-Null
            $script:Conn = 'smb'; return $n
        } catch { $errs += "$n => $($_.Exception.Message.Trim())" }
        try {
            $c = New-Object System.Management.Automation.PSCredential($n, $Cred.Password)
            New-PSDrive -Name WTT -PSProvider FileSystem -Root $Share -Credential $c -Scope Script -ErrorAction Stop | Out-Null
            $script:Conn = 'psdrive'; return $n
        } catch { $errs += "$n => $($_.Exception.Message.Trim())" }
    }
    throw ("Could not sign in to {0}.`n  {1}" -f $Share, ($errs -join "`n  "))
}
function Disconnect-OldPC([string]$Share) {
    Remove-PSDrive -Name WTT -Scope Script -Force -ErrorAction SilentlyContinue
    Remove-SmbMapping -RemotePath $Share -Force -ErrorAction SilentlyContinue
}

# What does the old PC offer? Ftps or Ftp if its service port answers, otherwise the SMB admin share.
function Resolve-DestTransport {
    if ($Transport -ne 'Auto') { return $Transport }
    Import-WttFtp
    Write-Step "Looking for the old PC's FTP service on port $FtpPort"
    $found = [Wtt.FtpClient]::Probe($script:IP, $FtpPort)
    if ($found) { return $found }
    Write-Host '    No FTP service answered; trying the SMB admin share instead.' -ForegroundColor DarkGray
    return 'Smb'
}

# FTP / FTPS counterpart of Connect-OldPC. With FTPS the certificate is checked BEFORE any password is sent:
# either against -Fingerprint, or by showing it so you can compare it with the old PC's screen. From then on
# only that exact certificate is accepted. Keeps the connection details in $script:FtpConn.
function Connect-OldPCFtp([string]$Mode) {
    Import-WttFtp
    $tls = ($Mode -eq 'Ftps')
    $given = if ($Fingerprint) { ($Fingerprint -replace '[^0-9A-Fa-f]', '') } else { $null }
    if ($Fingerprint -and $given.Length -lt 32) { throw '-Fingerprint needs at least the first 32 hex digits (as shown on the old PC).' }
    $pin = $null
    if ($tls) {
        $probe = New-Object Wtt.FtpClient $script:IP, $FtpPort, $true, $given
        try { $probe.Connect() }
        catch { throw ("Cannot set up a secure connection to {0}:{1} - {2}`n  Same network? Is the old PC waiting in stage S4? Is port {1} the one it shows (-FtpPort)?" -f $script:IP, $FtpPort, $_.Exception.Message) }
        finally { $probe.Dispose() }
        $fp = $probe.Fingerprint
        $shown = Format-Fingerprint $fp
        if ($given) {
            Write-Ok "Certificate matches the fingerprint you gave ($shown)"
            $pin = $given
        } else {
            Write-Host ''
            Write-Host "  Certificate fingerprint presented by $($script:IP):  $shown" -ForegroundColor Green
            Write-Host '  It must be identical to the Fingerprint line on the OLD PC screen. If it is not, something else is answering on that address.' -ForegroundColor Yellow
            if ((Read-Host '  Does it match? (y/N)') -notmatch '^y') { throw 'Fingerprint not confirmed. Nothing was sent to that server.' }
            $pin = $fp          # from here on only this exact certificate is accepted
        }
    } else {
        Write-Warn 'Plain FTP: the password and all your files cross the network unencrypted.'
    }

    $sec = Read-Host '  Password shown on the OLD PC' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $typed = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $conn = New-Object Wtt.FtpConn
    $conn.Host = $script:IP; $conn.Port = $FtpPort; $conn.Tls = $tls; $conn.Pin = $pin
    $conn.User = $FtpUser; $conn.Pass = (ConvertFrom-TypedFtpPassword $typed)
    try { $c = $conn.Open(); $c.Dispose() }
    catch { throw ("Could not sign in to the old PC: {0}" -f $_.Exception.Message) }
    $script:FtpConn = $conn
}

function Send-FtpMarker([string]$Name, $Data) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json))
    $c = $script:FtpConn.Open()
    try { $c.Upload("/pkg/$Name", $bytes) } finally { $c.Dispose() }
}

# Path of a profile-relative folder as the old PC's service names it.
function Get-RemoteProfilePath([string]$Rel) {
    if ($Rel -eq '.') { return '/profile' }
    return ('/profile/' + ($Rel -replace '\\', '/').Trim('/'))
}

# Checks the pairing code against pair.json on the old PC. Returns the pair record, or $null if the export has none.
function Confirm-Pairing {
    $pf = "$script:Pkg\pair.json"
    if (-not (Test-Path -LiteralPath $pf)) { Write-Warn 'The old PC export has no pairing info (older tool version); continuing without binding.'; return $null }
    $pair = Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json
    $code = $PairCode
    for ($try = 1; $try -le 3; $try++) {
        if (-not $code) { $code = Read-Host 'Pairing code shown on the OLD PC (6 digits)' }
        $code = ($code -replace '\D', '')
        if ((Get-PairHash $pair.Salt $code) -eq $pair.PairHash) { return $pair }
        if ($PairCode) { throw 'The -PairCode does not match the code shown on the old PC.' }
        Write-Warn 'That code does not match. Check the old PC window and try again.'
        $code = $null
    }
    throw 'Pairing failed three times. Make sure you are connecting to the right PC.'
}

function Write-Marker([string]$Name, $Data) {
    try {
        if ($script:Transport -eq 'Smb') { $Data | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Pkg $Name) -Encoding UTF8 }
        elseif ($script:Transport -eq 'Drive') { }          # nobody is waiting on the other side of a carried drive
        else { Send-FtpMarker $Name $Data }
        return $true
    }
    catch { Write-Warn "Could not write $Name to the old PC ($($_.Exception.Message))."; return $false }
}

# robocopy with live progress. Returns exit code, or -1 if the source is missing.
function Invoke-Robo {
    param([string]$Src, [string]$Dst, [string[]]$Files, [string[]]$XD, [string]$Label)
    if (-not (Test-Path -LiteralPath $Src)) { return -1 }
    $a = @(('"{0}"' -f $Src.TrimEnd('\')), ('"{0}"' -f $Dst.TrimEnd('\')))
    if ($Files) { $a += ($Files | ForEach-Object { '"{0}"' -f $_ }) } else { $a += '/E'; $a += '/XF'; $a += 'desktop.ini'; $a += 'Thumbs.db' }
    # /XO: never overwrite a file on the new PC that is newer than the old PC's copy
    $a += '/COPY:DAT','/DCOPY:DAT',"/MT:$Threads",'/R:2','/W:3','/XJ','/XO','/NP','/NDL',('/LOG+:"{0}"' -f $script:RoboLog)
    if ($XD) { $a += '/XD'; $a += ($XD | ForEach-Object { '"{0}"' -f $_ }) }
    if ($DryRun) { $a += '/L' }
    if ($script:RoboFat) { $a += '/FFT' }          # FAT and exFAT drives keep file times with 2 s resolution; without this every run would copy again
    $p = Start-Process robocopy -ArgumentList ($a -join ' ') -PassThru -WindowStyle Hidden
    $null = $p.Handle
    while (-not $p.HasExited) {
        $tail = ''
        try { $tail = (Get-Content -LiteralPath $script:RoboLog -Tail 1 -ErrorAction Stop | Out-String).Trim() } catch {}
        if (-not $tail) { $tail = 'working...' }       # Write-Progress rejects an empty -Status, and robocopy's log starts with blank lines
        Write-Progress -Activity "Copying: $Label" -Status $tail
        Start-Sleep -Milliseconds 400
    }
    $p.WaitForExit()
    Write-Progress -Activity "Copying: $Label" -Completed
    return $p.ExitCode
}

# FTP / FTPS counterpart of Invoke-Robo: mirror a folder (or a few named files) from the old PC, with progress.
# Same rules as robocopy /E /XO: junctions are never followed, newer files on this PC are kept.
# Returns the finished job (Missing, Copied, Skipped, Failed, Errors).
function Invoke-FtpCopy {
    param([string]$Remote, [string]$Dst, [string[]]$Files, [string[]]$XD, [string]$Label, [switch]$IgnoreDryRun)
    $xf = $null; if (-not $Files) { $xf = [string[]]@('desktop.ini', 'Thumbs.db') }
    $dry = [bool]($DryRun -and -not $IgnoreDryRun)        # the export package itself is always fetched, even in a dry run
    $job = [Wtt.FtpMirror]::Start($script:FtpConn, $Remote, $Dst, $Files, $XD, $xf, [Math]::Min($Threads, 8), $dry)
    while (-not $job.Done) {
        $status = '{0} of {1} files, {2:N0} of {3:N0} MB' -f $job.Copied, $job.FilesTotal, ($job.BytesDone / 1MB), ($job.BytesTotal / 1MB)
        $pct = 0; if ($job.BytesTotal -gt 0) { $pct = [Math]::Min(100, [int](100 * $job.BytesDone / $job.BytesTotal)) }
        Write-Progress -Activity "Copying: $Label" -Status $status -PercentComplete $pct
        Start-Sleep -Milliseconds 400
    }
    Write-Progress -Activity "Copying: $Label" -Completed
    if ($job.Fatal) { throw $job.Fatal }
    if ($script:RoboLog) {
        $lines = @('{0}  {1}: {2} copied, {3} skipped, {4} failed' -f (Get-Date -Format 's'), $Remote, $job.Copied, $job.Skipped, $job.Failed)
        foreach ($e in @($job.Errors)) { $lines += "    $e" }
        Add-Content -LiteralPath $script:RoboLog -Value $lines
    }
    return $job
}

function Copy-Spec {
    param([string]$SrcPath, [string]$DstPath, [string[]]$Files, [string[]]$XD, [string]$Label, [string]$RemotePath)
    if (Test-FtpTransport) {
        $j = Invoke-FtpCopy -Remote $RemotePath -Dst $DstPath -Files $Files -XD $XD -Label $Label
        if ($j.Missing) { Mark 0 "$Label not on old PC (skipped)"; return }
        if ($j.Failed -gt 0) { Mark 2 ('{0}: {1} file(s) failed (see log)' -f $Label, $j.Failed); return }
        $script:DidWork = $true
        return
    }
    $rc = Invoke-Robo -Src $SrcPath -Dst $DstPath -Files $Files -XD $XD -Label $Label
    if ($rc -eq -1) { Mark 0 "$Label not on old PC (skipped)"; return }
    if ($rc -ge 8)  { Mark 2 "$Label had copy errors (see log)"; return }
    $script:DidWork = $true
}

# Explorer owns the taskbar/Start/desktop settings and rewrites them on exit, so it must be
# dead while those keys are imported. Windows may auto-restart it, hence the re-check before each import.
function Stop-Shell {
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { $script:ShellStopped = $true; return }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    $t = 0
    while ((Get-Process explorer -ErrorAction SilentlyContinue) -and $t -lt 20) { Start-Sleep -Milliseconds 250; $t++ }
    $script:ShellStopped = $true
}
function Start-Shell {
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    $t = 0
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and $t -lt 40) { Start-Sleep -Milliseconds 250; $t++ }
    $script:ShellStopped = $false
}

function Import-RegItem {
    param($Item)
    $dir = Join-Path "$script:Pkg\reg" $Item.Key
    if (-not (Test-Path $dir)) { Mark 0 'no registry data exported'; return }
    if ($DryRun) { Mark 0 'dry run: registry not changed'; $script:DidWork = $true; return }
    if ($Item.Explorer) { Stop-Shell }

    # Backup what is there now so changes can be undone
    $bk = Join-Path $script:BackupDir $Item.Key; New-Item -ItemType Directory -Force $bk | Out-Null
    $n = 0
    foreach ($k in $Item.Reg) { $n++; [void](Invoke-Native reg @('export', $k, ('{0}\{1:D2}.reg' -f $bk, $n), '/y')) }

    # Rewrite the old profile path (C:\\Users\\Old in .reg escaping) to the new one. Text values only;
    # hex(2)/binary values are left alone (see docs/caveats.md). The lookahead stops "Bob" matching "Bobby".
    $rxOld = [regex]::Escape($script:OldProfile.Replace('\', '\\')) + '(?=\\\\|[";]|$)'
    $newEsc = $script:NewProfile.Replace('\', '\\')
    foreach ($f in (Get-ChildItem $dir -Filter *.reg | Sort-Object Name)) {
        $lines = Get-Content -LiteralPath $f.FullName -Encoding Unicode
        $lines = $lines | ForEach-Object { $_ -replace $rxOld, $newEsc }
        if ($Item.Drop) { $lines = $lines | Where-Object { $_ -notmatch $Item.Drop } }
        $tmp = Join-Path $env:TEMP ('mig_{0}.reg' -f [guid]::NewGuid().ToString('N'))
        $lines | Set-Content -LiteralPath $tmp -Encoding Unicode
        $rc = Invoke-Native reg @('import', $tmp)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($rc -ne 0) { Mark 2 "registry import of $($f.Name) failed" } else { $script:DidWork = $true }
    }
}

function Set-Wallpaper([string]$Path) {
    if (-not ('MigWall' -as [type])) {
        Add-Type -Namespace '' -Name 'MigWall' -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern int SystemParametersInfo(int a, int b, string c, int d);' | Out-Null
    }
    [void][MigWall]::SystemParametersInfo(20, 0, $Path, 3)
}

function Invoke-Special {
    param($Item)
    switch ($Item.Key) {
        'a_winget' {
            if (Test-Path "$script:Pkg\apps-report.csv") {
                $rep = Join-Path $script:ReportDir 'old-pc-installed-apps.csv'
                if (-not $DryRun) { Copy-Item "$script:Pkg\apps-report.csv" $rep -Force }
                Write-Host "    App list for manual follow-up: $rep" -ForegroundColor Gray
            }
            if (-not (Test-Path "$script:Pkg\apps.json")) { Mark 1 'no winget list exported from old PC'; return }
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Mark 2 'winget not available on this PC'; return }
            if ($DryRun) { Mark 0 'dry run: no apps installed'; $script:DidWork = $true; return }
            try {
                $wg = @(Install-WingetApps -ListFile "$script:Pkg\apps.json")
                $bad = @($wg | Where-Object { -not $_.Ok })
                if ($wg.Count -gt 0) { $script:DidWork = $true }
                if ($bad.Count -gt 0) {
                    Mark 2 ("{0} of {1} app(s) not installed: {2}. Logs: {3}\winget" -f $bad.Count, $wg.Count, (($bad | ForEach-Object { '{0} ({1})' -f $_.Id, $_.Note }) -join '; '), $script:LogDir)
                }
            } catch { Mark 2 "winget step failed: $($_.Exception.Message). See the debug log in $script:LogDir" }
        }
        'd_vscode' {
            $f = "$script:Pkg\vscode-extensions.txt"
            if (-not (Test-Path $f) -or $DryRun) { return }
            $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
            if (-not (Get-Command code -ErrorAction SilentlyContinue)) { Mark 2 'VS Code not installed yet - install it, then run this item again for extensions'; return }
            foreach ($e in (Get-Content $f | Where-Object { $_ })) { [void](Invoke-Native cmd @('/c', "code --install-extension `"$e`" --force")) }
            $script:DidWork = $true
        }
        's_appear' {
            # Prefer the copy in the export; fall back to the original path on the old PC.
            $src = $null
            if ($script:Manifest.WallpaperFile) { $c = Join-Path $script:Pkg $script:Manifest.WallpaperFile; if (Test-Path -LiteralPath $c) { $src = $c } }
            if (-not $src -and $script:Transport -eq 'Smb' -and $script:Manifest.Wallpaper) { $c = ConvertTo-Unc $script:Manifest.Wallpaper; if ($c -and (Test-Path -LiteralPath $c)) { $src = $c } }
            if (-not $src) { Mark 0 'wallpaper file not found (skipped)'; return }
            if ($DryRun) { Mark 0 'dry run: wallpaper not changed'; $script:DidWork = $true; return }
            $dstDir = Join-Path $script:NewProfile 'Pictures\Wallpaper'; New-Item -ItemType Directory -Force $dstDir | Out-Null
            $name = if ($script:Manifest.Wallpaper) { [IO.Path]::GetFileName($script:Manifest.Wallpaper) } else { 'wallpaper' }
            $dst = Join-Path $dstDir $name
            if (-not [IO.Path]::GetExtension($dst)) { $dst += [IO.Path]::GetExtension($src) }
            if (-not [IO.Path]::GetExtension($dst)) { $dst += '.jpg' }
            Copy-Item -LiteralPath $src $dst -Force
            $script:PendingWallpaper = $dst      # applied after Explorer is back (D6 end)
            $script:DidWork = $true
        }
        's_wifi' {
            $xmls = @(Get-ChildItem "$script:Pkg\wifi" -Filter *.xml -ErrorAction SilentlyContinue)
            if (-not $xmls) { Mark 1 'no Wi-Fi profiles exported'; return }
            if ($DryRun) { Mark 0 "dry run: $($xmls.Count) profiles found"; $script:DidWork = $true; return }
            $okc = 0
            foreach ($x in $xmls) { if ((Invoke-Native netsh @('wlan','add','profile',"filename=$($x.FullName)",'user=all')) -eq 0) { $okc++ } }
            Mark 0 "$okc of $($xmls.Count) Wi-Fi profiles added"; $script:DidWork = $true
        }
        's_power' {
            $pow = "$script:Pkg\power.pow"
            if (-not (Test-Path $pow)) { Mark 1 'no power plan exported'; return }
            if ($DryRun) { $script:DidWork = $true; return }
            $out = powercfg /import $pow 2>&1 | Out-String
            if ($out -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { [void](Invoke-Native powercfg @('/setactive', $Matches[1])); $script:DidWork = $true }
            else { Mark 2 'power plan import failed' }
        }
    }
}

# Runs one catalog item and returns a result row.
function Invoke-CatalogItem($it) {
    Write-Step $it.Label
    $script:Rank = 0; $script:DidWork = $false; $script:Notes = New-Object System.Collections.ArrayList
    try {
        if ($it.Kill -and -not $DryRun) { $it.Kill | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue } }
        if ($it.Known) {
            if (Test-FtpTransport) {
                Copy-Spec -RemotePath "/known-$($it.Known)" -DstPath (Get-TargetKnown $it.Known) -Label $it.Label
            } elseif ($script:Transport -eq 'Drive') {
                Copy-Spec -SrcPath (Join-Path $script:DriveData "known-$($it.Known)") -DstPath (Get-TargetKnown $it.Known) -Label $it.Label
            } else {
                $srcPath = ConvertTo-Unc $script:Manifest.KnownFolders.($it.Known)
                if (-not $srcPath) { Mark 2 'folder is not on a local drive of the old PC' }
                else { Copy-Spec -SrcPath $srcPath -DstPath (Get-TargetKnown $it.Known) -Label $it.Label }
            }
        }
        foreach ($c in @($it.Copies)) {
            if (-not $c) { continue }
            $dstRel = if ($c.Dst) { $c.Dst } else { $c.Src }
            $copySrc = $null
            if ($script:Transport -eq 'Smb') { $copySrc = Join-Rel $script:OldProfileUnc $c.Src }
            elseif ($script:Transport -eq 'Drive') { $copySrc = Join-Rel (Join-Path $script:DriveData 'profile') $c.Src }
            Copy-Spec -SrcPath $copySrc -RemotePath (Get-RemoteProfilePath $c.Src) `
                -DstPath (Join-Rel $script:NewProfile $dstRel) -Files $c.Files -XD $c.XD -Label $c.Src
        }
        if ($it.Reg) { Import-RegItem $it }
        Invoke-Special $it
    } catch { Mark 3 $_.Exception.Message }

    $status = switch ($script:Rank) { 0 { if ($script:DidWork) { 'OK' } else { 'SKIPPED' } } 1 { 'SKIPPED' } 2 { 'WARN' } default { 'FAILED' } }
    $color = switch ($status) { 'OK' { 'Green' } 'SKIPPED' { 'DarkGray' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('    {0} {1}' -f $status, ($script:Notes -join '; ')) -ForegroundColor $color
    return [pscustomobject]@{ Stage = $it.Stage; Item = $it.Label; Status = $status; Notes = ($script:Notes -join '; ') }
}

# Orders selected items by stage; inside Settings, items that need Explorer stopped go last.
function Get-StagedPlan($Keys) {
    $plan = @()
    foreach ($st in $StageNames) {
        foreach ($needsExplorer in $false, $true) {
            $plan += @($Catalog | Where-Object { $Keys -contains $_.Key -and $_.Stage -eq $st -and ([bool]$_.Explorer) -eq $needsExplorer })
        }
    }
    return $plan
}

function Start-DestinationMode {
    Write-Stage 'D1' 'Preflight (new PC)'
    if (-not (Test-Admin)) { Write-Warn 'Not elevated. Wi-Fi import, app installs and some settings need an administrator PowerShell.' }
    Assert-SignedInUser
    Set-KeepAwake $true
    $script:NewProfile = $env:USERPROFILE
    $script:ShellStopped = $false; $script:PendingWallpaper = $null
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Warn 'winget not found; the app reinstall item will be skipped (install "App Installer" from the Microsoft Store).' }
    Write-Host ("Receiving into profile '{0}' ({1})" -f $env:USERNAME, $script:NewProfile) -ForegroundColor White
    Write-Ok 'Preflight passed.'

    $script:FtpConn = $null; $script:Staging = $null; $script:IP = $null
    $share = $null; $cred = $null; $fromFile = $false
    # Note: $script:Transport IS the -Transport parameter (same variable), so only overwrite it once something is decided.
    if (Resolve-DriveChoice) { $script:Transport = 'Drive' }

    if ($script:Transport -eq 'Drive') {
        Write-Stage 'D2' 'Find the transfer drive'
        Connect-TransferDrive
    } else {
        Write-Stage 'D2' 'Bind to the old PC'
        $saved = Read-CredentialFile -Path $CredentialFile
        $script:IP = if ($OldPCIP) { $OldPCIP } elseif ($saved -and $saved.IP) { $saved.IP } else { Read-Host 'IP address of the OLD PC (shown by the old PC in stage S4)' }
        $script:Transport = Resolve-DestTransport

        if ($script:Transport -eq 'Smb') {
            if ($saved) { $cred = $saved.Cred; $fromFile = $true; Write-Ok "Using saved credentials from $CredentialFile" }
            if (-not (Test-Connection $script:IP -Count 1 -Quiet)) { throw "Cannot reach $($script:IP). Same network? Is the old PC waiting in stage S4?" }
            if (-not $cred) { $cred = Get-Credential -Message "Sign-in for the OLD PC ($($script:IP)). Use the temporary account and password shown on the OLD PC's screen in stage S4 - not your Microsoft account (unless the old PC was run with -UseOwnAccount)." }

            $share = "\\$($script:IP)\C$"
            try { $usedName = Connect-OldPC -Share $share -Cred $cred }
            catch {
                $hint = if ($fromFile) { " Saved credentials may be outdated - delete $CredentialFile and retry." } else { '' }
                throw "$($_.Exception.Message)$hint"
            }
            Write-Ok "Connected to $share as $usedName"
        } else {
            Connect-OldPCFtp $script:Transport
            Write-Ok ('Connected to {0}:{1} over {2}' -f $script:IP, $FtpPort, $script:Transport.ToUpper())
        }
    }

    $results = @()
    try {
        if ($script:Transport -eq 'Drive') {
            # Connect-TransferDrive already pointed Pkg at the package on the drive.
        } elseif ($script:Transport -eq 'Smb') {
            $script:Pkg = "$share\MigrationExport"
            if (-not (Test-Path "$script:Pkg\manifest.json")) { throw "No export found at $script:Pkg. Run the tool on the old PC first (it must be waiting in stage S4)." }
        } else {
            # The export package (settings, app list, pairing info) is small: fetch it into a private temporary folder.
            # Personal files are copied later, straight into their final place. The folder is deleted in the finally block.
            $script:Staging = Join-Path ([IO.Path]::GetTempPath()) ('wtt-' + [guid]::NewGuid().ToString('N'))
            $script:Pkg = Join-Path $script:Staging 'pkg'
            Write-Step 'Fetching the export package'
            $j = Invoke-FtpCopy -Remote '/pkg' -Dst $script:Pkg -Label 'export package' -IgnoreDryRun
            if ($j.Missing -or $j.Failed -gt 0 -or -not (Test-Path "$script:Pkg\manifest.json")) {
                throw ("The old PC has no usable export. Run the tool on the old PC first (it must be waiting in stage S4). {0}" -f (@($j.Errors) -join '; '))
            }
        }
        $script:Manifest = Get-Content "$script:Pkg\manifest.json" -Raw | ConvertFrom-Json
        $script:OldProfile = $script:Manifest.Profile
        $script:OldProfileUnc = if ($script:Transport -eq 'Smb') { ConvertTo-Unc $script:OldProfile } else { $null }
        Write-Ok ('Found export from {0} - user {1} - {2}' -f $script:Manifest.ComputerName, $script:Manifest.UserName, $script:Manifest.OS)

        $pair = $null
        if ($script:Transport -ne 'Drive') { $pair = Confirm-Pairing }       # a carried drive needs no pairing: you are holding the proof
        if ($pair) {
            $ok = Write-Marker 'bound.json' ([ordered]@{
                SessionId = $pair.SessionId; ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME
                IPs = @(Get-IPv4Addresses | ForEach-Object { $_.IPAddress }); BoundAt = (Get-Date).ToString('s'); ToolVersion = $ToolVersion })
            if ($ok) { Write-Ok ('Bound: {0} <-> {1}. The old PC now accepts connections from this PC only.' -f $script:Manifest.ComputerName, $env:COMPUTERNAME) }
        }
        if ($script:Transport -ne 'Smb') {
            # Nothing to save: the FTP password is random per run and stops working when the old PC cleans up.
        } elseif ($cred.UserName -match '^(.*\\)?WTT-[0-9a-f]{8}$') {
            Write-Host 'Not offering to save credentials: this is a one-time temporary account, deleted on the old PC when the transfer finishes.' -ForegroundColor DarkGray
        } elseif (-not $fromFile -and -not $NoSave -and -not $Select -and -not $Yes) {
            if ((Read-Host "Save these credentials to $CredentialFile for next time? Password is encrypted for this user/PC only (y/N)") -match '^y') {
                New-CredentialFile -Path $CredentialFile -IP $script:IP -Cred $cred
                Write-Ok 'Saved (git-ignored).'
            }
        }

        Write-Stage 'D3' 'Select what to transfer'
        $menuItems = @(if ($script:Transport -eq 'Drive') { Get-DriveMenuItems } else { $Catalog })
        if ($Select) {
            $keys = if ($Select -contains 'All') { @($menuItems | ForEach-Object { $_.Key }) } else { $Select }
        } else {
            Start-Sleep -Milliseconds 800
            $keys = Show-Menu -Items $menuItems
        }
        if (-not $keys -or $keys.Count -eq 0) { Write-Host 'Nothing selected. Bye.'; return }
        $plan = Get-StagedPlan $keys
        $bad = @($keys | Where-Object { $k = $_; -not ($Catalog | Where-Object { $_.Key -eq $k }) })
        if ($bad.Count -gt 0) { Write-Warn ("Unknown item key(s) ignored: {0}" -f ($bad -join ', ')) }

        Write-Host ''
        Write-Host "Plan ($($plan.Count) items):" -ForegroundColor White
        $codes = @{ Files = 'D4'; Apps = 'D5'; Settings = 'D6' }
        foreach ($st in $StageNames) {
            $in = @($plan | Where-Object { $_.Stage -eq $st })
            if ($in.Count -eq 0) { continue }
            Write-Host ("  {0} {1}" -f $codes[$st], $st) -ForegroundColor Cyan
            foreach ($it in $in) { Write-Host ("     - {0}{1}" -f $it.Label, $(if ($it.Explorer) { '  [Explorer restarts]' } else { '' })) }
        }
        $warns = @()
        foreach ($it in ($plan | Where-Object { $_.Known })) {
            $srcK = $script:Manifest.KnownFolders.($it.Known); $dstK = Get-TargetKnown $it.Known
            if ((Test-OneDrivePath $srcK) -and (Test-OneDrivePath $dstK)) { $warns += "$($it.Label) is inside OneDrive on BOTH PCs. If it is the same OneDrive account, untick it and let OneDrive sync (avoids duplicates and placeholder downloads)." }
            elseif (Test-OneDrivePath $dstK) { $warns += "$($it.Label) on this PC is inside OneDrive; everything copied there will upload to the cloud." }
        }
        if ($plan | Where-Object { $_.Key -eq 'd_dev' }) { $warns += "Developer config copies private keys (.ssh, .aws, ...)$(if ($script:Transport -eq 'Drive') { ' from the drive' } else { ' over the network' })." }
        if ($plan | Where-Object { $_.Key -eq 'a_winget' }) { $warns += 'App reinstall can take a long time and may show installer windows.' }
        if ($script:Manifest.UserName -ne $env:USERNAME) { $warns += "User names differ ($($script:Manifest.UserName) -> $env:USERNAME): taskbar pins and the user Path variable may still point at the old profile (docs/caveats.md)." }
        if ($warns.Count -gt 0) { Write-Host ''; foreach ($w in $warns) { Write-Warn $w } }
        if ($DryRun) { Write-Warn 'DRY RUN - nothing will be changed.' }
        if (-not $Yes) { if ((Read-Host "`nProceed? (Y/n)") -match '^n') { return } }

        # ---- run ----
        $migDir = Join-Path $script:NewProfile 'Migration'
        $script:ReportDir = $migDir
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:BackupDir = Join-Path $migDir "registry-backup-$stamp"
        New-Item -ItemType Directory -Force $script:BackupDir | Out-Null
        $script:RoboLog = Join-Path $script:LogDir "robocopy-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"

        foreach ($st in $StageNames) {
            Write-Stage $codes[$st] $st
            $items = @($plan | Where-Object { $_.Stage -eq $st })
            if ($items.Count -eq 0) { Write-Host '    (nothing selected for this stage)' -ForegroundColor DarkGray; continue }
            foreach ($it in $items) {
                if ($it.Explorer -and -not $DryRun -and -not $script:ShellStopped) {
                    Write-Step 'Stopping Explorer while shell settings are applied (taskbar disappears for a moment)'
                    Stop-Shell
                }
                $results += Invoke-CatalogItem $it
            }
            if ($st -eq 'Settings' -and -not $DryRun) {
                if ($script:ShellStopped) { Write-Step 'Starting Explorer'; Start-Shell }
                if ($script:PendingWallpaper) { Start-Sleep -Seconds 2; Set-Wallpaper $script:PendingWallpaper; $script:PendingWallpaper = $null }
            }
        }

        Write-Stage 'D7' 'Finish'
        $results | Format-Table -Property Stage, Item, Status, Notes -AutoSize -Wrap | Out-Host
        $summary = ('{0} OK, {1} SKIPPED, {2} WARN, {3} FAILED' -f @($results | Where-Object Status -eq 'OK').Count, @($results | Where-Object Status -eq 'SKIPPED').Count, @($results | Where-Object Status -eq 'WARN').Count, @($results | Where-Object Status -eq 'FAILED').Count)
        Write-Host $summary -ForegroundColor White
        Write-Host "Registry backups and reports: $migDir" -ForegroundColor Gray
        Write-Host "Debug logs: $script:LogDir" -ForegroundColor Gray
        Write-Host 'Tip: install anything missing from the app list, then re-run with -Select s_taskbar to pin it.' -ForegroundColor Gray

        if ($DryRun) {
            if ($script:Transport -eq 'Drive') { Write-Host 'Dry run complete. Nothing was copied or changed; run again without -DryRun for the real transfer.' -ForegroundColor Gray }
            else { Write-Host 'Dry run complete. The old PC keeps waiting; run again without -DryRun for the real transfer.' -ForegroundColor Gray }
        } elseif ($script:Transport -eq 'Drive') {
            Invoke-ClearTransferDriveOffer        # the drive still holds your files and the old PC's Wi-Fi keys
        } elseif ($pair) {
            $finish = $Yes -or ((Read-Host 'Tell the old PC to clean up now? Answer n if you plan another pass (Y/n)') -notmatch '^n')
            if ($finish) {
                [void](Write-Marker 'done.json' ([ordered]@{ SessionId = $pair.SessionId; ComputerName = $env:COMPUTERNAME; FinishedAt = (Get-Date).ToString('s'); Summary = $summary }))
                Write-Ok 'Old PC notified; it reverts sharing and deletes the export.'
            } else { Write-Host 'The old PC keeps sharing until you press Enter there or run -Cleanup.' -ForegroundColor Gray }
        }
        if (-not $DryRun -and -not $Yes -and (Read-Host 'Sign out now so every setting takes effect? (y/N)') -match '^y') { shutdown /l }
    }
    finally {
        if ($script:ShellStopped) { Start-Shell }
        if ($share) { Disconnect-OldPC $share }
        # The staging folder holds the old PC's Wi-Fi keys in clear text: never leave it behind.
        if ($script:Staging -and (Test-Path -LiteralPath $script:Staging)) { Remove-Item -LiteralPath $script:Staging -Recurse -Force -ErrorAction SilentlyContinue }
        Set-KeepAwake $false
    }
}

# =============================================================================
# Entry point
# =============================================================================
if ($InitCredentials) { Start-InitCredentials; return }
if ($Cleanup) {
    if (-not (Test-Admin)) { throw 'Run -Cleanup from an elevated PowerShell.' }
    Start-SourceCleanup; return
}
if ($PrepareDrive) {
    # One-time preparation of an external drive: creates the empty WTT-Transfer folder in its root, nothing else.
    $v = Initialize-TransferDrive $PrepareDrive
    Write-Host ("Drive {0}: is ready. Run the tool on the old PC with -Transport Drive (or choose the flash drive in the bootstrap)." -f $v.Letter) -ForegroundColor White
    return
}

if (-not $Mode) {
    Write-Host ''
    Write-Host '  Windows Transfer Tool' -ForegroundColor White
    Write-Host '   1) This is the OLD PC  (source: export, then share over the network or copy to a drive)'
    Write-Host '   2) This is the NEW PC  (destination: connect or read the drive, choose, copy, apply)'
    $c = Read-Host '  Choose 1 or 2'
    $Mode = if ($c -eq '1') { 'Source' } elseif ($c -eq '2') { 'Destination' } else { throw 'Cancelled.' }
}

# %TEMP% can be an 8.3 short path (C:\Users\ITWORK~1\...) on accounts with a space in the name; expand it so every log call gets a normal path.
function Get-LongTempPath {
    try {
        if (-not ('Wtt.LongPath' -as [type])) {
            Add-Type -Namespace Wtt -Name LongPath -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder b, uint n);'
        }
        $sb = New-Object System.Text.StringBuilder 520
        if ([Wtt.LongPath]::GetLongPathName($env:TEMP, $sb, 520) -gt 0) { return $sb.ToString() }
    } catch {}
    return $env:TEMP
}
# Debug log: always on, both PCs. A full transcript goes to a fixed folder in %TEMP%, and a desktop shortcut points at it.
function Hide-LogSecrets {
    if (-not $script:LogFile -or -not (Test-Path -LiteralPath $script:LogFile) -or $script:LogSecrets.Count -eq 0) { return }
    try {
        $txt = [IO.File]::ReadAllText($script:LogFile); $sha = [Security.Cryptography.SHA256]::Create()
        foreach ($s in ($script:LogSecrets | Select-Object -Unique | Sort-Object { $_.Length } -Descending)) {
            $h = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))[0..5] | ForEach-Object { $_.ToString('x2') })
            $txt = $txt.Replace($s, "[sha256:$h]")
        }
        [IO.File]::WriteAllText($script:LogFile, $txt, (New-Object Text.UTF8Encoding $true))
    } catch { Write-Warn "Could not hash the secrets in the debug log: $($_.Exception.Message). Delete $($script:LogFile) before sharing it." }
}
function Start-DebugLog {
    $debugRoot = Join-Path (Get-LongTempPath) 'Debug'   # Temp\Debug\<project>\<date>\<file>
    $projectLogs = Join-Path $debugRoot 'WindowsTransferTool'
    $runDir = if ($RunId) { $RunId } else { Get-Date -Format 'yyyy-MM-dd_HH-mm-ss' }       # Temp\Debug\<tool>\<run>\<file>
    $script:LogDir = Join-Path $projectLogs $runDir
    try {
        New-Item -ItemType Directory -Force $script:LogDir | Out-Null
        $tp = Join-Path $script:LogDir ('debug-{0}-{1}.log' -f $Mode.ToLower(), (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        Start-Transcript -Path $tp | Out-Null
        $script:LogFile = $tp; $script:Transcribing = $true
        Write-Host "Debug log: $script:LogDir" -ForegroundColor DarkGray
    } catch { Write-Warn "Could not start the debug log in $($script:LogDir): $($_.Exception.Message)" }
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Debug.lnk'      # Desktop\Debug -> Temp\Debug
        if (-not (Test-Path -LiteralPath $lnk)) {
            $make = $Yes -or -not (Test-Interactive) -or ((Read-Host '  Put a "Debug" shortcut (to the log folder) on the desktop? (Y/n)') -notmatch '^n')
            if ($make) {
                $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $sc.TargetPath = $debugRoot; $sc.Save()
                Write-Ok "Shortcut created: $lnk"
            }
        }
    } catch { Write-Warn "Could not create the desktop shortcut ($($_.Exception.Message)). Logs are in $($script:LogDir)" }
}

Start-DebugLog
try {
    if ($Mode -eq 'Source') {
        if ($Transport -eq 'Drive') { Start-DriveSourceMode } else { Start-SourceMode }
    } else { Start-DestinationMode }
} catch {
    # Put the failure in the transcript (with the line and stack) before the window can close; then fail as before.
    Write-Host ("FAILED: {0}`n{1}`n{2}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace) -ForegroundColor Red
    throw
} finally {
    if ($script:Transcribing) { try { Stop-Transcript | Out-Null } catch {}; $script:Transcribing = $false }
    Hide-LogSecrets
}
