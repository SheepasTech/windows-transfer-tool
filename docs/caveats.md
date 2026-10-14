# Caveats

What the tool cannot do, does imperfectly, or does in a way you should know about. Each entry says what happens, why, and what to do instead. Step-by-step manual procedures for every item are in [manual.md](manual.md).

- [Network and security](#network-and-security)
- [Accounts and sign-in](#accounts-and-sign-in)
- [Files](#files)
- [Flash drive or external SSD](#flash-drive-or-external-ssd)
- [Apps](#apps)
- [Windows settings](#windows-settings)
- [The tool itself](#the-tool-itself)

## Network and security

### The old PC listens while the tool runs
**What happens.** Between S3 and S6 the old PC accepts connections from the local network.
- **FTPS / FTP:** one control port (default 2121) and a passive range (52100-52150) are open to the local subnet, through one inbound Windows Firewall rule. Everything needs the one-time password. A wrong password costs a second, and five wrong ones lock the service. After binding in S4 the service and the rule accept the new PC's address only.
- **SMB:** File and Printer Sharing is enabled, Public networks become Private, and `LocalAccountTokenFilterPolicy=1` is set. Anyone on the subnet with a working sign-in can open `\\oldpc\C$` with full access. That sign-in is normally the temporary account S3 created (see [the temporary account](process.md#the-temporary-account-smb)), not a real one. After binding, the sharing firewall rules are limited to the new PC's address.

**Why.** The new PC has to reach the old one somehow; the admin share is the only share that exists on every Windows edition without creating one, and the FTP service is the only thing the tool starts itself.
**Instead.** Run the transfer on a home or office network you trust, never on public Wi-Fi. Or move the data without a network service at all (external drive, [manual.md](manual.md)).

### Plain FTP is not encrypted
**What happens.** With `-Transport Ftp` the password, the file list and every file cross the network in clear text, and nothing proves the new PC is talking to the right machine.
**Why.** It exists for networks where TLS gets in the way and you fully trust everyone on the wire.
**Instead.** Use FTPS (the default).

### FTPS uses a self-signed certificate, so you check the fingerprint
**What happens.** The certificate is created fresh in memory on every run and signed by itself, so there is no authority your PC could trust. The new PC shows its SHA-256 fingerprint before any password is sent, and you compare it with the old PC's screen. If you answer yes without comparing, FTPS still encrypts, but anyone who answers on the old PC's address first can collect the password.
**Why.** A certificate from a real authority needs a name and an internet-facing issuer, neither of which two PCs on a home network have.
**Instead.** Compare the two fingerprints (the first 32 hex digits are shown), or pass `-Fingerprint` / `WTT_FINGERPRINT`. TLS 1.2 is used; the tool does not negotiate anything older.

### The service port must be free and reachable
**What happens.** The old PC stops with "Could not start the service on port 2121" if another program uses it. The new PC reports it cannot set up a connection if a firewall, antivirus, Wi-Fi client isolation (guest networks) or a different subnet or VLAN sits between the PCs.
**Why.** The tool only adds a rule to Windows Firewall; it cannot see third-party firewalls or router settings. The rule allows the local subnet, and the service is IPv4 only.
**Instead.** Pick another port with `-FtpPort` (or `WTT_FTPPORT`) on both PCs, put both PCs on the same normal network, or use `-Transport Smb` where only SMB is open. ICMP ping is not needed.

### Wi-Fi passwords sit in clear text
**What happens.** `C:\MigrationExport\wifi\*.xml` on the old PC contains every saved Wi-Fi key in clear text until S6 deletes the folder. Over FTP/FTPS the new PC also keeps a copy of the whole export package in `%TEMP%\wtt-<guid>` for the duration of the run.
**Why.** `netsh wlan export profile key=clear` is the only way to carry keys between PCs.
**Instead.** Untick "Saved Wi-Fi networks" and type the keys on the new PC, make sure S6 ran (`-Cleanup` if the window was closed), and delete a leftover `%TEMP%\wtt-*` folder if the new PC's window was killed.

### The pairing code is a confirmation, not a secret
**What happens.** The six-digit code proves the new PC is reading the export of the PC you are looking at. It does not grant or deny access.
**Why.** Access is granted by a password - the FTP/FTPS one-time password, or the temporary SMB account's - shown on the same screen as the code. The code only lets the old PC learn which address to trust and lets you catch a wrong IP.
**Instead.** Nothing to do; just do not treat the code as the secret. The password shown next to it is the actual secret for this run.

### If the old PC window is closed, the firewall rule or sharing stays
**What happens.** S6 only runs when S4/S5 finish or fail inside the script. Closing the window skips it. For FTP/FTPS the server dies with the window, but the firewall rule stays; for SMB the sharing changes and the temporary account stay.
**Instead.** Run `Migrate-Windows.ps1 -Cleanup` elevated, or revert by hand ([manual.md](manual.md#reverting-by-hand)).

### `irm | iex` runs whatever the URL serves
**What happens.** The bootstrap executes a script straight from GitHub, and so does the compiled `lib/WttFtp.cs` it downloads next to it.
**Instead.** Pin a release or commit with `$env:WTT_REF='<tag or sha>'`, or download `bootstrap.ps1`, `Migrate-Windows.ps1` and `lib/WttFtp.cs`, read them, and run them locally (`Start-Migration.cmd`). The bootstrap prints a SHA-256 of both files so you can compare them with what you reviewed.

## Accounts and sign-in

### You do not need the Microsoft account password at all
**What happens.** With FTPS or FTP no Windows account takes part: the new PC signs in with a random one-time password shown on the old PC's screen. With SMB (without `-UseOwnAccount`), S3 creates a disposable local administrator account on the old PC and D2 expects that account's name and password instead. Either way you never need to know, type or have access to the real account's password, which also means a lost or reset password, or a work PC where someone else holds it, no longer blocks the transfer.
**Why.** SMB needs a password-equivalent credential even to read the pairing file; a Windows Hello PIN or biometric sign-in on the old PC is not one, and the real Microsoft account password is often unavailable, not worth exposing over the network, or both. The FTP service sidesteps Windows sign-in completely.
**Instead.** Pass `-Transport Smb -UseOwnAccount` on the old PC only if you deliberately want to sign in with a real account instead - then the old PC's share sign-in works with the account e-mail, sometimes only as `MicrosoftAccount\you@outlook.com` (the tool tries both forms).

### Elevating with another account migrates the wrong profile
**What happens.** If a standard user elevates by typing a different administrator's password, `HKCU` and `%USERPROFILE%` inside that window belong to the administrator. The tool compares the owner of Explorer with the current user and stops when they differ.
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
**What happens.** When Desktop, Documents or Pictures is inside OneDrive on both PCs and both sign in to the same account, copying creates duplicates or "- Copy" conflicts and forces cloud-only placeholders on the old PC to download while they are read. The plan step warns about this.
**Instead.** Untick those folders and let OneDrive sync them. Only copy folders that are not under OneDrive on at least one side.

### Newer files on the new PC are kept
**What happens.** robocopy runs with `/XO`, and the FTP mirror follows the same rule: if a file already exists on the new PC with a newer timestamp, or the same timestamp and size, the old PC's copy is skipped.
**Why.** Protects work done on the new PC before the transfer, and makes a second run cheap.
**Instead.** If you really want the old PC's version, delete the file on the new PC first or copy that file by hand.

### Folders redirected to a network drive
**What happens.** If Documents on the old PC points at `\\server\share`, the item is skipped ("not on a local drive" over SMB, "not on old PC" over FTP/FTPS).
**Instead.** Point the new PC's Documents at the same server location (Properties > Location).

### Files in use and long paths
**What happens.** Open files (Outlook `.pst`, databases) fail with "sharing violation" or "in use"; paths over 260 characters may fail. The item ends as WARN and the other files are still copied.
**Instead.** Close Outlook and other apps on the old PC before S2. Rerun just that item afterwards; the log names every failed file.

### Permissions and ownership
**What happens.** Files are copied with data, attributes and timestamps over SMB (`/COPY:DAT`), not with their ACLs. They inherit the new PC's profile permissions.
**Why.** Old-PC ACLs reference SIDs that do not exist on the new PC.
**Instead.** Nothing to do for personal files. For `.ssh` keys the inherited profile permissions are what OpenSSH expects.

### FTP and FTPS copy less metadata than robocopy
**What happens.** Over FTP/FTPS the file contents and each file's modified time (to the second) are copied. Not copied: attributes (Hidden, Read-only, System), ACLs, creation and access times, folder timestamps, and alternate data streams such as the "downloaded from the internet" mark. Empty folders are created. Directory junctions and symbolic links are skipped, as with robocopy `/XJ`.
**Why.** FTP has no way to carry them, and recreating them would need a second, Windows-only channel.
**Instead.** Use `-Transport Smb` if hidden or read-only attributes matter. For a few files, re-apply attributes by hand afterwards.

### FTP and FTPS are slower for many small files
**What happens.** Every file needs its own data connection (and, for FTPS, its own TLS handshake). The mirror runs up to eight connections in parallel (`-Threads`), which hides most of it, but a folder of tens of thousands of tiny files is still slower than robocopy over SMB. A failed file is retried three times from its start; there is no resume inside a file.
**Instead.** Rerun after an interruption: files that are already complete are skipped. Use `-Transport Smb` for huge trees of small files.

## Flash drive or external SSD

### Only a drive with the WTT-Transfer folder is used
**What happens.** The tool looks at external drives only (removable media, or a disk on a USB bus), never the system drive, and uses one only if its root contains a folder named `WTT-Transfer`. Without it the old PC step lists the external drives it found and offers to create the empty folder on the letter you type; the new PC step waits for you to plug the right drive in. Everything is written, read and deleted inside that folder.
**Why.** A tool that copies tens of gigabytes should not guess which disk may be written to.
**Instead.** Create the folder yourself, or run `.\Migrate-Windows.ps1 -PrepareDrive D:`. A folder that is itself a junction or link is refused, and so is a drive that holds one inside the folder when the tool is about to empty it.

### Some external drives are not recognised as external
**What happens.** Windows reports a drive as external when it is removable or sits on a USB bus. An external SSD or hard drive in a Thunderbolt or NVMe enclosure, or behind a bridge that presents itself as SATA, may be reported as an ordinary internal disk and is then not offered.
**Why.** The tool has no other reliable way to tell an external disk from a second internal one, and an internal data disk should not be offered by accident.
**Instead.** Name it with `-Drive X:` (and `-PrepareDrive X:` the first time). The folder is still required, and the system drive is still refused.

### The drive holds your files and your Wi-Fi passwords in clear text
**What happens.** `WTT-Transfer\pkg\wifi` contains every saved Wi-Fi key in clear text and `data` holds copies of your personal files, for as long as the transfer is on the drive. Nothing encrypts it unless you do.
**Why.** `netsh wlan export profile key=clear` is the only way to carry Wi-Fi keys between PCs, and a plain drive has no access control.
**Instead.** Turn on BitLocker To Go for the drive (right-click it in Explorer) before the transfer if it could be lost or stolen, keep it with you, untick "Saved Wi-Fi networks" in the new PC's menu if you would rather type them, and let the new PC empty the folder at the end (it asks, default no). To do it by hand, delete everything inside `WTT-Transfer`.

### FAT32 cannot hold files over 4 GB
**What happens.** On a FAT32 drive a single file above 4 GB fails to copy. The tool warns when it sees FAT32, and the item ends as WARN with the file named in the log.
**Why.** It is a limit of the file system.
**Instead.** Format the drive as exFAT or NTFS first (this erases it), or copy those few files another way. FAT and exFAT also keep file times with 2-second precision, so the tool adds `/FFT` to robocopy there; a repeat run then does not copy everything again.

### The size estimate is a list-only count with some headroom
**What happens.** Before copying, every file item is measured with a list-only `robocopy` and the menu shows the sizes. The selection must fit the free space plus 2% plus 300 MB, or you choose again. Files that are online-only in OneDrive count with their full size and are downloaded to this PC while they are copied.
**Why.** The real copy can differ slightly: files change between measuring and copying, and the package and logs need room too.
**Instead.** Leave some free space on the drive, close apps that write to the folders, and untick OneDrive folders if the new PC signs in to the same OneDrive.

### The new PC only gets what the old PC copied
**What happens.** With a drive the old PC decides which file items are copied. The new PC's menu hides file items that are not on the drive, and shows the settings items, which live in the small package that is always written.
**Why.** There is no live connection to fetch anything else from.
**Instead.** Run the old PC step again for the missing folders (finished transfers can be updated: it asks whether to replace, and "continue" is offered after an interruption), or copy them by hand ([manual.md](manual.md#copying-with-a-drive-by-hand)).

### An interrupted copy
**What happens.** `transfer.json` stays `incomplete` if the old PC step is stopped, the drive is pulled out or the PC sleeps. The new PC refuses such a drive unless you answer yes to "use it anyway".
**Instead.** Plug the drive back in and run the old PC step again; answer yes to "Continue it?". Files that are already complete are skipped. Eject the drive with Safely Remove Hardware after the last copy: the tool asks Windows to flush the drive's write cache at the end, but only a proper eject guarantees it, and an external SSD set to "better performance" may hold writes for a while.

### Drive letters do not matter, a PC with the same name does
**What happens.** Nothing on the drive refers to a drive letter, so it can be D: on one PC and F: on the other. If the drive was written by a PC with the new PC's own name, the tool stops and asks, because that usually means you are on the old PC.
**Instead.** Answer yes only if the two PCs really share a name (for example after a reinstall on the same hardware).

### More than one transfer drive
**What happens.** If two drives both have the folder, the tool asks which one to use. On the new PC only drives that also hold a `transfer.json` count.
**Instead.** Pick by number, or give the letter with `-Drive`.

### Files in use, junctions and metadata
The old PC copies with `robocopy`, so the usual limits apply: files that are open (an Outlook `.pst`, a running browser's profile) end as WARN, junctions and links are skipped (`/XJ`), and ACLs are not copied (`/COPY:DAT`). Attributes survive on NTFS, FAT32 and exFAT. Close Outlook, browsers and Sticky Notes on the old PC first: the old PC step reminds you for the items that need it and does not close anything itself.

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

### Tested on one machine, not yet between two PCs
The FTP/FTPS server and client are tested against each other and against `curl` on one machine in Windows PowerShell 5.1 and PowerShell 7: login and lockout, listing, hidden files, refused paths (parent folders, junctions, device names, alternate streams), uploads, pinning, resume of a second run, locked files, parallel copies. The script's stages around them are exercised with stand-ins for the firewall and prompts.

The drive transport is tested in both PowerShell versions against stand-in drive folders (an NTFS one and a FAT32 one): preparing a drive, refusing internal drives, junction markers and drives without the folder, the path guards, emptying, size measuring, the space check, the whole old PC flow including continue and replace, and the new PC's detection, menu filtering, restore and cleanup. The two USB sticks that were plugged in were only read: detection and the refusal to use a drive without the folder were checked on them, and nothing was written to them.

**Not yet exercised: writing to a real USB drive, creating the Windows Firewall rule (needs an elevated window) and a real run between two PCs.** Use `-DryRun` first, and keep the old PC until the new one is verified.

### The first start compiles a small C# file
**What happens.** `Add-Type` compiles `lib/WttFtp.cs` when FTP or FTPS is used, which takes a second or two and needs the file next to the script. It fails where PowerShell runs in Constrained Language Mode (AppLocker or Windows Defender Application Control policies on managed PCs).
**Instead.** Keep the `lib` folder with the script (the bootstrap does), or use `-Transport Smb` on such a PC.

### Windows PowerShell 5.1 is the default host
`bootstrap.ps1` runs in whichever PowerShell you paste it into; `Start-Migration.cmd` always uses Windows PowerShell 5.1. The script is written ASCII-only, and the C# file is ASCII-only and C# 5 compatible, for that reason.

### The pairing code wait is not a timeout
S4 and S5 wait until a marker appears or you press Enter. A PC that goes to sleep breaks the connection; the tool asks Windows to stay awake while it runs, but a lid close still sleeps a laptop.

### Keep-awake is best effort
`SetThreadExecutionState` is per thread; PowerShell normally runs the script on one thread, but a host that switches threads will drop the request. Plug both PCs in and set sleep to Never for the duration if the transfer is large.

### Interrupted runs
Ctrl+C on the new PC may leave Explorer stopped (run `explorer` from Task Manager) and, over SMB, leaves the connection open until the window closes. Over FTP/FTPS the temporary export folder in `%TEMP%` is normally removed even then; if the window was killed, delete `%TEMP%\wtt-*` yourself. Rerun afterwards: robocopy and the FTP mirror both skip files that are already there.
