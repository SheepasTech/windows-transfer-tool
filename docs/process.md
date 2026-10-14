# Process

The tool is two cooperating programs: `Migrate-Windows.ps1 -Mode Source` on the old PC and `-Mode Destination` on the new PC, both normally started by `bootstrap.ps1`. Each side is a fixed sequence of stages. The stage code (S1..S6, D1..D7) is printed on screen and written to the transcript log, so problems can be pinned to a stage.

- [Getting the tool onto both PCs](#getting-the-tool-onto-both-pcs)
- [Old PC stages](#old-pc-stages)
  - [The temporary account](#the-temporary-account)
- [New PC stages](#new-pc-stages)
- [Binding handshake](#binding-handshake)
- [Sharing state on the old PC](#sharing-state-on-the-old-pc)
- [Files produced](#files-produced)

## Getting the tool onto both PCs

```mermaid
sequenceDiagram
    autonumber
    actor U as You
    participant G as GitHub (raw)
    participant O as OLD PC
    participant N as NEW PC

    U->>O: irm .../bootstrap.ps1 | iex
    O->>O: ask role (1 = old PC), elevate (UAC)
    O->>G: GET Migrate-Windows.ps1
    G-->>O: script (parsed and hashed before use)
    O->>O: -Mode Source  (S1..S4), creates a temporary account, shows IP + pairing code + that account
    U->>N: irm .../bootstrap.ps1 | iex
    N->>N: ask role (2 = new PC), elevate (UAC)
    N->>G: GET Migrate-Windows.ps1
    G-->>N: script
    N->>N: -Mode Destination (D1..D7)
    N->>O: SMB connect as the temporary account, verify code, bound.json
    O->>O: S4 scopes firewall to the new PC, S5 waits
    N->>O: copy files, read registry exports
    N->>O: done.json
    O->>O: S6 cleanup
```

`bootstrap.ps1` only needs the network; the two copies of `Migrate-Windows.ps1` then talk to each other over SMB. Nothing is uploaded anywhere. By default the new PC signs in with a disposable account the old PC creates for this one run, not with either PC's real Windows or Microsoft account - see [the temporary account](#the-temporary-account).

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
    subgraph S2["S2 Export to C:\MigrationExport"]
        direction TB
        E1["manifest.json: user, profile path, known folders, OS"]
        E2["reg folder: one .reg file per registry key, per catalog item"]
        E3["wifi folder: one .xml per network (key=clear)"]
        E4["apps-report.csv, apps.json (winget), vscode-extensions.txt"]
        E5["power.pow, wallpaper file"]
        E1 --> E2 --> E3 --> E4 --> E5
    end
    E5 --> S3
    subgraph S3["S3 Open sharing (recorded in prep-state.json)"]
        direction TB
        H0{"-UseOwnAccount?"} -- no --> H0a["create temporary local admin account<br/>random name + 24-char password"]
        H0 -- yes --> H1
        H0a --> H1["start Server service if stopped"] --> H2["enable firewall group<br/>File and Printer Sharing"]
        H2 --> H3["Public networks -> Private"] --> H4["LocalAccountTokenFilterPolicy = 1"]
    end
    H4 --> S4
    subgraph S4["S4 Pair"]
        direction TB
        R1["pair.json: salt + SHA256(salt:code)"] --> R2["show IP addresses + 6-digit code<br/>+ temporary account name/password (if created)"]
        R2 --> R3{"bound.json with<br/>matching SessionId?"}
        R3 -- "Enter / Q" --> CANCEL["cancelled"]
        R3 -- yes --> R4["resolve client IP (SMB session)"] --> R5["firewall rules RemoteAddress = that IP"]
    end
    R5 --> S5
    subgraph S5["S5 Wait"]
        W1{"done.json?"} -- "Enter" --> W2["finish early"]
        W1 -- yes --> W2
    end
    CANCEL --> S6
    W2 --> S6
    subgraph S6["S6 Cleanup (also: -Cleanup)"]
        C1["restore firewall rules (enabled state + addresses)"] --> C2["Private -> Public where it was Public"]
        C2 --> C3["restore / remove LocalAccountTokenFilterPolicy"] --> C4["stop Server service if we started it"]
        C4 --> C5["delete the temporary account, if one was created"] --> C6["delete C:\MigrationExport"]
    end
    C6 --> Z([Old PC unchanged])
```

| Stage | Changes on the old PC | Undo |
|---|---|---|
| S1 | none | |
| S2 | writes `C:\MigrationExport` (contains Wi-Fi passwords in clear text) | deleted in S6 |
| S3 | creates a temporary local administrator account unless `-UseOwnAccount`; firewall group enabled, network profile Private, `LocalAccountTokenFilterPolicy=1`, Server service started if it was stopped | S6 restores each from `prep-state.json`, including deleting the temporary account |
| S4 | firewall rules scoped to the new PC's IP | S6 restores the original addresses |
| S5 | none | |
| S6 | reverts S2 to S4 | |

### The temporary account

Stage S3 normally creates a local administrator account named `WTT-xxxxxxxx` with a random 24-character password, used for nothing except the SMB sign-in the new PC needs in D2. It is hidden from the normal sign-in screen, shown on screen in S4 next to the pairing code, and deleted again in S6 - it never touches your real account and does not need your Microsoft account password, which is the point: you may not have that password at all (lost, reset, or held by someone else on a work PC). The new PC does not offer to save it to `credentials.json`, because it stops working the moment this run ends. Pass `-UseOwnAccount` on the old PC to skip all of this and sign in with your own Windows account instead, as earlier versions of this tool required.

Any error after S1 jumps straight to S6, so sharing is never left open by an exception. If the window is closed, run `Migrate-Windows.ps1 -Cleanup` (elevated) or follow [manual.md](manual.md#reverting-the-sharing-changes-by-hand).

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
        B1["credentials.json or prompt: IP, temporary account name/password<br/>(from the old PC's S4 screen)"] --> B2{"ping ok?"}
        B2 -- no --> X2[/"stop: old PC not reachable"/]
        B2 -- yes --> B3["SMB connect to the old PC's C$ share<br/>tries: user, IP + user, MicrosoftAccount + email"]
        B3 --> B4{"manifest.json present?"}
        B4 -- no --> X3[/"stop: run Source first"/]
        B4 -- yes --> B5{"pairing code matches pair.json?"}
        B5 -- "no (3 tries)" --> X4[/"stop: wrong PC or code"/]
        B5 -- yes --> B6["write bound.json"] --> B7{"temporary account?"}
        B7 -- yes --> B7a["skip credentials.json offer<br/>(stops working at S6 cleanup)"]
        B7 -- no --> B7b["offer to save credentials.json"]
    end
    B7 --> D3
    subgraph D3["D3 Select"]
        direction TB
        M1["menu or -Select"] --> M2["order: Files, Apps, Settings<br/>Explorer items last"] --> M3["show plan + warnings<br/>OneDrive, keys, user name differs"] --> M4{"Proceed?"}
    end
    M4 -- no --> END
    M4 -- yes --> L["create ~\Migration\logs, registry-backup-*<br/>start transcript"]
    L --> D4
    subgraph D4["D4 Files"]
        F1["robocopy each known folder and extra folder<br/>/E /XO /XJ, log to robocopy-*.log"]
    end
    F1 --> D5
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
    Z5 --> END([Disconnect share])
```

| Stage | Changes on the new PC | Undo |
|---|---|---|
| D1 | none | |
| D2 | SMB connection to the old PC, normally as its temporary account; optional `credentials.json` next to the script (skipped for a temporary account) | connection removed at the end; delete the file |
| D3 | none | |
| D4 | files added to the profile folders. `/XO` means a newer file already on the new PC is never overwritten | delete what you do not want; `robocopy-*.log` lists every file |
| D5 | app data files, winget installs, VS Code extensions | uninstall; delete files |
| D6 | registry keys imported, Explorer restarted, wallpaper set | every imported key was exported first to `~\Migration\registry-backup-<time>\<item>\NN.reg`; double-click to restore |
| D7 | `done.json` on the old PC, optional sign-out | |

Dry runs (`-DryRun`) still bind and still print the plan, but robocopy runs with `/L`, no registry is touched, Explorer is left alone and no `done.json` is written, so the old PC keeps waiting for the real run.

## Binding handshake

```mermaid
sequenceDiagram
    participant O as OLD PC (S4)
    participant N as NEW PC (D2)

    O->>O: code = random 6 digits, salt = GUID
    O->>O: pair.json = { SessionId, Salt, PairHash = SHA256(salt:code) }
    O-->>O: screen: IP addresses + code
    Note over O: polls C:\MigrationExport\bound.json every 2 s

    N->>O: SMB session with the old PC's Windows login
    N->>O: read manifest.json, pair.json
    N->>N: SHA256(salt:typed code) == PairHash ?
    alt mismatch
        N-->>N: ask again (3 tries), then stop
    else match
        N->>O: write bound.json = { SessionId, ComputerName, UserName, IPs }
    end

    O->>O: Get-SmbSession -> client IP (fallback: IPs from bound.json)
    O->>O: Set-NetFirewallRule -RemoteAddress clientIP on the sharing group
    Note over O,N: transfer runs (D3..D6) - only clientIP can reach the share
    N->>O: write done.json = { SessionId, Summary }
    O->>O: S6 cleanup
```

What the code does and does not protect:

- It confirms the new PC is reading the export of the PC whose screen you are looking at, and lets the old PC learn which address to trust.
- It is not a secret by itself. Anyone who can already open `\\oldpc\C$` has a working credential - normally the temporary account's password, shown on the same screen. That password *is* the real secret for this run: anyone who reads it off the old PC's screen before you do can also connect.
- The firewall scope stops other machines reaching the sharing ports after binding. Between S3 and the moment of binding the share is open to the local subnet, as it is on any PC with sharing turned on.

## Sharing state on the old PC

```mermaid
stateDiagram-v2
    [*] --> Normal
    Normal --> Open : S3 Enable-Sharing<br/>prep-state.json written
    Open --> Bound : S4 bound.json seen<br/>rules scoped to new PC
    Open --> Normal : S6 (Enter/Q in S4, or error)
    Bound --> Normal : S6 (done.json, Enter in S5, or error)
    Open --> Normal : -Cleanup (window was closed)
    Bound --> Normal : -Cleanup (window was closed)
    Normal --> [*]
```

`prep-state.json` is the single source of truth for the revert: firewall rule names with their original enabled state and remote addresses, the interfaces that were Public, the previous `LocalAccountTokenFilterPolicy` value, and whether the Server service was started by the tool.

## Files produced

Old PC, `C:\MigrationExport` (deleted in S6):

```
manifest.json            who, which profile, known-folder paths, OS, wallpaper file name
pair.json                salt + hash of the pairing code, SessionId
bound.json               written by the new PC in D2
done.json                written by the new PC in D7
prep-state.json          what S3/S4 changed, for S6
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
logs\robocopy-<time>.log           every file robocopy touched or skipped
registry-backup-<time>\<item>\     the new PC's keys before import (double-click a .reg to restore)
old-pc-installed-apps.csv          the old PC's program list for manual installs
```
