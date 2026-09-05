# Live point-in-time recovery proof. Run where SQL Express is present:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-pitr.ps1"
#
# Drives the engine's REAL backup + restore functions (not a re-implementation) against
# a live instance, proving a STOPAT restore lands between two log backups:
#   full -> log1 -> insert A -> [t] -> insert B -> log2 -> restore WITH STOPAT = t
# must yield a copy with A but NOT B, and pass DBCC CHECKDB.
#
# Self-contained: no config.json, no elevation, no network share, no scheduled task.
# It dot-sources the engine and calls the functions with explicit paths, using the
# instance's own backup/data directories (which the SQL service account can already
# write) so BACKUP/RESTORE need no ACL grant. Everything it creates is dropped at the end.
#
# Scratch names only (PitrProbe / PitrProbe_R); no host/share/database of record is touched.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$instance = '.\SQLEXPRESS'
$src = 'PitrProbe'
$dst = 'PitrProbe_R'
$pass = $true
function Say($m) { Write-Host $m }
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS $msg" } else { Write-Host "  FAIL $msg"; $script:pass = $false } }

# --- dot-source the engine (defines the functions without running main) --------------
. $engine -DotSourceOnly
$script:SebCompression = 'off'   # Express has no backup compression

# --- open a live connection (Windows auth) ------------------------------------------
$cs = "Server=$instance;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
function Exec($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; [void]$k.ExecuteNonQuery() }
function Scalar($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; return $k.ExecuteScalar() }

# Restore target dir: the instance's own data path (the service account owns it, so
# RESTORE can write the restored copy's files there).
$dataDir = [string](Scalar "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000))")
$hostName = $env:COMPUTERNAME
$instLabel = 'SQLEXPRESS'

# Backup root: a temp folder THIS user owns (so we can create the layout and read it back),
# with the SQL service account granted Modify (so BACKUP, which runs as that account, can
# write into it). Inheritance (OI)(CI) covers the per-kind subfolders created later.
$shareRoot = Join-Path $env:TEMP ('SebE1_' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $shareRoot -Force)
$svc = [string](Scalar "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'")
if ([string]::IsNullOrWhiteSpace($svc)) { $svc = 'NT SERVICE\MSSQL$SQLEXPRESS' }
icacls $shareRoot /grant ("{0}:(OI)(CI)M" -f $svc) /T 2>&1 | Out-Null
Say ("backup root ready under TEMP; granted write to the SQL service account")

try {
  # --- clean slate ------------------------------------------------------------------
  foreach ($db in @($dst, $src)) {
    if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$db'") -gt 0) {
      Exec "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
      Exec "DROP DATABASE [$db]"
    }
  }

  # --- create the probe database in FULL recovery -----------------------------------
  Exec "CREATE DATABASE [$src]"
  Exec "ALTER DATABASE [$src] SET RECOVERY FULL"
  Exec "CREATE TABLE [$src].dbo.T (id int NOT NULL)"
  Say 'created PitrProbe (FULL recovery) with table T'

  # helper: back up straight into the instance-owned share layout (service account writes)
  function Backup-Full {
    $dir = Get-SebBackupPath -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel -Database $src -Kind 'hourly'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $f = Join-Path $dir (Get-SebFileName -Database $src -Stamp (Get-Date))
    Invoke-SebBackupDatabase -Connection $conn -Database $src -TargetFile $f -Kind 'full'
    return $f
  }
  function Backup-Log {
    $dir = Get-SebBackupPath -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel -Database $src -Kind 'log'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $f = Join-Path $dir (Get-SebFileName -Database $src -Stamp (Get-Date) -Extension 'trn')
    Invoke-SebBackupLog -Connection $conn -Database $src -TargetFile $f
    return $f
  }

  # --- full base + a first log ------------------------------------------------------
  [void](Backup-Full); Say 'took the anchoring full'
  [void](Backup-Log);  Say 'took log 1 (chain established)'

  # --- row A, commit, mark the target time, then row B ------------------------------
  Exec "INSERT INTO [$src].dbo.T (id) VALUES (1)"      # row A
  Say 'inserted row A (id=1) and committed'
  Start-Sleep -Seconds 3
  $stopAt = Get-Date
  Say ("target restore point captured: {0:yyyy-MM-dd HH:mm:ss}" -f $stopAt)
  Start-Sleep -Seconds 3
  Exec "INSERT INTO [$src].dbo.T (id) VALUES (2)"      # row B (after the target)
  Say 'inserted row B (id=2) and committed'
  [void](Backup-Log); Say 'took log 2 (spans A and B)'

  # --- restore to the captured point ------------------------------------------------
  Say ("restoring {0} -> {1} WITH STOPAT the captured point..." -f $src, $dst)
  Invoke-SebRestoreToPoint -Connection $conn -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel `
    -Database $src -RestoreAs $dst -StopAt $stopAt -DataDir $dataDir -LogDir $dataDir -Replace $true -CloseConnections $true

  # --- verify: A present, B absent, and the copy is consistent ----------------------
  $state = [string](Scalar "SELECT state_desc FROM sys.databases WHERE name = '$dst'")
  Check ($state -eq 'ONLINE') "the restored copy is ONLINE (state=$state)"
  $total = [int](Scalar "SELECT COUNT(*) FROM [$dst].dbo.T")
  $hasA = [int](Scalar "SELECT COUNT(*) FROM [$dst].dbo.T WHERE id = 1")
  $hasB = [int](Scalar "SELECT COUNT(*) FROM [$dst].dbo.T WHERE id = 2")
  Check ($hasA -eq 1) 'row A (committed before the target) IS in the restored copy'
  Check ($hasB -eq 0) 'row B (committed after the target) is NOT in the restored copy'
  Check ($total -eq 1) "the restored copy has exactly one row (got $total)"

  # DBCC CHECKDB WITH NO_INFOMSGS stays silent on a clean database and raises on corruption.
  $clean = $true
  try { Exec "DBCC CHECKDB ([$dst]) WITH NO_INFOMSGS" }
  catch { $clean = $false; Write-Host ("  CHECKDB reported: " + $_.Exception.Message) }
  Check $clean 'DBCC CHECKDB on the restored copy is clean'
}
finally {
  # --- teardown: drop both databases and remove the temp backup tree ----------------
  foreach ($db in @($dst, $src)) {
    try {
      if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$db'") -gt 0) {
        Exec "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
        Exec "DROP DATABASE [$db]"
      }
    }
    catch { Write-Host ("  cleanup: could not drop {0}: {1}" -f $db, $_.Exception.Message) }
  }
  try { $conn.Close() } catch { }
  try { if ($shareRoot -and (Test-Path -LiteralPath $shareRoot)) { Remove-Item -LiteralPath $shareRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
  Say 'cleaned up scratch databases and temp backups'
}

if ($pass) { Write-Host 'LIVE PITR PROOF: ALL PASS'; exit 0 } else { Write-Host 'LIVE PITR PROOF: FAILED'; exit 1 }
