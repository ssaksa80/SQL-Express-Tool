# Live restore-testing proof. Run where SQL Express is present:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-restore-test.ps1"
#
# Drives the engine's REAL passes and restore test against a live instance:
#   A. Simple mode - a full backup restores to the scratch database, DBCC CHECKDB is clean,
#      and the scratch database and its files are gone afterwards (as is a leftover from an
#      "interrupted" earlier test, planted first).
#   B. Full mode - full + two log backups; the latest-recoverable plan restores all three,
#      and the row written just before the last log backup is in the restored copy - the
#      whole chain is proven, not just the full.
#   C. Broken chain - the middle log is deleted from the share; the test FAILS and says why.
#   D. Rotation - the next pick is the database not yet tested.
#
# Self-contained: temp config/state, temp staging and share, scratch databases (RtProbeS,
# RtProbeF). Nothing of record is touched; everything is removed at the end.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$sqlInstance = '.\SQLEXPRESS'
$dbS = 'RtProbeS'
$dbF = 'RtProbeF'
$pass = $true
function Say($m) { Write-Host $m }
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS $msg" } else { Write-Host "  FAIL $msg"; $script:pass = $false } }

. $engine -DotSourceOnly
$script:SebCompression = 'off'

$cs = "Server=$sqlInstance;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
function Exec($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; $k.CommandTimeout = 0; [void]$k.ExecuteNonQuery() }
function Scalar($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; return $k.ExecuteScalar() }
function DropDb($n) { if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$n'") -gt 0) { try { Exec "ALTER DATABASE [$n] SET SINGLE_USER WITH ROLLBACK IMMEDIATE" } catch { }; Exec "DROP DATABASE [$n]" } }

$workRoot = Join-Path $env:TEMP ('SebRtLive_' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $workRoot 'staging'
$share = Join-Path $workRoot 'share'
$cfgDir = Join-Path $workRoot 'cfg'
[void](New-Item -ItemType Directory -Path $staging, $share, $cfgDir -Force)
$svc = [string](Scalar "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'")
if ([string]::IsNullOrWhiteSpace($svc)) { $svc = 'NT SERVICE\MSSQL$SQLEXPRESS' }
icacls $workRoot /grant ("{0}:(OI)(CI)M" -f $svc) /T 2>&1 | Out-Null

$savedCfgDir = $script:SebConfigDir
$script:SebConfigDir = $cfgDir
function New-Cfg($db, $mode) {
  [pscustomobject]@{
    DataSource = $sqlInstance; InstanceName = 'SQLEXPRESS'; SharePath = $share; StagingPath = $staging
    IntervalHours = 6; HourlyKeep = 3; DailyKeepDays = 7; RecoveryMode = $mode; FullEveryHours = 24
    UseWindowsAuth = $true; NoHashVerify = $true; SqlServiceAccount = $svc; OnlyDatabase = $db
    CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
  }
}
$leftover = 'SebRestoreTest_leftover'

try {
  foreach ($n in @($dbS, $dbF, $leftover, (Get-SebRestoreTestName $dbS), (Get-SebRestoreTestName $dbF), 'RtVerify')) { DropDb $n }

  # --- A. Simple mode --------------------------------------------------------------
  Say '--- A. Simple mode: a full backup ---'
  Exec "CREATE DATABASE [$dbS]"
  Exec "CREATE TABLE [$dbS].dbo.T (id int NOT NULL)"; Exec "INSERT INTO [$dbS].dbo.T VALUES (1),(2),(3)"
  Exec "CREATE DATABASE [$leftover]"   # as if an earlier test had been killed mid-way
  $cfgS = New-Cfg $dbS 'Simple'
  [void](Invoke-SebPass -Config $cfgS)
  $rA = Invoke-SebRestoreTest -Connection $conn -Config $cfgS -Database $dbS
  Check ($rA.Result -eq 'ok') "A: the restore test passes ($($rA.Result): $($rA.Message))"
  Check ($rA.Steps -eq 1) "A: one step, the full ($($rA.Steps))"
  Check ([int](Scalar ("SELECT COUNT(*) FROM sys.databases WHERE name LIKE 'SebRestoreTest[_]%'")) -eq 0) 'A: no scratch database is left behind - the planted leftover included'
  Check (-not (Test-Path -LiteralPath (Join-Path $staging 'restore-test'))) 'A: its files are gone from staging'
  Save-SebRestoreTestResult -Config $cfgS -Result $rA
  $pub = Get-Content -LiteralPath (Join-Path $cfgDir 'public.json') -Raw | ConvertFrom-Json
  Check (@($pub.RestoreTests | Where-Object { $_.Database -eq $dbS -and $_.Result -eq 'ok' }).Count -eq 1) 'A: the result is published for the dashboard'

  # --- B. Full mode: full + two logs --------------------------------------------------
  Say '--- B. Full mode: full + two log backups ---'
  Exec "CREATE DATABASE [$dbF]"
  Exec "CREATE TABLE [$dbF].dbo.T (id int NOT NULL)"; Exec "INSERT INTO [$dbF].dbo.T VALUES (1)"
  $cfgF = New-Cfg $dbF 'Full'
  [void](Invoke-SebPass -Config $cfgF)                     # enrolls FULL, takes the anchoring full
  Exec "INSERT INTO [$dbF].dbo.T VALUES (2)"
  Start-Sleep -Seconds 1
  [void](Invoke-SebBackupLogPass -Connection $conn -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -StagingPath $staging -OnlyDatabase $dbF -NoHash)
  Exec "INSERT INTO [$dbF].dbo.T VALUES (3)"                # written just before the LAST log backup
  Start-Sleep -Seconds 1
  [void](Invoke-SebBackupLogPass -Connection $conn -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -StagingPath $staging -OnlyDatabase $dbF -NoHash)
  $rB = Invoke-SebRestoreTest -Connection $conn -Config $cfgF -Database $dbF
  Check ($rB.Result -eq 'ok') "B: the restore test passes ($($rB.Result): $($rB.Message))"
  Check ($rB.Steps -eq 3) "B: full + both logs were restored ($($rB.Steps) steps)"
  # Prove the plan really reaches the newest point: run the same plan into a copy we keep.
  $cat = @(Get-SebPointCatalogue -Connection $conn -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -Database $dbF)
  $plan = Get-SebLatestRestorePlan -Catalogue $cat
  $vDir = Join-Path $staging 'verify'; [void](New-Item -ItemType Directory -Path $vDir -Force)
  [void](Invoke-SebRestoreSteps -Connection $conn -Steps $plan.Steps -RestoreAs 'RtVerify' -DataDir $vDir -LogDir $vDir)
  Check ([int](Scalar 'SELECT COUNT(*) FROM [RtVerify].dbo.T') -eq 3) 'B: the restored copy has the row written just before the last log backup'
  DropDb 'RtVerify'

  # --- C. Broken chain ----------------------------------------------------------------
  Say '--- C. the middle log is lost ---'
  $logDir = Get-SebBackupPath -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -Database $dbF -Kind 'log'
  $logs = @(Get-ChildItem -LiteralPath $logDir -File | Sort-Object Name)
  Check ($logs.Count -ge 2) "C: the share holds the log chain ($($logs.Count) logs)"
  Remove-Item -LiteralPath $logs[0].FullName -Force
  $rC = Invoke-SebRestoreTest -Connection $conn -Config $cfgF -Database $dbF
  Check ($rC.Result -eq 'failed') "C: the restore test FAILS ($($rC.Result))"
  Check ($rC.Message -like '*chain is broken*') "C: and says the chain is broken ($($rC.Message))"
  Check ([int](Scalar ("SELECT COUNT(*) FROM sys.databases WHERE name LIKE 'SebRestoreTest[_]%'")) -eq 0) 'C: nothing is left behind after a failure either'
  $cond = @(Get-SebRestoreTestConditions -Result $rC)
  Check ($cond.Count -eq 1 -and $cond[0].Severity -eq 'critical') 'C: a failed test becomes a critical alert'

  # --- D. Rotation --------------------------------------------------------------------
  $st = Read-SebState
  $next = Select-SebRestoreTestDatabase -Databases @(Get-SebRestoreTestCandidates -Config $cfgF) -History $st.RestoreTests
  Check ($next -eq $dbF) "D: with $dbS tested, the next run picks $dbF (got $next)"
}
finally {
  $script:SebConfigDir = $savedCfgDir
  foreach ($n in @($dbS, $dbF, $leftover, (Get-SebRestoreTestName $dbS), (Get-SebRestoreTestName $dbF), 'RtVerify')) {
    try { DropDb $n } catch { Write-Host ("  cleanup: could not drop {0}: {1}" -f $n, $_.Exception.Message) }
  }
  try { $conn.Close() } catch { }
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  Say 'cleaned up scratch databases and temp trees'
}

if ($pass) { Write-Host 'LIVE RESTORE TEST PROOF: ALL PASS'; exit 0 } else { Write-Host 'LIVE RESTORE TEST PROOF: FAILED'; exit 1 }
