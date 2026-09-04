# Point-in-Time Recovery — Design Spec

- **Date:** 2026-09-04
- **Status:** Design approved; pending spec review
- **Component:** SQL-Express-Tool — `Invoke-SqlExpressBackup.ps1` (engine) + WPF app (`wpf/`)
- **Feature:** 1 of 4 in the enterprise roadmap. Order: **PITR** → Protect-the-backups → Automated restore testing → Alerting.

## 1. Goal & posture

Turn worst-case data loss (RPO) from the current backup interval (6 h default) down to about 15 minutes, and make any moment inside the retained window recoverable.

**Approved posture — "tightest practical, all user databases":** every *user* database moves to `FULL` recovery and receives full + differential + transaction-log backups, with automatic log-growth handling. The posture is still per-database overridable, but the default enrolls all user databases.

**Non-negotiable invariant:** moving a database to `FULL` must never bloat its transaction log. The switch to `FULL` and the start of log backups are coupled in a single operation (see §7).

## 2. Scope

**In scope:** recovery-model management; differential and transaction-log backup modes; chain-aware scheduling; chain storage layout; point-in-time restore (engine mode + WPF UI); chain-safe retention; log-growth safety and chain-health surfacing; config and status plumbing; tests.

**Out of scope (deferred to their own specs):**
- OS-level compression / encryption / immutability of the resulting files — roadmap feature #2. This spec must leave file handling wrappable but does not implement it.
- Scheduled *automated* restore-testing — feature #3. (This spec's live end-to-end test is a manual precursor.)
- Alerting transport (email/Teams/webhook) — feature #4. This spec only *raises* the health signals (log-growth warning, broken-chain) that #4 will consume.
- GFS long-horizon retention — Tier 3. This spec makes retention chain-safe so GFS drops in on top of it.

## 3. Backup model

Three backup types replace the single full:

| Type | Cadence | Role | Engine | File |
|---|---|---|---|---|
| Full | full-schedule (default daily) | anchors the chain | `Invoke-SebBackupDatabase` (`-Kind full`) | `.bak` |
| Differential | the intervening data-pass runs | shrinks restore (full + last diff + tail logs) | `Invoke-SebBackupDatabase` (`-Kind diff`, adds `WITH DIFFERENTIAL`) | `.dif` |
| Log | every ~15 min (configurable 5–60) | enables `STOPAT` to any moment | new `Invoke-SebBackupLog` (`BACKUP LOG … WITH CHECKSUM, STATS, NAME`) | `.trn` |

**System databases** (`master`, `model`, `msdb`, `tempdb`) are unchanged and stay full-only — `master`/`tempdb` cannot take log backups, and `msdb`/`model` are left as-is for simplicity. Enrollment applies to user databases only (`database_id > 4`, `state_desc = 'ONLINE'`, not read-only).

**Enabling PITR on a user database** (idempotent, evaluated each data pass):
1. If `recovery_model_desc <> 'FULL'` → `ALTER DATABASE … SET RECOVERY FULL`.
2. Immediately take an anchoring **full** if none exists since the switch. A recovery-model change starts a new log chain with no base; `BACKUP LOG` fails (error 4214) until a full is taken.
3. Thereafter the 15-minute log job backs it up.

`Invoke-SebBackupDatabase` reuses its existing `INIT, FORMAT, CHECKSUM, STATS = 5, NAME` clause and its native-`COMPRESSION` attempt-and-fallback path (already Express-aware); `-Kind diff` appends `DIFFERENTIAL`. `Invoke-SebBackupLog` mirrors the info-message/progress handler so log backups stream `[PROGRESS]` like the others.

## 4. Scheduling

Current: one SYSTEM scheduled task, `New-ScheduledTaskTrigger -Once … -RepetitionInterval (New-TimeSpan -Hours $Hours)`, running `-Run` → `Invoke-SebPass` (full of every database).

Changes:
- The existing N-hour task becomes **chain-aware** in `-Run`: it takes a **full** when due on the full-schedule and a **differential** otherwise. The full/diff split is governed by config (`FullEveryHours`, default 24).
- A **new 15-minute SYSTEM task** runs a new mode `-BackupLog`: transaction-log backups of every `FULL`-recovery user database. Registered by `Install-SebTask` under a second task name (`$script:SebTaskName + '-Log'`) with `-RepetitionInterval (New-TimeSpan -Minutes $LogIntervalMinutes)` and a short `ExecutionTimeLimit`. Log backups are small and fast.
- **Service alternative:** the service loop (today one pass per `IntervalHours`) runs full/diff on the data cadence and a log pass every `LogIntervalMinutes` in the same loop — no second task.
- **Teardown:** `-Uninstall` removes **both** tasks. The app's existing "remove the SYSTEM task" path (roadmap feature #4, already shipped) must delete the `-Log` task too.

## 5. Storage layout

- `Get-SebBackupPath` `ValidateSet` extends from `'hourly','daily'` to `'hourly','daily','diff','log'`. Fulls keep the existing hourly→daily promotion; diffs land in `diff\`, logs in `log\`, under the same `host\instance\db\` root.
- Extensions distinguish the types and stay human-sortable: full `.bak` (unchanged), diff `.dif`, log `.trn`. `Get-SebFileName` gains an extension parameter; `Get-SebStampFromName`'s regex becomes `_(\d{8})-(\d{6})\.(bak|dif|trn)$`; `Get-SebFolderFacts`'s filter includes all three.
- **LSNs come from headers, not filenames.** The restore planner and chain-retention read `RESTORE HEADERONLY` (`FirstLSN`/`LastLSN`/`DatabaseBackupLSN`/`BackupFinishDate`) — authoritative — while filenames stay timestamp-only for human legibility.

## 6. Point-in-time restore

**Engine — new mode** `-RestoreToPoint -RestoreAs <name> -StopAt <datetime> [-Database <src>]`, reusing the existing restore placement/replace flags.

`Get-SebRestorePlan` (pure, testable) — input: a catalogue of `{kind, file, firstLSN, lastLSN, databaseBackupLSN, backupFinishDate}` for one database plus a target datetime. Output: an ordered step list —
1. the newest **full** whose `backupFinishDate <= target`,
2. the newest **differential** based on that full and finishing `<= target` (optional),
3. each subsequent **log**, contiguous by LSN, up to and including the one that spans the target.

The final log restores `WITH STOPAT = target, RECOVERY`; every prior step `WITH NORECOVERY`. The planner validates LSN contiguity (each step's `firstLSN` continues the prior `lastLSN`) and returns a gap error naming the missing segment if the chain is broken. Targets before the earliest full or after the newest log return a clear bounded-range error.

The executor reuses `Get-SebRestoreTargets` / `Get-SebRestoreMoveClauses` for physical-file relocation on restore-as-new-name, and streams `[STAGE]` / `[PROGRESS]` like the existing `-RestoreRun`.

**WPF — `RestoreWindow` gains a "Restore to a point in time" mode:**
- pick the source database (from the catalogue),
- a datetime picker **bounded to `[earliest recoverable … newest log]`**, where earliest = the oldest retained full's finish time,
- a read-only **plan preview**: the full + diff + N logs it will use and the effective `STOPAT`,
- the existing **Verify** button, extended to validate the chain for the chosen point before **Restore** is enabled,
- live progress on the existing `GlowBar` via the `Elevate --live` tail.

## 7. Safety

- **Log-growth guard.** The §3 coupling (switch ⇒ anchor full ⇒ log job) prevents the classic post-`FULL` bloat. Each data pass also probes `sys.databases.log_reuse_wait_desc` and `DBCC SQLPERF(LOGSPACE)`; if a database shows `log_reuse_wait_desc = 'LOG_BACKUP'` with log space used past a threshold (default 70%), the pass takes an immediate catch-up log backup and records a warning.
- **Broken-chain detection & re-anchor.** If `BACKUP LOG` returns 4214/4211 (no base / chain broken), or the planner detects an LSN gap, the engine takes a fresh full to re-anchor and records the break window. Logs before the break stay restorable up to it.
- **Chain-safe retention.** For `FULL`-recovery databases the simple hourly/daily prune is replaced by `Get-SebChainRetentionPlan` (a pure sibling of `Get-SebRetentionPlan`): keep every full newer than `now − DailyKeepDays`; keep every diff/log whose `lastLSN >= firstLSN` of the oldest full still kept; prune only segments strictly older than the oldest retained anchor. Never delete a full/diff/log a retained recovery point still needs. GFS (Tier 3) extends this function rather than replacing it.
- **New-database enrollment.** `Invoke-SebPass` already enumerates user databases; any not yet `FULL` is enrolled per §3 on the next data pass.

## 8. Config & status surface

- `config.json` / `public.json` gain: `RecoveryMode` (`'Simple'` legacy | `'Full'`), `LogIntervalMinutes` (default 15), `FullEveryHours` (default 24), and chain-retention settings. Defaults preserve current behaviour whenever `RecoveryMode = 'Simple'`.
- The Setup wizard and `-Reschedule` (already present) expose `LogIntervalMinutes` and the full/diff cadence.
- Status (`-Status`, `DbaView`, `ModernView` schedule pane) shows, per database: recovery model, last full/diff/log times, current RPO (age of the newest log), and chain health (OK / warning / broken).

## 9. Backward compatibility

- `RecoveryMode` defaults to `'Simple'` on existing installs — no behaviour change until the user opts into `Full` via Setup or Reschedule. Selecting the approved posture sets `Full`.
- Existing `.bak`-only shares keep restoring through the current `-RestoreRun` path; `-RestoreToPoint` is purely additive.

## 10. Testing

**Pure-function unit tests** (dot-sourced, mutation-checked per the repo's "assert behaviour, not source text" rule):
- `Get-SebRestorePlan`: synthetic catalogues → correct step order and `STOPAT`; gap detection; diff-optional; target-before-earliest and target-after-latest → clear errors.
- `Get-SebChainRetentionPlan`: chains with dependent logs never propose deleting a still-needed anchor; a **positive control** proves a genuinely prunable old segment *is* pruned (so a zero-deletions result is never vacuous).
- `Get-SebStampFromName` / `Get-SebFolderFacts`: `.dif` / `.trn` recognised alongside `.bak`.

**Live end-to-end** (scratch database, Windows auth, mirroring this project's proven restore run; host/share/db names redacted in any echo):
full → insert row A → diff → insert row B → log → insert row C → log; then `-RestoreToPoint` with `STOPAT` set between the B-log and the C-log, restoring to `RestoreDemo2`; assert row B present, row C absent, `DBCC CHECKDB` clean; drop `RestoreDemo2`.

Run per the repo's suite rules — sequentially, and never via WSL on `/mnt/c`.

## 11. Rollout

Ship behind `RecoveryMode`. Build order within the feature, each landing green before the next:
(a) engine backup modes (`-Kind diff`, `Invoke-SebBackupLog`) + chain-aware scheduling + storage extensions; (b) chain-safe retention; (c) restore plan + executor (`-RestoreToPoint`); (d) WPF restore-to-point UI + status surface; (e) tests throughout.

## Open questions

None blocking. The three defaults — 15-minute log cadence, the scheduled-task model (over pushing install-as-service), and system databases staying full-only — were confirmed at design time. Compression/encryption wrapping, automated restore-testing, alerting transport, and GFS retention are deferred to their own specs.
