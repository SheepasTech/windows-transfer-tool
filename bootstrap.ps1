<#
  Windows Transfer Tool - bootstrap

  Run on BOTH PCs from a PowerShell window (it asks for administrator rights itself):

    irm https://raw.githubusercontent.com/SheepasTech/windows-transfer-tool/main/bootstrap.ps1 | iex

  What it does
    1. Asks whether this PC is the OLD one (source) or the NEW one (destination).
    2. Elevates if needed.
    3. Downloads Migrate-Windows.ps1 to %LOCALAPPDATA%\WindowsTransferTool and checks that it parses.
    4. Starts the staged migration for that role (docs/process.md). The two PCs then bind to
       each other with a pairing code and proceed.

  Optional environment variables (set them on the same line, before the one-liner):
    $env:WTT_ROLE   = 'Source' | 'Destination' | 'Download'   skip the role question
    $env:WTT_DRYRUN = '1'                                     destination: preview only
    $env:WTT_REF    = 'v0.2.0' | '<commit sha>'               pin a version (default: main)
    $env:WTT_REPO   = 'you/windows-transfer-tool'             use a fork
  Example:  $env:WTT_ROLE='Destination'; $env:WTT_DRYRUN='1'; irm https://raw.githubusercontent.com/SheepasTech/windows-transfer-tool/main/bootstrap.ps1 | iex
#>
$ErrorActionPreference = 'Stop'

$Repo       = if ($env:WTT_REPO) { $env:WTT_REPO } else { 'SheepasTech/windows-transfer-tool' }
$Ref        = if ($env:WTT_REF)  { $env:WTT_REF }  else { 'main' }
$Base       = if ($env:WTT_BASE) { $env:WTT_BASE } else { "https://raw.githubusercontent.com/$Repo/$Ref/" }
$InstallDir = Join-Path $env:LOCALAPPDATA 'WindowsTransferTool'
$Main       = 'Migrate-Windows.ps1'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host "  Windows Transfer Tool - bootstrap  ($Repo @ $Ref)" -ForegroundColor White

# ---- 1. role ---------------------------------------------------------------
$role = $env:WTT_ROLE
if ($role -and $role -notin 'Source','Destination','Download') { throw "WTT_ROLE must be Source, Destination or Download (got '$role')." }
if (-not $role) {
    Write-Host '   1) This is the OLD PC   (source: export settings, share, show pairing code, wait)'
    Write-Host '   2) This is the NEW PC   (destination: connect with the code, choose, copy, apply)'
    Write-Host '   3) Only download the tool, do not start it'
    switch (Read-Host '  Choose 1, 2 or 3') {
        '1' { $role = 'Source' }
        '2' { $role = 'Destination' }
        '3' { $role = 'Download' }
        default { throw 'Cancelled.' }
    }
}

# ---- 2. elevate --------------------------------------------------------------
if ($role -ne 'Download' -and -not (Test-Admin)) {
    Write-Host '  Administrator rights are needed - a UAC prompt follows. The tool continues in the new window.' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    $pre = "`$env:WTT_ROLE='$role'; "
    foreach ($v in 'WTT_REF','WTT_REPO','WTT_BASE','WTT_DRYRUN') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $pre += "`$env:$v='$val'; " }
    }
    $cmd = $pre + "irm '$($Base)bootstrap.ps1' | iex"
    Start-Process $exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$cmd
    return
}

# ---- 3. download -------------------------------------------------------------
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
New-Item -ItemType Directory -Force $InstallDir | Out-Null
$script = Join-Path $InstallDir $Main
$url = $Base + $Main
Write-Host "  Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $script -UseBasicParsing
Unblock-File $script -ErrorAction SilentlyContinue

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Downloaded $Main does not parse ($($errors[0].Message)). Truncated download or wrong WTT_REF? Delete $InstallDir and retry." }
$hash = (Get-FileHash $script -Algorithm SHA256).Hash
Write-Host "  Saved to $script"
Write-Host "  SHA256   $hash" -ForegroundColor DarkGray

# ---- 4. hand over to the staged tool ----------------------------------------
if ($role -eq 'Download') {
    Write-Host ''
    Write-Host "  Done. Start it later from an elevated PowerShell:" -ForegroundColor White
    Write-Host "    & '$script' -Mode Source          # old PC"
    Write-Host "    & '$script' -Mode Destination     # new PC (add -DryRun to preview)"
    return
}
$extra = @{}
if ($env:WTT_DRYRUN -and $role -eq 'Destination') { $extra.DryRun = $true }
Write-Host ("  Starting {0} mode..." -f $role) -ForegroundColor White
& $script -Mode $role @extra
