# Doing it by hand

Every item the tool offers, as manual steps. Useful when an item failed, when you want to move one more thing after the old PC is already cleaned up, or when you would rather not run the tool at all. Commands are PowerShell unless noted; "elevated" means Run as administrator.

Throughout, `OLD` is the old PC's name or IP and `C:\Users\Old` / `C:\Users\New` are the two profile folders. The `robocopy` commands below read from the old PC over SMB; if you use the tool's FTP service instead, fetch the same folders with an FTP client (see the next section).

- [Using the FTP service by hand](#using-the-ftp-service-by-hand)
- [Sharing by hand](#sharing-by-hand)
- [Reverting by hand](#reverting-by-hand)
- [Personal files](#personal-files)
- [Apps and app data](#apps-and-app-data)
- [Windows settings](#windows-settings)
- [Any other app](#any-other-app)

## Using the FTP service by hand

While the old PC's window is in stage S4 or S5 its FTP service is running, and any FTP client can use it instead of the new PC's half of the tool (for example to fetch one more folder, or to try the connection). The service is read-only; the examples below were checked against `curl`, the other clients are standard FTP and should work the same way.

| Setting | Value |
|---|---|
| Host | the old PC's IP address, shown in S4 |
| Port | `2121` (or the `-FtpPort` you gave) |
| User | `wtt` |
| Password | the 16 characters shown in S4, **without the dashes**, in capitals (the tool's own client forgives dashes and spaces, other clients do not) |
| Encryption | **Require explicit FTP over TLS** for FTPS (`AUTH TLS`); none for plain FTP |
| Mode | passive (the service has no active mode), data ports 52100-52150 |

Folders you can reach: `/pkg` (the export package), `/profile` (the whole user profile), and `/known-Desktop`, `/known-Documents`, `/known-Pictures`, `/known-Videos`, `/known-Music`, `/known-Downloads` (the real locations of the known folders, which differ from `/profile/...` when OneDrive or a folder redirection is involved). `prep-state.json` is hidden, uploads are refused except two small marker files, and junctions are not listed.

With FTPS a GUI client such as WinSCP or FileZilla shows the certificate's SHA-256 fingerprint on first connect. Compare it with the Fingerprint line on the old PC's screen **before** accepting it; the certificate is self-signed and different every run. Windows Explorer's `ftp://` and the built-in `ftp.exe` cannot do TLS, so they only work if the old PC was started with `-Transport Ftp`.

Quick checks and single files with the `curl.exe` that ships with Windows (`-k` turns certificate checking off, so use it only after you compared the fingerprint another way, for instance in a GUI client):

```powershell
curl.exe --ssl-reqd -k -u wtt:ABCDEFGHJKLMNPQR "ftp://OLD:2121/profile/Documents/"              # list a folder
curl.exe --ssl-reqd -k -u wtt:ABCDEFGHJKLMNPQR -O "ftp://OLD:2121/known-Documents/report.docx"    # download one file
curl.exe -u wtt:ABCDEFGHJKLMNPQR "ftp://OLD:2121/pkg/manifest.json"                                # plain FTP: drop --ssl-reqd and -k
```

Whole folders are easier with WinSCP or FileZilla (recursive download); curl copies one file per call. A file copied this way gets the download time as its modified time unless the client keeps the remote time (curl: add `-R`; the service answers `MDTM`, but that combination is untested). The tool's own client always keeps it.

## Sharing by hand

This section is for SMB. A dedicated read-only share of the profile avoids both the admin share and the `LocalAccountTokenFilterPolicy` change. On the **old PC**, elevated:

```powershell
New-SmbShare -Name Migration -Path $env:USERPROFILE -ReadAccess "$env:COMPUTERNAME\$env:USERNAME"
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28502'          # File and Printer Sharing
Get-NetConnectionProfile | Where-Object NetworkCategory -eq Public | Set-NetConnectionProfile -NetworkCategory Private
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notmatch '^(127|169)' | Select-Object IPAddress, InterfaceAlias
```

Optionally limit the firewall rules to the new PC's address once you know it:

```powershell
Set-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -RemoteAddress 192.168.1.60
```

On the **new PC**, connect once and then use `\\OLD\Migration\...` in the commands below instead of `\\OLD\C$\Users\Old\...`:

```powershell
New-SmbMapping -RemotePath \\OLD\Migration -UserName OLD\username -Password (Read-Host 'Old PC password')
```

This still needs the old PC's real Windows password, because `-ReadAccess` above names the signed-in account. If you do not have that password, grant read access to a temporary account instead, same idea as the tool's SMB default (see [process.md](process.md#the-temporary-account-smb)) - or skip Windows accounts entirely and use the FTP service above:

```powershell
# OLD PC, elevated
$pw = ConvertTo-SecureString (-join ((1..24) | ForEach-Object { [char](Get-Random -Minimum 33 -Maximum 126) })) -AsPlainText -Force
New-LocalUser -Name WTT-manual -Password $pw
Add-LocalGroupMember -Group Administrators -Member WTT-manual   # needed to read another account's profile
Grant-SmbShareAccess -Name Migration -AccountName "$env:COMPUTERNAME\WTT-manual" -AccessRight Read -Force
```

Use `WTT-manual` and that password in the `New-SmbMapping` call above instead of your own account, and when you are done:

```powershell
# OLD PC, elevated
Remove-LocalUser -Name WTT-manual
```

## Reverting by hand

If the tool's window was closed before stage S6 and `Migrate-Windows.ps1 -Cleanup` is not available:

**FTP / FTPS.** The server lived inside the closed window, so it is already gone. On the **old PC**, elevated, remove its firewall rule and the export (the export contains Wi-Fi keys):

```powershell
Remove-NetFirewallRule -Name WindowsTransferTool-temporary -ErrorAction SilentlyContinue
Remove-Item C:\MigrationExport -Recurse -Force
```

On the **new PC**, if its window was killed during a run, delete the temporary copy of the export package (it also contains the Wi-Fi keys):

```powershell
Get-ChildItem $env:TEMP -Directory -Filter 'wtt-*' | Remove-Item -Recurse -Force
```

**SMB.** On the **old PC**, elevated:

```powershell
# 1. firewall group back to its default (disabled on Public, enabled on Private/Domain) and unscoped
Set-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -RemoteAddress Any
Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' | Where-Object Profile -match Public | Disable-NetFirewallRule

# 2. network profile back to Public if it was Public before
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Public   # only if that is what it was

# 3. remove the UAC remote-restriction override
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue

# 4. delete the export (contains Wi-Fi keys)
Remove-Item C:\MigrationExport -Recurse -Force

# 5. if you created the manual share above
Remove-SmbShare -Name Migration -Force

# 6. the tool's temporary account, if the window was closed before S6 deleted it (its name is in prep-state.json, WTT-xxxxxxxx)
Get-LocalUser | Where-Object Name -like 'WTT-*' | Remove-LocalUser
```

`C:\MigrationExport\prep-state.json`, if it still exists, lists exactly which rules were enabled and which interfaces were Public before the tool ran.

## Personal files

**Old PC:** nothing to do, except closing Outlook and other apps that keep files open.

**New PC:** one robocopy per folder. `/E` copies subfolders, `/XO` keeps newer files already on the new PC, `/XJ` skips junctions, `/MT:8` uses eight threads.

```powershell
robocopy "\\OLD\C$\Users\Old\Desktop"   "$env:USERPROFILE\Desktop"   /E /XO /XJ /MT:8 /R:2 /W:3 /XF desktop.ini Thumbs.db /LOG+:"$env:USERPROFILE\migrate.log"
robocopy "\\OLD\C$\Users\Old\Documents" "$env:USERPROFILE\Documents" /E /XO /XJ /MT:8 /R:2 /W:3 /XF desktop.ini Thumbs.db /LOG+:"$env:USERPROFILE\migrate.log"
robocopy "\\OLD\C$\Users\Old\Pictures"  "$env:USERPROFILE\Pictures"  /E /XO /XJ /MT:8 /R:2 /W:3 /LOG+:"$env:USERPROFILE\migrate.log"
robocopy "\\OLD\C$\Users\Old\Downloads" "$env:USERPROFILE\Downloads" /E /XO /XJ /MT:8 /R:2 /W:3 /LOG+:"$env:USERPROFILE\migrate.log"
```

Repeat for Videos, Music, Favorites, Links, Contacts, Saved Games, Searches. If a folder was moved (for example Documents inside OneDrive), find the real path on the old PC with:

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
```

OneDrive folders on both PCs: do not copy, let OneDrive sync.

## Apps and app data

### Reinstall apps with winget
**Old PC:**
```powershell
winget export -o $env:USERPROFILE\Desktop\apps.json --accept-source-agreements
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher | Sort-Object DisplayName -Unique |
  Export-Csv $env:USERPROFILE\Desktop\all-apps.csv -NoTypeInformation
```
**New PC** (elevated, after copying the two files over):
```powershell
winget import -i .\apps.json --ignore-unavailable --accept-package-agreements --accept-source-agreements
```
Then go through `all-apps.csv` for everything winget did not know.

### Browser bookmarks
**Chrome / Edge:** close the browser on both PCs, then copy one file per profile into the same place on the new PC (the browser must have been started once so the folder exists):
```powershell
Copy-Item "\\OLD\C$\Users\Old\AppData\Local\Google\Chrome\User Data\Default\Bookmarks" "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\"
Copy-Item "\\OLD\C$\Users\Old\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks" "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\"
```
Or, in the browser: Bookmarks manager > Export bookmarks (HTML) on the old PC, Import on the new one.
**Firefox:** close Firefox on both PCs and copy the whole profile folder, which includes logins and extensions:
```powershell
robocopy "\\OLD\C$\Users\Old\AppData\Roaming\Mozilla\Firefox" "$env:APPDATA\Mozilla\Firefox" /E /XO
```
**Passwords (Chrome/Edge):** sign in to the browser to sync, or Settings > Passwords > Export to CSV on the old PC, Import on the new PC, then delete the CSV.

### Windows Terminal
```powershell
Copy-Item "\\OLD\C$\Users\Old\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json" "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\"
```
Open Terminal once first so the folder exists. Or use Settings > Open JSON file in Terminal and paste.

### VS Code
**Old PC:** `code --list-extensions > extensions.txt`
**New PC:** install VS Code, then
```powershell
robocopy "\\OLD\C$\Users\Old\AppData\Roaming\Code\User" "$env:APPDATA\Code\User" /E /XO /XD globalStorage workspaceStorage History
Get-Content .\extensions.txt | ForEach-Object { code --install-extension $_ --force }
```
Or sign in to VS Code and turn on Settings Sync.

### Developer config
Only over a network you trust; these include private keys.
```powershell
foreach ($f in '.gitconfig','.npmrc','.condarc','.gitignore_global') { Copy-Item "\\OLD\C$\Users\Old\$f" $env:USERPROFILE -ErrorAction SilentlyContinue }
foreach ($d in '.ssh','.aws','.kube','.config') { robocopy "\\OLD\C$\Users\Old\$d" "$env:USERPROFILE\$d" /E /XO }
```
Run `az login`, `gh auth login` and `docker login` again; their token caches do not survive the move.

### Office signatures, templates, dictionary
Close Outlook and Word on the new PC, then:
```powershell
foreach ($d in 'Signatures','Templates','UProof') { robocopy "\\OLD\C$\Users\Old\AppData\Roaming\Microsoft\$d" "$env:APPDATA\Microsoft\$d" /E /XO }
```
Outlook's account setup itself is not a file; add the account in Outlook. For POP accounts also copy the `.pst` from Documents\Outlook Files and open it with File > Open > Outlook Data File.

### Sticky Notes
Close Sticky Notes on both PCs (end `Microsoft.Notes` in Task Manager), then:
```powershell
robocopy "\\OLD\C$\Users\Old\AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState" "$env:LOCALAPPDATA\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState" /E
```
Or sign in to Sticky Notes with the same Microsoft account; it syncs.

## Windows settings

Registry-based items follow the same pattern: export on the old PC, fix paths, import on the new PC with Explorer stopped where noted. Back up the new PC's keys first with the same `reg export` command so you can undo.

### Appearance: theme, colors, cursors, wallpaper
**Old PC:**
```cmd
reg export "HKCU\Control Panel\Colors"  colors.reg /y
reg export "HKCU\Control Panel\Cursors" cursors.reg /y
reg export "HKCU\Control Panel\Desktop" desktop.reg /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes" themes.reg /y
reg export "HKCU\Software\Microsoft\Windows\DWM" dwm.reg /y
```
Open `desktop.reg` in Notepad and delete the lines starting with `"LogPixels"`, `"Win8DpiScaling"`, `"DpiScalingVer"` and `"AppliedDPI"` so the new screen keeps its own scaling. If the user names differ, replace `C:\\Users\\Old` with `C:\\Users\\New` (double backslashes) in every file.
**New PC:** copy the wallpaper file somewhere permanent (its path is the `WallPaper` value in `desktop.reg`), then:
```cmd
taskkill /f /im explorer.exe
reg import colors.reg & reg import cursors.reg & reg import desktop.reg & reg import themes.reg & reg import dwm.reg
start explorer.exe
```
Then right-click the wallpaper file > Set as desktop background. Sign out and in to apply the accent color everywhere. Or simply: Settings > Personalization and redo it by eye, which is often quicker.

### Taskbar, Start menu, File Explorer options
Install the apps first; pins to missing apps vanish.
**Old PC:**
```cmd
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3" stuckrects.reg /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" taskband.reg /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" advanced.reg /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" cabinet.reg /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" search.reg /y
```
**New PC:**
```powershell
robocopy "\\OLD\C$\Users\Old\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned" "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned" /E
robocopy "\\OLD\C$\Users\Old\AppData\Roaming\Microsoft\Windows\Start Menu" "$env:APPDATA\Microsoft\Windows\Start Menu" /E /XO
Copy-Item "\\OLD\C$\Users\Old\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin" "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\"
Copy-Item "\\OLD\C$\Users\Old\AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms" "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\"
```
then in cmd: `taskkill /f /im explorer.exe`, `taskkill /f /im StartMenuExperienceHost.exe`, import the five `.reg` files, `start explorer.exe`. The `Taskband` values are binary and contain `C:\Users\Old\...` paths; when the user name differs, skip `taskband.reg` and re-pin by hand (right-click an app > Pin to taskbar).

### Desktop icon positions and folder views
**Old PC:**
```cmd
reg export "HKCU\Software\Microsoft\Windows\Shell\Bags" bags1.reg /y
reg export "HKCU\Software\Microsoft\Windows\Shell\BagMRU" bagmru1.reg /y
reg export "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags" bags2.reg /y
reg export "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU" bagmru2.reg /y
```
**New PC:** kill Explorer, import the four files, start Explorer. Positions only survive on the same screen resolution.

### Mouse, touchpad, keyboard, sounds, accessibility
```cmd
reg export "HKCU\Control Panel\Mouse" mouse.reg /y
reg export "HKCU\Control Panel\Keyboard" keyboard.reg /y
reg export "HKCU\Control Panel\Sound" sound.reg /y
reg export "HKCU\Control Panel\Accessibility" access.reg /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad" touchpad.reg /y
```
Import on the new PC (no Explorer restart needed), then sign out and in.

### Language, keyboard layouts, regional formats
```cmd
reg export "HKCU\Control Panel\International" intl.reg /y
reg export "HKCU\Keyboard Layout" layout.reg /y
reg export "HKCU\Software\Microsoft\Input" input.reg /y
```
Import, sign out and in. Language packs themselves are installed in Settings > Time & language > Language.

### User environment variables
List on the old PC and add by hand on the new one; this avoids clobbering the new PC's `Path`:
```powershell
# old PC
Get-ItemProperty HKCU:\Environment | Format-List
# new PC, per variable
[Environment]::SetEnvironmentVariable('MYVAR', 'value', 'User')
# new PC, append to Path without replacing it
$p = [Environment]::GetEnvironmentVariable('Path','User'); [Environment]::SetEnvironmentVariable('Path', "$p;C:\Tools", 'User')
```

### Mapped drives and network printers
```powershell
# old PC: list
Get-SmbMapping
Get-Printer | Where-Object Type -eq Connection | Select-Object Name
# new PC: recreate
New-SmbMapping -LocalPath Z: -RemotePath \\server\share -Persistent $true
Add-Printer -ConnectionName \\server\printer
```

### Fonts installed for your user
```powershell
robocopy "\\OLD\C$\Users\Old\AppData\Local\Microsoft\Windows\Fonts" "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" /E
```
then on the old PC `reg export "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts" fonts.reg /y`, fix the profile path if the names differ, import on the new PC and sign out and in. Or just select all the font files, right-click, Install.

### Saved Wi-Fi networks
**Old PC** (elevated): `netsh wlan export profile key=clear folder=C:\wifi` (clear-text keys, delete afterwards).
**New PC** (elevated): `Get-ChildItem C:\wifi\*.xml | ForEach-Object { netsh wlan add profile filename="$($_.FullName)" user=all }`.
Or type the Wi-Fi password once on the new PC.

### Active power plan
**Old PC:** `powercfg /getactivescheme` then `powercfg /export C:\plan.pow <GUID>`.
**New PC:** `powercfg /import C:\plan.pow` prints a new GUID; `powercfg /setactive <GUID>`. Only sensible for the same hardware.

## Any other app

Most Windows apps keep their settings in one of these places. Install the app on the new PC, start it once, close it, then copy the folder:

| Location | Typical content |
|---|---|
| `%APPDATA%\<Vendor>\<App>` | settings, profiles (roaming) |
| `%LOCALAPPDATA%\<Vendor>\<App>` | caches, larger data |
| `%LOCALAPPDATA%\Packages\<PackageFamily>\LocalState` | Store apps |
| `%USERPROFILE%\.<app>` | cross-platform tools (git, ssh, npm, docker) |
| `HKCU\Software\<Vendor>\<App>` | registry-based settings: `reg export` / `reg import` |
| `%USERPROFILE%\Documents\<App>` | save files, projects |

```powershell
robocopy "\\OLD\C$\Users\Old\AppData\Roaming\Vendor\App" "$env:APPDATA\Vendor\App" /E /XO
```

Anything licensed per machine (Office activation, Adobe, DRM media, hardware dongles) has to be deactivated on the old PC and activated on the new one through the vendor's own process.
