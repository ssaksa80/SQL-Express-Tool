# Live encryption proof. Run where SQL Express is present:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-encrypt.ps1"
#
# Drives the engine's REAL passes, restores and restore test with EncryptBackups on:
#   1. every backup on the share is .enc (+ its sidecar) - no plaintext backup anywhere, and a
#      canary string written into the database appears in a plain backup (positive control)
#      but in none of the encrypted files
#   2. the key escrow is put on the share by the data pass
#   3. point-in-time restore through the encrypted chain lands between two rows
#   4. the restore test passes on the encrypted chain
#   5. a "rebuilt server" (empty keyring) cannot restore, says why, and after importing the
#      key from the share's escrow - with the passphrase, and separately the recovery key -
#      can restore again
#
# The keyring is held in memory for the test: the real one is sealed to SYSTEM/Administrators
# and this runs unelevated. Everything else - backups, encryption, share, escrow, restores,
# CHECKDB - is the real code against a real instance. Scratch database EncProbe; all removed.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$sqlInstance = '.\SQLEXPRESS'
$db = 'EncProbe'
$canary = 'SEB-PLAINTEXT-CANARY-7f3a9c'
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
function FileHas([string]$path, [string]$text) {
  $bytes = [IO.File]::ReadAllBytes($path)
  return ([System.Text.Encoding]::ASCII.GetString($bytes).IndexOf($text, [StringComparison]::Ordinal) -ge 0)
}

$workRoot = Join-Path $env:TEMP ('SebEncLive_' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $workRoot 'staging'; $share = Join-Path $workRoot 'share'; $cfgDir = Join-Path $workRoot 'cfg'
[void](New-Item -ItemType Directory -Path $staging, $share, $cfgDir -Force)
$svc = [string](Scalar "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'")
if ([string]::IsNullOrWhiteSpace($svc)) { $svc = 'NT SERVICE\MSSQL$SQLEXPRESS' }
icacls $workRoot /grant ("{0}:(OI)(CI)M" -f $svc) /T 2>&1 | Out-Null
$savedCfgDir = $script:SebConfigDir
$script:SebConfigDir = $cfgDir

# "-SetupEncryption", minus the sealing: a data key, a recovery key, the escrow.
$passphrase = 'live test passphrase, long enough'
$dek = New-SebRandomBytes 32
$rk = New-SebRandomBytes 32
$escrow = New-SebEscrow -DataKey $dek -Passphrase $passphrase -RecoveryKey $rk -Iterations 20000 -InstanceLabel 'SQLEXPRESS'
$keyId = [string]$escrow.KeyId
Set-Content -LiteralPath (Join-Path $cfgDir (Get-SebEscrowName $keyId)) -Value ($escrow | ConvertTo-Json) -Encoding ASCII
$realRing = ${function:Read-SebKeyring}
$script:LiveRing = @{ $keyId = $dek }
function Read-SebKeyring { return $script:LiveRing }

$config = [pscustomobject]@{
  DataSource = $sqlInstance; InstanceName = 'SQLEXPRESS'; SharePath = $share; StagingPath = $staging
  IntervalHours = 6; HourlyKeep = 3; DailyKeepDays = 7; RecoveryMode = 'Full'; FullEveryHours = 24
  UseWindowsAuth = $true; NoHashVerify = $true; SqlServiceAccount = $svc; OnlyDatabase = $db
  CreatedUtc = (Get-Date).ToUniversalTime().ToString('o'); EncryptBackups = $true; ActiveKeyId = $keyId
}

try {
  foreach ($n in @($db, 'EncProbe_R', (Get-SebRestoreTestName $db))) { DropDb $n }
  Exec "CREATE DATABASE [$db]"
  Exec "CREATE TABLE [$db].dbo.T (id int NOT NULL, note varchar(100) NOT NULL)"
  Exec "INSERT INTO [$db].dbo.T VALUES (0, '$canary')"

  # Positive control: a plain backup of this database DOES carry the canary in clear.
  $control = Join-Path $staging 'control.bak'
  Exec ("BACKUP DATABASE [{0}] TO DISK = N'{1}' WITH COPY_ONLY, INIT" -f $db, $control)
  Check (FileHas $control $canary) 'control: a plain backup carries the canary in clear (so its absence below means something)'
  Remove-Item -LiteralPath $control -Force

  Say '--- backups with encryption on ---'
  [void](Invoke-SebPass -Config $config)                                   # enrolls FULL, anchoring full
  Exec "INSERT INTO [$db].dbo.T VALUES (1, 'row A')"
  Start-Sleep -Seconds 1
  [void](Invoke-SebBackupLogPass -Connection $conn -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -StagingPath $staging -OnlyDatabase $db -NoHash -Encrypt $true -EncryptKey $dek)
  Start-Sleep -Seconds 2
  $target = Get-Date
  Start-Sleep -Seconds 2
  Exec "INSERT INTO [$db].dbo.T VALUES (2, 'row B')"
  [void](Invoke-SebBackupLogPass -Connection $conn -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -StagingPath $staging -OnlyDatabase $db -NoHash -Encrypt $true -EncryptKey $dek)

  $all = @(Get-ChildItem -LiteralPath $share -Recurse -File)
  $backups = @($all | Where-Object { $_.Name -match '\.(bak|trn|dif)' -and $_.Name -notlike '*.meta.json' })
  Check ($backups.Count -ge 3) "1: backups reached the share ($($backups.Count))"
  Check (@($backups | Where-Object { $_.Name -notlike '*.enc' }).Count -eq 0) '1: every backup on the share is encrypted - no plain .bak/.trn'
  Check (@($backups | Where-Object { -not (Test-Path -LiteralPath ($_.FullName + '.meta.json')) }).Count -eq 0) '1: each has its sidecar'
  Check (@($backups | Where-Object { FileHas $_.FullName $canary }).Count -eq 0) '1: the canary appears in none of them'
  Check (@(Get-ChildItem -LiteralPath $staging -Recurse -File | Where-Object { $_.Name -match '\.(bak|trn)$' }).Count -eq 0) '1: no plaintext backup is left in staging either'
  $escrowOnShare = Join-Path (Get-SebEscrowShareDir -Config $config) (Get-SebEscrowName $keyId)
  Check (Test-Path -LiteralPath $escrowOnShare) '2: the data pass put the key escrow on the share beside the backups'

  Say '--- point-in-time restore through the encrypted chain ---'
  $dataDir = Join-Path $staging 'restored'; [void](New-Item -ItemType Directory -Path $dataDir -Force)
  Invoke-SebRestoreToPoint -Connection $conn -Root $share -HostName $env:COMPUTERNAME -InstanceLabel 'SQLEXPRESS' -Database $db -RestoreAs 'EncProbe_R' -StopAt $target -DataDir $dataDir -LogDir $dataDir -WorkDir $staging
  Check ([int](Scalar 'SELECT COUNT(*) FROM [EncProbe_R].dbo.T WHERE id = 1') -eq 1) '3: row A (before the target) is in the restored copy'
  Check ([int](Scalar 'SELECT COUNT(*) FROM [EncProbe_R].dbo.T WHERE id = 2') -eq 0) '3: row B (after the target) is not'
  DropDb 'EncProbe_R'

  $rt = Invoke-SebRestoreTest -Connection $conn -Config $config -Database $db
  Check ($rt.Result -eq 'ok') "4: the restore test passes on the encrypted chain ($($rt.Result): $($rt.Message))"

  Say '--- a rebuilt server: no keys, then an import from the share ---'
  $script:LiveRing = @{}
  $rt2 = Invoke-SebRestoreTest -Connection $conn -Config $config -Database $db
  Check ($rt2.Result -eq 'failed' -and $rt2.Message -like "*$keyId*ImportEncryptionKey*") "5: without the key the test fails and names the key and the fix"
  $fromShare = Get-Content -LiteralPath $escrowOnShare -Raw | ConvertFrom-Json
  $script:LiveRing = @{ $keyId = (Open-SebEscrow -Escrow $fromShare -Passphrase $passphrase) }
  $rt3 = Invoke-SebRestoreTest -Connection $conn -Config $config -Database $db
  Check ($rt3.Result -eq 'ok') '5: after importing with the PASSPHRASE, restores work again'
  $script:LiveRing = @{ $keyId = (Open-SebEscrow -Escrow $fromShare -RecoveryKey (Format-SebRecoveryKey $rk)) }
  $rt4 = Invoke-SebRestoreTest -Connection $conn -Config $config -Database $db
  Check ($rt4.Result -eq 'ok') '5: and with the RECOVERY KEY instead'
}
finally {
  Set-Item -Path function:Read-SebKeyring -Value $realRing
  $script:SebConfigDir = $savedCfgDir
  foreach ($n in @($db, 'EncProbe_R', (Get-SebRestoreTestName $db))) { try { DropDb $n } catch { Write-Host ("  cleanup: {0}: {1}" -f $n, $_.Exception.Message) } }
  try { $conn.Close() } catch { }
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  Say 'cleaned up scratch databases and temp trees'
}

if ($pass) { Write-Host 'LIVE ENCRYPTION PROOF: ALL PASS'; exit 0 } else { Write-Host 'LIVE ENCRYPTION PROOF: FAILED'; exit 1 }
