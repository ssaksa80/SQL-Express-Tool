# Live COMPRESSED point-in-time recovery proof. Run where SQL Express is present:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-compress.ps1"
#
# Drives the engine's REAL compression + backup + restore functions (not a
# re-implementation) against a live instance, proving the compressed round trip
# end to end:
#   - backups are published as .zip + .meta.json on the share (Get-SebPublishSet)
#   - the point-in-time catalogue reads the .meta.json sidecar WITHOUT decompressing
#   - Invoke-SebRestoreToPoint decompresses the .zip, and its in-engine grant (7b)
#     makes the decompressed file readable by the SQL service account
#   - a STOPAT between two rows lands correctly (row A present, row B absent) and
#     DBCC CHECKDB is clean
#   - pruning a compressed backup (Remove-SebNamed) takes its .meta.json with it
#
# Same shape as test\live-pitr.ps1: self-contained, no config.json, no elevation,
# no network share, no scheduled task. Dot-sources the engine and calls its real
# functions with explicit paths, using a temp folder as the "share" (granted to the
# SQL service account) and the instance's own data path for the restored copy.
# Everything it creates is dropped at the end.
#
# Scratch names only (CompProbe / CompProbe_R); no host/share/database of record
# is touched.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$instance = '.\SQLEXPRESS'
$src = 'CompProbe'
$dst = 'CompProbe_R'
$pass = $true
$testStart = Get-Date
function Say($m) { Write-Host $m }
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS $msg" } else { Write-Host "  FAIL $msg"; $script:pass = $false } }

# --- dot-source the engine (defines the functions without running main) --------------
. $engine -DotSourceOnly
# This is SQL Server's native BACKUP ... WITH COMPRESSION option, which Express does
# not support - a different axis entirely from the app-level .zip under test here
# (Get-SebPublishSet -Compress). Off, exactly as live-pitr, so no wasted fallback dance.
$script:SebCompression = 'off'

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

# Backup root (the share, for this proof): a temp folder THIS user owns, with the
# SQL service account granted Modify (BACKUP runs as that account, and writes here).
# Inheritance (OI)(CI) covers the per-kind subfolders created later.
$shareRoot = Join-Path $env:TEMP ('SebComp_' + [Guid]::NewGuid().ToString('N'))
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
  Say 'created CompProbe (FULL recovery) with table T'

  # helper: verify the plain backup, then compress + sidecar it via the ENGINE's real
  # functions and copy the result to the share - mirrors what Invoke-SebPass and
  # Invoke-SebBackupLogPass do when CompressBackups is on. Does NOT re-implement
  # compression: Get-SebPublishSet is the engine's own function, called for real.
  function Publish-Compressed($stagedPlain, $plainName, $kind, $destKind) {
    # verify the plain backup (SQL can't RESTORE VERIFYONLY a .zip)
    Test-SebBackupFile -Connection $conn -TargetFile $stagedPlain
    $destDir = Get-SebBackupPath -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel -Database $src -Kind $destKind
    [void](New-Item -ItemType Directory -Path $destDir -Force)
    foreach ($art in @(Get-SebPublishSet -Connection $conn -StagedPlain $stagedPlain -PlainName $plainName -Kind $kind -Compress $true)) {
      Copy-SebVerified -Source $art.Src -Destination (Join-Path $destDir $art.Name) -NoHash
      # Get-SebPublishSet builds the .zip/.meta.json next to the plain file in staging;
      # once copied to the share (destDir) the staging copy is redundant. Staging lives
      # under $shareRoot in this test, so leaving these behind would double-count every
      # share inventory check below (each backup would look like two).
      Remove-Item -LiteralPath $art.Src -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $stagedPlain -Force -ErrorAction SilentlyContinue
  }
  function Backup-Full-Z {
    $stampDir = Join-Path $shareRoot 'staging'; [void](New-Item -ItemType Directory -Path $stampDir -Force)
    $name = Get-SebFileName -Database $src -Stamp (Get-Date)
    $staged = Join-Path $stampDir $name
    Invoke-SebBackupDatabase -Connection $conn -Database $src -TargetFile $staged -Kind 'full'
    Publish-Compressed $staged $name 'full' 'hourly'
  }
  function Backup-Log-Z {
    $stampDir = Join-Path $shareRoot 'staging'; [void](New-Item -ItemType Directory -Path $stampDir -Force)
    $name = Get-SebFileName -Database $src -Stamp (Get-Date) -Extension 'trn'
    $staged = Join-Path $stampDir $name
    Invoke-SebBackupLog -Connection $conn -Database $src -TargetFile $staged
    Publish-Compressed $staged $name 'log' 'log'
  }

  # --- compressed full base + a first compressed log ---------------------------------
  Backup-Full-Z; Say 'took the anchoring full (compressed, published as .zip+.meta.json)'
  Backup-Log-Z;  Say 'took log 1 (compressed, chain established)'

  # --- row A, commit, mark the target time, then row B --------------------------------
  Exec "INSERT INTO [$src].dbo.T (id) VALUES (1)"      # row A
  Say 'inserted row A (id=1) and committed'
  Start-Sleep -Seconds 3
  $stopAt = Get-Date
  Say ("target restore point captured: {0:yyyy-MM-dd HH:mm:ss}" -f $stopAt)
  Start-Sleep -Seconds 3
  Exec "INSERT INTO [$src].dbo.T (id) VALUES (2)"      # row B (after the target)
  Say 'inserted row B (id=2) and committed'
  Backup-Log-Z; Say 'took log 2 (compressed, spans A and B)'

  # --- assert the compression actually happened on the share, before restoring -------
  # The same recursive Get-ChildItem over $shareRoot is used for all three checks, so
  # the zero result for plain files below is trustworthy: it is proven (by the .zip and
  # .meta.json counts) to be a traversal that finds real files, not a broken probe.
  $zips = @(Get-ChildItem -LiteralPath $shareRoot -Recurse -File | Where-Object { $_.Name -like '*.zip' })
  $metas = @(Get-ChildItem -LiteralPath $shareRoot -Recurse -File | Where-Object { $_.Name -like '*.meta.json' })
  $plainOnShare = @(Get-ChildItem -LiteralPath $shareRoot -Recurse -File | Where-Object { $_.Name -match '\.(bak|dif|trn)$' })
  Check ($zips.Count -ge 3) "the share holds compressed backups (.zip): $($zips.Count)"
  Check ($metas.Count -ge 3) "each compressed backup has a .meta.json sidecar: $($metas.Count)"
  Check ($plainOnShare.Count -eq 0) "no plain .bak/.dif/.trn files leaked onto the share (found $($plainOnShare.Count))"

  # --- assert the catalogue reads the sidecar, not the .zip itself -------------------
  $cat = @(Get-SebPointCatalogue -Connection $conn -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel -Database $src)
  $fullEntries = @($cat | Where-Object { $_.Kind -eq 'full' })
  Check ($fullEntries.Count -ge 1) "the point-in-time catalogue lists at least one full backup ($($fullEntries.Count))"
  $zipFulls = @($fullEntries | Where-Object { $_.File -like '*.zip' })
  Check ($zipFulls.Count -ge 1) "the cataloged full's File ends .zip (RESTORE HEADERONLY cannot read a .zip, so this came from the sidecar)"
  if ($zipFulls.Count -ge 1) {
    $cf = $zipFulls[0]
    Check ([decimal]$cf.CheckpointLSN -gt 0) ("catalogue populated CheckpointLSN from the sidecar: {0}" -f $cf.CheckpointLSN)
    Check ([decimal]$cf.LastLSN -gt 0) ("catalogue populated LastLSN from the sidecar: {0}" -f $cf.LastLSN)
  }

  # --- restore to the captured point, decompressing via the production path ----------
  # No -WorkDir: decompression defaults to $env:TEMP, so the 7b in-engine grant (not a
  # manual icacls from this test) is what makes the decompressed file SQL-readable.
  Say ("restoring {0} -> {1} WITH STOPAT the captured point (default-temp decompress + 7b grant)..." -f $src, $dst)
  Invoke-SebRestoreToPoint -Connection $conn -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel `
    -Database $src -RestoreAs $dst -StopAt $stopAt -DataDir $dataDir -LogDir $dataDir -Replace $true -CloseConnections $true

  # --- verify: A present, B absent, and the copy is consistent -----------------------
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

  # --- retention pairing (8a), proved live: pruning a compressed backup takes its
  #     .meta.json sidecar with it. Run after the restore checks so this never risks
  #     removing a file the restore above still needed.
  $hourlyDir = Get-SebBackupPath -Root $shareRoot -HostName $hostName -InstanceLabel $instLabel -Database $src -Kind 'hourly'
  $hourlyZip = @(Get-ChildItem -LiteralPath $hourlyDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.zip' } | Select-Object -First 1)
  Check ($hourlyZip.Count -eq 1) "found an hourly .zip to test retention pairing against"
  if ($hourlyZip.Count -eq 1) {
    $leaf = $hourlyZip[0].Name
    $metaLeaf = Get-SebSidecarName $leaf
    Remove-SebNamed -Directory $hourlyDir -Names @($leaf)
    $zipGone = -not (Test-Path -LiteralPath (Join-Path $hourlyDir $leaf))
    $metaGone = -not (Test-Path -LiteralPath (Join-Path $hourlyDir $metaLeaf))
    Check $zipGone ("Remove-SebNamed removed the hourly .zip ({0})" -f $leaf)
    Check $metaGone ("Remove-SebNamed also removed its .meta.json sidecar ({0})" -f $metaLeaf)
  }
}
finally {
  # --- teardown: drop both databases, remove the temp backup tree, and sweep any
  #     seb-restore-* decompression temp this run may have left behind (the engine
  #     cleans its own in a finally too; this is a belt-and-suspenders net only for
  #     dirs created since this run started, so a genuinely unrelated concurrent
  #     process's temp folder is never touched) --------------------------------------
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
  try {
    Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'seb-restore-*' -ErrorAction SilentlyContinue |
      Where-Object { $_.CreationTime -ge $testStart } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { }
  Say 'cleaned up scratch databases and temp backups'
}

if ($pass) { Write-Host 'LIVE COMPRESS PROOF: ALL PASS'; exit 0 } else { Write-Host 'LIVE COMPRESS PROOF: FAILED'; exit 1 }
