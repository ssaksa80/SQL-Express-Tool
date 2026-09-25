# Live alerting proof. Run where SQL Express is present:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-alerting.ps1"
#
# Drives the engine's REAL data pass (Invoke-SebPass) against a live instance with the share
# toggled unreachable -> unreachable -> reachable, and proves the alerting contract end to end:
#   run 1 (share down):  the copy is pending          -> copy-pending RAISED, once
#   run 2 (still down):  the same condition persists  -> nothing sent (no noise)
#   run 3 (share back):  the pending copy drains      -> copy-pending RESOLVED, once
# plus: the heartbeat pings after each pass that backed up without a database failing, and the
# event log carries 9100 (raised) / 9102 (resolved) when the event source is registered.
#
# Self-contained like test\live-backuplog-resilience.ps1: temp config/state folder, temp
# staging and share, a scratch database (SebAlertProbe), and loopback listeners standing in
# for the webhook and the heartbeat monitor. Nothing of record is touched; all removed after.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$sqlInstance = '.\SQLEXPRESS'
$probe = 'SebAlertProbe'
$pass = $true
$started = Get-Date
function Say($m) { Write-Host $m }
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS $msg" } else { Write-Host "  FAIL $msg"; $script:pass = $false } }

. $engine -DotSourceOnly
$script:SebCompression = 'off'

$cs = "Server=$sqlInstance;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
function Exec($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; [void]$k.ExecuteNonQuery() }
function Scalar($sql) { $k = $conn.CreateCommand(); $k.CommandText = $sql; return $k.ExecuteScalar() }

# A loopback HTTP listener on a background runspace that records every request it gets.
function Start-Recorder {
  $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
      param($listener, $log)
      while ($true) {
        try { $client = $listener.AcceptTcpClient() } catch { break }
        try {
          $stream = $client.GetStream()
          $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
          $first = $reader.ReadLine(); $len = 0
          while (($h = $reader.ReadLine()) -ne '' -and $null -ne $h) { if ($h -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
          $buf = New-Object char[] $len; $got = 0
          while ($got -lt $len) { $n = $reader.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
          $resp = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok")
          $stream.Write($resp, 0, $resp.Length)
          [void]$log.Add([pscustomobject]@{ Request = $first; Body = (-join $buf) })
        }
        finally { $client.Close() }
      }
    }).AddArgument($listener).AddArgument($log)
  $handle = $ps.BeginInvoke()
  return [pscustomobject]@{ Url = ('http://127.0.0.1:{0}/' -f ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port); Listener = $listener; Log = $log; Ps = $ps }
}
function Stop-Recorder($r) { try { $r.Listener.Stop() } catch { }; try { $r.Ps.Stop(); $r.Ps.Dispose() } catch { } }
function Events($body) { return @(($body | ConvertFrom-Json).notifications | ForEach-Object { '{0}:{1}' -f $_.event, $_.key }) }

$workRoot = Join-Path $env:TEMP ('SebAlertLive_' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $workRoot 'staging'
$cfgDir = Join-Path $workRoot 'cfg'
$gate = Join-Path $workRoot 'gate'
$sharePath = Join-Path $gate 'share'
[void](New-Item -ItemType Directory -Path $staging, $cfgDir -Force)
$svc = [string](Scalar "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'")
if ([string]::IsNullOrWhiteSpace($svc)) { $svc = 'NT SERVICE\MSSQL$SQLEXPRESS' }
icacls $workRoot /grant ("{0}:(OI)(CI)M" -f $svc) /T 2>&1 | Out-Null

$savedCfgDir = $script:SebConfigDir
$script:SebConfigDir = $cfgDir
$hook = Start-Recorder
$beat = Start-Recorder
$realSecrets = ${function:Read-SebAlertSecrets}
# The sealed secrets need the machine key and an admin-only file; stand them in directly.
$script:LiveSecrets = @{ WebhookUrl = ($hook.Url + 'hook'); HeartbeatUrl = ($beat.Url + 'ping') }
function Read-SebAlertSecrets { return $script:LiveSecrets.Clone() }

$config = [pscustomobject]@{
  DataSource = $sqlInstance; InstanceName = 'SQLEXPRESS'; SharePath = $sharePath; StagingPath = $staging
  IntervalHours = 6; HourlyKeep = 3; DailyKeepDays = 7; RecoveryMode = 'Simple'
  UseWindowsAuth = $true; NoHashVerify = $true; SqlServiceAccount = $svc; OnlyDatabase = $probe
  CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
  AlertWebhookKind = 'generic'; AlertPendingMinutes = 0; AlertRemindHours = 24
}

try {
  if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$probe'") -gt 0) { Exec "ALTER DATABASE [$probe] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"; Exec "DROP DATABASE [$probe]" }
  Exec "CREATE DATABASE [$probe]"
  Say "created $probe"

  Set-Content -LiteralPath $gate -Value 'unreachable share stand-in' -Encoding ASCII
  Say '--- run 1: share unreachable ---'
  $code1 = Invoke-SebPass -Config $config
  Start-Sleep -Milliseconds 500
  Check ($code1 -eq 1) "run 1: the pass is partial (a copy is pending), exit $code1"
  Check ($hook.Log.Count -eq 1) "run 1: exactly one alert sent (got $($hook.Log.Count))"
  if ($hook.Log.Count -ge 1) { Check ((Events $hook.Log[0].Body) -contains 'raised:copy-pending') "run 1: it raises copy-pending ($((Events $hook.Log[0].Body) -join ', '))" }
  Check ($beat.Log.Count -eq 1) 'run 1: the heartbeat pinged (the database was backed up; only the copy waits)'

  Say '--- run 2: still unreachable ---'
  $code2 = Invoke-SebPass -Config $config
  Start-Sleep -Milliseconds 500
  Check ($code2 -eq 1) "run 2: still partial, exit $code2"
  Check ($hook.Log.Count -eq 1) "run 2: nothing new sent while the problem persists (total $($hook.Log.Count))"

  Remove-Item -LiteralPath $gate -Force
  [void](New-Item -ItemType Directory -Path $gate -Force)
  Say '--- run 3: share reachable ---'
  $code3 = Invoke-SebPass -Config $config
  Start-Sleep -Milliseconds 500
  Check ($code3 -eq 0) "run 3: clean pass, exit $code3"
  Check ($hook.Log.Count -eq 2) "run 3: exactly one more alert sent (total $($hook.Log.Count))"
  if ($hook.Log.Count -ge 2) { Check ((Events $hook.Log[1].Body) -contains 'resolved:copy-pending') "run 3: it resolves copy-pending ($((Events $hook.Log[1].Body) -join ', '))" }
  $st = Read-SebState
  Check (@($st.Alerts.PSObject.Properties).Count -eq 0) 'run 3: no alert left open in state'
  Check ($beat.Log.Count -eq 3) "every pass that backed up pinged the heartbeat (got $($beat.Log.Count))"

  if ([System.Diagnostics.EventLog]::SourceExists('SqlExpressBackup')) {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'SqlExpressBackup'; StartTime = $started } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -like '*copy-pending*' })
    Check (@($ev | Where-Object Id -eq 9100).Count -ge 1) 'the event log has a 9100 (raised) entry'
    Check (@($ev | Where-Object Id -eq 9102).Count -ge 1) 'and a 9102 (resolved) entry'
  }
  else { Say '  (event source not registered on this host - it needs one elevated run; event log check skipped)' }
}
finally {
  Set-Item -Path function:Read-SebAlertSecrets -Value $realSecrets
  $script:SebConfigDir = $savedCfgDir
  Stop-Recorder $hook; Stop-Recorder $beat
  try { if ([int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = '$probe'") -gt 0) { Exec "ALTER DATABASE [$probe] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"; Exec "DROP DATABASE [$probe]" } }
  catch { Write-Host ("  cleanup: could not drop {0}: {1}" -f $probe, $_.Exception.Message) }
  try { $conn.Close() } catch { }
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  Say 'cleaned up scratch database, temp trees and listeners'
}

if ($pass) { Write-Host 'LIVE ALERTING PROOF: ALL PASS'; exit 0 } else { Write-Host 'LIVE ALERTING PROOF: FAILED'; exit 1 }
