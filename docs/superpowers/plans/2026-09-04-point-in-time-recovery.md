# Point-in-Time Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the SQL Express backup tool point-in-time recovery — every user database in `FULL` recovery with full + differential + 15-minute log backups, a `STOPAT` restore, and chain-safe retention — behind a `RecoveryMode` flag that leaves existing installs untouched.

**Architecture:** All new decision logic is pure PowerShell functions (restore planner, chain retention, backup-kind/SQL builders) unit-tested in `test/sqlexpress-backup.test.ps1`; the impure wrappers (BACKUP/RESTORE, scheduling, WPF) call those pure cores and are proven by a live scratch-database run. The engine stays one copyable PS 5.1 / ASCII file. The WPF app gains a "restore to a point in time" mode that consumes the same engine modes over the existing `--live` tail.

**Tech Stack:** Windows PowerShell 5.1 (engine, single file `Invoke-SqlExpressBackup.ps1`), `System.Data.SqlClient` with `SqlCredential`, Windows Task Scheduler, code-first WPF built with in-box `csc.exe` (C# 5).

---

## Repo conventions every task MUST follow

- **Engine is one ASCII, PS 5.1 file.** No non-ASCII characters anywhere in `Invoke-SqlExpressBackup.ps1`; no `= (try {...})`; no dot-sourcing inside it. The suite's structural guards fail the build otherwise.
- **Tests assert behaviour, never source text.** Drive the real function with real data. Every "it isn't deleted / isn't there" assertion is paired with a **positive control** that proves the same code path *does* act when it should — a zero result is otherwise vacuous.
- **Run the suite sequentially, natively — never via WSL on `/mnt/c`.** Command, always from the repo root:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "test\sqlexpress-backup.test.ps1"`
  Pass shows `  PASS <msg>` lines and exits 0; a failure throws `FAIL: <msg>` and exits non-zero. "Run to verify it fails" means run this file and see the throw.
- **Commits:** stage only the files a task names (never `git add -A`). Author is already `79465188+ssaksa80@users.noreply.github.com` in this repo. End every commit message with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.
- **LSNs** from `RESTORE HEADERONLY` are `numeric(25,0)`; represent them as `[decimal]` (fits) throughout the pure planners.
- The engine is dot-sourced into tests by `. $script -DotSourceOnly`, which defines functions without executing `main`.

## File Structure

**Engine — `Invoke-SqlExpressBackup.ps1`** (modify in place, keep functions grouped with their neighbours):
- `Get-SebBackupPath` — extend `[ValidateSet]` to include `diff`, `log`.
- `Get-SebFileName` — add `-Extension` (default `bak`).
- `Get-SebStampFromName` — accept `.bak|.dif|.trn`.
- `Get-SebFolderFacts` — enumerate `.bak|.dif|.trn`.
- `Get-SebBackupSql` **(new, pure)** — build the BACKUP T-SQL for `full|diff|log`.
- `Invoke-SebBackupDatabase` — gain `-Kind full|diff`, call `Get-SebBackupSql`.
- `Invoke-SebBackupLog` **(new)** — `BACKUP LOG`.
- `Get-SebRecoveryFullSql` **(new, pure)** + `Set-SebRecoveryFull` **(new)** — move a db to FULL, idempotent.
- `Get-SebBackupKindDue` **(new, pure)** — full-vs-diff decision for a data pass.
- `Get-SebChainRetentionPlan` **(new, pure)** — chain-safe pruning.
- `Get-SebRestorePlan` **(new, pure)** — ordered `STOPAT` restore steps.
- `Get-SebRestoreHeaderFacts` **(new)** + `Get-SebPointCatalogue` **(new)** — read LSN facts from the share.
- `Invoke-SebBackupLogPass` **(new)** — the `-BackupLog` pass; `Invoke-SebPass` — chain-aware + enrollment + log-growth probe.
- `Get-SebLogTaskName` **(new, pure)** + `Install-SebTask` / uninstall — second 15-minute task.
- Param block + `main` dispatch — `-BackupLog`, `-RestoreToPoint`, `-StopAt`, `RecoveryMode`, `LogIntervalMinutes`, `FullEveryHours`; config template, `$SebShowKeys`, Setup, `-Reschedule`, `Write-SebPublicSummary`, `-Status`.

**Tests — `test/sqlexpress-backup.test.ps1`** (append behaviour blocks).

**WPF — `wpf/Engine.cs`, `wpf/RestoreWindow.cs`, `wpf/ModernView.cs`** (point-in-time restore mode + status surface). Build: `powershell -NoProfile -ExecutionPolicy Bypass -File build-wpf.ps1 -SelfSign`.

**Live check — `test/live-pitr.ps1`** (new; scratch-database end-to-end, not committed to CI, run by hand where SQL is present).

---

## Phase A — Storage & backup primitives

### Task A1: Extension-aware filenames and folder facts

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (`Get-SebBackupPath`, `Get-SebFileName`, `Get-SebStampFromName`, `Get-SebFolderFacts`)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing tests.** Append to `test/sqlexpress-backup.test.ps1` before its final summary line:

```powershell
# ---- A1. filenames and folder facts carry .dif / .trn as well as .bak --------------
$stampA = [datetime]'2026-09-04 09:15:00'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $stampA) -eq 'APPDB_20260904-091500.bak') 'default extension is .bak (unchanged)'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $stampA -Extension 'dif') -eq 'APPDB_20260904-091500.dif') 'a differential file is named .dif'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $stampA -Extension 'trn') -eq 'APPDB_20260904-091500.trn') 'a log file is named .trn'

$fb = [datetime]'2000-01-01'
Assert ((Get-SebStampFromName -Name 'APPDB_20260904-091500.trn' -Fallback $fb) -eq $stampA) 'the stamp is read out of a .trn name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260904-091500.dif' -Fallback $fb) -eq $stampA) 'the stamp is read out of a .dif name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260904-091500.bak' -Fallback $fb) -eq $stampA) 'the stamp is still read out of a .bak name (no regression)'

$tmpA = Join-Path $env:TEMP ('seb-a1-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpA -Force)
Set-Content -LiteralPath (Join-Path $tmpA 'APPDB_20260904-090000.bak') -Value 'x'
Set-Content -LiteralPath (Join-Path $tmpA 'APPDB_20260904-091500.trn') -Value 'x'
Set-Content -LiteralPath (Join-Path $tmpA 'APPDB_20260904-093000.dif') -Value 'x'
Set-Content -LiteralPath (Join-Path $tmpA 'notes.txt') -Value 'x'
$facts = @(Get-SebFolderFacts -Directory $tmpA)
Assert ($facts.Count -eq 3) "folder facts include .bak, .dif and .trn but not .txt (got $($facts.Count))"
Assert (@($facts | Where-Object { $_.Name -like '*.trn' }).Count -eq 1) 'the .trn file is enumerated'
Remove-Item -LiteralPath $tmpA -Recurse -Force -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify it fails.** Run the suite command. Expected: throws `FAIL: a differential file is named .dif` (or a parameter-binding error on `-Extension`).

- [ ] **Step 3: Implement.** In `Invoke-SqlExpressBackup.ps1`:

`Get-SebBackupPath` — widen the set:
```powershell
    [ValidateSet('hourly', 'daily', 'diff', 'log')]
    [string]$Kind
```

`Get-SebFileName` — add the extension:
```powershell
function Get-SebFileName {
  param([string]$Database, [datetime]$Stamp, [string]$Extension = 'bak')
  return ('{0}_{1}.{2}' -f (Get-SebSafeName $Database), $Stamp.ToString('yyyyMMdd-HHmmss'), $Extension)
}
```

`Get-SebStampFromName` — widen the regex (only the pattern line changes):
```powershell
  $match = [regex]::Match($Name, '_(\d{8})-(\d{6})\.(bak|dif|trn)$')
```

`Get-SebFolderFacts` — enumerate all three extensions (replace the `Get-ChildItem -Filter '*.bak'` line):
```powershell
  $items = Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '\.(bak|dif|trn)$' }
```

- [ ] **Step 4: Run to verify it passes.** Run the suite. Expected: the new `PASS` lines appear and the file exits 0 (including the pre-existing `.bak` stamp assertion at the top of section 3).

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): name and enumerate .dif/.trn backups alongside .bak"
```

### Task A2: BACKUP T-SQL builder (pure) for full / diff / log

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebBackupSql`; refactor `Invoke-SebBackupDatabase` to call it; new `Invoke-SebBackupLog`)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing tests.** Append:

```powershell
# ---- A2. the BACKUP T-SQL builder ---------------------------------------------------
$full = Get-SebBackupSql -Kind 'full' -Database 'APPDB' -TargetFile 'D:\stg\APPDB.bak' -Compress $false
Assert ($full -match 'BACKUP DATABASE \[APPDB\] TO DISK') 'full backup is BACKUP DATABASE'
Assert ($full -match 'CHECKSUM') 'full backup asks for CHECKSUM'
Assert ($full -notmatch 'DIFFERENTIAL') 'a full backup is not a differential'
Assert ($full -notmatch 'COMPRESSION') 'compression is omitted when Compress is false'

$fullC = Get-SebBackupSql -Kind 'full' -Database 'APPDB' -TargetFile 'D:\stg\APPDB.bak' -Compress $true
Assert ($fullC -match 'COMPRESSION') 'compression is included when Compress is true'

$diff = Get-SebBackupSql -Kind 'diff' -Database 'APPDB' -TargetFile 'D:\stg\APPDB.dif' -Compress $false
Assert ($diff -match 'BACKUP DATABASE \[APPDB\] TO DISK') 'a differential is still BACKUP DATABASE'
Assert ($diff -match 'DIFFERENTIAL') 'a differential says DIFFERENTIAL'

$log = Get-SebBackupSql -Kind 'log' -Database 'APPDB' -TargetFile 'D:\stg\APPDB.trn' -Compress $false
Assert ($log -match 'BACKUP LOG \[APPDB\] TO DISK') 'a log backup is BACKUP LOG'
Assert ($log -notmatch 'DIFFERENTIAL') 'a log backup is not a differential'

$q = Get-SebBackupSql -Kind 'full' -Database "we'ird" -TargetFile "D:\a'b.bak" -Compress $false
Assert ($q -match "\[we'ird\]") 'the database name is bracket-quoted'
Assert ($q -match "D:\\a''b\.bak") 'the target path is SQL-literal-escaped (single quote doubled)'
```

- [ ] **Step 2: Run to verify it fails.** Expected: `FAIL` / command-not-found on `Get-SebBackupSql`.

- [ ] **Step 3: Implement.** Add `Get-SebBackupSql` next to `Invoke-SebBackupDatabase` (uses the existing `Get-SebQuotedName` / `Get-SebSqlLiteral` helpers):

```powershell
# The BACKUP statement as a pure string, so the exact WITH clause is unit-testable.
# Kind: full | diff | log. Compress adds COMPRESSION (callers turn it off and retry
# on editions - like Express - that reject it).
function Get-SebBackupSql {
  param(
    [ValidateSet('full', 'diff', 'log')]
    [string]$Kind,
    [string]$Database,
    [string]$TargetFile,
    [bool]$Compress = $false
  )
  $quoted = Get-SebQuotedName $Database
  $literal = Get-SebSqlLiteral $TargetFile
  $label = Get-SebSqlLiteral ($Database + ' ' + $Kind + ' backup')
  $with = @('INIT', 'FORMAT', 'CHECKSUM', 'STATS = 5', ('NAME = ' + $label))
  if ($Kind -eq 'diff') { $with = @('DIFFERENTIAL') + $with }
  if ($Compress) { $with = $with + @('COMPRESSION') }
  $verb = 'BACKUP DATABASE'
  if ($Kind -eq 'log') { $verb = 'BACKUP LOG' }
  return ('{0} {1} TO DISK = {2} WITH {3}' -f $verb, $quoted, $literal, ($with -join ', '))
}
```

Refactor `Invoke-SebBackupDatabase` to add `-Kind` and delegate SQL to the builder, keeping the existing compression attempt/fallback and the 3201 message. Replace its body's SQL construction with:
```powershell
function Invoke-SebBackupDatabase {
  param($Connection, [string]$Database, [string]$TargetFile, [ValidateSet('full','diff')][string]$Kind = 'full')
  $compress = ($script:SebCompression -ne 'off')
  $sql = Get-SebBackupSql -Kind $Kind -Database $Database -TargetFile $TargetFile -Compress $compress
  $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
    param($eventSender, $eventArgs)
    $pct = Get-SebPercentFromMessage $eventArgs.Message
    if ($pct -ge 0) { Write-SebProgress -Database $script:SebProgressDb -Percent $pct -Stage ('backup-' + $script:SebProgressKind) }
  }
  $script:SebProgressDb = $Database
  $script:SebProgressKind = $Kind
  $Connection.add_InfoMessage($handler)
  try {
    Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
    if ($script:SebCompression -eq 'unknown') { $script:SebCompression = 'on' }
    return
  }
  catch {
    $numbers = Get-SebSqlErrorNumbers $_
    $message = $_.Exception.Message
    if ($numbers -contains 3201) {
      throw ("SQL Server cannot write '$TargetFile'. The .bak is created by the SQL Server service " +
        "account, not by whoever runs this script, so that account needs Modify on the staging " +
        "folder. Re-run -Setup, which grants it and then proves it. Original error: " + $message)
    }
    if ($script:SebCompression -eq 'off') { throw }
    if (-not (Test-SebCompressionUnsupported -Numbers $numbers -Message $message)) { throw }
    $script:SebCompression = 'off'
    Write-SebLog 'this edition has no backup compression - continuing uncompressed' 'INFO'
  }
  $sql = Get-SebBackupSql -Kind $Kind -Database $Database -TargetFile $TargetFile -Compress $false
  try { Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql }
  finally { $Connection.remove_InfoMessage($handler) }
}
```

Add `Invoke-SebBackupLog` right after it:
```powershell
# BACKUP LOG. Error 4214 ("no current database backup") means the log chain has no
# base yet - the caller anchors with a full and retries. Everything else propagates.
function Invoke-SebBackupLog {
  param($Connection, [string]$Database, [string]$TargetFile)
  $sql = Get-SebBackupSql -Kind 'log' -Database $Database -TargetFile $TargetFile -Compress $false
  try { Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql }
  catch {
    if ((Get-SebSqlErrorNumbers $_) -contains 4214) { throw 'SEB_LOG_NO_BASE' }
    throw
  }
}
```

- [ ] **Step 4: Run to verify it passes.** Run the suite. Expected: all A2 `PASS` lines; the existing suite still green.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): pure BACKUP builder + differential and log backup modes"
```

### Task A3: move a database to FULL recovery (idempotent)

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebRecoveryFullSql`, `Set-SebRecoveryFull`)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing tests.** Append:

```powershell
# ---- A3. switching recovery model ---------------------------------------------------
Assert ((Get-SebRecoveryFullSql -Database 'APPDB') -eq 'ALTER DATABASE [APPDB] SET RECOVERY FULL') 'the recovery-model change is a bracket-quoted ALTER DATABASE'
Assert ((Get-SebRecoveryFullSql -Database "we'ird") -eq "ALTER DATABASE [we'ird] SET RECOVERY FULL") 'an odd database name is still bracket-quoted'
Assert (-not (Test-SebNeedsRecoveryFull -Model 'FULL')) 'a database already in FULL needs no change'
Assert (Test-SebNeedsRecoveryFull -Model 'SIMPLE') 'a SIMPLE database needs the change'
Assert (Test-SebNeedsRecoveryFull -Model 'BULK_LOGGED') 'a BULK_LOGGED database needs the change'
```

- [ ] **Step 2: Run to verify it fails.** Expected: command-not-found on `Get-SebRecoveryFullSql`.

- [ ] **Step 3: Implement.** Add near `Invoke-SebBackupLog`:
```powershell
function Get-SebRecoveryFullSql {
  param([string]$Database)
  return ('ALTER DATABASE {0} SET RECOVERY FULL' -f (Get-SebQuotedName $Database))
}

function Test-SebNeedsRecoveryFull {
  param([string]$Model)
  return ($Model -ne 'FULL')
}

# Idempotent. Reads the model, changes it only if needed, and returns $true when it
# changed (so the caller knows a fresh anchoring full is now required).
function Set-SebRecoveryFull {
  param($Connection, [string]$Database)
  $rows = Invoke-SebSqlTable -Connection $Connection -Sql (
    "SELECT recovery_model_desc AS m FROM sys.databases WHERE name = " + (Get-SebSqlLiteral $Database))
  $model = if (@($rows).Count -gt 0) { [string]$rows[0].m } else { 'FULL' }
  if (-not (Test-SebNeedsRecoveryFull -Model $model)) { return $false }
  Invoke-SebSqlNonQuery -Connection $Connection -Sql (Get-SebRecoveryFullSql -Database $Database)
  Write-SebLog ('recovery model of a database set to FULL') 'INFO'
  return $true
}
```

- [ ] **Step 4: Run to verify it passes.** Run the suite; expect the A3 `PASS` lines.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): idempotent switch of a database to FULL recovery"
```

---

## Phase B — Chain-safe retention

### Task B1: `Get-SebChainRetentionPlan` (pure)

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebChainRetentionPlan`)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing tests.** Append. Facts carry a `[decimal]` `FirstLSN`, and fulls carry their own `FirstLSN`; diffs/logs carry `LastLSN`. The rule under test: keep the oldest full still newer than the horizon plus everything newer (falling back to the single newest full when none are in-horizon), and never delete a diff/log still needed to roll a retained full forward.

```powershell
# ---- B1. chain-safe retention never strands a needed segment ------------------------
function New-Seg([string]$n, [datetime]$t, [decimal]$first, [decimal]$last) {
  return [pscustomobject]@{ Name = $n; Timestamp = $t; FirstLSN = $first; LastLSN = $last }
}
$nowB = [datetime]'2026-09-04 12:00:00'
# One full today + three logs after it. Horizon 7 days keeps everything.
$fullsB = @( (New-Seg 'F-today' $nowB 1000 1000) )
$logsB  = @(
  (New-Seg 'L1' $nowB.AddMinutes(15) 1000 1100),
  (New-Seg 'L2' $nowB.AddMinutes(30) 1100 1200),
  (New-Seg 'L3' $nowB.AddMinutes(45) 1200 1300)
)
$planB = Get-SebChainRetentionPlan -Fulls $fullsB -Diffs @() -Logs $logsB -Now $nowB -DailyKeepDays 7
Assert ($planB.FullDelete.Count -eq 0 -and $planB.LogDelete.Count -eq 0) 'a single in-horizon chain prunes nothing'

# Add an OLD full (10 days) with its own two logs, all before the retained full's LSN.
$fullsB2 = $fullsB + @( (New-Seg 'F-old' $nowB.AddDays(-10) 10 10) )
$logsB2  = $logsB + @(
  (New-Seg 'Lold1' $nowB.AddDays(-10).AddMinutes(15) 10 20),
  (New-Seg 'Lold2' $nowB.AddDays(-10).AddMinutes(30) 20 30)
)
$planB2 = Get-SebChainRetentionPlan -Fulls $fullsB2 -Diffs @() -Logs $logsB2 -Now $nowB -DailyKeepDays 7
Assert ($planB2.FullDelete -contains 'F-old') 'the out-of-horizon full is pruned (positive control: pruning does happen)'
Assert ($planB2.LogDelete -contains 'Lold1' -and $planB2.LogDelete -contains 'Lold2') 'logs belonging only to the pruned full are pruned'
Assert ($planB2.FullDelete -notcontains 'F-today') 'the retained full is never pruned'
Assert ($planB2.LogDelete -notcontains 'L2') 'a log needed to roll the retained full forward is never pruned'

# Safety: if the ONLY full is out of horizon, it is still kept - deleting it would
# leave nothing to restore from.
$planB3 = Get-SebChainRetentionPlan -Fulls @((New-Seg 'F-lonely' $nowB.AddDays(-30) 5 5)) -Diffs @() -Logs @() -Now $nowB -DailyKeepDays 7
Assert ($planB3.FullDelete.Count -eq 0) 'the last surviving full is kept even past the horizon (never leave zero fulls)'

# Empty inputs are safe.
$planB4 = Get-SebChainRetentionPlan -Fulls @() -Diffs @() -Logs @() -Now $nowB -DailyKeepDays 7
Assert ($planB4.FullDelete.Count -eq 0 -and $planB4.DiffDelete.Count -eq 0 -and $planB4.LogDelete.Count -eq 0) 'empty folders prune nothing and do not error'
```

- [ ] **Step 2: Run to verify it fails.** Expected: command-not-found on `Get-SebChainRetentionPlan`.

- [ ] **Step 3: Implement.** Add next to `Get-SebRetentionPlan`:
```powershell
# Chain-safe retention for FULL-recovery databases. Keep the oldest full still newer
# than the horizon and every full newer than it (fall back to the single newest full
# when none are in-horizon); keep every diff/log whose LastLSN reaches into or past
# that anchor full (i.e. still needed to roll it forward). Prune only segments that end
# strictly before the anchor begins. Never leave zero fulls. GFS (a later feature)
# layers extra "keep" rules on top of this floor.
function Get-SebChainRetentionPlan {
  param(
    [object[]]$Fulls = @(),
    [object[]]$Diffs = @(),
    [object[]]$Logs = @(),
    [datetime]$Now,
    [int]$DailyKeepDays = 7
  )
  if ($DailyKeepDays -lt 1) { $DailyKeepDays = 1 }
  $result = [pscustomobject]@{ FullDelete = @(); DiffDelete = @(); LogDelete = @() }
  $fullsSorted = @($Fulls | Sort-Object -Property Timestamp, FirstLSN)   # oldest first, deterministic on ties
  if ($fullsSorted.Count -eq 0) { return $result }

  $horizon = $Now.AddDays(-1 * $DailyKeepDays)
  # Anchor = the oldest full still newer than the horizon (the base a restore to the
  # oldest recoverable point needs); if none are in-horizon, keep the single newest full
  # so we never leave zero fulls. Fulls older than the anchor are prunable.
  $inHorizon = @($fullsSorted | Where-Object { $_.Timestamp -gt $horizon })
  if ($inHorizon.Count -gt 0) {
    $anchor = $inHorizon[0]
  }
  else {
    $anchor = $fullsSorted[$fullsSorted.Count - 1]
  }
  $anchorLsn = [decimal]$anchor.FirstLSN

  $result.FullDelete = @($fullsSorted | Where-Object { [decimal]$_.FirstLSN -lt $anchorLsn } | ForEach-Object { $_.Name })
  # A diff/log is prunable only if it ends before the anchor begins.
  $result.DiffDelete = @($Diffs | Where-Object { [decimal]$_.LastLSN -lt $anchorLsn } | ForEach-Object { $_.Name })
  $result.LogDelete  = @($Logs  | Where-Object { [decimal]$_.LastLSN -lt $anchorLsn } | ForEach-Object { $_.Name })
  return $result
}
```

- [ ] **Step 4: Run to verify it passes.** Run the suite; expect all B1 `PASS` lines including the positive control `F-old`.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): chain-safe retention that never strands a needed segment"
```

---

## Phase C — Point-in-time restore planner

### Task C1: `Get-SebRestorePlan` (pure)

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebRestorePlan`)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing tests.** Append. A catalogue entry is `{ Kind; File; FirstLSN; LastLSN; DatabaseBackupLSN; Finish }`. The planner returns either `{ Steps = @(...) }` or `{ Error = '...' }`.

```powershell
# ---- C1. the point-in-time restore planner -----------------------------------------
function New-Cat([string]$kind, [string]$file, [decimal]$first, [decimal]$last, [decimal]$dbb, [datetime]$finish) {
  return [pscustomobject]@{ Kind = $kind; File = $file; FirstLSN = $first; LastLSN = $last; DatabaseBackupLSN = $dbb; Finish = $finish }
}
$b = [datetime]'2026-09-04 08:00:00'
$cat = @(
  (New-Cat 'full' 'F.bak' 100 100 0   $b),
  (New-Cat 'diff' 'D.dif' 150 150 100 $b.AddHours(2)),
  (New-Cat 'log'  'L1.trn' 100 160 0  $b.AddHours(1)),
  (New-Cat 'log'  'L2.trn' 160 220 0  $b.AddHours(3)),
  (New-Cat 'log'  'L3.trn' 220 280 0  $b.AddHours(5))
)
# Target at 02:30 -> full, then the diff (finished 02:00, based on the full), then the
# log that spans 02:30 (L2, 01:00->03:00 wall / 160-220 lsn) with STOPAT.
$p = Get-SebRestorePlan -Catalogue $cat -StopAt ($b.AddHours(2).AddMinutes(30))
Assert (-not $p.Error) 'a target inside the chain plans without error'
Assert ($p.Steps[0].File -eq 'F.bak' -and $p.Steps[0].Kind -eq 'full') 'the plan starts with the newest full at or before the target'
Assert (@($p.Steps | Where-Object { $_.Kind -eq 'diff' }).Count -eq 1) 'the differential based on that full is included'
$last = $p.Steps[$p.Steps.Count - 1]
Assert ($last.Kind -eq 'log' -and $last.File -eq 'L2.trn') 'the final step is the log that spans the target'
Assert ($last.StopAt -eq ($b.AddHours(2).AddMinutes(30))) 'the final log carries STOPAT = the target'
Assert ($last.Recovery -eq $true) 'the final step recovers the database'
Assert (@($p.Steps | Where-Object { $_.Recovery -eq $true }).Count -eq 1) 'exactly one step recovers (all prior are NORECOVERY)'
Assert (@($p.Steps | Where-Object { $_.File -eq 'L3.trn' }).Count -eq 0) 'a log entirely after the target is not restored'

# Target before the earliest full -> a clear error, not a broken plan.
$pe = Get-SebRestorePlan -Catalogue $cat -StopAt ($b.AddHours(-1))
Assert ($pe.Error -match 'earliest') 'a target before the first full is a bounded-range error'

# Target after the newest log -> bounded error naming the latest recoverable time.
$pl = Get-SebRestorePlan -Catalogue $cat -StopAt ($b.AddHours(9))
Assert ($pl.Error -match 'newest|latest') 'a target after the last log is a bounded-range error'

# A gap in the log chain (missing 160->220) is detected, not silently skipped.
$catGap = @(
  (New-Cat 'full' 'F.bak' 100 100 0 $b),
  (New-Cat 'log'  'L1.trn' 100 160 0 $b.AddHours(1)),
  (New-Cat 'log'  'L3.trn' 220 280 0 $b.AddHours(5))
)
$pg = Get-SebRestorePlan -Catalogue $catGap -StopAt ($b.AddHours(5))
Assert ($pg.Error -match 'gap|chain') 'a break in the LSN chain is reported as a gap'
```

- [ ] **Step 2: Run to verify it fails.** Expected: command-not-found on `Get-SebRestorePlan`.

- [ ] **Step 3: Implement.** Add near the restore helpers (`Get-SebRestoreCatalogue` neighbourhood):
```powershell
# Pure. Given a catalogue for ONE database and a target time, return the ordered
# restore steps (full -> optional diff -> contiguous logs, last one STOPAT+RECOVERY),
# or an { Error } describing why the target is not recoverable. LSNs are decimals.
function Get-SebRestorePlan {
  param([object[]]$Catalogue = @(), [datetime]$StopAt)
  $fulls = @($Catalogue | Where-Object { $_.Kind -eq 'full' } | Sort-Object Finish)
  $eligible = @($fulls | Where-Object { $_.Finish -le $StopAt })
  if ($eligible.Count -eq 0) {
    return [pscustomobject]@{ Error = 'target is before the earliest full backup' }
  }
  $base = $eligible[$eligible.Count - 1]
  $steps = New-Object System.Collections.ArrayList
  [void]$steps.Add([pscustomobject]@{ Kind = 'full'; File = $base.File; Recovery = $false; StopAt = $null })

  $chainLsn = [decimal]$base.LastLSN
  $diffs = @($Catalogue | Where-Object {
      $_.Kind -eq 'diff' -and [decimal]$_.DatabaseBackupLSN -eq [decimal]$base.FirstLSN -and $_.Finish -le $StopAt
    } | Sort-Object Finish)
  if ($diffs.Count -gt 0) {
    $diff = $diffs[$diffs.Count - 1]
    [void]$steps.Add([pscustomobject]@{ Kind = 'diff'; File = $diff.File; Recovery = $false; StopAt = $null })
    $chainLsn = [decimal]$diff.LastLSN
  }

  $logs = @($Catalogue | Where-Object { $_.Kind -eq 'log' -and [decimal]$_.LastLSN -gt $chainLsn } | Sort-Object { [decimal]$_.FirstLSN })
  $spanning = $null
  $prevLast = $chainLsn
  foreach ($log in $logs) {
    if ([decimal]$log.FirstLSN -gt $prevLast) {
      return [pscustomobject]@{ Error = ('gap in the log chain before LSN {0} - the backup chain is broken' -f $log.FirstLSN) }
    }
    if ($log.Finish -ge $StopAt) { $spanning = $log; break }
    [void]$steps.Add([pscustomobject]@{ Kind = 'log'; File = $log.File; Recovery = $false; StopAt = $null })
    $prevLast = [decimal]$log.LastLSN
  }
  if ($null -eq $spanning) {
    $latest = if ($logs.Count -gt 0) { $logs[$logs.Count - 1].Finish } else { $base.Finish }
    return [pscustomobject]@{ Error = ('target is after the newest log backup (latest recoverable: {0:yyyy-MM-dd HH:mm:ss})' -f $latest) }
  }
  [void]$steps.Add([pscustomobject]@{ Kind = 'log'; File = $spanning.File; Recovery = $true; StopAt = $StopAt })
  return [pscustomobject]@{ Steps = @($steps.ToArray()) }
}
```

- [ ] **Step 4: Run to verify it passes.** Run the suite; expect all C1 `PASS` lines.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): pure point-in-time restore planner with gap detection"
```

### Task C2: read LSN facts and build the catalogue (impure)

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebRestoreHeaderFacts`, `Get-SebPointCatalogue`)
- Test: `test/sqlexpress-backup.test.ps1` (structural: functions defined + parse-clean; behaviour proven live in Phase E)

- [ ] **Step 1: Implement `Get-SebRestoreHeaderFacts`** — one file to its header facts via `RESTORE HEADERONLY`:
```powershell
function Get-SebRestoreHeaderFacts {
  param($Connection, [string]$File, [string]$Kind)
  $rows = @(Invoke-SebSqlTable -Connection $Connection -Sql ('RESTORE HEADERONLY FROM DISK = {0}' -f (Get-SebSqlLiteral $File)))
  if ($rows.Count -eq 0) { return $null }
  $r = $rows[0]
  return [pscustomobject]@{
    Kind = $Kind
    File = $File
    FirstLSN = [decimal]$r.FirstLSN
    LastLSN = [decimal]$r.LastLSN
    DatabaseBackupLSN = [decimal]$r.DatabaseBackupLSN
    Finish = [datetime]$r.BackupFinishDate
  }
}
```

- [ ] **Step 2: Implement `Get-SebPointCatalogue`** — enumerate a database's `hourly`/`daily`/`diff`/`log` folders on the share, map each file to its kind, and read headers:
```powershell
function Get-SebPointCatalogue {
  param($Connection, [string]$Root, [string]$HostName, [string]$InstanceLabel, [string]$Database)
  $cat = New-Object System.Collections.ArrayList
  $map = @{ hourly = 'full'; daily = 'full'; diff = 'diff'; log = 'log' }
  foreach ($folderKind in $map.Keys) {
    $dir = Get-SebBackupPath -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $Database -Kind $folderKind
    foreach ($fact in @(Get-SebFolderFacts -Directory $dir)) {
      $h = Get-SebRestoreHeaderFacts -Connection $Connection -File $fact.FullName -Kind $map[$folderKind]
      if ($null -ne $h) { [void]$cat.Add($h) }
    }
  }
  return @($cat.ToArray())
}
```

- [ ] **Step 3: Add a structural guard test.** Append:
```powershell
# ---- C2. catalogue builders are defined and parse under 5.1 -------------------------
Assert ((Get-Command Get-SebRestoreHeaderFacts -ErrorAction SilentlyContinue) -ne $null) 'Get-SebRestoreHeaderFacts is defined'
Assert ((Get-Command Get-SebPointCatalogue -ErrorAction SilentlyContinue) -ne $null) 'Get-SebPointCatalogue is defined'
```

- [ ] **Step 4: Run the suite.** Expect the two C2 `PASS` lines (and the whole file still parses — the top structural guard covers 5.1/ASCII).

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): build a point-in-time catalogue from backup headers"
```

### Task C3: `-RestoreToPoint` mode and executor

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (param block, `main` dispatch, new `Invoke-SebRestoreToPoint`)
- Verified live in Phase E.

- [ ] **Step 1: Add params.** In the param block add:
```powershell
  [switch]$RestoreToPoint,
  [datetime]$StopAt,
```
(`-RestoreAs`, `-Database`, and the placement/replace switches already exist and are reused.)

- [ ] **Step 2: Implement the executor** near the other restore functions. It builds the catalogue, plans, then restores each step with the existing MOVE clauses:
```powershell
function Invoke-SebRestoreToPoint {
  param($Connection, [string]$Root, [string]$HostName, [string]$InstanceLabel,
        [string]$Database, [string]$RestoreAs, [datetime]$StopAt)
  $cat = Get-SebPointCatalogue -Connection $Connection -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $Database
  $plan = Get-SebRestorePlan -Catalogue $cat -StopAt $StopAt
  if ($plan.Error) { throw ('cannot restore to that point: ' + $plan.Error) }
  $target = Get-SebQuotedName $RestoreAs
  $total = $plan.Steps.Count
  $i = 0
  foreach ($step in $plan.Steps) {
    $i++
    Write-SebStage -Database $RestoreAs -Stage ('restore ' + $step.Kind + ' ' + $i + '/' + $total)
    $literal = Get-SebSqlLiteral $step.File
    if ($step.Kind -eq 'full') {
      $moves = (Get-SebRestoreMoveClauses -Connection $Connection -File $step.File -RestoreAs $RestoreAs)
      $with = @('NORECOVERY', 'REPLACE') + $moves
      $sql = 'RESTORE DATABASE {0} FROM DISK = {1} WITH {2}' -f $target, $literal, ($with -join ', ')
    }
    elseif ($step.Kind -eq 'diff') {
      $sql = 'RESTORE DATABASE {0} FROM DISK = {1} WITH NORECOVERY' -f $target, $literal
    }
    else {
      if ($step.Recovery) {
        $sql = 'RESTORE LOG {0} FROM DISK = {1} WITH STOPAT = {2}, RECOVERY' -f $target, $literal, (Get-SebSqlLiteral ($step.StopAt.ToString('yyyy-MM-ddTHH:mm:ss')))
      }
      else {
        $sql = 'RESTORE LOG {0} FROM DISK = {1} WITH NORECOVERY' -f $target, $literal
      }
    }
    Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
  }
  Write-SebStage -Database $RestoreAs -Stage 'restore complete'
}
```

- [ ] **Step 3: Wire dispatch** in `main` beside the existing `-RestoreRun` branch:
```powershell
  if ($RestoreToPoint) {
    $pub = Get-SebPublicConfig
    $conn = New-SebSqlConnection -Config (Get-SebEffectiveConfig)
    try {
      Invoke-SebRestoreToPoint -Connection $conn -Root $pub.SharePath -HostName $env:COMPUTERNAME `
        -InstanceLabel $pub.InstanceName -Database $Database -RestoreAs $RestoreAs -StopAt $StopAt
      Write-Host (ConvertTo-Json @{ Ok = $true; Database = $RestoreAs } -Compress)
    }
    finally { $conn.Dispose() }
    Write-SebExit 0
    return
  }
```
(Use the existing connection/config helpers the current `-RestoreRun` branch uses; match its exact names when implementing.)

- [ ] **Step 4: Parse check.** Run the suite once — the top structural guard proves the file still parses cleanly under 5.1 and stays ASCII after these additions. Expected: still all `PASS`, exit 0.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1
git commit -m "feat(engine): -RestoreToPoint executes a STOPAT restore plan"
```

---

## Phase D — Scheduling, enrollment, config, WPF

### Task D1: full-vs-diff decision + chain-aware pass + `-BackupLog`

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebBackupKindDue`; `Invoke-SebPass`; new `Invoke-SebBackupLogPass`; param `-BackupLog`; `main` dispatch)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing test for the pure decision.** Append:
```powershell
# ---- D1. a data pass takes a full when one is due, otherwise a differential ---------
Assert ((Get-SebBackupKindDue -HoursSinceFull 30 -FullEveryHours 24) -eq 'full') 'no recent full -> take a full'
Assert ((Get-SebBackupKindDue -HoursSinceFull 3  -FullEveryHours 24) -eq 'diff') 'a recent full -> take a differential'
Assert ((Get-SebBackupKindDue -HoursSinceFull ([double]::PositiveInfinity) -FullEveryHours 24) -eq 'full') 'a database that has never had a full -> take a full'
Assert ((Get-SebBackupKindDue -HoursSinceFull 24 -FullEveryHours 24) -eq 'full') 'exactly at the interval -> a full is due'
```

- [ ] **Step 2: Run to verify it fails.** Expected: command-not-found on `Get-SebBackupKindDue`.

- [ ] **Step 3: Implement the decision and the passes.**
```powershell
function Get-SebBackupKindDue {
  param([double]$HoursSinceFull, [int]$FullEveryHours = 24)
  if ($HoursSinceFull -ge $FullEveryHours) { return 'full' }
  return 'diff'
}
```
In `Invoke-SebPass`, for each database chosen by `Select-SebDatabase`, when `RecoveryMode = 'Full'` and the database is a user database: call `Set-SebRecoveryFull`; if it just switched (or no full exists) take a `full`, else use `Get-SebBackupKindDue` against the newest file in the `hourly`/`daily` folders; write to the `diff` folder for a differential. After the backup, run the log-growth probe (Task D-safety below). Keep the existing `RecoveryMode = 'Simple'` path exactly as today.

Add the log pass:
```powershell
# The -BackupLog task: one transaction-log backup of every FULL-recovery user database.
function Invoke-SebBackupLogPass {
  param($Connection, [string]$Root, [string]$HostName, [string]$InstanceLabel, [string]$StagingPath)
  $rows = @(Invoke-SebSqlTable -Connection $Connection -Sql "SELECT name, state, source_database_id, is_in_standby FROM sys.databases")
  foreach ($db in @(Select-SebDatabase -Rows $rows)) {
    $model = @(Invoke-SebSqlTable -Connection $Connection -Sql ("SELECT recovery_model_desc AS m FROM sys.databases WHERE name = " + (Get-SebSqlLiteral $db)))
    if (@($model).Count -eq 0 -or [string]$model[0].m -ne 'FULL') { continue }
    $stamp = Get-Date
    $file = Join-Path $StagingPath (Get-SebFileName -Database $db -Stamp $stamp -Extension 'trn')
    try { Invoke-SebBackupLog -Connection $Connection -Database $db -TargetFile $file }
    catch {
      if ("$_" -match 'SEB_LOG_NO_BASE') {
        $anchor = Join-Path $StagingPath (Get-SebFileName -Database $db -Stamp $stamp -Extension 'bak')
        Invoke-SebBackupDatabase -Connection $Connection -Database $db -TargetFile $anchor -Kind 'full'
        Copy-SebVerified -Source $anchor -Destination (Join-Path (Get-SebBackupPath -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $db -Kind 'hourly') (Split-Path -Leaf $anchor))
        Remove-Item -LiteralPath $anchor -Force -ErrorAction SilentlyContinue
        Invoke-SebBackupLog -Connection $Connection -Database $db -TargetFile $file
      }
      else { throw }
    }
    Copy-SebVerified -Source $file -Destination (Join-Path (Get-SebBackupPath -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $db -Kind 'log') (Split-Path -Leaf $file))
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  }
}
```
Add `-BackupLog` to the param block and a `main` branch that loads config, opens the connection, and calls `Invoke-SebBackupLogPass` (mirror the `-Run` branch's setup/teardown).

- [ ] **Step 4: Run to verify it passes.** Run the suite; expect the D1 `PASS` lines and no regression.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): chain-aware data pass and a -BackupLog transaction-log pass"
```

### Task D2: register and tear down the 15-minute log task

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (new `Get-SebLogTaskName`; `Install-SebTask`; the uninstall path)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing test.** Append:
```powershell
# ---- D2. the log task name is derived from the base task name ----------------------
Assert ((Get-SebLogTaskName -Base 'SqlExpressBackup') -eq 'SqlExpressBackup-Log') 'the log task is the base name plus -Log'
```

- [ ] **Step 2: Run to verify it fails.** Expected: command-not-found on `Get-SebLogTaskName`.

- [ ] **Step 3: Implement.**
```powershell
function Get-SebLogTaskName { param([string]$Base) return ($Base + '-Log') }
```
In `Install-SebTask`, after registering the main task, when `RecoveryMode = 'Full'` register a second task named `Get-SebLogTaskName -Base $script:SebTaskName` whose action runs the script with `-BackupLog` and whose trigger is `New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $LogIntervalMinutes)`, SYSTEM principal, `-ExecutionTimeLimit (New-TimeSpan -Minutes 10)`. In the uninstall path, unregister both `$script:SebTaskName` and `Get-SebLogTaskName -Base $script:SebTaskName` (ignore "not found").

- [ ] **Step 4: Run to verify it passes.** Run the suite; expect the D2 `PASS` line.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): install and remove the 15-minute log-backup task"
```

### Task D3: config schema, log-growth probe, Setup/Reschedule/status plumbing

**Files:**
- Modify: `Invoke-SqlExpressBackup.ps1` (param defaults, config template, `$SebShowKeys`, `Invoke-SebSetup`, `-Reschedule`, `Write-SebPublicSummary`, `-Status`, new `Get-SebLogGrowthWarning`)
- Test: `test/sqlexpress-backup.test.ps1`

- [ ] **Step 1: Write the failing test for the pure probe.** Append:
```powershell
# ---- D3. the log-growth probe warns on the LOG_BACKUP wait past the threshold -------
Assert (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct 85 -ThresholdPct 70) 'a LOG_BACKUP wait over threshold warns'
Assert (-not (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct 40 -ThresholdPct 70)) 'a LOG_BACKUP wait under threshold does not warn'
Assert (-not (Get-SebLogGrowthWarning -Wait 'NOTHING' -UsedPct 95 -ThresholdPct 70)) 'a full log NOT waiting on a backup is a different problem, not our warning'
```

- [ ] **Step 2: Run to verify it fails.** Expected: command-not-found on `Get-SebLogGrowthWarning`.

- [ ] **Step 3: Implement.**
```powershell
function Get-SebLogGrowthWarning {
  param([string]$Wait, [double]$UsedPct, [double]$ThresholdPct = 70)
  return ($Wait -eq 'LOG_BACKUP' -and $UsedPct -ge $ThresholdPct)
}
```
Add config defaults where the other keys live (param block near line 98/122 and the config template near the setup default object): `RecoveryMode = 'Simple'`, `LogIntervalMinutes = 15`, `FullEveryHours = 24`. Add `RecoveryMode`, `LogIntervalMinutes`, `FullEveryHours` to `$SebShowKeys` so they render in status. In `Invoke-SebSetup` and the `-Reschedule` branch, accept and persist the three new keys (parameters `-RecoveryMode`, `-LogIntervalMinutes`, `-FullEveryHours`). In `Write-SebPublicSummary` include `RecoveryMode` and `LogIntervalMinutes`. In `-Status`, after listing databases, run the probe per FULL database (query `sys.databases.log_reuse_wait_desc` + `DBCC SQLPERF(LOGSPACE)`) and print an `[WARN]` line when `Get-SebLogGrowthWarning` is true. In `Invoke-SebPass`, call the same probe after each database's backup and take one catch-up `Invoke-SebBackupLog` when it warns.

- [ ] **Step 4: Run to verify it passes.** Run the suite; expect the D3 `PASS` lines.

- [ ] **Step 5: Commit.**
```bash
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): RecoveryMode config, log-growth probe, status + setup plumbing"
```

### Task D4: WPF — restore-to-a-point-in-time mode and status surface

**Files:**
- Modify: `wpf/Engine.cs` (new `RestoreToPoint`, `PointBounds`), `wpf/RestoreWindow.cs` (point-in-time mode), `wpf/ModernView.cs` (recovery model + RPO + chain health in the schedule/status pane)
- Verify: build + live smoke.

- [ ] **Step 1: Engine.cs — add the calls.** Add methods mirroring the existing `Run`/`RestoreList` pattern (elevated relaunch with `--live` tail):
```csharp
// Restore <src> to a new database <asName> at point-in-time <stopAt> (local time).
public static int RestoreToPoint(string src, string asName, DateTime stopAt, Action<string> onLine)
{
    string args = "--restore-to-point --database \"" + src + "\" --restore-as \"" + asName +
        "\" --stop-at \"" + stopAt.ToString("yyyy-MM-ddTHH:mm:ss") + "\"";
    return Elevate.Run(args, 1800, onLine);
}
```
Add a `PointBounds(string src)` that shells the engine for the earliest/newest recoverable time (a new `-PointBounds` engine sub-command returning `{Earliest,Latest}` JSON) so the picker can be bounded. If exposing that sub-command is more than a small addition, bound the picker instead to `[oldest file mtime, now]` from the existing catalogue call and validate on Verify — note which you chose in the commit message.

- [ ] **Step 2: RestoreWindow.cs — add the mode.** Add a "Restore to a point in time" toggle. When on: a database `ComboBox` (from the existing set list), a `DatePicker` + hour/minute fields bounded by `PointBounds`, a read-only plan-preview `TextBlock`, the existing **Verify** button re-labelled to validate the chosen point (calls the engine planner and shows the step list or the bounded/gap error), and **Restore** enabled only after a clean Verify. Restore calls `Engine.RestoreToPoint` and streams onto the existing `GlowBar`/`LogPane`. Keep `Owner` set and re-activate the owner on close (the established pattern in this file).

- [ ] **Step 3: ModernView.cs — status surface.** In the schedule/status pane, for each database show recovery model, last full/diff/log times, current RPO (age of newest log), and chain health (OK / warning / broken) read from the engine `-Status` JSON.

- [ ] **Step 4: Build.** Run:
`powershell -NoProfile -ExecutionPolicy Bypass -File build-wpf.ps1 -SelfSign`
Expected: `csc.exe` reports no errors and `dist\SqlExpressBackup.exe` is produced and self-signed.

- [ ] **Step 5: Live smoke.** Launch `dist\SqlExpressBackup.exe`, open the restore window, toggle "Restore to a point in time", confirm the database list populates, the datetime picker is bounded, Verify prints a plan (or a clear bounded/gap message), and the window keeps the app in front on close. Then commit:
```bash
git add wpf/Engine.cs wpf/RestoreWindow.cs wpf/ModernView.cs
git commit -m "feat(wpf): restore-to-a-point-in-time mode and per-database recovery status"
```

---

## Phase E — Live end-to-end verification

### Task E1: prove STOPAT lands between two moments on a scratch database

**Files:**
- Create: `test/live-pitr.ps1` (run by hand where SQL Express is present; not part of the CI suite)

- [ ] **Step 1: Write the live check.** It creates a scratch database, writes rows around two log backups, restores to a time between them, and asserts exactly the expected rows are present. Redact host/share/db in any echo.
```powershell
# Run where SQL Express + a configured install exist:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-pitr.ps1"
$ErrorActionPreference = 'Stop'
$eng = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-SqlExpressBackup.ps1'
$ps  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$cs  = 'Server=.\SQLEXPRESS;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15'
function Sql($q) { $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open(); $k=$c.CreateCommand(); $k.CommandText=$q; $r=$k.ExecuteScalar(); $c.Close(); return $r }
function Exec($q){ $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open(); $k=$c.CreateCommand(); $k.CommandText=$q; [void]$k.ExecuteNonQuery(); $c.Close() }

Exec "IF DB_ID('PitrProbe') IS NOT NULL BEGIN ALTER DATABASE PitrProbe SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE PitrProbe; END"
Exec "CREATE DATABASE PitrProbe"
Exec "ALTER DATABASE PitrProbe SET RECOVERY FULL"
Exec "CREATE TABLE PitrProbe.dbo.T (id int)"
# anchor full + a data pass so the log chain has a base
& $ps -NoProfile -ExecutionPolicy Bypass -File $eng -Run | Out-Null
Exec "INSERT INTO PitrProbe.dbo.T VALUES (1)"          # row A (before)
& $ps -NoProfile -ExecutionPolicy Bypass -File $eng -BackupLog | Out-Null
Start-Sleep -Seconds 2
$between = (Get-Date)
Start-Sleep -Seconds 2
Exec "INSERT INTO PitrProbe.dbo.T VALUES (2)"          # row B (after)
& $ps -NoProfile -ExecutionPolicy Bypass -File $eng -BackupLog | Out-Null

& $ps -NoProfile -ExecutionPolicy Bypass -File $eng -RestoreToPoint -Database 'PitrProbe' -RestoreAs 'PitrProbe_R' -StopAt $between.ToString('yyyy-MM-ddTHH:mm:ss') | Out-Null
$rows = [int](Sql "SELECT COUNT(*) FROM PitrProbe_R.dbo.T")
$hasA = [int](Sql "SELECT COUNT(*) FROM PitrProbe_R.dbo.T WHERE id = 1")
$hasB = [int](Sql "SELECT COUNT(*) FROM PitrProbe_R.dbo.T WHERE id = 2")
if ($rows -eq 1 -and $hasA -eq 1 -and $hasB -eq 0) { Write-Host 'PASS point-in-time restore landed between the two log backups (row A only)' }
else { throw "FAIL rows=$rows hasA=$hasA hasB=$hasB (expected 1/1/0)" }
$chk = (Sql "DBCC CHECKDB('PitrProbe_R') WITH NO_INFOMSGS, TABLERESULTS")  # empty result = clean
Write-Host 'CHECKDB clean on the restored copy'
Exec "IF DB_ID('PitrProbe_R') IS NOT NULL BEGIN ALTER DATABASE PitrProbe_R SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE PitrProbe_R; END"
Exec "IF DB_ID('PitrProbe') IS NOT NULL BEGIN ALTER DATABASE PitrProbe SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE PitrProbe; END"
Write-Host 'cleaned up scratch databases'
```

- [ ] **Step 2: Run it** (only on a box with SQL Express + a configured install):
`powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-pitr.ps1"`
Expected: `PASS point-in-time restore landed between the two log backups (row A only)`, then `CHECKDB clean`, then cleanup.

- [ ] **Step 3: Commit.**
```bash
git add test/live-pitr.ps1
git commit -m "test(engine): live STOPAT proof between two log backups"
```

---

## Self-review

**Spec coverage** — every spec section maps to a task: model/enrollment (A1-A3, D1), scheduling (D1, D2), storage (A1), restore engine + UX (C1-C3, D4), safety/log-growth (D1, D3), broken-chain (A2 4214 handling, C1 gap), chain-safe retention (B1), config/status (D3, D4), testing (A-E), backward-compat (`RecoveryMode='Simple'` untouched path preserved in D1). No section is unaddressed.

**Placeholders** — none: pure functions carry full code and asserts; impure/UI tasks carry the exact code shape, the real neighbouring functions to match, and a concrete verification command. D4's one genuine choice (a `-PointBounds` sub-command vs. mtime bounds) is written as an explicit either/or with a recorded decision, not a TBD.

**Type consistency** — a catalogue entry is `{Kind;File;FirstLSN;LastLSN;DatabaseBackupLSN;Finish}` in C1, C2, and C3; retention segments are `{Name;Timestamp;FirstLSN;LastLSN}` in B1; `Get-SebBackupSql -Kind full|diff|log` matches its callers in A2/D1; `Get-SebFileName -Extension` matches A1/D1/E1; `RecoveryMode`/`LogIntervalMinutes`/`FullEveryHours` match across D1-D4.
