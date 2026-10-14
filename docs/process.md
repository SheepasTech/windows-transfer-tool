# Process

The tool is two cooperating programs: `Migrate-Windows.ps1 -Mode Source` on the old PC and `-Mode Destination` on the new PC, both normally started by `bootstrap.ps1`. Each side is a fixed sequence of stages. The stage code (S1..S6, D1..D7) is printed on screen and written to the transcript log, so problems can be pinned to a stage.

There are three ways for the new PC to reach the old one, chosen on the old PC: **FTPS** (default), **FTP** and **SMB**. The stages are the same for all three; only S3, S4, D2, D4 and S6 differ inside.

- [Getting the tool onto both PCs](#getting-the-tool-onto-both-pcs)
- [Old PC stages](#old-pc-stages)
- [The FTP and FTPS service](#the-ftp-and-ftps-service)
- [The temporary account (SMB)](#the-temporary-account-smb)
- [New PC stages](#new-pc-stages)
- [Binding handshake](#binding-handshake)
- [State on the old PC](#state-on-the-old-pc)
- [Files produced](#files-produced)

## Getting the tool onto both PCs

```mermaid
sequenceDiagram
    autonumber
    actor U as You
    participant G as GitHub (raw, branch ftp-ftps)
    participant O as OLD PC
    participant N as NEW PC

    U->>O: irm .../ftp-ftps/bootstrap.ps1 | iex
    O->>O: ask role (old PC) and transfer method, elevate (UAC)
    O->>G: GET Migrate-Windows.ps1 and lib/WttFtp.cs
    G-->>O: both files (the script is parsed, both are hashed)
    O->>O: -Mode Source  (S1..S4) shows IP, port, pairing code, password, fingerprint
    U->>N: irm .../ftp-ftps/bootstrap.ps1 | iex
    N->>N: ask role (new PC), elevate (UAC)
    N->>G: GET Migrate-Windows.ps1 and lib/WttFtp.cs
    G-->>N: both files
    N->>N: -Mode Destination (D1..D7) detects the transport
    N->>O: connect, check certificate, sign in, verify code, bound.json
    O->>O: S4 narrows the service to the new PC, S5 waits
    N->>O: copy files, read registry exports
    N->>O: done.json
    O->>O: S6 cleanup
```

`bootstrap.ps1` only needs the network; the two copies of `Migrate-Windows.ps1` then talk to each other directly. Nothing is uploaded anywhere. Both PCs need `lib/WttFtp.cs` next to the script for FTP and FTPS (the bootstrap downloads it; for an offline copy take the whole folder).

## Old PC stages

```mermaid
flowchart TD
    A([Start -Mode Source]) --> S1
    subgraph S1["S1 Preflight"]
        direction TB
        P1{"Elevated?"} -- no --> X1[/"stop: run as administrator"/]
        P1 -- yes --> P2{"Explorer owner = this user?"}
        P2 -- no --> X2[/"stop: wrong account elevated"/]
        P2 -- yes --> P3["keep PC awake<br/>warn if known folders are in OneDrive"]
    end
    P3 --> S2
    subgraph S2["S2 Export to the MigrationExport folder on C:"]
        direction TB
        E1["manifest.json: user, profile path, known folders, OS"]
        E2["reg folder: one .reg file per registry key, per catalog item"]
        E3["wifi folder: one .xml per network (key=clear)"]
        E4["apps-report.csv, apps.json (winget), vscode-extensions.txt"]
        E5["power.pow, wallpaper file"]
        E1 --> E2 --> E3 --> E4 --> E5
    end
    E5 --> S3
    subgraph S3["S3 Open the way in (recorded in prep-state.json first)"]
        direction TB
        T0{"transport"} -- "Ftps or Ftp" --> T1["Ftps: self-signed certificate, made in memory<br/>random 16-character password (80 bits)"]
        T1 --> T2["prep-state.json notes the transport and the firewall rule name"]
        T2 --> T3["inbound firewall rule: control port and passive range,<br/>local subnet only"]
        T3 --> T4["start the read-only server inside this PowerShell window"]
        T0 -- "Smb" --> H0{"-UseOwnAccount?"}
        H0 -- no --> H0a["create temporary local admin account<br/>random name + 24-char password"]
        H0 -- yes --> H1
        H0a --> H1["start Server service if stopped"] --> H2["enable firewall group<br/>File and Printer Sharing"]
        H2 --> H3["Public networks -> Private"] --> H4["LocalAccountTokenFilterPolicy = 1"]
    end
    T4 --> S4
    H4 --> S4
    subgraph S4["S4 Pair"]
        direction TB
        R1["pair.json: salt + SHA256(salt:code)"] --> R2["show IP addresses and the 6-digit code<br/>Ftps/Ftp: port, password, fingerprint (Ftps)<br/>Smb: temporary account name and password"]
        R2 --> R3{"bound.json with<br/>matching SessionId?"}
        R3 -- "Enter / Q" --> CANCEL["cancelled"]
        R3 -- yes --> R4["client address:<br/>Ftps/Ftp: the address that logged in<br/>Smb: the SMB session"] --> R5["narrow to that address:<br/>Ftps/Ftp: server + firewall rule<br/>Smb: sharing firewall rules"]
    end
    R5 --> S5
    subgraph S5["S5 Wait"]
        W1{"done.json?"} -- "Enter" --> W2["finish early"]
        W1 -- yes --> W2
    end
    CANCEL --> S6
    W2 --> S6
    subgraph S6["S6 Cleanup (also: -Cleanup)"]
        direction TB
        C1{"transport in prep-state.json"} -- "Ftps or Ftp" --> C2["server stopped and certificate dropped,<br/>firewall rule removed"]
        C1 -- "Smb" --> C3["firewall rules restored, Public -> Private undone,<br/>token policy restored, Server service stopped if we started it,<br/>temporary account deleted"]
        C2 --> C4["delete the MigrationExport folder"]
        C3 --> C4
    end
    C4 --> Z([Old PC unchanged])
```

| Stage | Changes on the old PC | Undo |
|---|---|---|
| S1 | none | |
| S2 | writes `C:\MigrationExport` (contains Wi-Fi passwords in clear text) | deleted in S6 |
| S3 FTP/FTPS | `prep-state.json`, one inbound firewall rule named `WindowsTransferTool-temporary` (control port 2121 and passive ports 52100-52150, local subnet), a server running inside the PowerShell window, for FTPS a certificate held in memory | S6 stops the server, removes the rule and deletes the export |
| S3 SMB | creates a temporary local administrator account unless `-UseOwnAccount`; firewall group enabled, network profile Private, `LocalAccountTokenFilterPolicy=1`, Server service started if it was stopped | S6 restores each from `prep-state.json`, including deleting the temporary account |
| S4 | FTP/FTPS: the server accepts the bound address only and the rule is narrowed to it. SMB: sharing rules scoped to the new PC's IP | S6 |
| S5 | none | |
| S6 | reverts S2 to S4 | |

Any error after S1 jumps straight to S6, so nothing is left open by an exception. If the window is closed, run `Migrate-Windows.ps1 -Cleanup` (elevated): it removes the firewall rule recorded in `prep-state.json` (or reverts SMB sharing) and deletes the export. The FTP server itself dies with the PowerShell window. Manual steps: [manual.md](manual.md#reverting-by-hand).

## The FTP and FTPS service

The old PC runs a small FTP server, written for this tool in [lib/WttFtp.cs](../lib/WttFtp.cs) and compiled when the tool starts. It implements just what a read-only transfer needs (explicit TLS with `AUTH TLS`, passive mode with `EPSV` and `PASV`, `MLSD`/`LIST`/`NLST`, `RETR`, `SIZE`, `MDTM`, `REST`, and `STOR` for two marker files), so ordinary FTP clients can use it as well.

One transfer session as the new PC sees it (FTPS shown; plain FTP is the same without the TLS steps):

```mermaid
sequenceDiagram
    participant N as NEW PC (client)
    participant O as OLD PC (service)

    N->>O: TCP connect to the control port (default 2121)
    O-->>N: 220 ready
    N->>O: AUTH TLS
    O-->>N: 234 proceed
    Note over N,O: TLS handshake on the control connection
    N->>N: SHA-256 of the certificate, compare with the old PC's screen, pin it
    N->>O: USER wtt, then PASS with the one-time password
    O-->>N: 230 logged in (five wrong passwords lock the service)
    N->>O: PBSZ 0 and PROT P so data connections are protected too
    loop every folder and every file
        N->>O: EPSV
        O-->>N: 229 passive port from the range 52100-52150
        N->>O: TCP connect to that port
        N->>O: MLSD folder, or RETR file
        O-->>N: 150 opening data connection
        Note over N,O: TLS handshake on the data connection, same pinned certificate
        O-->>N: listing or file bytes, then the connection closes
        O-->>N: 226 transfer complete
    end
    N->>O: STOR bound.json or done.json (the only uploads allowed)
```

For the bulk copy the new PC opens up to eight such connections in parallel, each pulling the next file from a shared list. A file is written next to its destination under a temporary name, given the old PC's modified time, and renamed into place, so an interrupted run never leaves a half-written file that looks complete.

Every path the client sends is vetted before anything touches the disk:

```mermaid
flowchart TD
    Q["client sends a path, for example /profile/Documents/a.txt"] --> A{"every segment safe?<br/>no backslash, colon, wildcard or control character,<br/>no trailing dot or space,<br/>no device name such as NUL or CON"}
    A -- no --> R550["550 refused"]
    A -- yes --> B["dot-dot only removes a segment of the virtual path,<br/>so it can never leave the shared roots"]
    B --> C{"first segment is a shared root?<br/>pkg, profile, known-Desktop, known-Documents ..."}
    C -- no --> R550
    C -- yes --> D{"a folder on the way is a<br/>junction or symbolic link?"}
    D -- yes --> R550
    D -- no --> E{"hidden name?<br/>pkg/prep-state.json"}
    E -- yes --> R550
    E -- no --> F{"command"}
    F -- "list or read" --> OK["served, read-only"]
    F -- "STOR" --> G{"exactly /pkg/bound.json<br/>or /pkg/done.json?"}
    G -- yes --> H["at most 64 KB, written to a temporary file, then renamed"]
    G -- no --> R550
    F -- "delete, rename, make folder ..." --> R550
```

The data port only accepts a connection from the address that owns the control connection. After the new PC has bound, the server accepts that address only. Directory listings leave out junctions and symbolic links, so a copy cannot wander into folders outside the profile.

## The temporary account (SMB)

Only for `-Transport Smb`. Stage S3 then creates a local administrator account named `WTT-xxxxxxxx` with a random 24-character password, used for nothing except the SMB sign-in the new PC needs in D2. It is hidden from the normal sign-in screen, shown on screen in S4 next to the pairing code, and deleted again in S6 - it never touches your real account and does not need your Microsoft account password, which is the point: you may not have that password at all (lost, reset, or held by someone else on a work PC). The new PC does not offer to save it to `credentials.json`, because it stops working the moment this run ends. Pass `-UseOwnAccount` on the old PC to sign in with your own Windows account instead. FTP and FTPS do not need any Windows account, which is why they are the default.

## New PC stages

```mermaid
flowchart TD
    A([Start -Mode Destination]) --> D1
    subgraph D1["D1 Preflight"]
        direction TB
        P1{"Elevated?"} -- no --> P1w["warn: Wi-Fi, winget and some settings need it"]
        P1 -- yes --> P2
        P1w --> P2{"Explorer owner = this user?"}
        P2 -- no --> X1[/"stop: wrong account elevated"/]
        P2 -- yes --> P3["keep PC awake, check winget"]
    end
    P3 --> D2
    subgraph D2["D2 Bind"]
        direction TB
        B0["old PC address: -OldPCIP or prompt"] --> B1{"-Transport Auto?"}
        B1 -- yes --> B2["probe the FTP port: AUTH TLS accepted = Ftps,<br/>plain FTP greeting = Ftp, no answer = Smb"]
        B1 -- no --> B3
        B2 --> B3{"transport"}
        B3 -- "Ftps" --> F1["TLS handshake, nothing secret sent yet:<br/>show the certificate fingerprint, or compare with -Fingerprint"]
        F1 --> F2{"fingerprint confirmed?"}
        F2 -- no --> X2[/"stop: nothing was sent to that server"/]
        F2 -- yes --> F3["ask for the password and sign in,<br/>pin this exact certificate for every later connection"]
        B3 -- "Ftp" --> F3
        F3 --> F4["fetch the export package into a private temporary folder"]
        B3 -- "Smb" --> M1["ping, sign-in (temporary account), SMB connect to the C$ share<br/>tries: user, IP + user, MicrosoftAccount + email"]
        M1 --> M2{"manifest.json present?"}
        M2 -- no --> X3[/"stop: run Source first"/]
        F4 --> M3
        M2 -- yes --> M3{"pairing code matches pair.json?"}
        M3 -- "no (3 tries)" --> X4[/"stop: wrong PC or code"/]
        M3 -- yes --> M4["write bound.json"]
    end
    M4 --> D3
    subgraph D3["D3 Select"]
        direction TB
        N1["menu or -Select"] --> N2["order: Files, Apps, Settings<br/>Explorer items last"] --> N3["show plan + warnings<br/>OneDrive, keys, user name differs"] --> N4{"Proceed?"}
    end
    N4 -- no --> END
    N4 -- yes --> L["create the Migration folder in the profile:<br/>logs and registry backups, start transcript"]
    L --> D4
    subgraph D4["D4 Files"]
        direction TB
        Y1{"transport"} -- "Ftps or Ftp" --> Y2["FTP mirror, up to 8 connections: list with MLSD, download,<br/>keep the old modified time, skip when the file here is newer,<br/>junctions never followed"]
        Y1 -- "Smb" --> Y3["robocopy each known folder and extra folder<br/>/E /XO /XJ, log to robocopy-*.log"]
    end
    Y2 --> D5
    Y3 --> D5
    subgraph D5["D5 Apps"]
        AP1["close browsers / Sticky Notes, copy app data"] --> AP2["winget import (if ticked)"] --> AP3["code --install-extension (if code exists)"]
    end
    AP3 --> D6
    subgraph D6["D6 Settings"]
        direction TB
        G1["items that do not need Explorer:<br/>input, region, env, net, fonts, Wi-Fi, power"] --> G2["backup current keys to registry-backup-*"]
        G2 --> G3["stop Explorer + StartMenuExperienceHost"] --> G4["Explorer items: appearance, taskbar, icons<br/>re-check Explorer is dead before every reg import"]
        G4 --> G5["start Explorer"] --> G6["apply wallpaper"]
    end
    G6 --> D7
    subgraph D7["D7 Finish"]
        Z1["summary table per stage"] --> Z2{"tell the old PC to clean up?"}
        Z2 -- yes --> Z3["write done.json"]
        Z2 -- "no (another pass planned)" --> Z4["old PC keeps waiting"]
        Z3 --> Z5{"sign out now?"}
        Z4 --> Z5
    end
    Z5 --> END([Disconnect, delete the temporary folder])
```

| Stage | Changes on the new PC | Undo |
|---|---|---|
| D1 | none | |
| D2 SMB | SMB connection to the old PC, normally as its temporary account; optional `credentials.json` next to the script (skipped for a temporary account) | connection removed at the end; delete the file |
| D2 FTP/FTPS | a private temporary folder in `%TEMP%` holding the export package (it contains the old PC's Wi-Fi keys in clear text); nothing is saved to `credentials.json` | the folder is deleted at the end of the run, also after an error |
| D3 | none | |
| D4 | files added to the profile folders. A newer file already on the new PC is never overwritten (`/XO` for robocopy, the same rule in the FTP mirror) | delete what you do not want; `robocopy-*.log` (SMB) or the same log file (FTP/FTPS) lists what was copied, skipped or failed |
| D5 | app data files, winget installs, VS Code extensions | uninstall; delete files |
| D6 | registry keys imported, Explorer restarted, wallpaper set | every imported key was exported first to `~\Migration\registry-backup-<time>\<item>\NN.reg`; double-click to restore |
| D7 | `done.json` on the old PC, optional sign-out | |

Dry runs (`-DryRun`) still bind, still fetch the small export package and still print the plan, but the copy lists what it would do and writes nothing (robocopy `/L`, or the FTP mirror's dry-run mode), no registry is touched, Explorer is left alone and no `done.json` is written, so the old PC keeps waiting for the real run.

## Binding handshake

```mermaid
sequenceDiagram
    participant O as OLD PC (S3, S4)
    participant N as NEW PC (D2)

    O->>O: code = random 6 digits, salt = GUID
    O->>O: pair.json = { SessionId, Salt, PairHash = SHA256(salt:code) }
    O-->>O: screen: IP addresses, code, and the password (FTP/FTPS) or temporary account (SMB)
    Note over O: polls bound.json in the export folder every 2 s

    alt FTPS or FTP
        N->>O: FTPS: certificate fingerprint checked against the old PC's screen
        N->>O: sign in with the one-time password
        N->>O: fetch the export package (manifest.json, pair.json, reg, wifi ...)
    else SMB
        N->>O: SMB session as the temporary account (or your own with -UseOwnAccount)
        N->>O: read manifest.json and pair.json from the C$ share
    end
    N->>N: SHA256(salt:typed code) == PairHash ?
    alt mismatch
        N-->>N: ask again (3 tries), then stop
    else match
        N->>O: write bound.json = { SessionId, ComputerName, UserName, IPs }
    end

    alt FTPS or FTP
        O->>O: the address that logged in (fallback: IPs from bound.json)
        O->>O: server accepts that address only, firewall rule RemoteAddress = that address
    else SMB
        O->>O: Get-SmbSession gives the client IP (fallback: IPs from bound.json)
        O->>O: Set-NetFirewallRule -RemoteAddress on the sharing group
    end
    Note over O,N: transfer runs (D3..D6), only that address can reach the old PC
    N->>O: write done.json = { SessionId, Summary }
    O->>O: S6 cleanup
```

What the code and the password do and do not protect:

- The code confirms the new PC is reading the export of the PC whose screen you are looking at, and lets the old PC learn which address to trust.
- The code is not a secret by itself. What grants access is the FTP/FTPS password (or the temporary SMB account's password), shown on the same screen. Anyone who reads it off the old PC's screen before you do can also connect, until the new PC has bound.
- With FTPS the fingerprint check is what stops someone else answering on the old PC's address from collecting the password: the password is only sent after you have confirmed the certificate.
- The firewall rule is limited to the local subnet from the start and to the new PC's address after binding. Between S3 and the moment of binding, other machines on the subnet can reach the port but need the password.

## State on the old PC

```mermaid
stateDiagram-v2
    [*] --> Normal
    Normal --> Open : S3 service started or sharing opened<br/>prep-state.json written
    Open --> Bound : S4 bound.json seen<br/>narrowed to the new PC
    Open --> Normal : S6 (Enter/Q in S4, or error)
    Bound --> Normal : S6 (done.json, Enter in S5, or error)
    Open --> Normal : -Cleanup (window was closed)
    Bound --> Normal : -Cleanup (window was closed)
    Normal --> [*]
```

`prep-state.json` is the single source of truth for the revert. For FTP/FTPS it records the transport, the firewall rule name and the bound address. For SMB it records firewall rule names with their original enabled state and remote addresses, the interfaces that were Public, the previous `LocalAccountTokenFilterPolicy` value, whether the Server service was started by the tool, and the temporary account's name. The FTP server needs no revert of its own: it lives inside the PowerShell window and ends with it.

## Files produced

Old PC, `C:\MigrationExport` (deleted in S6):

```
manifest.json            who, which profile, known-folder paths, OS, wallpaper file name
pair.json                salt + hash of the pairing code, SessionId
bound.json               written by the new PC in D2
done.json                written by the new PC in D7
prep-state.json          what S3/S4 changed, for S6 (never served over FTP)
reg\<item>\NN.reg        registry exports per catalog item
wifi\*.xml               Wi-Fi profiles with clear-text keys
apps-report.csv          every installed program (from the Uninstall registry keys)
apps.json                winget export
vscode-extensions.txt    output of code --list-extensions
power.pow                active power plan
wallpaper.<ext>          copy of the current wallpaper
```

New PC, `%USERPROFILE%\Migration` (kept):

```
logs\transfer-<time>.log           PowerShell transcript of the run
logs\robocopy-<time>.log           every file robocopy touched or skipped (SMB); per-folder copied/skipped/failed lines and errors (FTP/FTPS)
registry-backup-<time>\<item>\     the new PC's keys before import (double-click a .reg to restore)
old-pc-installed-apps.csv          the old PC's program list for manual installs
```

New PC, `%TEMP%\wtt-<guid>` (FTP/FTPS only, deleted at the end of the run): the fetched export package.
