# Automated Restore Testing — Design Spec

- **Date:** 2026-09-25
- **Status:** Design decisions approved (depth, coverage, cadence). Increment 1 (engine) and increment 2 (app) implemented and tested.
- **Component:** SQL-Express-Tool — `Invoke-SqlExpressBackup.ps1` (engine, increment 1); `wpf/` (increment 2)
- **Feature:** Roadmap feature 3 — automated restore testing. (The compression spec called offsite replication "feature 3"; the PITR spec's order — PITR → protect → restore testing → alerting — is the canonical one. Alerting shipped first by decision.)

## 1. Goal

Prove, on a schedule and without a person, that the backups on the share actually restore: the newest backup chain of a database is restored to a scratch database, checked with `DBCC CHECKDB`, recorded, and dropped. A failure is an alert. The drill record that started this project — every backup verified, every pass green, and the restore refused with OS error 5 — is exactly what this catches before an incident does.

## 2. Decisions (approved)

| Question | Decision |
|---|---|
| Depth | **Latest recoverable point.** Full mode: the newest full + its differential + every log after it, recovered at the end of the last log — the whole chain is exercised. Simple mode: the newest full. Then `DBCC CHECKDB`. |
| Coverage | **Rotate, one database per run** — the one whose last test is oldest (never-tested first). Bounded time and disk per run. |
| Cadence | **Daily at a quiet hour** — a SYSTEM task, default 03:30, configurable. |

## 3. Behaviour

**Selection (pure):** the databases with backups on the share for this host/instance, ordered by last test time from `state.json` `RestoreTests` (never tested first, then oldest; ties alphabetical). `-TestRestore -Database X` tests one database on demand.

**Plan (pure):** `Get-SebLatestRestorePlan` — newest full as the base; the newest differential whose `DatabaseBackupLSN` equals the base's `CheckpointLSN`; then logs with `LastLSN` past the chain point, contiguous by LSN. A gap is a **failed test** ("the chain is broken after <file>"), not a shorter test. The last step carries `RECOVERY`. `Get-SebRestoreStepSql` gains plain `RECOVERY` for a final full, diff, or log without `STOPAT`.

**Execution (impure):** the existing point-in-time executor is split so both callers share it: `Invoke-SebRestoreSteps` (inspect the full's file list, clobber guard, MOVE clauses, `.zip` expansion into a SQL-readable temp folder, each step) is used by `-RestoreToPoint` and by the test.

- **Target:** `SebRestoreTest_<db>` (non-word characters → `_`). Files in `<StagingPath>\restore-test\` — staging is already granted to the SQL service account. The name prefix is reserved: before a test, any leftover `SebRestoreTest_%` database from an interrupted run is dropped, and the target is refused if it names a database that is not ours.
- **Space:** the sum of the backup's file sizes (from `FILELISTONLY`) × 1.1 must fit on the staging drive; otherwise the test is **skipped** with a warning alert, never attempted.
- **Check:** `DBCC CHECKDB (…) WITH NO_INFOMSGS, ALL_ERRORMSGS`.
- **Always cleaned up** in `finally`: drop the scratch database (`SINGLE_USER WITH ROLLBACK IMMEDIATE`), remove its files and the temp folder.
- **Locking:** does **not** take the backup mutex. A long test would otherwise make every log backup stand down for its duration — a point-in-time gap caused by the thing meant to prove point-in-time works. Retention keeps the newest chain, so the files under test are not pruned mid-test.

**Result** per database in `state.json` `RestoreTests[<db>]`: `{ LastUtc, Result (ok|failed|skipped), Message, DurationSeconds, Steps, RecoveredToUtc }`, published in `public.json` for the app.

## 4. Alerting

Conditions, owner `restore-test:<db>` so a test of one database never resolves another's alert:

| Key | Severity | When |
|---|---|---|
| `restore-test-failed:<db>` | critical | the restore or CHECKDB failed, or the chain is broken |
| `restore-test-skipped:<db>` | warning | not enough space on the staging drive to try |

The watchdog adds `restore-test-task-missing` (warning) when testing is enabled but its task is absent or disabled.

## 5. Configuration

Config keys (allow-listed): `RestoreTesting` (bool, default **off** — opt-in like compression; the app's setup wizard offers it ticked), `RestoreTestTime` (`HH:mm`, default `03:30`). CLI on `-Setup`/`-Reschedule`: `-RestoreTesting On|Off` (the `-File`-safe spelling of a bool), `-RestoreTestTime HH:mm`; unbound = unchanged (and `-Setup` carries them over, like the recovery settings). The task `SqlExpressBackup-RestoreTest` is reconciled by every install path, removed by `-Uninstall`.

Mode: `-TestRestore [-Database <name>]` (elevated). Prints a JSON result; exit 0 ok, 1 skipped, 2 failed.

## 6. Testing

**Unit:** database selection (never-tested first, oldest next, tie order); `Get-SebLatestRestorePlan` (full only; full + diff matched by CheckpointLSN; full + logs; a gap → error; a diff for a different base is ignored); step SQL for every final-step kind; scratch-name sanitising and the reserved-prefix guard; the space check; result → condition mapping.

**Live** (`test/live-restore-test.ps1`): Simple mode — a full restores and CHECKDBs clean, scratch database gone afterwards. Full mode — full + diff + logs restore to the newest log, and a row written just before the last log backup is present in the restored copy. A deliberately deleted middle log → the test reports the broken chain.

## 7. Increment 2 (app)

The setup wizard's Protection section gains "Test restores daily at HH:mm"; the overview shows the last restore test (database, result, when); a "Test a restore now" action runs `-TestRestore` as an elevated job.
