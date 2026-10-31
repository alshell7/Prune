# Prune

A native macOS utility for developers that finds and clears disk space with explanations, not guesses.
Every suggestion tells you **what it is**, **why it's not needed**, **why you might keep it**, **what happens if you remove it**, and **how to get it back**.

- **Native SwiftUI app** (~2 MB binary) with a **menu bar companion** (free space, quick clean, watched folders).
- A full scan of a developer home folder (~900 projects, 1.3 M files) takes about **10 s**.
- **Local-only.** Nothing is uploaded and there are no network calls.

## Build & install

Requires macOS 14+ and Xcode or the Command Line Tools (Swift 5.9+).

```bash
./build.sh            # builds build/Prune.app
./build.sh --install  # also copies it to ~/Applications
```

**First launch:** grant **Full Disk Access** (System Settings › Privacy & Security › Full Disk Access › add Prune).
Without it, macOS hides the Trash, app containers and device backups, and asks separately before Prune can read Documents, Desktop and Downloads.
Each of those prompts pauses the scan until you answer it.

> The build is ad-hoc signed, so macOS treats every rebuild as a new app and asks for permissions again.
> To keep grants across rebuilds, create a code-signing certificate named `Prune Local Signing` in Keychain Access (Certificate Assistant › Create a Certificate › Code Signing).
> Then replace `--sign -` in `build.sh` with `--sign "Prune Local Signing"`.

## What it finds

| Category | Examples | How it decides |
|---|---|---|
| **Project Artifacts** | `node_modules`, `target/`, `.next`, `build/`, `dist/`, `.venv`, `Pods`, `.gradle`, `__pycache__`, `CACHEDIR.TAG` folders | Each folder is checked against a manifest beside it (`package.json`, `Cargo.toml`, `build.gradle`, `pyvenv.cfg`…). Anything git **tracks** is skipped. The verdict depends on how recently the project (or its worktree) was active. |
| **Dev Environments** | Android NDK / build-tools / platforms / system images / AVDs, Gradle distributions and JDKs, rustup toolchains, Go auto-toolchains, Node versions (nvm/fnm/volta/asdf/mise), Python (uv/pyenv/python.org/conda), JDKs, Ruby, FVM Flutter, .NET, ESP-IDF | **Cross-referenced with what your projects pin**: `ndkVersion`, `compileSdk`, `buildToolsVersion`, React Native's version catalog, `gradle-wrapper.properties`, `rust-toolchain.toml`, `go.mod`, `.nvmrc`, `.python-version`, `.tool-versions`, virtualenv `home =` paths, AVD `config.ini`. Defaults and versions in use are kept. Unpinned versions are suggested, with the project names listed. |
| **Developer Caches** | npm/yarn/pnpm/bun, pip/uv/poetry, Cargo registry, Go build & module caches, Gradle, Maven, CocoaPods, SwiftPM, Playwright/Puppeteer browsers, Metro, `~/.cache/*` | Safe caches are recommended. Re-download-heavy caches are recommended only when that ecosystem has been idle. Native tools are used where it matters (`go clean -modcache`, `uv cache clean`, `pnpm store prune`). |
| **Xcode & Simulators** | DerivedData (flags projects that no longer exist), old Device Support, archives, simulator runtimes, unavailable simulators, stale simulator data | Keeps the newest runtime and Device Support per platform. Archives are never auto-recommended because they hold dSYMs. |
| **Git Worktrees** | Linked worktrees (incl. Claude Code's `.claude/worktrees`) | Removed only via `git worktree remove`, which itself refuses dirty worktrees. Worktrees with uncommitted changes or orphan commits are **locked**. Branches are always kept. |
| **Docker & Homebrew** | Build cache, unused images, stopped containers, volumes, `brew cleanup`, orphaned dependencies | Volumes are flagged **High risk** because databases live there. |
| **Editors & IDEs** | Superseded VS Code/Cursor/Windsurf extension versions, workspace data for deleted folders, JetBrains/Android Studio caches from old versions | Uses each editor's own extension registry (`extensions.json`, `.obsolete`). |
| **AI Models & Tools** | Hugging Face hub (incl. shared/unreferenced blobs), Ollama, LM Studio, Chrome's on-device Gemini Nano, Claude Desktop's sandbox VM and old bundled Claude Code builds, Codex session history | Models are never auto-recommended unless untouched for months. Anything a running process uses is locked. |
| **System Junk** | App caches, Squirrel/ShipIt updater leftovers, Electron/Chromium web caches, logs, crash reports, iOS firmware, local Time Machine snapshots, Trash | Running apps are never auto-recommended. |
| **Applications** | Apps not opened in 60+ days, plus their Library leftovers | Uses Spotlight's last-used date. Running apps are locked. |
| **Dangling & Orphaned** | Data left by uninstalled apps, broken symlinks in `bin/` dirs, launch agents for missing programs, stale worktree records, broken git checkouts | |
| **Large & Old Files** | Files above your size threshold on all indexed volumes, plus old installers in Downloads | Recognizes installers whose app is already installed. |

Also included:
- **System Data:** breaks down what macOS's Storage settings calls "System Data" (SDKs, simulators, VMs, hidden tool folders, system volumes). Each part comes with advice and a link to act on it.
- **Disk Explorer:** browse any volume by folder size.
- **Watched Folders:** FSEvents-driven size tracking with growth alerts.
- **Low-disk notifications.**
- **History:** every action Prune has taken.

## Security

A local, read-only check that looks for malware, risky background items, poisoned packages and AI-agent backdoors. Results are judged in context: a finding needs a combination of signals, such as an unsigned program *and* a hidden location *and* network traffic. Developer tools aren't flagged just for being unsigned.

| Area | What it checks |
|---|---|
| Background items | LaunchAgents/Daemons, root helpers, cron, login hooks. Detects Apple-impersonating labels, random adware names, scripts that download and run code, and programs in hidden or temp folders. Shows each item's signer. |
| Running processes | System-process impersonators, binaries deleted after launch, temp-folder programs, reverse shells, miners, fake password dialogs, unsigned programs talking to the internet or listening on your network. |
| Packages | Known-compromised npm versions (chalk/debug 2025, nx "s1ngularity", Shai-Hulud, eslint-config-prettier, @solana/web3.js…), malicious install scripts, the Shai-Hulud `bundle.js` payload, typosquats, and Python `.pth` startup backdoors. Optional, opt-in **OSV.dev** check for malware reported since this build (sends only package names and versions). |
| AI agents | Claude Code hooks (personal and project-supplied), MCP servers in Claude, Codex, Cursor, VS Code, Gemini and Windsurf (unpinned packages, plaintext secrets, malicious commands). Third-party skills are scanned for malicious scripts and hidden-Unicode prompt injection. Rule files (CLAUDE.md, AGENTS.md, .cursorrules) are scanned for "rules file backdoor" tricks. |
| Projects | VS Code tasks that run on folder open (the fake-job-interview "Contagious Interview" technique), git hooks, install scripts, and Xcode build-phase scripts (XCSSET). |
| Project credentials | `.env` variants and likely hard-coded credentials in project source and configuration, including private-key headers and common token formats. Tracked files and files under public web folders are prioritized; ignored local files and examples are identified separately. |
| Browser extensions | Sideloaded extensions with broad access in Chromium-family browsers, and force-install files. |
| System | SIP, Gatekeeper, FileVault, Firewall and XProtect status, plus shell startup files, /etc/hosts overrides, configuration profiles and SSH authorized keys. |

Every finding comes with:
- a **chain diagram** of how it's wired (item → program → signer → network)
- the evidence, what it is, why it might be fine, and a recommendation

Credential findings show the file, line number, type of match, and Git exposure status; they never include the detected values. Open or reveal the file to review it yourself. Detection is heuristic and does not validate credentials or search Git history. The check reads UTF-8 project files up to 512 KiB, skips dependency/build directories and lockfiles, and reports when its scan limits or access errors leave coverage incomplete.

**Actions** are confirmed first and logged in History:
- Stop a process.
- Disable and quarantine a background item.
- Quarantine a file, package, skill or extension. It's moved aside with execute bits stripped, and restorable.
- Remove a hook or MCP server from its config. The file is backed up first.
- Comment out a shell-startup line.
- Remove cron entries.

## Task Manager

A live process list grouped by app, with CPU, memory and network bars.
- **Insights:** forgotten dev servers (orphaned node/python processes still listening on a port), runaway CPU, memory hogs, swarms of orphaned processes.
- **"Why is it running?":** a plain-language answer plus a chain diagram (launchd job → parent → process → signer → network).
- **Actions:** Stop, Force Stop, Pause/Resume (SIGSTOP/SIGCONT), Lower Priority, Disable Autostart (quarantines the launch item), Quarantine Program.

## Network

Live per-app traffic from `nettop`, plus sockets from `lsof`. Hostnames come from your own DNS (reverse lookup), and well-known owners are named (Apple, GitHub, Anthropic, AWS, Cloudflare…).
- **Insights:** top talkers, scripts online (which script, which hosts), unidentified hosts on unusual or backdoor ports, **beaconing** (steady periodic check-ins), apps accepting connections from your network, unsigned programs online.
- **Connection map:** a radial map per app, colored by destination owner.
- **Actions:** Stop, Block Incoming (macOS Application Firewall, admin), Open in Task Manager.

## Apps & Extensions

- **Apps:** every app with its size *and* its data, flagged as unused, never opened, Intel-only, 32-bit, unsigned or damaged, duplicate, installer leftover, or runs in the background. A tree shows what each app installs: login items, agents, root daemons, privileged helpers, system extensions, app extensions.
- **Extensions & Add-ons:** system extensions, virtual audio drivers, Quick Look generators, Spotlight importers, preference panes, internet plug-ins, screen savers, input methods and kernel extensions. Each is marked **dangling** (its app is gone), **obsolete** (macOS no longer loads it) or OK. Folder-based add-ons can be quarantined. For a missing app extension, Prune attempts to remove its PlugInKit registration; when macOS refuses a missing bundle, it can disable stale registrations instead. It refuses to disable an identifier if another copy exists or is on a disconnected drive. System extensions must still be managed through macOS or their owning app.
- **App Mover:** each app gets a verdict (movable, caution or stays) with reasons. Apps with system extensions, root helpers or App Store management stay put. A move works like this:
  1. Copies the bundle to the drive and checksums every file.
  2. Requires the copy to pass `codesign --verify --deep --strict`.
  3. Leaves a link in /Applications and registers the new location with Launch Services.
  4. Can also move the app's Application Support data.

  Bring Back reverses it.

## Disks

Overview shows every mounted disk with its own ring and an **Analyze** switch (also in Settings › Scanning). Cleanup, Code Backup, and project security checks use the disks you pick. Project artifacts and large files on those disks are discovered directly even when Spotlight is disabled. The startup-disk ring counts only cleanup attributed to that disk. Read-only disks can be analyzed, but their cleanup actions are locked. Any disk can be opened in Disk Explorer or used as an Offload destination.

## Duplicate Finder

Run this separate scan from **Tools › Duplicate Finder** to compare files of at least 10 MB across selected locations. Prune groups candidates by size and sampled content, verifies matches with full SHA-256 hashes, and ignores symlinks and duplicate hard links. It rechecks both files before moving a chosen copy to the Trash. The scan caps full-content verification at 8 GiB and reports incomplete coverage; APFS clones and the Trash can make actual space recovered differ from file size.

## Code Backup

Checks every project for source code that exists only on this Mac:
- not in git
- no remote
- unpushed commits, local-only branches or stashes
- uncommitted edits

A "This Mac ↔ Remote" diagram shows each branch's state. Actions:
- **Initialize Git:** adds a starter .gitignore and never auto-commits.
- **Push.**
- **Create a private GitHub repo** via `gh`, after confirmation.
- **Fetch.**

Remote comparisons use the last locally known remote state; run Fetch to refresh it. Linked worktrees are checked too, and Git errors are shown as unknown instead of treating them as proof of a backup. Credentials embedded in remote URLs are hidden in the interface.

Offload and Disk Explorer warn before moving or trashing folders that contain unbacked-up source.

## Visuals

- **Overview:** a disk ring showing in use, recommended, optional, purgeable and free space, plus "free after cleanup".
- **Disk Explorer:** a squarified treemap you can drill into, color-coded by kind (rebuildable, hidden/tool data, media, archives).
- **System Data:** a composition bar.
- **Offload:** live before/after disk bars.
- **Tables:** inline size bars.
- **Animation:** spring transitions and hover lift throughout.

## Offload to Drive

Moves projects and folders (Documents, Downloads, Desktop, data folders inside projects) to an external drive to free internal space.

**Choosing what to move**
- **Projects** are listed with how recently you touched them. Idle ones are marked as good candidates.
- **Rebuildable folders** (`node_modules`, `target/`, `.next`, venvs…) are left behind instead of copied. Their restore commands are saved with the move.
- **Data folders** such as `models/` and `data/` can move on their own, while the code next to them stays put. Folders git tracks are never offered, because a link would change the repository.

**How a move works**
1. **Copy:** Apple's `copyfile` in parallel, keeping permissions, extended attributes, ACLs, symlinks and sparse files. Re-running after an interruption skips files that are already there.
2. **Catch up:** re-scans the source and copies anything that changed during the copy. If files keep changing, it stops.
3. **Verify:** compares sizes and links for every file, plus SHA-256 checksums (on by default).
4. **Swap:** renames the original aside (atomic), puts a link in its place, then removes the original. If anything fails before this step, your Mac is unchanged. `git worktree repair` keeps linked worktrees valid.

**Refusals and warnings**
- Refuses a folder that any process is using (a terminal, dev server or IDE has it open).
- Refuses top-level home folders, app Library data, iCloud folders and credential folders.
- Refuses the startup disk as a destination.
- Warns about ExFAT/FAT32 drives (they can't hold symlinks or permissions) and network drives.

**Bring Back** reverses a move. The data is copied home, checksummed, then swapped back in, and you can keep or delete the drive copy. Every move is recorded in History and in `~/Library/Application Support/Prune/offloads.json`.

## Safety model

1. **Trash first.** Everything goes to the Trash unless it's a cache rated *Safe* **and** you enabled "Delete Safe items immediately". Commands (`git`, `docker`, `xcrun`, `brew`…) are shown verbatim before they run.
2. **SafetyGuard re-checks every path right before removal.** It refuses:
   - system folders, top-level home and Library folders, and volume roots;
   - Keychains, `~/.ssh`, iCloud Drive, Photos/Mail/Messages libraries, `.aws`, `.kube`;
   - anything inside `.git`, and any folder that is itself a git repository;
   - the inside of app bundles, and mount points.
3. **Git-aware.** Folders git tracks are never offered. Worktrees go through `git worktree remove` (no `--force`).
4. **Review sheet.** You see every item, its risk and its action. You must tick a confirmation before anything rated *Review* or *High* is removed. Items nested in other selected items are counted once.
5. **Administrator actions** (system crash reports, broken links in `/usr/local/bin`, root launch agents) go through the standard macOS password prompt and move items to the Trash.
6. **Audit log** at `~/Library/Logs/Prune/history.jsonl`.
7. **"Never Suggest This Again"** (right-click any item) adds the path to Settings › Safety › Never touch.

## Command line

```bash
build/Prune.app/Contents/MacOS/Prune --scan        # headless, read-only report
build/Prune.app/Contents/MacOS/Prune --scan --all  # every item
build/Prune.app/Contents/MacOS/Prune --selftest            # 32 cleanup safety checks on throwaway fixtures (not logged to History)
build/Prune.app/Contents/MacOS/Prune --selftest-offload    # moves a fixture repo and a signed test app to a scratch APFS disk image and back
build/Prune.app/Contents/MacOS/Prune --offload-candidates  # what Offload would suggest (read-only)
build/Prune.app/Contents/MacOS/Prune --security [--all]     # security check report (read-only)
build/Prune.app/Contents/MacOS/Prune --code-backup          # backup status of every project (read-only)
build/Prune.app/Contents/MacOS/Prune --apps                 # app inventory, move verdicts and add-ons (read-only)
build/Prune.app/Contents/MacOS/Prune --selftest-security    # plants inert attack fixtures, checks detection and actions (34 checks)
build/Prune.app/Contents/MacOS/Prune --selftest-features    # disk-selection, credential, duplicate and extension fixtures
build/Prune.app/Contents/MacOS/Prune --selftest-volumes     # disposable fixture on the workspace's mounted external disk
```

## Code map

```
Sources/Prune/
  App/        Main (CLI/GUI entry), AppModel (scan orchestration, totals), FolderWatcher (FSEvents), CLI, SelfTest
  Core/       Sizer (parallel getattrlistbulk walker), ProjectIndex (parallel project walk + artifact rules),
              SafetyGuard, Cleaner (+ audit log), Git, Shell, SystemInfo, ScanContext
  Scanners/   One file per area. Each returns [CleanupItem] with risk, verdict and explanations
  UI/         SwiftUI views: Overview, Category table + detail, Review sheet, Explorer, Watched, History, Settings, Menu bar
```

To add a cache or artifact rule, add an entry to `DevCacheScanner.rules()` or `ArtifactRules.rules`.

## Notes

- Sizes are allocated bytes on disk. APFS clones and snapshots mean freed space can differ slightly.
- Trashed items free space only once the Trash is emptied (the review sheet and menu bar say so).
- Docker contents can only be analyzed while Docker is running.
- Project discovery has a 14-level depth limit and a 1,500,000-directory limit; the scan reports when limits or unreadable folders make discovery incomplete.
