# SQL Express Tool

Scheduled, verified backups for SQL Server Express — with a portable operator console.

SQL Server Express has no SQL Agent, so it has no native scheduled backup. Sites
running on Express therefore have **no backups at all** unless someone builds the
schedule outside the engine. This does that, and tries hard not to be the kind of
backup job that reports success for a year and then cannot restore.

## Two front-ends

There are two ways to drive the same engine, and one engine underneath both:

- **The application** — a modern, DPI-native Windows app with a Modern/DBA view toggle,
  a real restore window, and portable or installed modes with a self-registering
  installer. This is the one to reach for. See **[docs/APP.md](docs/APP.md)**, built
  with `build-wpf.ps1` (no SDK needed) or `dotnet build wpf\SqlExpressBackup.csproj`.
- **The console** — the original operator window described below, built with
  `build-app.ps1`. Still supported; lighter, and the reference for how the engine is
  set up and scheduled.

The rest of this README covers the console and the engine they share.

## Quick start

Build it once, then run the one file it produces:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-app.ps1
```

Double-click `dist\SqlExpressBackup.exe`. It opens a **native window** — no browser,
no local web server, nothing listening on a port.

Press **Self test** first. It creates its own scratch database, backs it up, checks
retention, restores it from the copy on the share, reads the rows back, then drops
everything it made. It needs no administrator and touches no existing database — if
that passes, this host can back up and restore.

Then **Full install**: creates a local share, sets up against it, schedules every
6 hours as SYSTEM, and takes the first backup. It asks you to type `FULL INSTALL`
first, because it is permanent.

No console needed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Setup -SharePath \\fileserver\sqlbackups -UseWindowsAuth
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Install -As Task
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Status
```

`Backup-SqlExpress.cmd` is a menu-driven launcher for the same thing, for hosts
where you would rather not build the exe.

### Which one to use

**The PowerShell path is the supported one.** The exe ships unsigned, and endpoint
protection reasonably treats a freshly compiled binary that spawns elevated
PowerShell as suspicious — CrowdStrike Falcon quarantines it on the estate this was
written for. The `.ps1` and `.cmd` are not affected, because `powershell.exe` is
signed and script rules are usually permissive.

### Signing it

The build signs the exe whenever a code-signing certificate is available, and says
so plainly when it is not:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .uild-app.ps1 -CertThumbprint <thumbprint>
```

Omit `-CertThumbprint` and it uses the first code-signing certificate with a private
key in `CurrentUser\My` or `LocalMachine\My`; pass `-NoSign` to skip. The signature
is SHA-256 and timestamped, so it stays valid after the certificate expires — and a
timestamp server that cannot be reached is a warning, not a build failure.

**A self-signed certificate is enough to LAUNCH, though not to distribute** — and
that was measured, not assumed. On a CrowdStrike Falcon estate, a controlled A/B in
one time window had the unsigned exe blocked 3 of 3 and the same binary self-signed
launch 3 of 3. Falcon appears to treat any Authenticode signature as a lower-risk
signal than a completely unsigned binary that launches elevated PowerShell, even an
untrusted one. So for running on the box it was built on:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-app.ps1 -SelfSign
```

`-SelfSign` creates a code-signing certificate in `CurrentUser\My` (reused on later
builds) when no real one is present. Nothing off that machine will trust it, and
Windows will not validate its chain — so for anything handed to another host, enrol
from your own CA instead. A certificate chaining to a root the domain already trusts
is the only thing that makes the signature *trusted* rather than merely present.

Note that applying a signature and being able to *validate* it are different: a
certificate from an internal CA reports `Valid` on a domain-joined machine and
`UnknownError` on one that lacks that root. The file is signed correctly either way,
so the build reports the distinction rather than failing on it.

## What it does

Every 6 hours (configurable), for every eligible database on the instance:

1. `BACKUP DATABASE ... WITH CHECKSUM` to a **local staging folder** — not straight to
   the share, so a share outage costs you the offsite copy and not the backup.
2. `RESTORE VERIFYONLY` before it is allowed to count as a success.
3. Copy to the share, verified by length and SHA-256.
4. Prune: newest 3 hourly per database, plus one archive per calendar day kept 7 days.

`master` and `msdb` are included, because a rebuilt instance without its logins and
job history is not really recovered. `tempdb` and `model` are skipped, as are
snapshots and standby databases.

Exit codes: `0` everything backed up **and** on the share, `1` partial — a database
failed, or a copy is still waiting for the share, `2` nothing backed up.

## Decisions worth knowing about

**Daily promotion is state-based, not clock-based.** It asks "does today already have
an archive?" rather than matching a schedule time. A clock match silently produces no
daily at all for a day whose midnight run was missed — the host was rebooting, the
share was down, the pass overran — which is exactly the day you wanted one.

**A pending copy is not success.** If the share is unreachable the backup still
completes and verifies locally, is held in staging, and the next pass drains it before
starting new work. The pass exits `1`, not `0` — otherwise a share that has been down
for a week reports success every six hours.

**The identity that runs the backups is checked, not assumed.** Under Windows
authentication the scheduled task connects as SYSTEM, so setup verifies that
`NT AUTHORITY\SYSTEM` can actually log in and has the rights, rather than proving the
operator can. It also proves SQL Server can write to the staging folder with a real
backup — the `.bak` is created by the *engine's* service account, not by whoever ran
setup, and a folder an administrator just created grants that account nothing.

**Backup compression is decided by error number, not message text.** Error 1844 is
stable across versions; the wording is not, and is localized.

## Alerting

A failure nobody sees is the worst kind on an unattended server, so the engine tells
someone — once when a problem starts, a reminder every 24 hours while it lasts, and
once when it clears:

| Channel | How |
|---|---|
| Windows event log | Always on. Source `SqlExpressBackup`: **9100** raised, **9101** reminder, **9102** resolved — key your existing monitoring on them. |
| Email | SMTP with STARTTLS (port 587 by default); Microsoft 365, Exchange or any relay. |
| Webhook | Microsoft Teams (a Power Automate *Workflows* webhook — Adaptive Card), Slack, or generic JSON. HTTPS only. |
| Heartbeat | A ping after every good pass to healthchecks.io, Uptime Kuma or similar — the only thing that notices a host that is **off**. |

It raises alerts for:
- a pass that failed or partly failed, or a log backup that failed;
- copies stuck waiting for the share;
- a transaction log filling up, or a FULL-recovery database with nobody backing up its log;
- no successful backup (or log backup) for too long;
- a backup task that was deleted or disabled.

The last two come from an hourly **watchdog** task, which exists only while a channel is configured.

```powershell
# elevated; unset parameters are left as they are
.\Invoke-SqlExpressBackup.ps1 -ConfigureAlerts -AlertEmailTo 'ops@example.com' -AlertEmailFrom 'sqlbackup@example.com' `
    -AlertSmtpHost 'smtp.office365.com' -AlertSmtpUser 'sqlbackup@example.com' -AlertWebhookKind Teams -AlertPromptSecrets
.\Invoke-SqlExpressBackup.ps1 -TestAlert      # sends a test through every channel and reports each
.\Invoke-SqlExpressBackup.ps1 -Status         # shows the channels and any open alerts
.\Invoke-SqlExpressBackup.ps1 -ClearAlerts
```

The SMTP password and the webhook and heartbeat URLs (which carry their own tokens) are
secrets. They are prompted for, never passed on the command line, and sealed in
`alert.dat` the same way as the SQL credential. The design is in
[docs/superpowers/specs/2026-09-25-alerting-design.md](docs/superpowers/specs/2026-09-25-alerting-design.md).

## Encryption

SQL Server Express cannot encrypt a backup, so the tool does it after SQL writes the file:
compress, then encrypt (AES-256 with HMAC-SHA256 integrity), then copy. Anyone who can
read the share sees ciphertext. A backup that has been tampered with or damaged is refused
before it reaches `RESTORE`.

**Losing the key would mean losing the backups**, so there are two ways to get it back:

- **A passphrase you choose.** It wraps a copy of the key that the backup pass keeps on the
  share, beside the backups.
- **A recovery key**, shown once, for you to keep somewhere safe offline.

Day to day, backups use a copy of the key sealed to the server, so nothing is typed. On a
rebuilt server, `-ImportEncryptionKey` with either secret brings the backups back.

```powershell
.\Invoke-SqlExpressBackup.ps1 -SetupEncryption              # elevated: passphrase twice, recovery key shown ONCE
.\Invoke-SqlExpressBackup.ps1 -ImportEncryptionKey          # on a rebuilt server: passphrase or recovery key
.\Invoke-SqlExpressBackup.ps1 -Reschedule -EncryptBackups Off   # new backups plain again; keys are kept
.\Invoke-SqlExpressBackup.ps1 -SetupEncryption -RotateKey   # a new key for new backups; old ones still restore
```

Backups already on the share stay as they are and age out through retention. Restoring an
encrypted backup needs an elevated console, because the keys are readable only by
administrators. The design is in
[docs/superpowers/specs/2026-09-25-backup-encryption-design.md](docs/superpowers/specs/2026-09-25-backup-encryption-design.md).

## Restore testing

A backup nobody has restored is only a hope. With restore testing on, a daily task (03:30
by default) takes the database tested longest ago and does four things:

1. Restores its newest chain to a scratch database. In point-in-time mode that is the full
   backup, its differential and every log after it, up to the newest log.
2. Runs `DBCC CHECKDB` on the copy.
3. Records the result.
4. Drops the scratch copy.

Every database is covered in turn. A broken log chain, a file SQL cannot read, or a
consistency error fails the test and raises a critical alert. Not enough disk to try
raises a warning. The scratch copy is always dropped, even after a failure.

```powershell
.\Invoke-SqlExpressBackup.ps1 -Reschedule -RestoreTesting On -RestoreTestTime 02:30   # elevated
.\Invoke-SqlExpressBackup.ps1 -TestRestore [-Database AppDb]                          # one test, now
```

The scratch database is named `SebRestoreTest_<database>` and its files go in the staging
folder. The test does not take the backup lock, so log backups keep running while it runs.
The design is in
[docs/superpowers/specs/2026-09-25-restore-testing-design.md](docs/superpowers/specs/2026-09-25-restore-testing-design.md).

## Security

This ships a tool that runs as SYSTEM and holds a database credential, so:

- **The credential is sealed to the machine.** A 32-byte key under DPAPI
  *LocalMachine* with secondary entropy; the password is AES-256-CBC under that key
  with HMAC-SHA256, encrypt-then-MAC. `AesGcm` does not exist on .NET Framework 4.8,
  which is what PowerShell 5.1 has; this is the strongest in-box equivalent. The
  password travels `SecureString` → `SqlCredential` and is never a command-line
  argument, never logged.
  *Stated limit:* any administrator or SYSTEM process on the host can reverse this,
  because an unattended service must. What it buys is that the files are worthless
  anywhere else. Prefer a login with `dbcreator` + `db_backupoperator` over `sa`.
- **There is no local server.** An earlier version served an HTML page from a
  loopback socket and opened a browser. It worked, and it cost three security
  defects in a single session — a capability token in a file that inherited a
  permissive profile ACL among them. The native window needs no listener, no token,
  and no page to lock down, so none of that has to be defended any more.
- **The scheduled task never runs a script a non-admin can rewrite.** The console
  extracts its engine copy under the user profile — correct for something run as that
  user — and the elevated install places the copy the *task* uses somewhere only
  SYSTEM and Administrators can write.
- **Encrypted backups protect the share, not the running host.** An administrator or
  SYSTEM on the server can read the keyring, as with the SQL credential. The key copy on
  the share is only as strong as the passphrase, which is why it must be at least 12
  characters and is stretched with 600,000 PBKDF2 rounds. Sidecar files reveal backup
  times and log positions, never data.
- **The pass validates what it reads.** Pending copies recorded in state are checked
  against the configured staging and share folders before anything is copied, so a
  tampered state file is not a "put this anywhere, as SYSTEM" primitive.
- **Nothing is fetched at runtime, ever.** No CDN, no update check; the exe carries the
  engine and nothing else. The only outbound traffic besides the share is alerting,
  and only to the email server, webhook and heartbeat URL you configure: webhooks
  over HTTPS only, and URLs stripped from anything logged.

## Requirements

- **Windows 10 / Server 2016 or newer**, out of the box. That floor is set by
  PowerShell 5.1 (`#requires -version 5.1`) and by `New-SmbShare` /
  `Register-ScheduledTask`. Server 2012 R2 needs WMF 5.1 installed first; older than
  that is not worth it.
- .NET Framework 4.x for the exe — in the box since Windows 8 / Server 2012.
- SQL Server Express (or any edition) **on the same host**. This is not a remote
  backup tool: instance discovery reads the local registry, and staging has to be a
  local path the SQL *service account* can write, because the engine creates the
  `.bak`, not the script.
- `csc.exe` from the .NET Framework to build the exe. No SDK, no package restore, no
  network — the tool is meant to be carried to a server that has nothing on it, so
  the build must not need anything either.

The exe is portable; the settings deliberately are not. Config, the sealed
credential and state live in `C:\ProgramData\SqlExpressBackup` per host, and DPAPI
binds the seal to that machine. Carry the exe to ten servers and each keeps its own.

## Building and testing

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-app.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\sqlexpress-backup.test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\backup-app.test.ps1
```

Where SQL Express is installed, the `test\live-*.ps1` scripts prove the real thing against
scratch databases:
- point-in-time restore;
- compressed round trips;
- share-outage recovery;
- alerting (raise once, stay quiet, resolve once);
- restore testing (a full chain restores and checks clean, and a broken chain fails the test);
- encryption (no plaintext on the share, and restores still work after a key import).

`dist/` is gitignored: the source and the build script are the reviewable artifacts.

The suites drive real behaviour rather than grepping source — the retention planner
against real files, the sealing round-trip and its refusals, and the app built and
then actually run (`--check` constructs the window, extracts the engine and reports,
without needing a message pump). Where a guard matters, it has been mutation-checked:
the guard is removed, and the suite is confirmed to fail.

One check earns its place specially: the app must extract the engine under the
**user profile**, never into the machine-wide state directory. Doing the latter, with
a SYSTEM task pointed at it, hands any non-admin a script SYSTEM runs every six
hours. That shipped once. The test now asserts the path the app actually used.

## Known limitations

- **A share on the same host is not an offsite copy.** If that disk dies, the backups
  die with it. `Full install` says so before it will proceed. Point setup at a real
  file server when you have one — the schedule, retention and credential all stay.
- **DPAPI is machine-bound.** Sealed credentials do not move between servers; re-run
  setup on the new host.
- **Point-in-time recovery is opt-in.** By default databases stay in SIMPLE recovery
  and the loss window is the backup interval (6 hours). Turn on *Point-in-time
  recovery* in setup (or `-RecoveryMode Full`) for log backups every 15 minutes and
  restores to any minute; master and msdb stay full-only.
- **A dead UNC path takes about 7.5 minutes to fail.** The task's execution time limit
  and a named mutex keep that contained, but a share outage makes a pass slow.
- **Restoring over a live database is not automated.** Restore *testing* is: backups are
  restored to scratch databases and checked, never over a real one. Restoring for real is
  a human decision. The procedure is written down: [docs/RESTORE.md](docs/RESTORE.md),
  including the permission trap that makes a perfectly good backup unreadable and a
  drill record proving a real database came back.
- **The exe is unsigned**, so endpoint protection may quarantine it. See *Which one to
  use* above. The PowerShell path is unaffected.
- **On Server Core there is no window.** Use the `.ps1` and `.cmd` directly; the
  engine does not care.

## Licence

Proprietary - all rights reserved. See `LICENSE`. No licence is granted to anyone;
this is internal operational tooling, and that is deliberate rather than an
oversight.

No third-party code is redistributed here any more — the vendored GSAP went with
the browser UI, so nothing in this repo carries someone else's licence.
