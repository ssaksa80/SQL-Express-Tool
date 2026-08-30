# SQL Express backup to a file share - design

Date: 2026-08-30
Status: approved

## Problem

SQL Server Express has no SQL Agent, so it has no native scheduled backup. Sites
running APPDB beside other applications on a single Express instance therefore
have no backups at all unless someone builds the schedule outside the engine.

We need one operator-runnable artifact that:

* discovers the Express instance(s) on the host without being told where they are,
* backs up every database on them to a UNC file share,
* runs unattended every 6 hours, forever, surviving reboots,
* keeps 3 rolling copies plus a daily archive, pruning the rest,
* stores a SQL login credential on disk in a form that is useless off this machine.

## Non-goals

* Restore automation. This produces verified backup files; restoring is a human
  decision and gets its own runbook.
* Transaction-log backups / point-in-time recovery. The stated RPO is 6 hours.
  Log chains bring real operational complexity (chain breaks, `NORECOVERY`
  sequencing) that a 6-hour RPO does not justify.
* Off-host key escrow. The credential is deliberately machine-bound.

## Artifact

`deploy/Invoke-SqlExpressBackup.ps1` - one file, `#requires -version 5.1`,
dot-sources nothing, pure ASCII.

It follows the `the standalone probe` precedent rather than the bundle-tool
precedent, for the same reason: an operator must be able to copy one file to a
server and run it. It is therefore NOT staged by `build-bundle.ps1`, and its test
asserts that, exactly as `probe-prereqs.test.ps1` does for the probe.

## Modes

| Mode | Behaviour |
| --- | --- |
| `-Setup` | Interactive, run once. Detect instances, choose one, capture the credential, seal it, write config, prove a connection and a share write. |
| `-Install -As Task` | Register a Scheduled Task running as SYSTEM: at-boot trigger + repetition every `-IntervalHours` for an indefinite duration, `RunLevel Highest`. |
| `-Install -As Service` | Register an NSSM service running a supervised loop, matching how APPDB itself is hosted. |
| `-Run` | One backup pass. What the scheduler invokes; also runnable by hand. |
| `-Status` | Instances, last run result, per-database last good backup, share reachability, retention counts. Prints no secret. |
| `-Uninstall` | Remove the task or service. `-Purge` additionally removes config and key material. Never touches backup files. |
| `-DotSourceOnly` | Define functions and do nothing else, so tests can drive the pure logic. |

Both scheduler mechanisms are supported because they fail differently and sites
differ: a Scheduled Task is inspectable in `taskschd.msc` and needs no extra
binary, while a service auto-restarts a crashed loop. `-Install` refuses to
proceed if the other mechanism is already registered, so a host can never carry
both.

### Instance auto-detection

Read `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL` for the
instance-name -> instance-ID map, then each instance's `Setup\Edition` and
`Setup\Version`, then cross-check `MSSQLSERVER` / `MSSQL$*` service state.

* Exactly one instance -> used without prompting.
* Several -> numbered prompt at `-Setup`; `-Instance` pins it non-interactively.
* Edition is reported but never used to exclude: a host with Express and Standard
  side by side should still back up both if the operator points at them.

The registry reader is injectable so the resolver is testable on a machine with
no SQL Server installed.

## Credential sealing

Mirrors `server/src/crypto/masterKey.js` so this host has exactly one crypto story.

* `key.bin` - 32 random bytes sealed with DPAPI **LocalMachine** plus a secondary
  entropy blob. LocalMachine (not CurrentUser) because the reader is SYSTEM or a
  service account, not the operator who ran `-Setup`.
* `cred.dat` - the password encrypted AES-256-CBC under that key, then
  HMAC-SHA256 over IV+ciphertext (encrypt-then-MAC, verified before decrypting).
  `AesGcm` does not exist on .NET Framework 4.8 / PS 5.1; this is the strongest
  in-box equivalent.
* Both files: ACL inheritance disabled, SYSTEM + Administrators only.
* The password is held as a `SecureString`, marshalled to bytes only inside the
  connection call, and the byte array is zeroed in a `finally`. It is never a
  command-line argument, never logged, never transcribed. Connections use
  `SqlConnectionStringBuilder` - the same approach as `lib/common.ps1`, which also
  keeps the existing `sqlcmd-password-args` pin satisfied by construction.
* `-UseWindowsAuth` skips all of the above and connects as the scheduled
  identity. Offered because it is strictly safer where the site can use it.

### Stated limit

Any administrator or SYSTEM process on this host can reverse this sealing,
because an unattended service must be able to. What the design buys is that the
sealed files are worthless anywhere else: DPAPI LocalMachine binds them to this
machine, so exfiltrating `key.bin` and `cred.dat` yields nothing. A dedicated
login with `dbcreator` + `db_backupoperator` is therefore still preferable to
`sa`, and `-Setup` says so at the prompt.

### Elevation (found during implementation)

The ACL has a consequence the design did not spell out: a non-elevated process
cannot read the key files even when the user is an administrator, because a
filtered token does not carry the group. Every mode therefore asserts elevation
before touching anything - `-Status` included, since it reads the same locked
config. Without the check, `-Setup` writes the key, locks it, and then fails
reading its own key back, leaving the credential half-committed. SYSTEM satisfies
the check, so the scheduled pass is unaffected.

## Backup pass

```
staging\<DB>_<yyyyMMdd-HHmmss>.bak        local; the SQL service account can always write here
  |  RESTORE VERIFYONLY
  v
\\share\<HOST>\<INSTANCE>\<DB>\hourly\    newest 3 kept
                         \<DB>\daily\     one per calendar day, newest 7 kept
```

Database selection: `sys.databases` where `state = 0` (ONLINE), excluding
`tempdb` (impossible) and `model` (no value), excluding snapshots
(`source_database_id IS NOT NULL`) and standby databases; `master` and `msdb`
included so a rebuilt instance can recover its logins and job history.

Per database: `BACKUP DATABASE ... WITH CHECKSUM, INIT`, plus `COMPRESSION` where
supported. Compression support is probed once per run and falls back cleanly on
the pre-2016 Express error rather than being inferred from a version string.
Every backup is then proved with `RESTORE VERIFYONLY` before it is allowed to
count as a success.

Staging is local rather than backing up straight to the UNC path because a share
outage must not also mean no backup: the local file still exists and still
verifies. The staged file is deleted only after the copy to the share is verified
by length and hash.

### Retention

* `hourly\` - newest 3 files per database survive; older ones deleted.
* `daily\` - after a successful backup, if `daily\` holds no file dated today,
  this backup is promoted into it. Newest `-DailyKeepDays` (default 7) survive.

Daily promotion is state-based, not clock-based, on purpose. A schedule-time
match ("promote the 00:00 run") silently produces no daily at all when that one
run is missed - the host was rebooting, the share was down, the pass overran.
Asking "does today already have a daily?" produces one daily per day under every
one of those conditions.

## Failure handling

* Databases are independent. One failing database does not abort the pass.
* Exit codes: `0` every database succeeded, `1` partial, `2` none succeeded.
* Share unreachable -> the backup still completes into staging and is recorded as
  pending. The next run drains pending copies **before** starting new backups, so
  a restored share catches up rather than starting from empty.
* Free space in staging is checked against the summed database sizes before SQL is
  asked to do anything, so the failure is a clear message rather than a
  half-written `.bak`.
* A named mutex guards the pass. A task and a service, or an overrun pass
  overlapping its successor, can never run concurrently.
* Logging to a rotating file plus a Windows Event Log source, both redacted on
  the `the standalone probe` allow-list principle.

## Found by running it against a live instance

Four defects survived a green unit suite, because every one of them lived in the
gap between what the tests assumed and what a real server does. Recorded here
because the assumption, not the code, is the reusable lesson.

**The staging folder was unwritable.** This document asserted that the SQL service
account "can always write there". It cannot: the `.bak` is created by the engine's
account - on Express normally the virtual account `NT Service\MSSQL$INSTANCE` -
and a folder an administrator just created grants that account nothing. Every
backup failed with `Operating system error 5(Access is denied.)`. Setup now reads
the account off the service, grants it Modify, and then *proves* it with a real
`COPY_ONLY` backup of `model` rather than assuming.

**Compression fallback never fired.** The code matched the message text `not
supported in this edition`; SQL Server 2025 says `is not supported on Express
Edition (64-bit)`. Every backup on Express rethrew instead of falling back - on
the one edition this script exists for. Error **1844** is stable across versions
and is not localized, so detection is by error number now, and the edition is
probed up front so a doomed attempt is never made.

**Retention never ran.** `Get-SebFolderFacts` returned `, @(...)` while callers
wrapped the call in `@(...)`; `@( ,@(x) )` is an array whose single element is the
array, so `Count` was 1 regardless of how many backups existed and nothing ever
exceeded `HourlyKeep`. The planner's own tests passed throughout, because they
were handed arrays directly and never went through the folder reader.

**A pending staged file could be deleted.** Two passes in the same second reuse
the staged name (the stamp is one-second resolution), and the second pass deleted
the file the first pass's pending copies were the only source for. Deletion is now
guarded by the pending list.

One behaviour was changed as a result rather than fixed: a pass with copies still
waiting for the share now exits **1**, not 0. A share down for a week previously
reported success every six hours.

Known bound, not fixed: `Copy-Item` to an unreachable UNC path took **7.5 minutes**
to fail. The scheduled task's execution time limit and the named mutex keep that
contained, but a share outage makes a pass slow, not instant.

## Running it: the launcher and the self-test

`deploy/Backup-SqlExpress.cmd` is the entry point an operator actually uses.
Double-clicking it shows a menu; nothing changes on the server until an item is
chosen, and only `[3] Install` makes anything permanent - it demands a typed
`YES` first. Elevation is requested per action rather than up front, so the
self-test needs no administrator prompt while the others do.

`-SelfTest` is a shipped mode, not a scratch harness. It creates its own scratch
database, runs three real passes, checks retention against real files, holds a
copy through a simulated share outage, restores the file off the share and reads
the rows back, then drops the database and deletes everything it made. The pass
is scoped by `OnlyDatabase`, so a self-test never touches a live database. It
needs no elevation, because it works only in a folder it creates and owns and
connects with the caller's own Windows credentials.

It exists because the unit suite structurally cannot see the things that break an
install: whether the SQL service account can write to staging, whether this
edition rejects `COMPRESSION`, whether retention prunes real files, and whether
the file on the share genuinely restores.

### Full install, and a local share

`-FullInstall` is the one-click path: create `C:\SqlBackups`, share it, set up
against that UNC with Windows authentication, register the 6-hourly task, take a
backup immediately, then print status. The launcher's `[F]` item runs it behind a
typed `YES`.

Two things are stated rather than hidden. A share on the SAME host is not an
offsite copy - if that disk dies the backups die with it - so it is a way to prove
the whole UNC path end to end and a staging point to mirror elsewhere, not
disaster recovery. And SYSTEM reaching `\thishost\share` over the loopback
authenticates as the COMPUTER account, not as SYSTEM, so the machine account is
what gets granted on both the share and the file system.

### The identity that actually runs the backups

Setup proved the OPERATOR could connect. Under Windows authentication the
scheduled task connects as SYSTEM, so the operator's success said nothing about
the account that does the work: with no login for `NT AUTHORITY\SYSTEM`, setup
passed and every run afterwards would have failed at six-hour intervals with
nobody watching. Setup now probes that login - exists, not disabled, holds
sysadmin or dbcreator - and refuses with the T-SQL that fixes it.

### One more found by the launcher

Installing PowerShell 7 puts its module directories on the machine-wide
`PSModulePath` **ahead of** Windows PowerShell's own. A 5.1 process then finds
PS7's manifest for a shipped module first, cannot load it because it targets
Core, and the cmdlets inside it cease to exist - reported as "the command was
found in the module 'X', but the module could not be loaded". It took out
`Set-Acl`, and then `Get-FileHash`, which made every copy verification throw so
every backup was recorded as pending.

Whether it bites depends on the `PSModulePath` the process inherits, so it
appeared only when the launcher started `powershell.exe` from `cmd`, and never
when the same script was started from an existing PowerShell session. Fixing it
cmdlet by cmdlet is whack-a-mole; the search path is the fault, so the script
repairs `PSModulePath` at startup and additionally loads the two modules it needs
straight from `$PSHOME`.

## Testing

`deploy/test/sqlexpress-backup.test.ps1`, in the house style: plain `Assert`,
run by `powershell -NoProfile -ExecutionPolicy Bypass -File`, no Pester.

Structural guards, mirroring `probe-prereqs.test.ps1`: pure ASCII, parses under
PS 5.1, declares its `#requires` floor, dot-sources nothing, is not staged by
`build-bundle.ps1`, never assigns a `try` block (the 5.1 trap).

Behavioural guards drive the pure functions with data through `-DotSourceOnly`:

* retention planner - given a file list and a "now", returns keep/delete sets.
  Exercised for fewer than 3 files, exactly 3, more than 3, a day with no daily
  yet, a day already covered, and daily expiry at the boundary.
* path builder - host/instance/database/kind composition, including a default
  instance and names needing bracket-quoting.
* instance resolver - injectable registry reader; zero, one, and several
  instances.
* database selector - given a `sys.databases` shaped row set, proves `tempdb`,
  `model`, snapshots, standby and non-ONLINE rows are excluded and `master` and
  `msdb` are not.
* crypto round-trip - seal then open recovers the exact string; a flipped
  ciphertext byte is rejected by the MAC rather than returning garbage.
* redaction - a config block containing a password renders with the value gone.

Each assertion must fail if the behaviour it names is broken, not merely if a
string disappears from the source. Source-text assertions pass vacuously here and
have done before.
