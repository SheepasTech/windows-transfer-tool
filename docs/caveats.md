# Caveats

What the tool cannot do, does imperfectly, or does in a way you should know about. Each entry says what happens, why, and what to do instead. Step-by-step manual procedures for every item are in [manual.md](manual.md).

- [Network and security](#network-and-security)
- [Accounts and sign-in](#accounts-and-sign-in)
- [Files](#files)
- [Apps](#apps)
- [Windows settings](#windows-settings)
- [The tool itself](#the-tool-itself)

## Network and security
 
### The old PC exposes its admin share
**What happens.** Stage S3 enables File and Printer Sharing, makes Public networks Private, and sets `LocalAccountTokenFilterPolicy=1`. Until the new PC binds in S4, anyone on the same subnet who knows the old PC's Windows password can open `\\oldpc\C$` with full access. After binding, the firewall rules are limited to the new PC's address.
**Why.** The admin share is the only share that exists on every Windows edition without creating one, and it reaches every folder a user may have redirected.
**Instead.** Run the transfer on a home or office network you trust, never on public Wi-Fi. Or create a dedicated read-only share by hand ([manual.md](manual.md#sharing-by-hand)) and copy with robocopy yourself; then the token-filter policy is not needed.

### Wi-Fi passwords sit in clear text on the old PC
**What happens.** `C:\MigrationExport\wifi\*.xml` contains every saved Wi-Fi key in clear text until S6 deletes the folder.
**Why.** `netsh wlan export profile key=clear` is the only way to carry keys between PCs.
**Instead.** Untick "Saved Wi-Fi networks" and type the keys on the new PC, or make sure S6 ran (`-Cleanup` if the window was closed).

### The pairing code is a confirmation, not a secret
**What happens.** The six-digit code proves the new PC is reading the export of the PC you are looking at. It does not grant or deny access.
**Why.** Access is granted by the Windows password over SMB; the code only lets the old PC learn which address to trust and lets you catch a wrong IP.
**Instead.** Nothing to do; just do not treat the code as a password.

### If the old PC window is closed, sharing stays open
**What happens.** S6 only runs when S4/S5 finish or fail inside the script. Closing the window skips it.
**Instead.** Run `Migrate-Windows.ps1 -Cleanup` elevated, or revert by hand ([manual.md](manual.md#reverting-the-sharing-changes-by-hand)).

### `irm | iex` runs whatever the URL serves
**What happens.** The bootstrap executes a script straight from GitHub.
**Instead.** Pin a release with `$env:WTT_REF='v0.2.0'`, or download `bootstrap.ps1` and `Migrate-Windows.ps1`, read them, and run them locally (`Start-Migration.cmd`).

## Accounts and sign-in

### Microsoft accounts need the e-mail form
**What happens.** Signing in to the old PC's share with a Microsoft account works with the account e-mail, sometimes only as `MicrosoftAccount\you@outlook.com`. The tool tries both forms. Windows Hello PIN-only sign-in does not change the password used over the network.
**Instead.** If both forms fail, create a local administrator account on the old PC for the duration of the transfer and use that.

### Elevating with another account migrates the wrong profile
**What happens.** If a standard user elevates by typing a different administrator's password, `HKCU` and `%USERPROFILE%` inside that window belong to the administrator. The tool compares the SheepasTech of Explorer with the current user and stops when they differ.
**Instead.** Sign in as the user to migrate and give that user administrator rights for the transfer (Settings > Accounts > Other users > Change account type), then remove them afterwards.

### Different user names on the two PCs
**What happens.** Text registry values containing `C:\Users\OldName` are rewritten to the new profile path. Binary values and `REG_EXPAND_SZ` values are not: taskbar pins (`Taskband`), the user `Path` variable and some app settings keep the old path and silently stop working.
**Why.** Those values are stored as hex in `.reg` files, with the string encoded as UTF-16 and wrapped across lines; rewriting them safely needs a real registry editor, not a text replace.
**Instead.** Create the user on the new PC with the same name, or after the transfer re-pin the taskbar by hand and fix `Path` in Settings > System > About > Advanced system settings > Environment Variables.

### Credential Manager, saved browser passwords and default apps
**What happens.** None of these move.
**Why.** Credential Manager and Chrome/Edge passwords are encrypted with DPAPI, which is bound to the user's account on that machine. Default-app choices are protected by a per-machine hash.
**Instead.** Turn on browser sync, or export passwords from the browser's password manager to CSV and import on the new PC, then delete the CSV. Set default apps in Settings > Apps > Default apps. Firefox is the exception: copying the whole profile does carry its saved logins.

## Files

### OneDrive folders on both PCs
**What happens.** When Desktop, Documents or Pictures is inside OneDrive on both PCs and both sign in to the same account, copying creates duplicates or "- Copy" conflicts and forces cloud-only placeholders on the old PC to download over SMB. The plan step warns about this.
**Instead.** Untick those folders and let OneDrive sync them. Only copy folders that are not under OneDrive on at least one side.

### Newer files on the new PC are kept
**What happens.** robocopy runs with `/XO`: if a file already exists on the new PC with a newer timestamp, the old PC's copy is skipped.
**Why.** Protects work done on the new PC before the transfer.
**Instead.** If you really want the old PC's version, delete the file on the new PC first or copy that file by hand.

### Folders redirected to a network drive
**What happens.** If Documents on the old PC points at `\\server\share`, the item is skipped with "not on a local drive".
**Instead.** Point the new PC's Documents at the same server location (Properties > Location).

### Files in use and long paths
**What happens.** Open files (Outlook `.pst`, databases) fail with "sharing violation"; paths over 260 characters may fail.
**Instead.** Close Outlook and other apps on the old PC before S2. Rerun just that item afterwards; the robocopy log names every failed file.

### Permissions and SheepasTechship
**What happens.** Files are copied with data, attributes and timestamps (`/COPY:DAT`), not with their ACLs. They inherit the new PC's profile permissions.
**Why.** Old-PC ACLs reference SIDs that do not exist on the new PC.
**Instead.** Nothing to do for personal files. For `.ssh` keys the inherited profile permissions are what OpenSSH expects.

## Apps

### winget only knows some apps
**What happens.** `winget export` lists only programs it can match to a package. The rest appear in `~\Migration\old-pc-installed-apps.csv`.
**Instead.** Install the remainder by hand from that CSV. Licensed software (Office, Adobe, games) needs sign-in or license transfer regardless.

### winget may need an update first
**What happens.** A brand-new Windows install sometimes has an old App Installer; the first `winget` run fails or hangs on source agreements.
**Instead.** Open the Microsoft Store, Library, update "App Installer", run `winget --version` once, then rerun the item.

### App settings versus app data
**What happens.** Only the listed app data is copied (bookmarks, Terminal, VS Code, Office signatures, Sticky Notes, dev configs). Other apps keep their defaults.
**Instead.** Most apps keep settings in `%APPDATA%\<Vendor>` or `%LOCALAPPDATA%\<Vendor>`. Copy that folder by hand after installing the app and before starting it ([manual.md](manual.md#any-other-app)).

### Browser profiles other than Default
**What happens.** Chrome and Edge: only the `Default` profile's `Bookmarks` file is copied. Firefox: the entire profile folder, including logins and extensions.
**Instead.** For extra Chrome/Edge profiles copy `User Data\Profile N\Bookmarks` by hand, or sign in to the browser.

### Azure CLI, Docker and other token caches
**What happens.** `.azure` is copied but its token cache is DPAPI-protected and will not decrypt; `.aws\credentials` and `.kube\config` do work.
**Instead.** Run `az login` again.

## Windows settings

### Taskbar pins need the apps first
**What happens.** Pins reference `.lnk` files and executable paths. Apps that are not yet installed at the same path show as blank or vanish when Explorer restarts.
**Instead.** Run the Apps stage first (the tool orders it that way), install the rest by hand, then run `-Select s_taskbar` again.

### Explorer restarts
**What happens.** Appearance, Taskbar and Icon items need Explorer stopped while their keys are imported, because Explorer writes those keys when it exits. The taskbar disappears for a few seconds at the end of D6. Windows may auto-restart Explorer (`AutoRestartShell`), so the tool re-checks before each import.
**Instead.** Nothing to do. If Explorer does not come back, press Ctrl+Shift+Esc, File > Run new task, `explorer`.

### Desktop icon positions
**What happens.** Positions are stored per resolution; a different screen size shuffles them.
**Instead.** Right-click the desktop, View, turn off Auto arrange, and drag.

### Display scaling is not copied
**What happens.** `LogPixels`, `Win8DpiScaling`, `DpiScalingVer` and `AppliedDPI` are dropped from the Appearance export on purpose.
**Why.** The new screen almost always wants its own scaling.
**Instead.** Settings > System > Display > Scale.

### Windows 10 Start layout
**What happens.** Start pins are carried via `start2.bin` (Windows 11 22H2 and later). Windows 10 tiles and older Windows 11 builds are not covered.
**Instead.** Pin by hand.

### Environment variables are replaced, not merged
**What happens.** `reg import` of `HKCU\Environment` overwrites any variable with the same name, including `Path`. Values of type `REG_EXPAND_SZ` are not path-rewritten (see user names above).
**Instead.** Note the new PC's user `Path` before the transfer (`[Environment]::GetEnvironmentVariable('Path','User')`) and re-add anything missing afterwards.

### Mapped drives and printers need credentials
**What happens.** Drive letters and printer connections are recreated at next sign-in but prompt for credentials; printers also need their driver.
**Instead.** Reconnect once and tick "Remember my credentials".

### Power plan and hardware-bound settings
**What happens.** A power plan from another laptop may reference devices that do not exist; it is off by default. Touchpad settings only apply to Precision touchpads.
**Instead.** Leave the power plan unticked unless the machines are the same model.

### Wi-Fi import on a PC without Wi-Fi
**What happens.** Every `netsh wlan add profile` fails and the item reports "0 of N added" as OK.
**Instead.** Nothing to do; the profiles are simply not applicable.

## The tool itself

### Untested draft
The script parses on Windows PowerShell 5.1 and PowerShell 7 and the pure functions are unit-checked, but no end-to-end run between two real PCs has been recorded yet. Use `-DryRun` first, and keep the old PC until the new one is verified.

### Windows PowerShell 5.1 is the default host
`bootstrap.ps1` runs in whichever PowerShell you paste it into; `Start-Migration.cmd` always uses Windows PowerShell 5.1. The script is written ASCII-only for that reason.

### The pairing code wait is not a timeout
S4 and S5 wait until a marker appears or you press Enter. A PC that goes to sleep breaks SMB; the tool asks Windows to stay awake while it runs, but a lid close still sleeps a laptop.

### Keep-awake is best effort
`SetThreadExecutionState` is per thread; PowerShell normally runs the script on one thread, but a host that switches threads will drop the request. Plug both PCs in and set sleep to Never for the duration if the transfer is large.

### Interrupted runs
Ctrl+C on the new PC leaves the SMB connection open until the window closes and may leave Explorer stopped. Run `explorer` from Task Manager if needed, then rerun; robocopy skips files that are already there.
