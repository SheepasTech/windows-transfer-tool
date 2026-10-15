<#
  Windows Transfer Tool - bootstrap  (branch: main)

  Run on BOTH PCs from a PowerShell window (it asks for administrator rights itself):

    irm https://raw.githubusercontent.com/SheepasTech/windows-transfer-tool/main/bootstrap.ps1 | iex

  What it does
    1. Asks whether this PC is the OLD one (source) or the NEW one (destination).
       On the old PC it also asks how the data should travel: FTPS, FTP, SMB, or a flash drive / external SSD.
    2. Elevates if needed.
    3. Downloads Migrate-Windows.ps1 and lib\WttFtp.cs to %LOCALAPPDATA%\WindowsTransferTool and checks them.
    4. Starts the staged migration for that role (docs/process.md). Over the network the two PCs bind
       to each other with a pairing code. With a drive you carry it from one PC to the other.

  Optional environment variables (set them on the same line, before the one-liner):
    $env:WTT_ROLE        = 'Source' | 'Destination' | 'Download'   skip the role question
    $env:WTT_TRANSPORT   = 'Ftps' | 'Ftp' | 'Smb' | 'Drive'       old PC: how the data travels (default Ftps)
                                                                   new PC: leave unset, it uses a plugged-in
                                                                   transfer drive, else the old PC's network service
    $env:WTT_DRIVE       = 'D:'                                    drive transport: use this drive letter (it must
                                                                   contain the WTT-Transfer folder)
    $env:WTT_FTPPORT     = '2121'                                  control port of the FTP(S) service, same on both PCs
    $env:WTT_FINGERPRINT = '29BF 5009 ...'                         new PC, FTPS: certificate fingerprint shown on the old PC
    $env:WTT_DRYRUN      = '1'                                     preview only (new PC: nothing copied or changed;
                                                                   old PC with a drive: nothing written to the drive)
    $env:WTT_REF         = 'v0.4.0' | '<commit sha>'               pin a version (default: main, this branch)
    $env:WTT_REPO        = 'you/windows-transfer-tool'             use a fork
  Example:  $env:WTT_ROLE='Destination'; $env:WTT_DRYRUN='1'; irm https://raw.githubusercontent.com/SheepasTech/windows-transfer-tool/main/bootstrap.ps1 | iex
#>
$ErrorActionPreference = 'Stop'

$Repo       = if ($env:WTT_REPO) { $env:WTT_REPO } else { 'SheepasTech/windows-transfer-tool' }
$Ref        = if ($env:WTT_REF)  { $env:WTT_REF }  else { 'main' }
$Base       = if ($env:WTT_BASE) { $env:WTT_BASE } else { "https://raw.githubusercontent.com/$Repo/$Ref/" }
$InstallDir = Join-Path $env:LOCALAPPDATA 'WindowsTransferTool'
$Main       = 'Migrate-Windows.ps1'
$Lib        = 'lib/WttFtp.cs'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
# Bootstrap log: every window (the first one and the elevated one) writes its own file, one line at a time, so a crash
# or a closed window still leaves everything up to that point. Layout: Temp\Debug\<project>\<date>\<file>.
$script:BootLog = $null
try {
    $d = Join-Path (Get-LongTempPath) ('Debug\WindowsTransferTool\{0}' -f (Get-Date -Format 'yyyy-MM-dd'))
    New-Item -ItemType Directory -Force $d | Out-Null
    $script:BootLog = Join-Path $d ('bootstrap-{0}-pid{1}-{2}.log' -f $(if (Test-Admin) { 'admin' } else { 'user' }), $PID, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
} catch {}
function Write-BootLog([string]$Msg) {
    if (-not $script:BootLog) { return }
    try { Add-Content -LiteralPath $script:BootLog -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) -Encoding UTF8 } catch {}
}
Write-BootLog ("start: pid {0}, admin {1}, PS {2}, repo {3} @ {4}, WTT_ROLE='{5}' WTT_TRANSPORT='{6}'" -f $PID, (Test-Admin), $PSVersionTable.PSVersion, $Repo, $Ref, $env:WTT_ROLE, $env:WTT_TRANSPORT)

try {

Write-Host ''
Write-Host "  Windows Transfer Tool - bootstrap  ($Repo @ $Ref)" -ForegroundColor White

# ---- 1. role (and, on the old PC, the transfer method) ------------------------
$role = $env:WTT_ROLE
if ($role -and $role -notin 'Source','Destination','Download') { throw "WTT_ROLE must be Source, Destination or Download (got '$role')." }
if (-not $role) {
    Write-Host '   1) This is the OLD PC   (source: export settings, then share over the network or copy to a drive)'
    Write-Host '   2) This is the NEW PC   (destination: read the drive or connect with the code, choose, copy, apply)'
    Write-Host '   3) Only download the tool, do not start it'
    switch (Read-Host '  Choose 1, 2 or 3') {
        '1' { $role = 'Source' }
        '2' { $role = 'Destination' }
        '3' { $role = 'Download' }
        default { throw 'Cancelled.' }
    }
}

$transport = $env:WTT_TRANSPORT
if ($transport -and $transport -notin 'Ftps','Ftp','Smb','Drive') { throw "WTT_TRANSPORT must be Ftps, Ftp, Smb or Drive (got '$transport')." }
if ($role -eq 'Source' -and -not $transport) {
    Write-Host ''
    Write-Host '   How should the data travel to the new PC?'
    Write-Host '   1) FTPS - over the network, encrypted, random one-time password, no Windows account needed   (recommended)'
    Write-Host '   2) FTP  - the same, but not encrypted (only for a LAN you fully trust)'
    Write-Host '   3) SMB  - over the network with Windows file sharing; a temporary local account is created for the sign-in'
    Write-Host '   4) Drive - no network: copy to a flash drive or external SSD that contains a folder named WTT-Transfer'
    switch (Read-Host '  Choose 1, 2, 3 or 4 (Enter = 1)') {
        '2' { $transport = 'Ftp' }
        '3' { $transport = 'Smb' }
        '4' { $transport = 'Drive' }
        default { $transport = 'Ftps' }
    }
}
if ($role -eq 'Destination' -and -not $transport) {
    Write-Host ''
    Write-Host '   How does the data reach this PC?'
    Write-Host '   1) Network - the old PC is waiting (you will be asked for its IP address)'
    Write-Host '   2) Drive   - a flash drive or external SSD written by the old PC (no IP address needed)'
    if ((Read-Host '  Choose 1 or 2 (Enter = 1)') -eq '2') { $transport = 'Drive' }
}
# WTT_DRYRUN only sets the default answer; it is cleared here so it never sticks in this window, and the question is always asked.
$wttDry = [bool]($env:WTT_DRYRUN -and $env:WTT_DRYRUN -ne '0')
Remove-Item Env:WTT_DRYRUN -ErrorAction SilentlyContinue
if (-not $env:WTT_DRYASKED -and ($role -eq 'Destination' -or ($role -eq 'Source' -and $transport -eq 'Drive'))) {
    Write-Host ''
    $hint = if ($wttDry) { 'Y/n' } else { 'y/N' }
    $ans = Read-Host ("  Dry run first (preview only, nothing is copied or changed)? ($hint)")
    $wttDry = if ($ans) { $ans -match '^y' } else { $wttDry }
}
Remove-Item Env:WTT_DRYASKED -ErrorAction SilentlyContinue     # one-shot: the elevated window must not skip the question on its next run

Write-BootLog ("choices: role {0}, transport {1}, dry run {2}" -f $role, $transport, $wttDry)
# ---- 2. elevate --------------------------------------------------------------
if ($role -ne 'Download' -and -not (Test-Admin)) {
    Write-Host '  Administrator rights are needed - a UAC prompt follows. The tool continues in the new window.' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    $pre = "`$env:WTT_ROLE='$role'; "
    if ($transport) { $pre += "`$env:WTT_TRANSPORT='$transport'; " }
    $pre += "`$env:WTT_DRYASKED='1'; "
    if ($wttDry) { $pre += "`$env:WTT_DRYRUN='1'; " }
    foreach ($v in 'WTT_REF','WTT_REPO','WTT_BASE','WTT_FTPPORT','WTT_FINGERPRINT','WTT_DRIVE') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $pre += "`$env:$v='$val'; " }
    }
    $cmd = $pre + "irm '$($Base)bootstrap.ps1' | iex"
    Write-BootLog "not elevated: starting an elevated window (it writes its own bootstrap and debug logs)"
    Start-Process $exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$cmd
    return
}

# ---- 3. download -------------------------------------------------------------
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
New-Item -ItemType Directory -Force (Join-Path $InstallDir 'lib') | Out-Null

function Get-ToolFile([string]$Rel) {
    $dest = Join-Path $InstallDir ($Rel -replace '/', '\')
    Write-Host "  Downloading $Base$Rel"
    Invoke-WebRequest -Uri ($Base + $Rel) -OutFile $dest -UseBasicParsing
    Unblock-File $dest -ErrorAction SilentlyContinue
    return $dest
}

$script = Get-ToolFile $Main
Write-BootLog "downloaded $Main"
$libFile = Get-ToolFile $Lib
Write-BootLog "downloaded $Lib"

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Downloaded $Main does not parse ($($errors[0].Message)). Truncated download or wrong WTT_REF? Delete $InstallDir and retry." }
if (-not ((Get-Content -LiteralPath $libFile -Raw) -match 'namespace Wtt')) { throw "Downloaded $Lib is not the expected file. Wrong WTT_REF? Delete $InstallDir and retry." }
Write-Host "  Saved to $InstallDir"
Write-Host ("  SHA256   {0}  {1}" -f (Get-FileHash $script -Algorithm SHA256).Hash, $Main) -ForegroundColor DarkGray
Write-Host ("  SHA256   {0}  {1}" -f (Get-FileHash $libFile -Algorithm SHA256).Hash, $Lib) -ForegroundColor DarkGray

# ---- 4. hand over to the staged tool ----------------------------------------
if ($role -eq 'Download') {
    Write-Host ''
    Write-Host "  Done. Start it later from an elevated PowerShell:" -ForegroundColor White
    Write-Host "    & '$script' -Mode Source          # old PC (add -Transport Ftps|Ftp|Smb|Drive)"
    Write-Host "    & '$script' -Mode Destination     # new PC (add -DryRun to preview)"
    Write-Host "    & '$script' -PrepareDrive D:      # one time: make an external drive a transfer drive"
    return
}
$extra = @{}
if ($transport) { $extra.Transport = $transport }
if ($env:WTT_FTPPORT) { $extra.FtpPort = [int]$env:WTT_FTPPORT }
if ($env:WTT_DRIVE) { $extra.Drive = $env:WTT_DRIVE }
if ($wttDry -and ($role -eq 'Destination' -or $transport -eq 'Drive')) { $extra.DryRun = $true }     # the network old-PC flow has no dry run
if ($env:WTT_FINGERPRINT -and $role -eq 'Destination') { $extra.Fingerprint = $env:WTT_FINGERPRINT }
Write-Host ("  Starting {0} mode..." -f $role) -ForegroundColor White
Write-Host ("  Running: Migrate-Windows.ps1 -Mode {0} {1}" -f $role, (($extra.GetEnumerator() | ForEach-Object { if ($_.Value -is [bool]) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" } }) -join " ")) -ForegroundColor DarkGray
Write-BootLog ("launching: Migrate-Windows.ps1 -Mode {0} {1}" -f $role, (($extra.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join " "))
& $script -Mode $role @extra
Write-BootLog "tool returned"
} catch {
    Write-BootLog ("ERROR: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    Write-Host ("  Bootstrap failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($script:BootLog) { Write-Host ("  Details: {0}" -f $script:BootLog) -ForegroundColor Yellow }
    throw
}
