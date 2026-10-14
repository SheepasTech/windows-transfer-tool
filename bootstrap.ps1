<#
  Windows Transfer Tool - bootstrap  (branch: ftp-ftps)

  Run on BOTH PCs from a PowerShell window (it asks for administrator rights itself):

    irm https://raw.githubusercontent.com/SheepasTech/windows-transfer-tool/ftp-ftps/bootstrap.ps1 | iex

  What it does
    1. Asks whether this PC is the OLD one (source) or the NEW one (destination).
       On the old PC it also asks how the new PC should connect (FTPS, FTP or SMB).
    2. Elevates if needed.
    3. Downloads Migrate-Windows.ps1 and lib\WttFtp.cs to %LOCALAPPDATA%\WindowsTransferTool and checks them.
    4. Starts the staged migration for that role (docs/process.md). The two PCs then bind to
       each other with a pairing code and proceed.

  Optional environment variables (set them on the same line, before the one-liner):
    $env:WTT_ROLE        = 'Source' | 'Destination' | 'Download'   skip the role question
    $env:WTT_TRANSPORT   = 'Ftps' | 'Ftp' | 'Smb'                  old PC: how the new PC connects (default Ftps)
                                                                   new PC: leave unset, it detects what the old PC offers
    $env:WTT_FTPPORT     = '2121'                                  control port of the FTP(S) service, same on both PCs
    $env:WTT_FINGERPRINT = '29BF 5009 ...'                         new PC, FTPS: certificate fingerprint shown on the old PC
    $env:WTT_DRYRUN      = '1'                                     new PC: preview only
    $env:WTT_REF         = 'v0.3.0' | '<commit sha>'               pin a version (default: ftp-ftps, this branch)
    $env:WTT_REPO        = 'you/windows-transfer-tool'             use a fork
  Example:  $env:WTT_ROLE='Destination'; $env:WTT_DRYRUN='1'; irm https://raw.githubusercontent.com/SheepasTech/windows-transfer-tool/ftp-ftps/bootstrap.ps1 | iex
#>
$ErrorActionPreference = 'Stop'

$Repo       = if ($env:WTT_REPO) { $env:WTT_REPO } else { 'SheepasTech/windows-transfer-tool' }
$Ref        = if ($env:WTT_REF)  { $env:WTT_REF }  else { 'ftp-ftps' }
$Base       = if ($env:WTT_BASE) { $env:WTT_BASE } else { "https://raw.githubusercontent.com/$Repo/$Ref/" }
$InstallDir = Join-Path $env:LOCALAPPDATA 'WindowsTransferTool'
$Main       = 'Migrate-Windows.ps1'
$Lib        = 'lib/WttFtp.cs'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host "  Windows Transfer Tool - bootstrap  ($Repo @ $Ref)" -ForegroundColor White

# ---- 1. role (and, on the old PC, the transfer method) ------------------------
$role = $env:WTT_ROLE
if ($role -and $role -notin 'Source','Destination','Download') { throw "WTT_ROLE must be Source, Destination or Download (got '$role')." }
if (-not $role) {
    Write-Host '   1) This is the OLD PC   (source: export settings, start the service, show pairing code, wait)'
    Write-Host '   2) This is the NEW PC   (destination: connect with the code, choose, copy, apply)'
    Write-Host '   3) Only download the tool, do not start it'
    switch (Read-Host '  Choose 1, 2 or 3') {
        '1' { $role = 'Source' }
        '2' { $role = 'Destination' }
        '3' { $role = 'Download' }
        default { throw 'Cancelled.' }
    }
}

$transport = $env:WTT_TRANSPORT
if ($transport -and $transport -notin 'Ftps','Ftp','Smb') { throw "WTT_TRANSPORT must be Ftps, Ftp or Smb (got '$transport')." }
if ($role -eq 'Source' -and -not $transport) {
    Write-Host ''
    Write-Host '   How should the new PC connect to this one?'
    Write-Host '   1) FTPS - encrypted, random one-time password, no Windows account needed   (recommended)'
    Write-Host '   2) FTP  - the same, but not encrypted (only for a LAN you fully trust)'
    Write-Host '   3) SMB  - Windows file sharing; a temporary local account is created for the sign-in'
    switch (Read-Host '  Choose 1, 2 or 3 (Enter = 1)') {
        '2' { $transport = 'Ftp' }
        '3' { $transport = 'Smb' }
        default { $transport = 'Ftps' }
    }
}

# ---- 2. elevate --------------------------------------------------------------
if ($role -ne 'Download' -and -not (Test-Admin)) {
    Write-Host '  Administrator rights are needed - a UAC prompt follows. The tool continues in the new window.' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    $pre = "`$env:WTT_ROLE='$role'; "
    if ($transport) { $pre += "`$env:WTT_TRANSPORT='$transport'; " }
    foreach ($v in 'WTT_REF','WTT_REPO','WTT_BASE','WTT_DRYRUN','WTT_FTPPORT','WTT_FINGERPRINT') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $pre += "`$env:$v='$val'; " }
    }
    $cmd = $pre + "irm '$($Base)bootstrap.ps1' | iex"
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
$libFile = Get-ToolFile $Lib

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
    Write-Host "    & '$script' -Mode Source          # old PC (add -Transport Ftps|Ftp|Smb)"
    Write-Host "    & '$script' -Mode Destination     # new PC (add -DryRun to preview)"
    return
}
$extra = @{}
if ($role -eq 'Source' -and $transport) { $extra.Transport = $transport }
if ($env:WTT_FTPPORT) { $extra.FtpPort = [int]$env:WTT_FTPPORT }
if ($env:WTT_DRYRUN -and $role -eq 'Destination') { $extra.DryRun = $true }
if ($env:WTT_FINGERPRINT -and $role -eq 'Destination') { $extra.Fingerprint = $env:WTT_FINGERPRINT }
Write-Host ("  Starting {0} mode..." -f $role) -ForegroundColor White
& $script -Mode $role @extra
