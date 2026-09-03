# The application

A modern Windows desktop application for scheduled, verified SQL Server Express
backups — and for restoring them. It is a single self-contained executable: a
DPI-native WPF interface with the proven PowerShell engine embedded inside it.

There are two ways to drive the same engine. This document is about the **application**
— the window you install and click. The engine it wraps, and the PowerShell console
front-end, are documented in the main [README](../README.md); the restore procedure
itself is in [RESTORE.md](RESTORE.md).

---

## What it is

- **One file.** The engine ships embedded in the executable and is extracted beside it
  on first run, so there is nothing else to copy and no separate install of a script.
- **Vector, DPI-native.** Built on WPF, so it is crisp at 4K and stays crisp dragged
  between monitors of different scaling. Resize it freely; it reopens at the size and
  position you left it.
- **Two looks, one switch.** A Modern console and a DBA-native (SSMS-style) view, swapped
  by a single toggle in the header. A separate toggle switches light and dark. Both
  choices are remembered.
- **Runs the tested engine.** The application owns none of the backup or restore logic.
  Every action invokes the same engine modes the PowerShell console uses, so there is one
  implementation of the work, not two.

---

## Getting it

Build the executable once with the in-box .NET compiler — no SDK, no MSBuild, no
packages:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-wpf.ps1 -SelfSign
```

`-SelfSign` creates a self-signed certificate and signs the output. On an estate that
runs CrowdStrike Falcon this is what lets the binary launch rather than be quarantined
— measured, not assumed (see [Signing](#signing-and-endpoint-protection)). The result
is `dist-wpf\SqlExpressBackup.exe`.

---

## First run — choosing how it lives

Launch the fresh executable and it asks, once, how you want to run it:

| Choice | What it does |
|---|---|
| **Install** | Installs into `Program Files` like a normal Windows app: a Start-menu shortcut and an entry in **Add or Remove Programs**. Asks for administrator once. |
| **Portable** | Extracts to a folder you pick and runs from there. No system changes, nothing to uninstall — delete the folder and it is gone. Its settings live beside the executable, so a portable copy carries its own preferences. |
| **Just run once** | Runs now without installing. The engine is unpacked to your user folder; no shortcut, no registry entry. |

The choice is remembered by a small marker file beside the executable, so every later
launch knows which mode it is in and skips the chooser.

---

## Installing

Pick **Install** in the chooser, or from a command line:

```powershell
& "path\to\SqlExpressBackup.exe" --install
```

Either way it copies itself into `C:\Program Files\SQL Express Backup`, extracts the
engine there, registers an uninstall entry, and drops an all-users Start-menu shortcut,
then launches the installed copy. Installing writes to `Program Files` and the machine
registry, so it needs administrator — an unelevated launch relaunches itself through a
UAC prompt.

After it runs you will find **SQL Express Backup** in **Settings → Apps → Installed
apps**, with a working **Uninstall** button.

### Uninstalling

Use the **Uninstall** button in Installed apps, or:

```powershell
& "C:\Program Files\SQL Express Backup\SqlExpressBackup.exe" --uninstall
```

Uninstall first removes the **scheduled task** (so it is not left running with no app
behind it), then the registry entry, the Start-menu shortcut, and the install folder.
**It never touches your backups or your configuration** — the backups live on the share,
not in the install directory, and the sealed credential and config are left in place. (A
running executable cannot delete itself, so the folder removal is handed to a short
detached command that runs once the app exits.)

---

## The interface

### The two views

The header toggle swaps the whole look between **Modern** and **DBA**. Both show the
same data and drive the same engine; they differ only in presentation.

- **Modern** (the default) — a sidebar over status tiles and the list of protected
  databases, with the primary actions across the bottom. Approachable; good for a
  quick "is everything healthy" glance.
- **DBA** — an object-explorer tree of the instance and its databases, with the
  selected database's recovery points as a grid. Familiar to anyone who lives in SQL
  Server Management Studio.

The light/dark toggle sits beside the view toggle. Every combination works, and the
window follows the app's own choice rather than only the OS setting.

### Status and databases

The tiles read the published backup status — last result, schedule interval, database
count, instance — with no elevation and no SQL round-trip. The database list is the
backup catalogue grouped per database, each row showing how many recovery points
exist.

> If the list is empty while backups are clearly running, the account you launched as
> cannot read the backup share (it is deliberately locked down). Run the app elevated,
> or grant that account read on the share.

### Restoring

**Restore** opens a separate window — deliberately, because a restore is a long,
high-stakes operation you want to read before you commit. It shows the backup sets on
the left; the selected set's readability check, the restore sequence, and the options
on the right; progress along the bottom.

It uses SQL Server's own vocabulary — **backup set**, **restore sequence**, **recovery
state**, **MOVE**, **REPLACE** — so it matches SSMS and every article you will reach
for under pressure. Options that cannot work on this instance are shown greyed with the
reason stated rather than hidden.

The safe default restores to a **new** database name, leaving the original untouched.
Overwriting a live database (**REPLACE**) is allowed but guarded: you must type the
database name to confirm, and the sequence renames rather than drops, so a wrong
restore costs nothing. The full procedure — including the permission trap that makes a
good backup look corrupt — is in [RESTORE.md](RESTORE.md).

### Watching a job — progress and logs

Every backup, restore, and self test shows a **glowing progress bar** that fills 0→100%
with a sheen sweeping the filled portion while the work advances. The readout carries the
percentage, the elapsed time, and an estimate of the time remaining. The glow is a
liveness signal, not decoration: if progress stops moving for a few seconds the bar turns
**amber and the glow freezes**, so a stalled job reads as stalled rather than sitting at a
falsely reassuring percentage.

Beside the bar is a **live activity log** — the engine's own output, streamed line by line
as the job runs, so you watch each step (backing up, verifying, copying, pruning) as it
happens. Lines are tinted by level: errors red, warnings amber, successes green.

The same log is available on **one click**, without waiting for a job. Every database row
in the Modern view, every backup set in the restore window, and every recovery point in
the DBA view carries a **log** affordance; clicking it reads that database's recent
history from the engine's log files (`%ProgramData%\SqlExpressBackup\logs`) and shows it
in the pane. It reads the log shared, so a scheduled backup writing at that moment does
not lock you out.

Any log pane can be **popped out** into its own resizable window — minimize, maximize,
free resize — for reading a long log full-screen; a pane popped out mid-job keeps
streaming new lines into it.

From the restore window you can also **Copy SQL** — the restore sequence as a template to
paste into a ticket or SSMS — and **Verify media** without starting a restore. The Modern
view's **Refresh** re-reads status and the catalogue, and its **Activity** item opens the
full recent log.

---

## Configuring and scheduling

Backups are configured and scheduled from inside the app. Each of these writes the locked
configuration and registers a scheduled task that runs as SYSTEM, so each needs
administrator — rather than run the whole app elevated, the app spawns a single elevated
helper for the one job through a Windows UAC prompt and streams its output back live.

### Set up backups

**Set up…** (on the overview) opens a wizard: the SQL instance (blank picks the only one
on the host), the backup share (a UNC path), the staging folder, the interval, and how
many hourly and daily copies to keep. It uses **Windows authentication** — the SQL service
account — so no SQL password is ever entered in the app. Applying it configures the engine
and registers the scheduled task in one elevated step, with the engine's output shown as
it runs.

### Changing the schedule

The **Schedule** window (in the sidebar) shows the interval, the last run, the estimated
next run, pending copies, the instance and the share. Below that, **Change schedule** lets
you pick a new interval and, optionally, new retention counts, and **Apply** re-registers
the task — again in one elevated step. Only the values you change are changed; the rest of
the configuration is left as it is.

### Running a backup now

**Run backup now** runs a pass immediately. A backup reads the SYSTEM-only sealed
credential, so it runs elevated; when the app is not already elevated it runs the pass as
an elevated job and streams the same glowing progress bar and activity log a scheduled run
would.

---

## Settings and persistence

Everything you change is saved immediately, and the app reopens exactly as you left it:

- window size and position (and whether it was maximized)
- the Modern/DBA view choice and the light/dark theme
- backup parameters as they are wired in

Where the settings file lives depends on the mode: **beside the executable** for a
portable copy (so it travels with it), or **per-user** for an installed one.

---

## Command-line reference

Useful for scripted deployment and for testing:

| Argument | Effect |
|---|---|
| `--install` | Install into Program Files (elevates if needed) and launch. |
| `--uninstall [--quiet]` | Remove the install (elevates if needed). |
| `--portable <path>` | Extract a portable copy to `<path>` and launch it. |
| `--restore` | Open straight to the restore window. |
| `--selftest` | Run a self test on launch. |
| `--backup-now` | Run one backup pass now (elevates if needed). Behind **Run backup now**. |
| `--reschedule <file>` | Apply the interval/retention in a JSON file and re-register the task (elevates). Behind **Change schedule**. |
| `--apply-setup <file>` | Configure and schedule from a JSON file, Windows auth (elevates). Behind the setup wizard. |
| `--live <file>` | With the three above: stream the engine's output to `<file>`, ending in `[EXIT] N`, so the launching app can tail it live across the UAC boundary. |
| `--check <file>` | Construct every view headless and write findings to `<file>`; used by the test suite. No window is shown. |

---

## Signing and endpoint protection

The executable is unsigned by default. On a managed estate, an unsigned binary that
launches PowerShell is close to a textbook endpoint-protection heuristic and may be
quarantined — which is the security tool working, not failing.

A **self-signed** certificate is enough to *launch* here, though not to *distribute*.
This was measured rather than assumed: in one controlled comparison the unsigned
executable was blocked three times out of three, while the same binary self-signed
launched three times out of three. Endpoint protection appears to treat any Authenticode
signature as a lower-risk signal than a completely unsigned binary. So:

- For running on the machine it was built on, `build-wpf.ps1 -SelfSign` is enough.
- For anything handed to another host, enrol a certificate from a CA the domain trusts.
  A certificate chaining to a trusted root is the only thing that makes the signature
  *trusted* rather than merely present.

Nothing off the build machine will trust a self-signed certificate, and Windows will
not validate its chain — that is expected, and separate from whether it launches.

---

## Building from source

`build-wpf.ps1` compiles the application with the in-box C# compiler and the WPF
assemblies that ship with the .NET Framework. It needs no .NET SDK and no MSBuild — the
interface is written in code (no XAML), so the compiler alone is enough. The engine is
embedded as a resource at build time.

| Switch | Effect |
|---|---|
| `-SelfSign` | Create/reuse a self-signed certificate and sign the output. |
| `-OutDir <dir>` | Write the build somewhere other than `dist-wpf`. |
| `-Quiet` | Suppress progress output. |

The `--check` smoke mode constructs every view and the restore window without showing a
window, so a broken layout fails a build check rather than an operator's first click.

---

## How it relates to the engine

The application is a front-end. Underneath it is `Invoke-SqlExpressBackup.ps1` — the
same engine the PowerShell console uses, embedded in the executable and extracted on
demand. It performs the backups, the retention, the verification, and the restores; the
application reads its status and drives its modes, relaying the engine's progress markers
into the glowing progress bar (which turns amber if a job stalls) and streaming its output
into the activity log. The elevated modes — `-Setup`, `-Reschedule`, `-Run`, `-Uninstall`
— are driven the same way, run in a short elevated helper process whose output the app
tails live, so configuration and scheduling never require running the whole UI as
administrator.

This split is deliberate. The engine is tested and mutation-verified; a second
implementation of the backup or restore logic inside the UI would be two things that
must agree forever, and they would diverge at the worst possible time. One engine, two
faces.
