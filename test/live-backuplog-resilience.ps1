# Live proof of -BackupLog copy-resilience. Run where SQL Express is present:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-backuplog-resilience.ps1"
#
# Drives the engine's REAL Invoke-SebBackupLogPass against a live instance to prove the
# drain-first Pending mechanism: a transaction-log backup (and its anchoring full) whose
# share copy fails while the share is unreachable is recorded to state.json's Pending and
# kept in staging, then copied to the share on the NEXT run once the share is reachable
# again - so BACKUP LOG truncating the log chain never leaves a permanent PITR gap.
#
# The share going down then back up is simulated on ONE constant SharePath by toggling a
# parent path component between a FILE (every write under it fails) and a DIRECTORY (writes
# succeed). The SharePath string is identical across both runs, so the Pending destinations
# recorded in run 1 stay valid in run 2 (Test-SebPendingEntry checks Dest against SharePath).
#
# Self-contained: no config.json of record, no elevation, no network share, no scheduled
# task. State is redirected to a temp folder; only a scratch database (SebLogResProbe) and
# temp staging/share trees are touched, and all are removed at the end. -OnlyDatabase keeps
# it off every other database on a shared instance.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$sqlInstance = '.\SQLEXPRESS'
$probe = 'SebLogResProbe'
$pass = $true
function Say($m) { Write-Host $m }
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS $msg" } else { Write-Host "  FAIL $msg"; $script:pass = $false } }

# --- dot-source the engine (defines the functions without running main) --------------
. $engine -DotSourceOnly
$script:SebCompression = 'off'   # Express has no backup compression

# --- open a live connection (Windows auth) ------------------------------------------
$cs = "Server=$sqlInstance;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
function Exec($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; [void]$k.ExecuteNonQuery() }
function Scalar($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; return $k.ExecuteScalar() }

$hostName = $env:COMPUTERNAME
$instLabel = 'SQLEXPRESS'

# Work area under TEMP that this user owns.
$workRoot = Join-Path $env:TEMP ('SebD1dLive_' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $workRoot 'staging'
$cfgDir  = Join-Path $workRoot 'cfg'
$gate    = Join-Path $workRoot 'gate'      # toggled FILE <-> DIRECTORY to fake reachability
$sharePath = Join-Path $gate 'share'       # CONSTANT across both runs
[void](New-Item -ItemType Directory -Path $staging -Force)
[void](New-Item -ItemType Directory -Path $cfgDir -Force)

# Two operations run as the SQL service account, not as this user: BACKUP writes the staged
# .bak/.trn, and RESTORE VERIFYONLY (the final check) reads the recovered file back off the
# share. Grant the account across the whole work area (inheritance covers the share tree the
# gate creates later) so both can reach their files. The staging->share COPY runs as THIS
# user and needs no grant.
$svc = [string](Scalar "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'")
if ([string]::IsNullOrWhiteSpace($svc)) { $svc = 'NT SERVICE\MSSQL$SQLEXPRESS' }
icacls $workRoot /grant ("{0}:(OI)(CI)M" -f $svc) /T 2>&1 | Out-Null
Say 'work area ready; granted the SQL service account read/write for BACKUP and VERIFYONLY'

# Redirect engine state (state.json / public summary) into the temp cfg folder so the real
# install's state is never read or written.
$savedCfgDir = $script:SebConfigDir
$script:SebConfigDir = $cfgDir

try {
  # --- scratch database in FULL recovery --------------------------------------------
  if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$probe'") -gt 0) {
    Exec "ALTER DATABASE [$probe] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"; Exec "DROP DATABASE [$probe]"
  }
  Exec "CREATE DATABASE [$probe]"
  Exec "ALTER DATABASE [$probe] SET RECOVERY FULL"
  Exec "CREATE TABLE [$probe].dbo.T (id int NOT NULL)"
  Exec "INSERT INTO [$probe].dbo.T (id) VALUES (1)"
  Say "created $probe (FULL recovery) with one row"

  $logDir = Get-SebBackupPath -Root $sharePath -HostName $hostName -InstanceLabel $instLabel -Database $probe -Kind 'log'
  $hourlyDir = Get-SebBackupPath -Root $sharePath -HostName $hostName -InstanceLabel $instLabel -Database $probe -Kind 'hourly'

  # --- RUN 1: the share is unreachable (gate is a FILE) -----------------------------
  Set-Content -LiteralPath $gate -Value 'unreachable share stand-in' -Encoding ASCII
  Say '--- run 1: share unreachable ---'
  $r1 = Invoke-SebBackupLogPass -Connection $conn -Root $sharePath -HostName $hostName -InstanceLabel $instLabel -StagingPath $staging -OnlyDatabase $probe -NoHash
  Check ($r1.Succeeded -eq 1) "run 1: the log backup was taken (Succeeded=$($r1.Succeeded))"
  Check ($r1.Failed -eq 0) "run 1: no hard database failure (Failed=$($r1.Failed))"
  Check ($r1.Pending -ge 1) "run 1: the share copy is recorded as pending (Pending=$($r1.Pending))"
  $stagedTrn = @(Get-ChildItem -LiteralPath $staging -Filter '*.trn' -File -ErrorAction SilentlyContinue)
  Check ($stagedTrn.Count -ge 1) 'run 1: the truncated .trn is held in staging, not orphaned'
  $st1 = Read-SebState
  Check (@($st1.Pending).Count -ge 1) "run 1: state.json records $(@($st1.Pending).Count) pending copy(s)"
  Check (-not (Test-Path -LiteralPath $logDir)) 'run 1: nothing reached the (unreachable) share'

  # --- RUN 2: the share is back (gate becomes a DIRECTORY, same SharePath) -----------
  Remove-Item -LiteralPath $gate -Force
  [void](New-Item -ItemType Directory -Path $gate -Force)
  Say '--- run 2: share reachable; the drain recovers the pending copies ---'
  $r2 = Invoke-SebBackupLogPass -Connection $conn -Root $sharePath -HostName $hostName -InstanceLabel $instLabel -StagingPath $staging -OnlyDatabase $probe -NoHash
  Check ($r2.Pending -eq 0) "run 2: everything drained, nothing left pending (Pending=$($r2.Pending))"
  $st2 = Read-SebState
  Check (@($st2.Pending).Count -eq 0) 'run 2: state.json Pending is cleared'
  $sharedTrn = @(Get-ChildItem -LiteralPath $logDir -Filter '*.trn' -File -ErrorAction SilentlyContinue)
  Check ($sharedTrn.Count -ge 1) "run 2: the recovered .trn reached the share log/ folder ($($sharedTrn.Count) file(s))"
  $sharedBak = @(Get-ChildItem -LiteralPath $hourlyDir -Filter '*.bak' -File -ErrorAction SilentlyContinue)
  Check ($sharedBak.Count -ge 1) 'run 2: the anchoring full recovered to the share hourly/ folder'

  # decisive: a recovered file on the share is a real, restorable backup - not a truncated
  # or half-written copy. RESTORE VERIFYONLY raises on a bad backup and is silent on a good one.
  $anchor = $sharedBak | Select-Object -First 1
  $ok = $true
  try { Exec ("RESTORE VERIFYONLY FROM DISK = N'" + ($anchor.FullName -replace "'", "''") + "' WITH CHECKSUM") }
  catch { $ok = $false; Write-Host ("  VERIFYONLY reported: " + $_.Exception.Message) }
  Check $ok 'run 2: RESTORE VERIFYONLY on the recovered full passes (the recovered copy is intact)'
}
finally {
  $script:SebConfigDir = $savedCfgDir
  try {
    if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$probe'") -gt 0) {
      Exec "ALTER DATABASE [$probe] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"; Exec "DROP DATABASE [$probe]"
    }
  } catch { Write-Host ("  cleanup: could not drop {0}: {1}" -f $probe, $_.Exception.Message) }
  try { $conn.Close() } catch { }
  try { if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
  Say 'cleaned up scratch database and temp trees'
}

if ($pass) { Write-Host 'LIVE BACKUPLOG RESILIENCE PROOF: ALL PASS'; exit 0 } else { Write-Host 'LIVE BACKUPLOG RESILIENCE PROOF: FAILED'; exit 1 }
