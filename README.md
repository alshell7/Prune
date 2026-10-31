<div align="center">

<img src="Resources/AppIcon-preview.png" width="110" alt="Prune icon">

# Prune

**Your Mac is full of things you can rebuild. Prune finds them, proves they're safe, and gives the space back.**

Disk cleanup, code safety and security for developers, across every drive.

[![Download](https://img.shields.io/github/v/release/alshell7/Prune?label=Download&color=34c759)](https://github.com/alshell7/Prune/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#install)
[![License: MIT](https://img.shields.io/badge/License-MIT-3b82f6)](LICENSE)
[![Local only](https://img.shields.io/badge/data-never%20leaves%20your%20Mac-8b5cf6)](#safety)

<img src="docs/media/scan-and-clean.gif" width="900" alt="Prune scans, explains what it found, and frees 21.6 GB after review">

<sub>Real app, recorded with demo data. Scan → review → 9.8 GB free becomes 31.4 GB.</sub>

</div>

## What it does

| | |
|---|---|
| 🧹 **Cleanup** | `node_modules`, `target/`, `.next`, DerivedData, caches, stale SDKs and emulators, each with *why* and *what happens if you delete it*. |
| 💽 **Every drive** | Internal and external disks each get their own scan, totals and suggestions. |
| 🔑 **Secrets** | API keys and `.env` files, checked against git: tracked, ignored or **already pushed**. |
| 🛟 **Code Backup** | Projects that exist only on this Mac: no git, no remote, unpushed work. |
| 🩺 **Project Doctor** | Broken venvs, worktrees and symlinks after moving projects, plus bloated repos. |
| 🛡️ **Security** | Launch agents, npm/pip packages, AI skills and MCP configs scored for malware patterns. |
| 📦 **Offload** | Move projects, apps and folders to an SSD, checksum-verified, with links left behind. |
| 🧩 **Apps & Extensions** | Leftover drivers, plug-ins and extensions, and a way to remove them. |
| 📈 **Timeline · 🔧 Maintenance** | When your disk fills up, plus one-click macOS fixes, each explained. |

## See it work

**Every drive gets its own suggestions.** Pick a disk; projects on your external SSD are judged the same way, down to a virtualenv that broke when it moved.

<img src="docs/media/every-drive.gif" width="900" alt="Switching from all disks to the Studio SSD in Project Artifacts and Overview">

**A leaked key, caught.** 35+ key formats plus a randomness score, checked against git. Values are masked and never stored.

<img src="docs/media/secrets.gif" width="900" alt="A pushed OpenAI key, a token in .zshrc, then stopping git from tracking the .env">

**Code that only lives here.** No git, no remote, unpushed commits, stashes.

<img src="docs/media/code-backup.gif" width="900" alt="Code Backup listing projects without git or remote">

**Fix what moving broke, and remove leftover drivers.**

<img src="docs/media/doctor-and-extensions.gif" width="900" alt="Project Doctor relinks moved projects; Apps & Extensions shows a dangling driver">

**Every module explains itself.**

<img src="docs/media/how-it-works.gif" width="820" alt="Animated How Secrets works card">

<table>
<tr>
<td><img src="docs/media/overview-dark.png" alt="Overview in dark mode"></td>
<td><img src="docs/media/timeline.png" alt="Space Timeline with a fill-up forecast"></td>
</tr>
<tr>
<td align="center"><sub>Light, dark or system</sub></td>
<td align="center"><sub>Space Timeline: when you'll run out</sub></td>
</tr>
</table>

## Install

1. Download **[Prune.dmg](https://github.com/alshell7/Prune/releases/latest/download/Prune.dmg)** and drag Prune to Applications.
2. First launch: Prune isn't notarized yet, so macOS blocks it once. Click **Open Anyway** in System Settings › Privacy & Security.
3. Grant **Full Disk Access** in System Settings › Privacy & Security for a complete scan.

Prune updates itself from GitHub releases, verifying a SHA-256 checksum and the code signature first.

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/alshell7/Prune.git && cd Prune
./build.sh --install        # needs Xcode 15+ command-line tools
```

</details>

## Safety

- **You review everything.** Cleanups go to the Trash; quarantined items can be restored.
- **Git-aware.** Tracked files are never junk, and unbacked-up code is flagged before any move or delete.
- **Guard rails.** System locations, volume roots, `.git` internals and personal libraries are refused.
- **Local only.** No telemetry. Update checks talk only to GitHub (off in Settings).
- **Logged.** Every action is in History.

<details>
<summary>Terminal</summary>

```bash
P=/Applications/Prune.app/Contents/MacOS/Prune
$P --scan          # cleanup suggestions
$P --secrets       # secrets & env files
$P --doctor        # broken environments and links
$P --code-backup   # what isn't pushed
$P --security      # threat check
```

</details>

<details>
<summary>Maintainers</summary>

- `scripts/release.sh`: build, self-test, then publish `Prune.dmg`, `Prune.zip` and its checksum.
- `scripts/make_demos.sh`: re-record these GIFs from the real app with demo data.

</details>

<div align="center">

Maintained by [**@alshell7**](https://github.com/alshell7) · [MIT License](LICENSE)

</div>
