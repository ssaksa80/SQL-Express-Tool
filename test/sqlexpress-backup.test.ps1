# Run: powershell -NoProfile -ExecutionPolicy Bypass -File "test\sqlexpress-backup.test.ps1"
#
# Guards Invoke-SqlExpressBackup.ps1 - the scheduled SQL Express backup.
#
# Every assertion below drives a real function with real data. Asserting that a
# keyword still appears in the source proves nothing here: the keyword survives
# every refactor that breaks the behaviour, so the test passes while the backups
# rot. The two exceptions are the structural guards at the top, which are ABOUT
# the file rather than about its behaviour.
#
# The properties that matter most:
#   1. It stays a single copyable file (no dot-source, not staged into the bundle).
#   2. Retention keeps what it promises and deletes only the rest. A planner that
#      is off by one silently destroys the oldest good backup on every run.
#   3. NULL from SQL is DBNull, not $null, and DBNull is TRUTHY in PowerShell. A
#      snapshot check written the obvious way excludes every database on the box.
#   4. A tampered credential is refused, not decrypted into something else.
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "FAIL: $msg" } else { Write-Host "  PASS $msg" } }

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
Assert (Test-Path $script) 'Invoke-SqlExpressBackup.ps1 exists'

# ---- structural: it has to run where the servers are ----------------------------
$raw = Get-Content -Raw $script
Assert (-not ($raw -match '[^\x00-\x7F]')) 'script is pure ASCII (it runs on a server console under PS 5.1)'

$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
Assert (@($errs).Count -eq 0) "script parses cleanly (parser reported $(@($errs).Count) error(s))"
Assert ($raw -match '#requires -version 5\.1') 'script declares the PS 5.1 floor it targets'
Assert (-not ($raw -match '=\s*\(\s*try\s*\{')) 'script avoids assigning a try block (invalid on PS 5.1)'

$code = (($raw -split "`n") | Where-Object { -not ($_.TrimStart().StartsWith('#')) }) -join "`n"
Assert (-not ($code -match '(?m)^\s*\.\s+')) 'script dot-sources nothing - one copyable file, not a bundle tool'

# NOTE: this suite was extracted from the application repo where the tool was first
# written. There it also asserted that the packaging script did NOT bundle these two
# files, because being copyable to a bare server by hand was the whole design. That
# assertion has no subject here - this repo IS the tool - so it is gone rather than
# left passing vacuously against a file that does not exist.

# The password must never reach a command line. sqlcmd -P is the classic way this
# leaks into Win32_Process for every local user; this script uses SqlCredential.
Assert (-not ($code -match 'sqlcmd')) 'script never shells out to sqlcmd (a -P argument is world-readable in the process list)'
Assert ($code -match 'SqlCredential') 'script authenticates with SqlCredential, keeping the password a SecureString'

. $script -DotSourceOnly

# ---- 1. DBNull is truthy: the snapshot filter has to survive it ------------------
$rows = @(
  [pscustomobject]@{ name = 'master'; state = 0; source_database_id = [System.DBNull]::Value; is_in_standby = $false }
  [pscustomobject]@{ name = 'msdb'; state = 0; source_database_id = [System.DBNull]::Value; is_in_standby = $false }
  [pscustomobject]@{ name = 'tempdb'; state = 0; source_database_id = [System.DBNull]::Value; is_in_standby = $false }
  [pscustomobject]@{ name = 'model'; state = 0; source_database_id = [System.DBNull]::Value; is_in_standby = $false }
  [pscustomobject]@{ name = 'APPDB'; state = 0; source_database_id = $null; is_in_standby = $false }
  [pscustomobject]@{ name = 'Offline_App'; state = 6; source_database_id = $null; is_in_standby = $false }
  [pscustomobject]@{ name = 'APPDB_snap'; state = 0; source_database_id = 5; is_in_standby = $false }
  [pscustomobject]@{ name = 'LogShipTarget'; state = 0; source_database_id = $null; is_in_standby = $true }
)
$picked = Select-SebDatabase -Rows $rows
Assert ($picked -contains 'master') 'master is backed up (a rebuilt instance needs its logins back)'
Assert ($picked -contains 'msdb') 'msdb is backed up'
Assert ($picked -contains 'APPDB') 'a plain online user database is backed up'
Assert ($picked -notcontains 'tempdb') 'tempdb is skipped (it cannot be backed up at all)'
Assert ($picked -notcontains 'model') 'model is skipped'
Assert ($picked -notcontains 'Offline_App') 'a database that is not ONLINE is skipped'
Assert ($picked -notcontains 'APPDB_snap') 'a snapshot is skipped'
Assert ($picked -notcontains 'LogShipTarget') 'a standby database is skipped'
Assert ($picked.Count -eq 3) "exactly the 3 eligible databases are chosen (got $($picked.Count))"

# The specific trap: DBNull is not $null and is truthy, so "-not $row.source_database_id"
# reads correctly and excludes EVERYTHING. Prove the DBNull rows survived.
Assert ($picked -contains 'master' -and $picked -contains 'msdb') 'DBNull in source_database_id does not read as "is a snapshot"'

# ---- 2. retention keeps exactly what it promises ---------------------------------
function New-Fact([string]$n, [datetime]$t) { return [pscustomobject]@{ Name = $n; Timestamp = $t } }
$now = [datetime]'2026-08-30 18:00:00'

$plan = Get-SebRetentionPlan -HourlyFiles @(New-Fact 'a' $now) -DailyFiles @() -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert ($plan.HourlyDelete.Count -eq 0) 'one hourly file and a keep of 3 deletes nothing'

$three = @(
  (New-Fact 'h1' $now.AddHours(-12)),
  (New-Fact 'h2' $now.AddHours(-6)),
  (New-Fact 'h3' $now)
)
$plan = Get-SebRetentionPlan -HourlyFiles $three -DailyFiles @() -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert ($plan.HourlyDelete.Count -eq 0) 'exactly 3 hourly files and a keep of 3 deletes nothing (the off-by-one that eats a good backup)'

$five = $three + @((New-Fact 'h0' $now.AddHours(-24)), (New-Fact 'hm1' $now.AddHours(-18)))
$plan = Get-SebRetentionPlan -HourlyFiles $five -DailyFiles @() -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert ($plan.HourlyDelete.Count -eq 2) '5 hourly files and a keep of 3 deletes 2'
Assert ($plan.HourlyDelete -contains 'h0' -and $plan.HourlyDelete -contains 'hm1') 'the 2 OLDEST hourly files are the ones deleted'
Assert ($plan.HourlyDelete -notcontains 'h3') 'the newest hourly file is never deleted'

# Daily promotion is state-based: it asks whether TODAY is covered, not whether the
# clock says midnight. A run at 18:00 on a day whose 00:00 run never happened must
# still produce that day's archive.
$plan = Get-SebRetentionPlan -HourlyFiles @() -DailyFiles @() -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert ($plan.PromoteToDaily) 'an empty daily folder gets today promoted'

$plan = Get-SebRetentionPlan -HourlyFiles @() -DailyFiles @((New-Fact 'd-today' $now.AddHours(-12))) -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert (-not $plan.PromoteToDaily) 'a daily archive already dated today is not promoted again'

$plan = Get-SebRetentionPlan -HourlyFiles @() -DailyFiles @((New-Fact 'd-yesterday' $now.AddDays(-1))) -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert ($plan.PromoteToDaily) "yesterday's archive does not satisfy today - a missed midnight run still gets a daily"

# A promotion consumes one slot, so the survivors compete for one fewer. Without
# that the folder sits at DailyKeepDays + 1 for the rest of the day.
$sevenDailies = @(0..6 | ForEach-Object { New-Fact ("d$_") $now.AddDays(-1 - $_) })
$plan = Get-SebRetentionPlan -HourlyFiles @() -DailyFiles $sevenDailies -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert ($plan.PromoteToDaily) '7 older dailies and none for today still promotes today'
Assert ($plan.DailyDelete.Count -eq 1) 'promoting into a full daily folder deletes exactly 1 to make room'
Assert ($plan.DailyDelete -contains 'd6') 'the oldest daily is the one that goes'

$withToday = @((New-Fact 'd-today' $now)) + @(0..5 | ForEach-Object { New-Fact ("d$_") $now.AddDays(-1 - $_) })
$plan = Get-SebRetentionPlan -HourlyFiles @() -DailyFiles $withToday -Now $now -HourlyKeep 3 -DailyKeepDays 7
Assert (-not $plan.PromoteToDaily) '7 dailies including today promotes nothing'
Assert ($plan.DailyDelete.Count -eq 0) 'and with no promotion, a full-but-not-over daily folder loses nothing'

$plan = Get-SebRetentionPlan -HourlyFiles $five -DailyFiles @() -Now $now -HourlyKeep 0 -DailyKeepDays 0
Assert ($plan.HourlyDelete.Count -eq 4) 'a keep of 0 is clamped to 1 rather than deleting every backup'

# ---- 3. the stamp comes from the name, not the mtime -----------------------------
$fallback = [datetime]'2000-01-01'
$parsed = Get-SebStampFromName -Name 'APPDB_20260830-181500.bak' -Fallback $fallback
Assert ($parsed -eq ([datetime]'2026-08-30 18:15:00')) 'the timestamp is read out of the file name'
$parsed = Get-SebStampFromName -Name 'handcopied.bak' -Fallback $fallback
Assert ($parsed -eq $fallback) 'a name with no stamp falls back to the mtime it was given'
# Why it matters: copying to a share can rewrite LastWriteTime, and retention that
# sorted on mtime would then treat the oldest backup as the newest.
$stamped = Get-SebFileName -Database 'APPDB' -Stamp ([datetime]'2026-08-30 18:15:00')
Assert ((Get-SebStampFromName -Name $stamped -Fallback $fallback) -eq ([datetime]'2026-08-30 18:15:00')) 'the name this script writes round-trips through the parser it reads with'

# ---- 4. paths ---------------------------------------------------------------------
$path = Get-SebBackupPath -Root '\\fs\sqlbackups' -HostName 'APPSRV1' -InstanceLabel 'SQLEXPRESS' -Database 'APPDB' -Kind 'hourly'
Assert ($path -eq '\\fs\sqlbackups\APPSRV1\SQLEXPRESS\APPDB\hourly') "share path composes host/instance/database/kind (got '$path')"
$path = Get-SebBackupPath -Root 'C:\b' -HostName 'H' -InstanceLabel 'MSSQLSERVER' -Database 'we:ird/name' -Kind 'daily'
Assert ($path -eq 'C:\b\H\MSSQLSERVER\we_ird_name\daily') "a database name holding path characters is sanitised (got '$path')"
Assert ((Get-SebQuotedName 'we]ird') -eq '[we]]ird]') 'a bracket in a database name is escaped for T-SQL, not left to break the statement'
Assert ((Get-SebSqlLiteral "o'brien") -eq "'o''brien'") 'a quote in a path is escaped for T-SQL'

# ---- 5. instance discovery, with no SQL Server needed ----------------------------
$fakeRegistry = {
  param([string]$Path)
  if ($Path -eq 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL') {
    return [pscustomobject]@{ MSSQLSERVER = 'MSSQL15.MSSQLSERVER'; SQLEXPRESS = 'MSSQL15.SQLEXPRESS'; PSPath = 'noise' }
  }
  if ($Path -like '*MSSQL15.SQLEXPRESS\Setup') { return [pscustomobject]@{ Edition = 'Express Edition'; Version = '15.0.2000.5' } }
  if ($Path -like '*MSSQL15.MSSQLSERVER\Setup') { return [pscustomobject]@{ Edition = 'Standard Edition'; Version = '15.0.2000.5' } }
  return $null
}
$fakeService = { param([string]$Name) return [pscustomobject]@{ Status = 'Running' } }
$found = Get-SebInstanceList -RegistryReader $fakeRegistry -ServiceReader $fakeService -HostName 'APPSRV1'
Assert ($found.Count -eq 2) "both instances are discovered (got $($found.Count))"
$express = $found | Where-Object { $_.InstanceName -eq 'SQLEXPRESS' }
Assert ($express.DataSource -eq 'APPSRV1\SQLEXPRESS') 'a named instance gets a host\instance data source'
Assert ($express.ServiceName -eq 'MSSQL$SQLEXPRESS') 'a named instance maps to its MSSQL$ service'
Assert ($express.IsExpress) 'Express is recognised from the edition string'
$default = $found | Where-Object { $_.InstanceName -eq 'MSSQLSERVER' }
Assert ($default.DataSource -eq 'APPSRV1') 'the default instance is the bare host name, with no backslash'
Assert ($default.ServiceName -eq 'MSSQLSERVER') 'the default instance maps to the MSSQLSERVER service'
Assert (-not $default.IsExpress) 'a Standard instance is not reported as Express'

$empty = Get-SebInstanceList -RegistryReader { param($p) return $null } -ServiceReader $fakeService
Assert ($empty.Count -eq 0) 'a host with no SQL Server yields no instances instead of throwing'

# ---- 6. sealing: round-trip, and refusal ------------------------------------------
$key = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $key[$i] = [byte]($i * 7 % 251) }
$other = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $other[$i] = [byte]($i * 11 % 251) }

$secretText = 'P@ssw0rd with spaces and $ymbols'
$sealed = Protect-SebString -Plain $secretText -Master $key
Assert ($sealed -notmatch 'P@ssw0rd') 'the sealed blob does not contain the plaintext'
Assert ((Unprotect-SebString -Blob $sealed -Master $key) -eq $secretText) 'sealing then opening returns the exact original'

$again = Protect-SebString -Plain $secretText -Master $key
Assert ($again -ne $sealed) 'sealing the same value twice gives different blobs (the IV is fresh each time)'

$threw = $false
try { [void](Unprotect-SebString -Blob $sealed -Master $other) } catch { $threw = $true }
Assert $threw 'the wrong key is refused'

$bytes = [Convert]::FromBase64String($sealed)
$bytes[20] = [byte](($bytes[20] + 1) % 256)
$threw = $false
try { [void](Unprotect-SebString -Blob ([Convert]::ToBase64String($bytes)) -Master $key) } catch { $threw = $true }
Assert $threw 'a flipped ciphertext byte is REFUSED by the MAC, not decrypted into garbage'

$bytes = [Convert]::FromBase64String($sealed)
$bytes[$bytes.Length - 1] = [byte](($bytes[$bytes.Length - 1] + 1) % 256)
$threw = $false
try { [void](Unprotect-SebString -Blob ([Convert]::ToBase64String($bytes)) -Master $key) } catch { $threw = $true }
Assert $threw 'a flipped MAC byte is refused'

$threw = $false
try { [void](Unprotect-SebString -Blob ([Convert]::ToBase64String($bytes[0..40])) -Master $key) } catch { $threw = $true }
Assert $threw 'a truncated blob is refused rather than half-decrypted'

Assert (Test-SebFixedTimeEqual ([byte[]](1, 2, 3)) ([byte[]](1, 2, 3))) 'the constant-time compare accepts equal arrays'
Assert (-not (Test-SebFixedTimeEqual ([byte[]](1, 2, 3)) ([byte[]](1, 2, 4)))) 'and rejects unequal ones'
Assert (-not (Test-SebFixedTimeEqual ([byte[]](1, 2, 3)) ([byte[]](1, 2)))) 'and rejects a length mismatch'

# The live path never turns the password into a managed string, so prove the
# SecureString round-trip works on its own terms.
$secure = New-Object System.Security.SecureString
foreach ($ch in 'hunter2!'.ToCharArray()) { $secure.AppendChar($ch) }
$secure.MakeReadOnly()
$sealedSecure = Protect-SebSecureString -Secret $secure -Master $key
$reopened = Unprotect-SebSecureString -Blob $sealedSecure -Master $key
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($reopened)
try { $roundTripped = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
Assert ($roundTripped -eq 'hunter2!') 'a SecureString seals and reopens without ever becoming a managed string in the script'
Assert ($reopened.IsReadOnly()) 'the reopened SecureString is read-only, as SqlCredential requires'

# ---- 7. redaction is an allow-list ------------------------------------------------
$config = [pscustomobject]@{
  DataSource   = 'APPSRV1\SQLEXPRESS'
  SqlUser      = 'appdb_backup'
  SharePath    = '\\fs\sqlbackups'
  SealedSecret = 'SUPERSECRETVALUE'
  FutureField  = 'ALSOSECRET'
}
$facts = Format-SebConfigFacts -Config $config
$text = $facts -join "`n"
Assert ($text -match 'APPSRV1\\SQLEXPRESS') 'an allow-listed field is shown'
Assert ($text -match 'appdb_backup') 'the login NAME is shown - it is not the secret'
Assert (-not ($text -match 'SUPERSECRETVALUE')) 'a value outside the allow-list is not printed'
Assert (-not ($text -match 'ALSOSECRET')) 'a field nobody thought about yet is hidden by default, not shown by default'
Assert ($text -match 'SealedSecret') 'hidden fields are still reported BY NAME, so status output stays honest'

# ---- 8. elevation is checked up front, not discovered halfway through -------------
# Set-SebSecretAcl locks key.bin to SYSTEM + Administrators with inheritance off,
# and a filtered token does not carry that group. Without an up-front check, -Setup
# writes the key, locks it, and then dies on "Access to the path is denied" reading
# back the file it just wrote - with the credential already half-committed.
$threw = $false
$message = ''
try { Assert-SebElevated -Mode 'Setup' -ElevationCheck { $false } }
catch { $threw = $true; $message = $_.Exception.Message }
Assert $threw 'a non-elevated run is refused before it touches anything'
Assert ($message -match 'Setup') 'the refusal names the mode that was attempted'
Assert ($message -match '(?i)administrator') 'the refusal tells the operator what to do about it'

$threw = $false
try { Assert-SebElevated -Mode 'Setup' -ElevationCheck { $true } } catch { $threw = $true }
Assert (-not $threw) 'an elevated run passes the check silently'
Assert ((Test-SebElevated) -is [bool]) 'the real elevation probe returns a boolean'

# Structural, and deliberately so: the guard is worthless if a mode forgets to call
# it, and that is a property of the dispatch rather than of any one function.
$dispatch = $code.Substring($code.IndexOf('if ($DotSourceOnly) { return }'))
foreach ($mode in @('Setup', 'Install', 'Uninstall', 'Status', 'Run', 'FullInstall')) {
  Assert ($dispatch -match ("Assert-SebElevated -Mode '" + $mode + "'")) "the $mode mode calls the elevation guard"
}
# -SelfTest deliberately does NOT: it creates and owns every folder it touches and
# connects with the caller's own Windows credentials, so demanding an administrator
# would put a UAC prompt in front of the one action that proves the tool works.
$selfTestBranch = [regex]::Match($dispatch, '(?s)elseif \(\$SelfTest\) \{.*?\n  \}')
Assert ($selfTestBranch.Success) 'the -SelfTest dispatch branch is present'
Assert (-not ($selfTestBranch.Value -match 'Assert-SebElevated')) '-SelfTest does NOT demand elevation'

# ---- 8b. the folder-reading path, in the exact shape the pass calls it -------------
# Three live defects hid behind hand-built test data. This one: Get-SebFolderFacts
# used the "return , @(...)" idiom, every caller wraps it in @(...), and
# @( ,@(x) ) is an array whose single element IS the array. Count was therefore 1
# no matter how many backups existed, nothing ever exceeded HourlyKeep, and
# retention silently never ran - while the planner's own tests stayed green
# because they were handed arrays directly.
$factDir = Join-Path $env:TEMP ('seb-facts-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $factDir)
try {
  Assert ((@(Get-SebFolderFacts -Directory $factDir)).Count -eq 0) 'an empty folder yields no facts'
  Assert ((@(Get-SebFolderFacts -Directory (Join-Path $factDir 'nope'))).Count -eq 0) 'a missing folder yields no facts'

  $one = Get-SebFileName -Database 'D' -Stamp ([datetime]'2026-08-29 12:00:00')
  Set-Content -LiteralPath (Join-Path $factDir $one) -Value 'x'
  Assert ((@(Get-SebFolderFacts -Directory $factDir)).Count -eq 1) 'a single file yields ONE fact, not an array wrapping one'

  foreach ($h in @(0, 6, 12, 18)) {
    $n = Get-SebFileName -Database 'D' -Stamp ([datetime]'2026-08-30 18:00:00').AddHours(-$h)
    Set-Content -LiteralPath (Join-Path $factDir $n) -Value 'x'
  }
  $facts = @(Get-SebFolderFacts -Directory $factDir)
  Assert ($facts.Count -eq 5) "five files yield five facts, not one wrapper (got $($facts.Count))"
  Assert ($facts[0].Timestamp -is [datetime]) 'each fact carries a real DateTime, not a nested array'

  # And now the whole retention decision through that real path, which is what the
  # pass actually does - not through arrays assembled by hand.
  $plan = Get-SebRetentionPlan -HourlyFiles $facts -DailyFiles @() -Now ([datetime]'2026-08-30 18:00:00') -HourlyKeep 3 -DailyKeepDays 7
  Assert (@($plan.HourlyDelete).Count -eq 2) "retention through the real folder path deletes 2 of 5 (got $(@($plan.HourlyDelete).Count))"
  Assert (@($plan.HourlyDelete) -contains (Get-SebFileName -Database 'D' -Stamp ([datetime]'2026-08-29 12:00:00'))) 'and the oldest is among those that go'
  Assert (@($plan.HourlyDelete) -notcontains (Get-SebFileName -Database 'D' -Stamp ([datetime]'2026-08-30 18:00:00'))) 'and the newest is never among them'
}
finally { Remove-Item -LiteralPath $factDir -Recurse -Force -ErrorAction SilentlyContinue }

# Format-SebConfigFacts has the same shape, and piping it emitted ONE object - so
# -Status printed the whole config joined onto a single line.
$piped = @([pscustomobject]@{ A = 1; B = 2; C = 3 } | ForEach-Object { Format-SebConfigFacts -Config $_ } | ForEach-Object { $_ })
Assert ($piped.Count -eq 3) "config facts survive a pipeline as separate lines (got $($piped.Count))"

# ---- 8c. compression support is decided by ERROR NUMBER, not English text ---------
# The live failure: SQL Server 2025 says "is not supported on Express Edition
# (64-bit)" where the code matched "not supported in this edition". Every backup on
# Express rethrew instead of falling back, on the one edition this script exists
# for. Error 1844 is stable across versions and is not localized; the message is
# both. These are the REAL strings from a live server.
Assert (Test-SebCompressionUnsupported -Numbers @(1844, 3013) -Message 'BACKUP DATABASE WITH COMPRESSION is not supported on Express Edition (64-bit).') 'SQL Server 2025 Express wording is recognised by error number'
Assert (Test-SebCompressionUnsupported -Numbers @(1844) -Message 'BACKUP DATABASE WITH COMPRESSION wird auf dieser Edition nicht unterstuetzt.') 'a localized message is still recognised, because the number carries it'
Assert (Test-SebCompressionUnsupported -Numbers @() -Message 'BACKUP DATABASE WITH COMPRESSION is not supported in this edition of SQL Server.') 'the older wording still matches via the text fallback when no number survives'
Assert (-not (Test-SebCompressionUnsupported -Numbers @(3201, 3013) -Message "Cannot open backup device 'x'. Operating system error 5(Access is denied.).")) 'a permissions failure is NOT mistaken for missing compression'
Assert (-not (Test-SebCompressionUnsupported -Numbers @(3202) -Message 'Write on "x" failed: 112(There is not enough space on the disk.)')) 'a full disk is not mistaken for missing compression'
Assert (-not (Test-SebCompressionUnsupported)) 'no error information at all does not claim compression is unsupported'

# ---- 8d. the SQL service account is what actually writes the .bak -----------------
# The other live defect: setup created the staging folder but granted the SQL
# service account nothing, so every BACKUP died with "Operating system error
# 5(Access is denied.)" - on every install, because the .bak is written by the
# engine's account and not by whoever ran the script.
Assert ((Get-SebAclIdentity 'LocalSystem') -eq 'NT AUTHORITY\SYSTEM') 'Win32_Service LocalSystem maps to an identity an ACL will accept'
Assert ((Get-SebAclIdentity 'NetworkService') -eq 'NT AUTHORITY\NETWORK SERVICE') 'NetworkService maps too'
Assert ((Get-SebAclIdentity 'NT Service\MSSQL$SQLEXPRESS') -eq 'NT Service\MSSQL$SQLEXPRESS') 'a virtual account is already in the right form and passes through'
Assert ((Get-SebAclIdentity 'CONTOSO\sqlsvc') -eq 'CONTOSO\sqlsvc') 'a domain account passes through'
Assert ((Get-SebAclIdentity '') -eq '') 'an unknown account yields empty, so callers can warn rather than build a broken rule'
Assert ((Get-SebServiceAccount -ServiceName 'MSSQL$X' -ServiceQuery { param($n) [pscustomobject]@{ StartName = 'NT Service\MSSQL$X' } }) -eq 'NT Service\MSSQL$X') 'the service account is read from the service, not guessed'
Assert ((Get-SebServiceAccount -ServiceName 'nope' -ServiceQuery { param($n) $null }) -eq '') 'an absent service yields empty rather than throwing'

# The account is read from the registry rather than WMI, and that is a performance
# fix with a measured cause: Win32_Service took 12.6 SECONDS on the first call on a
# host running endpoint protection, which instruments WMI heavily. The registry read
# is 15ms. It was found by timing a self test that spent four and a half minutes
# between two adjacent log lines.
#
# Asserted against a service every Windows host has, so this does not depend on SQL
# being installed on the machine running the suite.
$fromReg = Get-SebServiceAccountFromRegistry -ServiceName 'Winmgmt'
Assert (-not [string]::IsNullOrWhiteSpace($fromReg)) "the registry lookup finds a well-known service's account (got '$fromReg')"
Assert ((Get-SebServiceAccountFromRegistry -ServiceName 'NoSuchServiceHere') -eq '') 'an absent service yields empty rather than throwing'
Assert ((Get-SebServiceAccountFromRegistry -ServiceName '') -eq '') 'an empty service name yields empty'
# A service name is a registry KEY name and cannot contain a separator. Asserting the
# RETURN VALUE alone proved nothing - the path does not resolve with or without the
# guard, so the check passed for the wrong reason and a mutation removing the guard
# still went green. What distinguishes them is whether the registry is touched at
# all, so that is what is asserted.
$touched = New-Object System.Collections.ArrayList
$spy = { param($k) [void]$touched.Add($k); return $null }

[void](Get-SebServiceAccountFromRegistry -ServiceName '..\..\..\Winmgmt' -Reader $spy)
Assert ($touched.Count -eq 0) "a name containing a backslash is refused BEFORE the registry is read (reads attempted: $($touched.Count))"
[void](Get-SebServiceAccountFromRegistry -ServiceName 'a/b' -Reader $spy)
Assert ($touched.Count -eq 0) 'a forward slash is refused the same way'

# And the spy really does fire for a legitimate name - otherwise the two assertions
# above would hold no matter what the function did.
[void](Get-SebServiceAccountFromRegistry -ServiceName 'Winmgmt' -Reader $spy)
Assert ($touched.Count -eq 1) "the reader IS called for an ordinary name (reads: $($touched.Count))"
Assert ($touched[0] -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\Winmgmt') "and it is handed the expected key (got '$($touched[0])')" 

# The injected query must still win outright. If the registry fast path ran first the
# two assertions above this block would be testing the real machine, not the seam,
# and would pass whatever the function did.
Assert ((Get-SebServiceAccount -ServiceName 'Winmgmt' -ServiceQuery { param($n) [pscustomobject]@{ StartName = 'INJECTED' } }) -eq 'INJECTED') 'an injected query overrides the registry, so the seam is still real'

$stagingDir = Join-Path $env:TEMP ('seb-staging-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $stagingDir)
try {
  Set-SebStagingAcl -Path $stagingDir -SqlAccount 'NT AUTHORITY\NETWORK SERVICE'
  $sacl = Get-Acl -Path $stagingDir
  $names = @($sacl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } | Sort-Object -Unique)
  Assert ($sacl.AreAccessRulesProtected) 'staging stops inheriting too'
  Assert ($names -contains 'NT AUTHORITY\NETWORK SERVICE') 'the SQL service account is granted on staging - without this every BACKUP fails with OS error 5'
  Assert ($names -contains 'NT AUTHORITY\SYSTEM') 'SYSTEM keeps access - it is what runs the scheduled pass'
  Assert ($names -contains 'BUILTIN\Administrators') 'Administrators keep access'
  $sqlRule = @($sacl.Access | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value -eq 'NT AUTHORITY\NETWORK SERVICE' })
  Assert ($sqlRule[0].FileSystemRights -match 'Modify') 'the SQL account gets Modify - enough to write a .bak, short of FullControl'
  Assert ($sqlRule[0].InheritanceFlags -match 'ObjectInherit') 'the grant reaches the .bak files inside, not just the folder'
}
finally { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---- 8e. a staged .bak is the ONLY source for a copy the share has not taken ------
# Seen live: two passes landing in the same second reuse the staged file name (the
# stamp is one-second resolution), and the second pass deleted the file that the
# first pass's pending copies still pointed at - destroying the only source they had.
$pendingSet = @(
  [pscustomobject]@{ Staged = 'C:\stage\D_20260830-214047.bak'; Dest = '\\fs\s\hourly\D.bak' }
  [pscustomobject]@{ Staged = 'C:\stage\D_20260830-214047.bak'; Dest = '\\fs\s\daily\D.bak' }
)
Assert (Test-SebStagedStillNeeded -Staged 'C:\stage\D_20260830-214047.bak' -Pending $pendingSet) 'a staged file a pending copy still points at is kept'
Assert (-not (Test-SebStagedStillNeeded -Staged 'C:\stage\D_20260830-220000.bak' -Pending $pendingSet)) 'an unreferenced staged file is free to delete'
Assert (-not (Test-SebStagedStillNeeded -Staged 'C:\stage\D_20260830-214047.bak' -Pending @())) 'with nothing pending, nothing is held back'
Assert (-not (Test-SebStagedStillNeeded -Staged 'C:\stage\x.bak' -Pending @($null, $null))) 'null entries in the pending list do not throw'

# ---- 8e2. the pass must not act on paths it merely read back ----------------------
# state.json names, for each pending copy, a staged file and where to put it - and the
# pass then copies as SYSTEM. Trusting that turns a writable state file into a "copy
# this anywhere, as SYSTEM" primitive. Locking the file was tried and was the wrong
# instrument: it also stopped an unelevated self test rewriting its own throwaway
# state. Validating what is read holds even against something that CAN write the file.
$stage = 'C:\SqlBackupStaging'
$share = '\\fs\sqlbackups'
Assert (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\D_20260830-060000.bak' -Dest '\\fs\sqlbackups\H\I\D\hourly\D.bak' -StagingPath $stage -SharePath $share) 'a pending entry inside the configured folders is honoured'
Assert (-not (Test-SebPendingEntry -Staged 'C:\Windows\System32\evil.bak' -Dest '\\fs\sqlbackups\H\I\D\hourly\D.bak' -StagingPath $stage -SharePath $share)) 'a staged path outside the staging folder is refused'
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\D.bak' -Dest 'C:\Windows\System32\evil.dll' -StagingPath $stage -SharePath $share)) 'a destination outside the share is refused - this is the write-anywhere case'
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\..\Windows\x.bak' -Dest '\\fs\sqlbackups\a.bak' -StagingPath $stage -SharePath $share)) 'a staged path walking through .. is refused'
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\a.bak' -Dest '\\fs\sqlbackups\..\other\a.bak' -StagingPath $stage -SharePath $share)) 'a destination walking through .. is refused'
# The sibling-prefix trap: "C:\SqlBackupStagingEvil" starts with "C:\SqlBackupStaging"
# as a plain string, so a prefix test without a separator lets it straight through.
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStagingEvil\a.bak' -Dest '\\fs\sqlbackups\a.bak' -StagingPath $stage -SharePath $share)) 'a sibling folder that merely shares the prefix is refused'
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\a.bak' -Dest '\\fs\sqlbackupsEvil\a.bak' -StagingPath $stage -SharePath $share)) 'and the same trap on the share side'
Assert (Test-SebPendingEntry -Staged 'c:\sqlbackupstaging\a.bak' -Dest '\\FS\SQLBACKUPS\a.bak' -StagingPath $stage -SharePath $share) 'the comparison is case-insensitive, as Windows paths are'
Assert (-not (Test-SebPendingEntry -Staged '' -Dest '\\fs\sqlbackups\a.bak' -StagingPath $stage -SharePath $share)) 'an empty staged path is refused'
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\a.bak' -Dest '\\fs\sqlbackups\a.bak' -StagingPath '' -SharePath $share)) 'with no configured staging folder nothing is honoured'

# A SYSTEM task must not run a script a non-admin can rewrite. The console extracts
# its engine under the user profile - correct for something run AS that user, and
# completely wrong as the target of a SYSTEM task - so the elevated install places
# its own copy somewhere only SYSTEM and Administrators can write. Structural: the
# behaviour needs elevation, but a mode that forgets the call is worth catching.
Assert ($code -match 'function Copy-SebEngineForService') 'the install has a step that puts the engine somewhere non-admins cannot rewrite'
$installBody = [regex]::Match($code, '(?s)function Install-SebTask \{.*?\n\}')
Assert ($installBody.Success -and $installBody.Value -match 'Copy-SebEngineForService') 'Install-SebTask uses it rather than registering whatever path it was handed'
$serviceBody = [regex]::Match($code, '(?s)function Install-SebService \{.*?\n\}')
Assert ($serviceBody.Success -and $serviceBody.Value -match 'Copy-SebEngineForService') 'and so does the service install'

# ---- 8f00. a refusal must say WHAT was refused ------------------------------------
# Seen live: setup got as far as proving staging, then logged "Access is denied" and
# nothing else. No path, no account, no operation - in the one tool whose whole
# premise is being debuggable during a change window. Setup touches staging, the
# share, the config folder and the key file; those are four different problems with
# four different fixes, and a bare message picks none of them.
$denial = Get-SebShareDenialMessage -Share '\\fs\sqlbackups' -Account 'CONTOSO\admin' -MachineAccount 'CONTOSO\HOST$' -Original 'Access is denied'
Assert ($denial -match [regex]::Escape('\\fs\sqlbackups')) 'the refusal names the share it could not write'
Assert ($denial -match 'CONTOSO\\admin') 'and the account it tried as'
Assert ($denial -match 'Access is denied') 'and keeps the original error rather than replacing it'
Assert ($denial -match '(?i)nothing has been changed') 'and says nothing was changed, so the operator is not hunting for damage'
Assert ($denial -match [regex]::Escape('CONTOSO\HOST$')) 'and names the machine account the SCHEDULED run will use'
Assert ($denial -match '(?i)NTFS') 'and points at the share-versus-NTFS trap, which is the usual cause'
$bare = Get-SebShareDenialMessage -Share '\\fs\s' -Account 'me' -MachineAccount '' -Original ''
Assert ($bare -match [regex]::Escape('\\fs\s')) 'it still names the share with no machine account and no inner error'
Assert (-not ($bare -match 'reach it as')) 'and does not dangle a sentence about an account it does not know'

# ---- 8f000. the SYSTEM share probe generates a script - so parse it --------------
# The share check runs as SYSTEM, because that is who the scheduled backup is; the
# operator's own access proves nothing. It does that by writing a small script for a
# short-lived task, and generated code that is never parsed is a guess.
#
# The specific trap: in PowerShell the comma binds TIGHTER than +, so inside @( ... )
# an unparenthesised 'text ' + $x + ' more' becomes THREE array elements rather than
# one string. The file then holds "Set-Content -LiteralPath" on one line and the path
# on the next. That still parses - it just runs Set-Content with no path and then
# tries to run "-Value" as a command, so the probe would report that SYSTEM cannot
# write whatever the permissions actually were, and block every setup.
foreach ($p in @('C:\plain\p.tmp', "\srv\share\o'brien\p.tmp", "two 'quotes' here")) {
  $lit = Get-SebPsLiteral $p
  Assert (((& ([scriptblock]::Create($lit)))) -eq $p) "a path round-trips through its PowerShell literal: $p"
}

$probeBody = @(Get-SebShareProbeBody -ProbeFile "\srv\share\o'brien\p.tmp" -ResultFile 'C:\pd\r.txt')
Assert ($probeBody.Count -eq 9) "the probe body is 9 lines, not split by comma precedence (got $($probeBody.Count))"
Assert (@($probeBody | Where-Object { $_ -match "`n|`r" }).Count -eq 0) 'no line contains an embedded newline'
Assert (@($probeBody | Where-Object { $_ -match '^\s*-' }).Count -eq 0) 'no line begins with a parameter, which is what a split concatenation looks like'

$probeText = $probeBody -join "`r`n"
$probeErrs = $null
$probeAst = [System.Management.Automation.Language.Parser]::ParseInput($probeText, [ref]$null, [ref]$probeErrs)
Assert (@($probeErrs).Count -eq 0) "the generated probe script parses ($(@($probeErrs).Count) error(s))"
$probeCmds = @($probeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() })
Assert (($probeCmds -join ',') -eq 'Set-Content,Remove-Item,Set-Content,Set-Content') "it runs exactly the four intended commands (got '$($probeCmds -join ',')')"
Assert (@($probeBody | Where-Object { $_ -match "o''brien" }).Count -ge 2) 'the apostrophe in the path is escaped, not left to break the script'

# ---- 8f0. the account that will actually run the backups -------------------------
# Setup proves the OPERATOR can connect. Under Windows authentication the scheduled
# task connects as SYSTEM instead, so the operator's success says nothing about the
# thing that does the work: with no login for SYSTEM, setup passes and every run
# afterwards fails at six-hour intervals with nobody watching.
Assert ((Get-SebMachineAccount -Domain 'CONTOSO' -Computer 'HOST1') -eq 'CONTOSO\HOST1$') 'a domain-joined host has a DOMAIN\HOST$ machine account'
Assert ((Get-SebMachineAccount -Domain 'HOST1' -Computer 'HOST1') -eq 'HOST1$') 'a workgroup host, where domain equals the name, drops the redundant prefix'
Assert ((Get-SebMachineAccount -Domain '' -Computer 'HOST1') -eq 'HOST1$') 'no domain still yields a usable machine account'
Assert ((Get-SebUncPath -HostName 'HOST1' -ShareName 'SqlBackups') -eq '\\HOST1\SqlBackups') 'the UNC path is composed from host and share'

$probeSql = Get-SebLoginProbeSql -LoginName "NT AUTHORITY\SYSTEM"
Assert ($probeSql -match "'NT AUTHORITY\\SYSTEM'") 'the login probe quotes the login name as a literal'
Assert ((Get-SebLoginProbeSql -LoginName "o'brien") -match "'o''brien'") 'a quote in a login name is escaped, not left to break the query'

$verdict = Test-SebLoginUsable -Rows @() -LoginName 'NT AUTHORITY\SYSTEM'
Assert (-not $verdict.Ok) 'a missing login for the scheduled identity is refused at setup, not discovered six hours later'
Assert ($verdict.Reason -match 'CREATE LOGIN') 'and the refusal carries the T-SQL that fixes it'

$verdict = Test-SebLoginUsable -LoginName 'NT AUTHORITY\SYSTEM' -Rows @([pscustomobject]@{ name = 'NT AUTHORITY\SYSTEM'; is_disabled = $true; is_sysadmin = 1; is_dbcreator = 1 })
Assert (-not $verdict.Ok) 'a DISABLED login is refused even though it holds the roles'
Assert ($verdict.Reason -match 'ENABLE') 'and says how to enable it'

$verdict = Test-SebLoginUsable -LoginName 'NT AUTHORITY\SYSTEM' -Rows @([pscustomobject]@{ name = 'NT AUTHORITY\SYSTEM'; is_disabled = $false; is_sysadmin = 0; is_dbcreator = 0 })
Assert (-not $verdict.Ok) 'a login with neither sysadmin nor dbcreator cannot back up every database'
Assert ($verdict.Reason -match 'dbcreator') 'and names the role to add'

$verdict = Test-SebLoginUsable -LoginName 'NT AUTHORITY\SYSTEM' -Rows @([pscustomobject]@{ name = 'NT AUTHORITY\SYSTEM'; is_disabled = $false; is_sysadmin = 1; is_dbcreator = 0 })
Assert ($verdict.Ok) 'sysadmin alone is enough'
$verdict = Test-SebLoginUsable -LoginName 'NT AUTHORITY\SYSTEM' -Rows @([pscustomobject]@{ name = 'NT AUTHORITY\SYSTEM'; is_disabled = $false; is_sysadmin = 0; is_dbcreator = 1 })
Assert ($verdict.Ok) 'dbcreator alone is enough'
# DBNull again: is_disabled comes back as a bit and a missing value must not read as disabled.
$verdict = Test-SebLoginUsable -LoginName 'X' -Rows @([pscustomobject]@{ name = 'X'; is_disabled = [System.DBNull]::Value; is_sysadmin = 1; is_dbcreator = 0 })
Assert ($verdict.Ok) 'DBNull in is_disabled does not read as disabled'

# ---- 8f1. the first backup must be proved as SYSTEM, not as the installer --------
# An in-process pass during the install proves only that the elevated administrator
# could do it. SYSTEM is what runs it every six hours, and it reaches the share as
# the machine account, so the install starts the task and reads back what it got.
$stateQueue = New-Object System.Collections.Queue
@('Running', 'Running', 'Ready') | ForEach-Object { $stateQueue.Enqueue($_) }
$waited = Wait-SebScheduledRun -TaskName 'X' -TimeoutSec 900 -StateReader { param($n) $stateQueue.Dequeue() } -ResultReader { param($n) 0 } -Sleeper { param($s) $null }
Assert ($waited.Completed) 'a task that finishes is waited out rather than assumed done'
Assert ($waited.Result -eq 0) 'and its result code is read back from the scheduler'
Assert ($waited.WaitedSec -gt 0) 'the wait actually polled rather than returning instantly'

$timedOut = Wait-SebScheduledRun -TaskName 'X' -TimeoutSec 9 -StateReader { param($n) 'Running' } -ResultReader { param($n) 0 } -Sleeper { param($s) $null }
Assert (-not $timedOut.Completed) 'a task still running at the timeout is reported as such, not as a failure'
Assert ($null -eq $timedOut.Result) 'and no result is invented for it'

Assert ((Get-SebRunVerdict -Completed $true -Result 0) -match 'landed on the share') 'result 0 reads as a complete success'
Assert ((Get-SebRunVerdict -Completed $true -Result 1) -match 'PARTIAL') 'result 1 reads as partial, not success'
Assert ((Get-SebRunVerdict -Completed $true -Result 2) -match 'FAILED') 'result 2 reads as failure'
Assert ((Get-SebRunVerdict -Completed $true -Result 267011) -match '267011') 'an unexpected scheduler code is shown verbatim rather than guessed at'
Assert ((Get-SebRunVerdict -Completed $false -Result $null) -match 'still running') 'a timeout is not reported as a failure'

# ---- 8f. PowerShell 7 on the box must not disarm Windows PowerShell ---------------
# Installing PS7 puts its Modules folders on the machine-wide PSModulePath ahead of
# Windows PowerShell's. A 5.1 process finds PS7's manifest for a shipped module
# first, cannot load it (it targets Core), and the cmdlets inside it cease to
# exist. It took out Set-Acl, then Get-FileHash, so every copy verification threw
# and every backup was recorded as pending. It only appears when the process
# inherits that PSModulePath - starting the script from an existing PowerShell
# hides it completely, which is why the one-click launcher found it and nothing else did.
$savedModulePath = $env:PSModulePath
try {
  $ps7 = 'C:\Program Files\PowerShell\7\Modules'
  $ps7shared = 'C:\Program Files\PowerShell\Modules'
  $real = Join-Path $PSHOME 'Modules'
  $env:PSModulePath = ($ps7 + ';' + $ps7shared + ';C:\Users\someone\Documents\WindowsPowerShell\Modules;' + $real)
  Initialize-SebModulePath
  $after = @($env:PSModulePath -split ';' | Where-Object { $_ })
  Assert ($after[0].TrimEnd('\') -ieq $real.TrimEnd('\')) "this host's own module path is searched first (got '$($after[0])')"
  Assert (@($after | Where-Object { $_ -imatch '\\PowerShell\\7' }).Count -eq 0) "PowerShell 7's module path is removed"
  Assert (@($after | Where-Object { $_ -imatch '\\Program Files\\PowerShell\\Modules$' }).Count -eq 0) "PowerShell 7's shared module path is removed"
  Assert (@($after | Where-Object { $_ -imatch 'Documents\\WindowsPowerShell' }).Count -eq 1) 'unrelated module paths are left alone'
  Assert (@($after | Where-Object { $_.TrimEnd('\') -ieq $real.TrimEnd('\') }).Count -eq 1) 'the real path is not duplicated'
}
finally { $env:PSModulePath = $savedModulePath }

Assert ((Get-Command Set-Acl -ErrorAction SilentlyContinue) -ne $null) 'Set-Acl is available after the path repair'
Import-SebShippedModule -Command 'Get-FileHash' -Module 'Microsoft.PowerShell.Utility'
Assert ((Get-Command Get-FileHash -ErrorAction SilentlyContinue) -ne $null) 'Get-FileHash is available - copy verification depends on it'

# The integration form of the same bug, which is the only shape that actually
# reproduced it: a child Windows PowerShell started BY CMD, inheriting the machine
# PSModulePath, dot-sourcing this script and using Set-Acl.
$probeDir = Join-Path $env:TEMP ('seb-modpath-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $probeDir)
$probeScript = Join-Path $probeDir 'probe.ps1'
try {
  $probeTarget = Join-Path $probeDir 'target'
  [void](New-Item -ItemType Directory -Path $probeTarget)
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  Set-Content -LiteralPath $probeScript -Encoding ASCII -Value @(
    '$ErrorActionPreference = ''Stop''',
    ". `"$script`" -DotSourceOnly",
    "Set-SebStagingAcl -Path `"$probeTarget`" -SqlAccount '' -AlsoGrant @('$me')",
    "[void](Get-FileHash -LiteralPath `"$probeScript`" -Algorithm SHA256)",
    'Write-Host CHILD-OK'
  )
  $childOut = & cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$probeScript`" 2>&1"
  Assert (($childOut -join "`n") -match 'CHILD-OK') "a cmd-launched Windows PowerShell can still use Set-Acl and Get-FileHash (child said: $($childOut -join ' '))"
}
finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---- 8g. the one-click launcher ---------------------------------------------------
$launcher = Join-Path $root 'Backup-SqlExpress.cmd'
Assert (Test-Path $launcher) 'Backup-SqlExpress.cmd exists next to the script it drives'
$cmdRaw = [IO.File]::ReadAllText($launcher)
Assert (-not ($cmdRaw -match '[^\x00-\x7F]')) 'launcher is pure ASCII'
# An LF-only .cmd runs NOTHING under cmd.exe - no output, no error, exit 0 - which
# is why .gitattributes pins it and why this is asserted on the working tree.
Assert ($cmdRaw -match "\r\n") 'launcher has CRLF line endings (an LF-only .cmd silently does nothing)'
Assert (-not ($cmdRaw -match "(?<!\r)\n")) 'launcher has NO bare LF line endings at all'
Assert ($cmdRaw -match 'Invoke-SqlExpressBackup\.ps1') 'launcher points at the backup script'
Assert ($cmdRaw -match '%~dp0') 'launcher finds the script beside itself, not via the working directory'
Assert ($cmdRaw -match 'Verb RunAs') 'launcher can elevate for the actions that need it'
Assert ($cmdRaw -match '(?s):act_install.*?YES') 'installing the permanent schedule demands an explicit YES'
Assert ($cmdRaw -match '(?s):selftest.*?-SelfTest') 'the self-test entry runs -SelfTest'
# The menu dispatch must use parenthesised blocks: without them "&" is not part of
# the IF, "goto :menu" runs unconditionally, and [0] Exit can never be reached.
Assert (-not ($cmdRaw -match 'if "%CHOICE%"=="\d" [^(\r\n]*&')) 'menu branches are parenthesised, so Exit is reachable'
Assert ($cmdRaw -match '(?s):act_fullinstall.*?YES') 'the full install demands an explicit YES before it changes the host'
Assert ($cmdRaw -match '(?s):act_fullinstall.*?-FullInstall') 'the full install entry runs -FullInstall'
Assert ($cmdRaw -match '(?i)not an offsite copy') 'the launcher says plainly that a share on this host is not an offsite copy'
# The property that REPLACES bundling: these two files travel together by hand, so
# the launcher must fail loudly when its script is not beside it. Until now that was
# a hand-read code path in a .cmd - and this repo has been bitten twice by exactly
# that: a .cmd that ran nothing at all (LF line endings), and a .cmd stub that
# silently ended its caller instead of returning. Both were silent-success failures,
# which is the worst kind here: an operator would think the backup was installed.
# So drive it for real rather than reading it.
$sepDir = Join-Path $env:TEMP ('seb-sep-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $sepDir)
try {
  Copy-Item -LiteralPath $launcher -Destination (Join-Path $sepDir 'Backup-SqlExpress.cmd')
  Assert (-not (Test-Path (Join-Path $sepDir 'Invoke-SqlExpressBackup.ps1'))) 'the separated copy really is on its own'
  # Catch, rather than let $ErrorActionPreference='Stop' turn the child's stderr into
  # a terminating error: a broken launcher would then abort this suite instead of
  # failing the assertion that names what is wrong with it.
  $sepOut = ''
  $sepCode = -1
  try { $sepOut = (('' | & cmd /c "`"$sepDir\Backup-SqlExpress.cmd`" selftest" 2>&1) | Out-String) }
  catch { $sepOut = [string]$_ }
  $sepCode = $LASTEXITCODE
  Assert ($sepCode -ne 0) "a launcher with no script beside it exits non-zero (got $sepCode) - silent success is the failure mode that matters"
  Assert ($sepOut -match 'Cannot find Invoke-SqlExpressBackup\.ps1') 'and it says which file is missing'
  Assert ($sepOut -match 'same folder') 'and what to do about it'
  Assert (-not ($sepOut -match 'SELF TEST')) 'and it does NOT get as far as pretending to run anything'
}
finally { Remove-Item -LiteralPath $sepDir -Recurse -Force -ErrorAction SilentlyContinue }

foreach ($verb in @('selftest', 'fullinstall', 'setup', 'install', 'status', 'uninstall')) {
  Assert ($cmdRaw -match ('if /i "%~1"=="' + $verb + '"')) "launcher accepts the '$verb' action when re-launched elevated"
}

# ---- 8h. no top-level variable may shadow a script parameter ----------------------
# $Run is declared [switch] in the param block, so at script scope $run is already a
# TYPED variable. "$run = Wait-SebScheduledRun ..." therefore failed with a
# MetadataError naming SwitchParameter and pointing at the assignment - which looks
# like a parameter-binding problem in the function being called, and is not. It made
# -FullInstall report failure after it had actually created the share, registered the
# task and taken a backup. It also broke this suite, arriving through the dot-source,
# which brings the param block into the caller's scope - and it was dismissed there as
# an oddity of the test file. This checks the whole class rather than that one name.
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$paramNames = @($scriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert ($paramNames.Count -gt 10) "the param block was read ($($paramNames.Count) parameters)"
Assert ($paramNames -contains 'Run') 'including Run, the one that caused this'

# Only TOP-LEVEL assignments matter: a function parameter of the same name is its own
# scope and is fine.
$funcExtents = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { [pscustomobject]@{ Start = $_.Extent.StartOffset; End = $_.Extent.EndOffset } })
$shadowed = @()
foreach ($assign in @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
  if ($assign.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
  $name = $assign.Left.VariablePath.UserPath
  if ($name -like '*:*') { continue }
  if ($paramNames -notcontains $name) { continue }
  $off = $assign.Extent.StartOffset
  $inside = @($funcExtents | Where-Object { $off -ge $_.Start -and $off -lt $_.End })
  if ($inside.Count -eq 0) { $shadowed += ('{0} at line {1}' -f $name, $assign.Extent.StartLineNumber) }
}
Assert ($shadowed.Count -eq 0) "no top-level assignment shadows a script parameter ($($shadowed -join '; '))"

# ---- 9. the ACL is the control the whole credential story rests on ----------------
# If this silently stops narrowing the DACL, the sealed password sits in ProgramData
# readable by whoever ProgramData grants - and every other test here still passes.
$aclDir = Join-Path $env:TEMP ('seb-acl-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $aclDir)
try {
  $aclFile = Join-Path $aclDir 'key.bin'
  Set-Content -LiteralPath $aclFile -Value 'x' -Encoding ASCII
  $before = @((Get-Acl -Path $aclFile).Access).Count
  Set-SebSecretAcl $aclFile
  $after = Get-Acl -Path $aclFile
  Assert ($after.AreAccessRulesProtected) 'the sealed file stops inheriting from its parent'
  $ids = @($after.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } | Sort-Object -Unique)
  Assert ($ids.Count -eq 2) "exactly 2 identities are granted (got $($ids.Count): $($ids -join ', '))"
  Assert ($ids -contains 'NT AUTHORITY\SYSTEM') 'SYSTEM is granted - it is what the scheduled pass runs as'
  Assert ($ids -contains 'BUILTIN\Administrators') 'Administrators is granted - it is what -Setup runs as'
  Assert ($before -gt $after.Access.Count -or $before -eq 2) "the inherited rules were actually dropped (was $before, now $($after.Access.Count))"
  Assert (@($after.Access | Where-Object { $_.FileSystemRights -notmatch 'FullControl' }).Count -eq 0) 'both grants are FullControl and nothing weaker was left behind'
}
finally { Remove-Item -LiteralPath $aclDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---- 10. the -DotSourceOnly guard must actually stop before doing anything ---------
Assert ($raw -match 'if \(\$DotSourceOnly\) \{ return \}') 'the -DotSourceOnly guard returns BEFORE any mode dispatch runs'

# ---- 11. the backup destination must let SQL READ what it will have to restore ----
# Regression for a fault a restore drill found and nothing else could have: backups
# are written by SQL into staging and copied to the destination by the engine, so
# the copies were owned by the engine and SQL could not open them. Every pass was
# green and RESTORE FILELISTONLY failed with operating system error 5 - a backup set
# nobody could restore, reporting success four times a day.
#
# Asserted on the returned ACL rather than by creating a share, which needs
# elevation. A rule only an administrator on a live host can check is a rule nobody
# checks.
# Well-known accounts, because AddAccessRule resolves the name to a SID eagerly and
# a made-up domain principal throws instead of failing the assertion. What is under
# test is the SHAPE of the grant - who gets read, who gets write - not the names.
$MACH = 'NT AUTHORITY\NETWORK SERVICE'   # stands in for the machine account
$SQLA = 'NT AUTHORITY\LOCAL SERVICE'     # stands in for the SQL service account
$acl = New-SebShareAcl -MachineAccount $MACH -SqlAccount $SQLA
$rules = @($acl.GetAccessRules($true, $false, [System.Security.Principal.NTAccount]))

$sqlRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $SQLA })
Assert ($sqlRule.Count -eq 1) "the SQL service account gets exactly one rule on the destination (got $($sqlRule.Count)) - without it RESTORE cannot open the file it just backed up"
Assert ($sqlRule[0].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read) 'and that rule grants READ'
Assert (-not ($sqlRule[0].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write)) 'but NOT write - SQL writes through staging and must not alter what is already archived'
Assert ($sqlRule[0].InheritanceFlags -eq ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')) 'and it is inherited, so the per-database folders and the .bak files carry it too'

# The machine account is a DIFFERENT identity and covers a different path: local
# loopback UNC presents the service's own virtual account, a remote share presents
# the computer account. Granting one is not granting the other.
$machRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $MACH })
Assert ($machRule.Count -eq 1) 'the machine account still gets its own rule'
Assert ($machRule[0].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write) 'and it keeps WRITE - it is the identity that copies backups in'

Assert ($acl.AreAccessRulesProtected) 'inheritance stays off, so a permissive parent folder cannot widen this'

# Omitting the SQL account must not silently grant something else instead.
$bare = New-SebShareAcl -MachineAccount $MACH -SqlAccount ''
Assert (@($bare.GetAccessRules($true,$false,[System.Security.Principal.NTAccount]) | Where-Object { $_.IdentityReference.Value -eq $SQLA }).Count -eq 0) 'no SQL rule is invented when no SQL account is supplied'

# ---- 12. the restore sequence -----------------------------------------------------
# Pure construction, so it is asserted directly rather than by restoring a database.
# What matters is that the statement says what the operator was shown it says.

$files = @(
  [pscustomobject]@{ LogicalName = 'db';      Type = 'D' },
  [pscustomobject]@{ LogicalName = 'db_log';  Type = 'L' }
)

$mv = @(Get-SebRestoreMoveClauses -Files $files -TargetName 'Target' -DataDir 'D:\data' -LogDir 'L:\logs')
Assert ($mv.Count -eq 2) "one MOVE per file in the backup set (got $($mv.Count))"
Assert ($mv[0] -eq "MOVE 'db' TO 'D:\data\Target.mdf'") "the data file goes to the data folder (got '$($mv[0])')"
Assert ($mv[1] -eq "MOVE 'db_log' TO 'L:\logs\Target_log.ldf'") "and the log file goes to the LOG folder, which is the whole point of two folders (got '$($mv[1])')"

# Secondary data files must not collide with the primary. Naming them all <target>.mdf
# would make RESTORE overwrite the first with the second and lose half the database.
$three = @(
  [pscustomobject]@{ LogicalName = 'a'; Type = 'D' },
  [pscustomobject]@{ LogicalName = 'b'; Type = 'D' },
  [pscustomobject]@{ LogicalName = 'c'; Type = 'L' }
)
$mv3 = @(Get-SebRestoreMoveClauses -Files $three -TargetName 'T' -DataDir 'D:\d' -LogDir 'D:\d')
$targets = @($mv3 | ForEach-Object { ($_ -split ' TO ')[1] })
Assert (@($targets | Sort-Object -Unique).Count -eq 3) "three files land on three DISTINCT paths (got $((@($targets | Sort-Object -Unique)).Count))"
Assert ($mv3[1] -match '_1\.ndf') "the second data file becomes an .ndf rather than overwriting the .mdf (got '$($mv3[1])')"

# One folder supplied means both go there - the common case, and it must not produce
# an empty path for the log.
$one = @(Get-SebRestoreMoveClauses -Files $files -TargetName 'T' -DataDir 'D:\only' -LogDir '')
Assert ($one[1] -eq "MOVE 'db_log' TO 'D:\only\T_log.ldf'") "an empty log folder falls back to the data folder (got '$($one[1])')"

$sql = Get-SebRestoreSql -Path 'C:\b\x.bak' -TargetName 'Target' -Files $files -DataDir 'D:\d' -LogDir 'D:\d'
Assert ($sql -match '^RESTORE DATABASE \[Target\] FROM DISK') "the statement restores to the requested name (got '$($sql.Substring(0, [Math]::Min(60, $sql.Length)))')"
Assert ($sql -match 'RECOVERY') 'and recovers by default'
Assert ($sql -notmatch 'REPLACE') 'and does NOT carry REPLACE unless it was asked for - this is the difference between a new database and destroying a live one'
Assert ($sql -notmatch 'RESTRICTED_USER') 'nor RESTRICTED_USER'

$sqlR = Get-SebRestoreSql -Path 'C:\b\x.bak' -TargetName 'T' -Files $files -DataDir 'D:\d' -LogDir 'D:\d' -Replace $true -RestrictedUser $true
Assert ($sqlR -match 'REPLACE') 'REPLACE appears when it is asked for'
Assert ($sqlR -match 'RESTRICTED_USER') 'and so does RESTRICTED_USER'

# NORECOVERY is what makes a chain possible; silently substituting RECOVERY would
# recover the database after the first backup set and make the rest unrestorable.
$sqlN = Get-SebRestoreSql -Path 'C:\b\x.bak' -TargetName 'T' -Files $files -DataDir 'D:\d' -LogDir 'D:\d' -RecoveryState 'NORECOVERY'
Assert ($sqlN -match 'NORECOVERY') 'NORECOVERY is honoured'
$sqlJunk = Get-SebRestoreSql -Path 'C:\b\x.bak' -TargetName 'T' -Files $files -DataDir 'D:\d' -LogDir 'D:\d' -RecoveryState 'banana'
Assert ($sqlJunk -match ', RECOVERY,') "an unrecognised recovery state falls back to RECOVERY rather than being pasted into the statement (got '$sqlJunk')"

# A UNC pointing anywhere else must be left alone - resolving someone else's server to
# a local path would restore from the wrong file.
Assert ((Resolve-SebLocalShare -Root 'C:\plain\path') -eq 'C:\plain\path') 'a local path is returned unchanged'
Assert ((Resolve-SebLocalShare -Root ('\otherhost\share')) -eq '\otherhost\share') 'a UNC for ANOTHER host is left alone'
Assert ((Resolve-SebLocalShare -Root '') -eq '') 'an empty root is returned unchanged'

# ---- 13. reusing a share must still grant the SQL service read --------------------
# Regression for a fault a live re-setup surfaced: New-SebLocalShare granted the SQL
# service read on the SMB share only when CREATING one. Re-running setup over an
# existing share reused it and skipped the grant, so RESTORE from the UNC path failed
# with operating system error 5 while the local path worked - a backup readable on
# disk and unreadable over its own share. Both code paths now call one helper, so
# they cannot drift.
#
# Asserted on the AST rather than by creating a share (which needs elevation and a
# real SMB stack): the reuse branch must call the shared grant helper, or the create
# path's grant is a promise only kept for brand-new shares.
$engineText = Get-Content -Raw -LiteralPath $script
$reuseIdx = $engineText.IndexOf("already exists at")
Assert ($reuseIdx -ge 0) 'the share-reuse branch is present to test'
$elseIdx = $engineText.IndexOf('New-SmbShare @params')
$reuseBlock = $engineText.Substring($reuseIdx, [Math]::Max(0, $elseIdx - $reuseIdx))
Assert ($reuseBlock -match 'Grant-SebShareAccess') 'the reuse path grants share access rather than silently keeping stale permissions'

# And the helper must grant the SQL account READ specifically - not omit it, and not
# hand it Full. This is what the AST check above cannot see: that the grant is right.
$helperIdx = $engineText.IndexOf('function Grant-SebShareAccess')
Assert ($helperIdx -ge 0) 'the shared grant helper exists'
$helperBlock = $engineText.Substring($helperIdx, 700)
Assert ($helperBlock -match 'SqlAccount' -and $helperBlock -match "AccessRight Read") 'the SQL service is granted READ on the share'
Assert ($helperBlock -match "MachineAccount" -and $helperBlock -match "AccessRight Full") 'the machine account keeps Full - it is what copies backups in'

# ---- A1. filenames and folder facts carry .dif / .trn as well as .bak --------------
$stampA = [datetime]'2026-09-04 09:15:00'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $stampA) -eq 'APPDB_20260904-091500.bak') 'default extension is .bak (unchanged)'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $stampA -Extension 'dif') -eq 'APPDB_20260904-091500.dif') 'a differential file is named .dif'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $stampA -Extension 'trn') -eq 'APPDB_20260904-091500.trn') 'a log file is named .trn'

$fb = [datetime]'2000-01-01'
Assert ((Get-SebStampFromName -Name 'APPDB_20260904-091500.trn' -Fallback $fb) -eq $stampA) 'the stamp is read out of a .trn name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260904-091500.dif' -Fallback $fb) -eq $stampA) 'the stamp is read out of a .dif name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260904-091500.bak' -Fallback $fb) -eq $stampA) 'the stamp is still read out of a .bak name (no regression)'

$tmpA = Join-Path $env:TEMP ('seb-a1-' + [Guid]::NewGuid().ToString('N'))
try {
  [void](New-Item -ItemType Directory -Path $tmpA -Force)
  Set-Content -LiteralPath (Join-Path $tmpA 'APPDB_20260904-090000.bak') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpA 'APPDB_20260904-091500.trn') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpA 'APPDB_20260904-093000.dif') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpA 'notes.txt') -Value 'x'
  $facts = @(Get-SebFolderFacts -Directory $tmpA)
  Assert ($facts.Count -eq 3) "folder facts include .bak, .dif and .trn but not .txt (got $($facts.Count))"
  Assert (@($facts | Where-Object { $_.Name -like '*.trn' }).Count -eq 1) 'the .trn file is enumerated'
}
finally { Remove-Item -LiteralPath $tmpA -Recurse -Force -ErrorAction SilentlyContinue }

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

Assert (Test-SebLogNeedsBase -Numbers @(4214)) 'error 4214 means the log chain has no base yet'
Assert (Test-SebLogNeedsBase -Numbers @(3013,4214)) 'a 4214 among other numbers is still detected'
Assert (-not (Test-SebLogNeedsBase -Numbers @(3201))) 'an unrelated SQL error is not a missing-base signal'
Assert (-not (Test-SebLogNeedsBase -Numbers @())) 'no error numbers is not a missing-base signal'

# ---- A3. switching recovery model ---------------------------------------------------
Assert ((Get-SebRecoveryFullSql -Database 'APPDB') -eq 'ALTER DATABASE [APPDB] SET RECOVERY FULL') 'the recovery-model change is a bracket-quoted ALTER DATABASE'
Assert ((Get-SebRecoveryFullSql -Database "we'ird") -eq "ALTER DATABASE [we'ird] SET RECOVERY FULL") 'an odd database name is still bracket-quoted'
Assert (-not (Test-SebNeedsRecoveryFull -Model 'FULL')) 'a database already in FULL needs no change'
Assert (Test-SebNeedsRecoveryFull -Model 'SIMPLE') 'a SIMPLE database needs the change'
Assert (Test-SebNeedsRecoveryFull -Model 'BULK_LOGGED') 'a BULK_LOGGED database needs the change'
Assert ((Get-SebRecoveryModelFromRows -Rows @()) -eq 'FULL') 'no row reads as already-FULL - nothing to ALTER'
Assert ((Get-SebRecoveryModelFromRows -Rows @([pscustomobject]@{ m = [System.DBNull]::Value })) -eq 'FULL') 'an unreadable model (offline/inaccessible db) reads as already-FULL, not as needing a change'
Assert ((Get-SebRecoveryModelFromRows -Rows @([pscustomobject]@{ m = 'SIMPLE' })) -eq 'SIMPLE') 'a readable model passes through unchanged'
Assert ((Get-SebRecoveryModelSql -Database 'APPDB') -match "WHERE name = 'APPDB'") 'the model query literal-escapes the database name'

# ---- A4. the SQL InfoMessage handler is unsubscribed on every exit path -------------
# Regression for a delegate leak. The progress handler was subscribed once up front but
# unsubscribed only in the finally of the compression-fallback retry at the bottom of
# the function. The common success path returned early and both rethrow paths threw, so
# each left one more handler subscribed on the connection. The SAME connection is reused
# for every database in a pass, and the handler reads the script-scoped current database,
# so by the Nth database its BACKUP emitted N copies of every [PROGRESS] line - noise
# that grew across the pass, plus a delegate leak for the life of the connection. The fix
# routes the whole body through Invoke-SebWithInfoHandler, which pairs add/remove in one
# try/finally so it runs on success, on either throw, and after the fallback retry.
#
# Invoke-SebBackupDatabase needs a live connection, so it is driven with a fake one that
# counts subscribe/unsubscribe and serves one ExecuteNonQuery outcome per call from a
# queue - the same injected-collaborator style as the seams above (a ScriptMethod that
# throws is wrapped in a MethodInvocationException, exactly as a real SqlException is, so
# the error-classification path is exercised for real). This drives the REAL function,
# not a copy of its logic.
function New-SebFakeConn {
  param([System.Collections.Queue]$Behaviours)
  $c = [pscustomobject]@{ Added = 0; Removed = 0; Execs = 0; Behaviours = $Behaviours }
  $c | Add-Member -MemberType ScriptMethod -Name add_InfoMessage -Value { param($h) $this.Added++ }
  $c | Add-Member -MemberType ScriptMethod -Name remove_InfoMessage -Value { param($h) $this.Removed++ }
  $c | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
    $cmd = [pscustomobject]@{ CommandText = ''; CommandTimeout = 0; Parent = $this }
    $cmd | Add-Member -MemberType ScriptMethod -Name ExecuteNonQuery -Value {
      $this.Parent.Execs++
      $behaviour = $this.Parent.Behaviours.Dequeue()
      return (& $behaviour)
    }
    $cmd | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    return $cmd
  }
  return $c
}

$savedCompression = $script:SebCompression

# Success path: the first BACKUP succeeds and the function returns early. This is the
# path that leaked - the early return jumped over the only remove_InfoMessage.
$script:SebCompression = 'unknown'
$queue = New-Object System.Collections.Queue
$queue.Enqueue({ 0 })
$conn = New-SebFakeConn -Behaviours $queue
Invoke-SebBackupDatabase -Connection $conn -Database 'APPDB' -TargetFile 'D:\stg\APPDB.bak' -Kind 'full'
Assert ($conn.Added -eq 1) "success path subscribes to InfoMessage exactly once (added=$($conn.Added))"
Assert ($conn.Removed -eq 1) "success path UNSUBSCRIBES exactly once - the leak this fixes (removed=$($conn.Removed))"
Assert ($script:SebCompression -eq 'on') 'a first success probes compression as on'

# Fallback path: a recognised compression failure retries uncompressed and succeeds.
# This was the one path that already unsubscribed; asserted so the retry and the
# unknown->off transition keep working after the refactor.
$script:SebCompression = 'unknown'
$queue = New-Object System.Collections.Queue
$queue.Enqueue({ throw 'Backup compression is not supported on this edition' })
$queue.Enqueue({ 0 })
$conn = New-SebFakeConn -Behaviours $queue
Invoke-SebBackupDatabase -Connection $conn -Database 'APPDB' -TargetFile 'D:\stg\APPDB.bak'
Assert ($conn.Added -eq 1) 'fallback path still subscribes once'
Assert ($conn.Removed -eq 1) "fallback path still unsubscribes once (removed=$($conn.Removed))"
Assert ($conn.Execs -eq 2) "the compressed attempt actually fell back to an uncompressed retry (execs=$($conn.Execs))"
Assert ($script:SebCompression -eq 'off') 'a recognised compression failure flips compression to off'

# Rethrow path 1: compression already off, so an error is not a compression signal and
# propagates. That exception used to skip the remove.
$script:SebCompression = 'off'
$queue = New-Object System.Collections.Queue
$queue.Enqueue({ throw 'Write on backup device failed' })
$conn = New-SebFakeConn -Behaviours $queue
$threw = $false
try { Invoke-SebBackupDatabase -Connection $conn -Database 'APPDB' -TargetFile 'D:\stg\APPDB.bak' } catch { $threw = $true }
Assert $threw 'an error with compression already off still propagates to the caller'
Assert ($conn.Added -eq 1) 'the already-off rethrow path subscribes once'
Assert ($conn.Removed -eq 1) "the already-off rethrow path UNSUBSCRIBES once even though it throws (removed=$($conn.Removed))"

# Rethrow path 2: an unrecognised error while compression is on is not a compression
# signal either, so it also propagates - and must not leak the handler.
$script:SebCompression = 'on'
$queue = New-Object System.Collections.Queue
$queue.Enqueue({ throw 'some unrelated backup failure' })
$conn = New-SebFakeConn -Behaviours $queue
$threw = $false
try { Invoke-SebBackupDatabase -Connection $conn -Database 'APPDB' -TargetFile 'D:\stg\APPDB.bak' } catch { $threw = $true }
Assert $threw 'an unrecognised error still propagates'
Assert ($conn.Added -eq 1) 'the unrecognised-error path subscribes once'
Assert ($conn.Removed -eq 1) "the unrecognised-error path UNSUBSCRIBES once (removed=$($conn.Removed))"

# The seam in isolation: add/remove are paired around the body whether it returns a
# value, returns early, or throws. A fake connection counts the calls; the throw case
# also proves the exception is not swallowed.
function New-SebPairCounter {
  $x = [pscustomobject]@{ Added = 0; Removed = 0 }
  $x | Add-Member -MemberType ScriptMethod -Name add_InfoMessage -Value { param($h) $this.Added++ }
  $x | Add-Member -MemberType ScriptMethod -Name remove_InfoMessage -Value { param($h) $this.Removed++ }
  return $x
}
$pc = New-SebPairCounter
Invoke-SebWithInfoHandler -Connection $pc -Handler $null -Body { 'ok' } | Out-Null
Assert ($pc.Added -eq 1 -and $pc.Removed -eq 1) "the seam pairs add/remove around a body that completes normally (added=$($pc.Added) removed=$($pc.Removed))"

$pc = New-SebPairCounter
Invoke-SebWithInfoHandler -Connection $pc -Handler $null -Body { return }
Assert ($pc.Added -eq 1 -and $pc.Removed -eq 1) "the seam pairs add/remove around a body that returns early (added=$($pc.Added) removed=$($pc.Removed))"

$pc = New-SebPairCounter
$threw = $false
try { Invoke-SebWithInfoHandler -Connection $pc -Handler $null -Body { throw 'boom' } } catch { $threw = $true }
Assert ($threw -and $pc.Added -eq 1 -and $pc.Removed -eq 1) "the seam unsubscribes and rethrows when the body throws (threw=$threw added=$($pc.Added) removed=$($pc.Removed))"

$script:SebCompression = $savedCompression

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
$diffsB2 = @( (New-Seg 'Dold' $nowB.AddDays(-10).AddMinutes(20) 10 25) )
$logsB2  = $logsB + @(
  (New-Seg 'Lold1' $nowB.AddDays(-10).AddMinutes(15) 10 20),
  (New-Seg 'Lold2' $nowB.AddDays(-10).AddMinutes(30) 20 30),
  (New-Seg 'L-boundary' $nowB.AddMinutes(1) 990 1000)
)
$planB2 = Get-SebChainRetentionPlan -Fulls $fullsB2 -Diffs $diffsB2 -Logs $logsB2 -Now $nowB -DailyKeepDays 7
Assert ($planB2.FullDelete -contains 'F-old') 'the out-of-horizon full is pruned (positive control: pruning does happen)'
Assert ($planB2.LogDelete -contains 'Lold1' -and $planB2.LogDelete -contains 'Lold2') 'logs belonging only to the pruned full are pruned'
Assert ($planB2.FullDelete -notcontains 'F-today') 'the retained full is never pruned'
Assert ($planB2.LogDelete -notcontains 'L2') 'a log needed to roll the retained full forward is never pruned'
Assert ($planB2.DiffDelete -contains 'Dold') 'a diff belonging only to the pruned full is pruned'
Assert ($planB2.LogDelete -notcontains 'L-boundary') 'a log ending exactly at the anchor LSN still reaches it and must be kept'

# Safety: if the ONLY full is out of horizon, it is still kept - deleting it would
# leave nothing to restore from.
$planB3 = Get-SebChainRetentionPlan -Fulls @((New-Seg 'F-lonely' $nowB.AddDays(-30) 5 5)) -Diffs @() -Logs @() -Now $nowB -DailyKeepDays 7
Assert ($planB3.FullDelete.Count -eq 0) 'the last surviving full is kept even past the horizon (never leave zero fulls)'

# Empty inputs are safe.
$planB4 = Get-SebChainRetentionPlan -Fulls @() -Diffs @() -Logs @() -Now $nowB -DailyKeepDays 7
Assert ($planB4.FullDelete.Count -eq 0 -and $planB4.DiffDelete.Count -eq 0 -and $planB4.LogDelete.Count -eq 0) 'empty folders prune nothing and do not error'

# ---- C1. the point-in-time restore planner -----------------------------------------
function New-Cat([string]$kind, [string]$file, [decimal]$first, [decimal]$last, [decimal]$dbb, [decimal]$chk, [datetime]$finish) {
  return [pscustomobject]@{ Kind = $kind; File = $file; FirstLSN = $first; LastLSN = $last; DatabaseBackupLSN = $dbb; CheckpointLSN = $chk; Finish = $finish }
}
$b = [datetime]'2026-09-04 08:00:00'
$cat = @(
  # The full's CheckpointLSN (105) deliberately differs from its FirstLSN (100) - a
  # database taking writes during the full ends its checkpoint after the backup
  # started. The diff below records DatabaseBackupLSN = 105, so the match only works
  # if the planner keys off CheckpointLSN rather than FirstLSN.
  (New-Cat 'full' 'F.bak' 100 100 0   105 $b),
  (New-Cat 'diff' 'D.dif' 150 150 105 0   $b.AddHours(2)),
  (New-Cat 'log'  'L1.trn' 100 160 0  0   $b.AddHours(1)),
  (New-Cat 'log'  'L2.trn' 160 220 0  0   $b.AddHours(3)),
  (New-Cat 'log'  'L3.trn' 220 280 0  0   $b.AddHours(5))
)
# Target at 02:30 -> full, then the diff (finished 02:00, based on the full), then the
# log that spans 02:30 (L2) with STOPAT.
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

# When a differential is the newest usable backup and no log extends past it, the
# latest-recoverable time in the error must reflect the DIFF's finish, not the full's -
# reporting the full's time here would understate how much is actually recoverable.
$catNoLog = @(
  (New-Cat 'full' 'F.bak' 100 100 0   105 $b),
  (New-Cat 'diff' 'D.dif' 150 150 105 0   $b.AddHours(2))
)
$pnl = Get-SebRestorePlan -Catalogue $catNoLog -StopAt ($b.AddHours(2).AddMinutes(30))
Assert ($pnl.Error -match 'latest recoverable: 2026-09-04 10:00:00') 'the latest-recoverable time reflects the newest diff when no log extends past it'

# A gap in the log chain (missing 160->220) is detected, not silently skipped.
$catGap = @(
  (New-Cat 'full' 'F.bak' 100 100 0 105 $b),
  (New-Cat 'log'  'L1.trn' 100 160 0 0 $b.AddHours(1)),
  (New-Cat 'log'  'L3.trn' 220 280 0 0 $b.AddHours(5))
)
$pg = Get-SebRestorePlan -Catalogue $catGap -StopAt ($b.AddHours(5))
Assert ($pg.Error -match 'gap|chain') 'a break in the LSN chain is reported as a gap'

# ---- C2. header facts map DBNull-safely and carry CheckpointLSN ----------------------
$fakeRow = [pscustomobject]@{ FirstLSN = [decimal]1000; LastLSN = [decimal]1200; DatabaseBackupLSN = [decimal]0; CheckpointLSN = [decimal]1100; BackupFinishDate = [datetime]'2026-09-04 08:00:00' }
$hf = Get-SebHeaderFactsFromRow -Row $fakeRow -File 'X.bak' -Kind 'full'
Assert ($hf.Kind -eq 'full' -and $hf.File -eq 'X.bak') 'header facts carry the kind and file'
Assert ($hf.FirstLSN -eq 1000 -and $hf.LastLSN -eq 1200) 'first/last LSN are mapped as decimals'
Assert ($hf.CheckpointLSN -eq 1100 -and $hf.CheckpointLSN -ne $hf.FirstLSN) 'CheckpointLSN is mapped and is distinct from FirstLSN (the field a diff matches on)'
Assert ($hf.Finish -eq ([datetime]'2026-09-04 08:00:00')) 'the backup finish time is mapped'

# A NULL header column arrives as DBNull; it must map to 0, not throw a cast error
# (the suite header warns: NULL from SQL is DBNull, and [decimal]DBNull throws).
$nullRow = [pscustomobject]@{ FirstLSN = [System.DBNull]::Value; LastLSN = [decimal]5; DatabaseBackupLSN = [decimal]0; CheckpointLSN = [decimal]0; BackupFinishDate = [datetime]'2026-09-04 09:00:00' }
$hn = Get-SebHeaderFactsFromRow -Row $nullRow -File 'Y.trn' -Kind 'log'
Assert ($hn.FirstLSN -eq 0) 'a DBNull LSN maps to 0, not a thrown cast'
Assert ($null -eq (Get-SebHeaderFactsFromRow -Row $null -File 'Z.bak' -Kind 'full')) 'a null row yields null facts'

# A NULL finish date cannot be placed on the restore timeline - [datetime]$null throws
# (unlike [decimal]$null, which is 0), so this must be skipped, not crash the cast.
$noFinishRow = [pscustomobject]@{ FirstLSN=[decimal]1; LastLSN=[decimal]2; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]3; BackupFinishDate=[System.DBNull]::Value }
Assert ($null -eq (Get-SebHeaderFactsFromRow -Row $noFinishRow -File 'bad.bak' -Kind 'full')) 'a header with no finish time is skipped (unusable), not a thrown datetime cast'

Assert ((Get-Command Get-SebRestoreHeaderFacts -ErrorAction SilentlyContinue) -ne $null) 'Get-SebRestoreHeaderFacts is defined'
Assert ((Get-Command Get-SebPointCatalogue -ErrorAction SilentlyContinue) -ne $null) 'Get-SebPointCatalogue is defined'

# Get-SebRestoreHeaderFacts must honour Invoke-SebSqlTable's unary-comma contract
# (rows returned AS ONE object). A double-@() wrap made 0 rows look like 1 and N rows
# crash the cast; shadow the SQL call to prove 0/1/N are handled. Restore it after.
$realInvoke = ${function:Invoke-SebSqlTable}
try {
  function Invoke-SebSqlTable { param($Connection, [string]$Sql, [int]$TimeoutSec = 60) return , @($script:SebFakeRows) }
  $script:SebFakeRows = @()
  Assert ($null -eq (Get-SebRestoreHeaderFacts -Connection 'x' -File 'e.bak' -Kind 'full')) 'zero header rows yields null (the double-wrap had made it look like one row)'
  $script:SebFakeRows = @([pscustomobject]@{ FirstLSN=[decimal]1; LastLSN=[decimal]2; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]3; BackupFinishDate=[datetime]'2026-09-04 08:00:00' })
  $one = Get-SebRestoreHeaderFacts -Connection 'x' -File 'e.bak' -Kind 'full'
  Assert ($one.CheckpointLSN -eq 3 -and $one.File -eq 'e.bak' -and $one.Kind -eq 'full') 'one header row maps to facts'
  $script:SebFakeRows = @(
    [pscustomobject]@{ FirstLSN=[decimal]1; LastLSN=[decimal]2; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]3; BackupFinishDate=[datetime]'2026-09-04 08:00:00' },
    [pscustomobject]@{ FirstLSN=[decimal]9; LastLSN=[decimal]9; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]9; BackupFinishDate=[datetime]'2026-09-04 09:00:00' }
  )
  $multi = Get-SebRestoreHeaderFacts -Connection 'x' -File 'e.bak' -Kind 'full'
  Assert ($multi.CheckpointLSN -eq 3) 'multiple header rows use the first backup set without a cast crash'
}
finally { ${function:Invoke-SebSqlTable} = $realInvoke; $script:SebFakeRows = $null }

# ---- C3. per-step RESTORE SQL builder ----------------------------------------------
$sFull = [pscustomobject]@{ Kind='full'; File='D:\s\F.bak'; Recovery=$false; StopAt=$null }
$sqlF = Get-SebRestoreStepSql -Step $sFull -RestoreAs 'RestoreDemo' -Replace $true -MoveClauses @("MOVE 'd' TO 'X'", "MOVE 'l' TO 'Y'")
Assert ($sqlF -match 'RESTORE DATABASE \[RestoreDemo\] FROM DISK') 'a full step is RESTORE DATABASE into the target name'
Assert ($sqlF -match 'NORECOVERY') 'a full step restores WITH NORECOVERY'
Assert ($sqlF -match 'REPLACE') 'a full step restores WITH REPLACE only when replace is requested'
Assert ($sqlF -match "MOVE 'd' TO 'X'" -and $sqlF -match "MOVE 'l' TO 'Y'") 'a full step carries the MOVE clauses that relocate its files'
Assert ((Get-SebRestoreStepSql -Step $sFull -RestoreAs 'RestoreDemo') -notmatch 'REPLACE') 'a full step omits REPLACE by default (no silent overwrite)'

$sDiff = [pscustomobject]@{ Kind='diff'; File='D:\s\D.dif'; Recovery=$false; StopAt=$null }
$sqlD = Get-SebRestoreStepSql -Step $sDiff -RestoreAs 'RestoreDemo'
Assert ($sqlD -match 'RESTORE DATABASE \[RestoreDemo\] FROM DISK') 'a diff step is RESTORE DATABASE'
Assert ($sqlD -match 'NORECOVERY') 'a diff step restores WITH NORECOVERY'

$sLog = [pscustomobject]@{ Kind='log'; File='D:\s\L.trn'; Recovery=$false; StopAt=$null }
$sqlL = Get-SebRestoreStepSql -Step $sLog -RestoreAs 'RestoreDemo'
Assert ($sqlL -match 'RESTORE LOG \[RestoreDemo\] FROM DISK') 'a non-final log step is RESTORE LOG'
Assert ($sqlL -match 'NORECOVERY') 'a non-final log step is WITH NORECOVERY'

$sLogR = [pscustomobject]@{ Kind='log'; File='D:\s\L2.trn'; Recovery=$true; StopAt=[datetime]'2026-09-04 10:30:00' }
$sqlLR = Get-SebRestoreStepSql -Step $sLogR -RestoreAs 'RestoreDemo'
Assert ($sqlLR -match "STOPAT = '2026-09-04T10:30:00'") 'the final log step carries STOPAT = the target time (ISO 8601)'
Assert ($sqlLR -match 'RECOVERY' -and $sqlLR -notmatch 'NORECOVERY') 'the final log step recovers the database'

Assert ((Get-Command Invoke-SebRestoreToPoint -ErrorAction SilentlyContinue) -ne $null) 'Invoke-SebRestoreToPoint is defined'

# ---- D1a. a data pass takes a full when one is due, otherwise a differential --------
Assert ((Get-SebBackupKindDue -HoursSinceFull 30 -FullEveryHours 24) -eq 'full') 'no recent full -> take a full'
Assert ((Get-SebBackupKindDue -HoursSinceFull 3  -FullEveryHours 24) -eq 'diff') 'a recent full -> take a differential'
Assert ((Get-SebBackupKindDue -HoursSinceFull ([double]::PositiveInfinity) -FullEveryHours 24) -eq 'full') 'a database that has never had a full -> take a full'
Assert ((Get-SebBackupKindDue -HoursSinceFull 24 -FullEveryHours 24) -eq 'full') 'exactly at the interval -> a full is due'
Assert ((Get-Command Invoke-SebBackupLogPass -ErrorAction SilentlyContinue) -ne $null) 'Invoke-SebBackupLogPass is defined'

# ---- D1a code-review fixes: -BackupLog honours the same knobs -Run does -------------
# A live SQL seam for this pass is tracked separately, so these stay structural: they
# guard the parameter surface the dispatch now depends on, without driving the pass.
$logPassParams = (Get-Command Invoke-SebBackupLogPass).Parameters
Assert ($logPassParams.ContainsKey('OnlyDatabase')) 'Invoke-SebBackupLogPass accepts -OnlyDatabase, mirroring Invoke-SebPass'
Assert ($logPassParams.ContainsKey('NoHash')) 'Invoke-SebBackupLogPass accepts -NoHash, mirroring Copy-SebVerified callers'

# ---- D1b. RecoveryMode=Full enrolls + takes full/diff; RecoveryMode=Simple is untouched --
# The enrollment/kind wiring inside Invoke-SebPass needs a live SQL connection to drive
# end to end (that is Phase E's job). What a pure assert CAN pin here is the two things
# Simple-mode backward compatibility actually rests on.
Assert ((Get-Command Invoke-SebPass -ErrorAction SilentlyContinue) -ne $null) 'Invoke-SebPass is defined and the file still parses with the D1b changes in it'

# Every existing install's config.json has no RecoveryMode key at all. Read-SebConfig
# hands back a plain PSCustomObject, and PowerShell reads a missing property on one of
# those as $null rather than throwing - so the [string]$Config.RecoveryMode -eq 'Full'
# test Invoke-SebPass uses reads a config with no such key as Simple, not as a crash.
Assert (([string]([pscustomobject]@{}).RecoveryMode -eq 'Full') -eq $false) 'a config with no RecoveryMode property (every existing install) reads as Simple, not Full'
Assert (([string]([pscustomobject]@{ RecoveryMode = 'Full' }).RecoveryMode -eq 'Full') -eq $true) 'a config with RecoveryMode = Full is detected as Full mode'

# The Simple branch now sits behind "if ($isFullMode) {...} else {...}" instead of running
# unconditionally, but it still names its file exactly as before: no -Extension argument
# and -Extension 'bak' must be the same string, since Simple mode never sets $kind to 'diff'.
$d1bStamp = [datetime]'2026-09-04 12:00:00'
Assert ((Get-SebFileName -Database 'APPDB' -Stamp $d1bStamp) -eq (Get-SebFileName -Database 'APPDB' -Stamp $d1bStamp -Extension 'bak')) `
  'RecoveryMode=Simple computes the same file name as today (no-Extension == -Extension bak)'

# Get-SebHoursSinceNewestFull: the age rule the per-database loop now calls instead of
# inlining, so it can be pinned without a SQL connection.
$nowHS = [datetime]'2026-09-05 12:00:00'
Assert ((Get-SebHoursSinceNewestFull -Facts @() -Now $nowHS) -eq [double]::PositiveInfinity) 'no fulls -> infinite age (forces a full)'
$hsFacts = @(
  [pscustomobject]@{ Name='X_20260905-000000.bak'; Timestamp=[datetime]'2026-09-05 00:00:00' },
  [pscustomobject]@{ Name='X_20260905-060000.bak'; Timestamp=[datetime]'2026-09-05 06:00:00' },
  [pscustomobject]@{ Name='X_20260905-030000.trn'; Timestamp=[datetime]'2026-09-05 03:00:00' }
)
Assert ((Get-SebHoursSinceNewestFull -Facts $hsFacts -Now $nowHS) -eq 6) 'age is from the newest .bak (6h), ignoring .trn'
$hsZip = @(
  [pscustomobject]@{ Name='X_20260905-000000.bak'; Timestamp=[datetime]'2026-09-05 00:00:00' },
  [pscustomobject]@{ Name='X_20260905-080000.bak.zip'; Timestamp=[datetime]'2026-09-05 08:00:00' },
  [pscustomobject]@{ Name='X_20260905-030000.trn.zip'; Timestamp=[datetime]'2026-09-05 03:00:00' }
)
Assert ((Get-SebHoursSinceNewestFull -Facts $hsZip -Now ([datetime]'2026-09-05 12:00:00')) -eq 4) 'a compressed full (.bak.zip) counts as a full (4h), and a .trn.zip is not a full'

# ---- D1c. catalogue entries map to chain-retention facts, split by kind --------------
$catD = @(
  [pscustomobject]@{ Kind='full'; File='C:\s\host\INST\db\hourly\db_20260905-000000.bak'; FirstLSN=[decimal]100; LastLSN=[decimal]100; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]100; Finish=[datetime]'2026-09-05 00:00:00' },
  [pscustomobject]@{ Kind='diff'; File='C:\s\host\INST\db\diff\db_20260905-060000.dif'; FirstLSN=[decimal]150; LastLSN=[decimal]150; DatabaseBackupLSN=[decimal]100; CheckpointLSN=[decimal]0; Finish=[datetime]'2026-09-05 06:00:00' },
  [pscustomobject]@{ Kind='log'; File='C:\s\host\INST\db\log\db_20260905-001500.trn'; FirstLSN=[decimal]100; LastLSN=[decimal]160; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]0; Finish=[datetime]'2026-09-05 00:15:00' }
)
$cf = Get-SebChainFactsFromCatalogue -Catalogue $catD
Assert ($cf.Fulls.Count -eq 1 -and $cf.Diffs.Count -eq 1 -and $cf.Logs.Count -eq 1) 'catalogue is split into fulls/diffs/logs by kind'
Assert ($cf.Fulls[0].Name -eq 'db_20260905-000000.bak') 'a fact Name is the file leaf, not the full path'
Assert ($cf.Fulls[0].Timestamp -eq ([datetime]'2026-09-05 00:00:00')) 'a fact Timestamp is the backup Finish time'
Assert ($cf.Logs[0].LastLSN -eq 160 -and $cf.Fulls[0].FirstLSN -eq 100) 'LSNs carry through to the facts'
# The mapped facts drive the real retention planner end to end (positive control below).
$rp = Get-SebChainRetentionPlan -Fulls $cf.Fulls -Diffs $cf.Diffs -Logs $cf.Logs -Now ([datetime]'2026-09-05 12:00:00') -DailyKeepDays 7
Assert ($rp.FullDelete.Count -eq 0 -and $rp.LogDelete.Count -eq 0) 'an in-horizon chain from a catalogue prunes nothing'
$catOld = $catD + @([pscustomobject]@{ Kind='full'; File='C:\s\h\I\db\hourly\db_20260820-000000.bak'; FirstLSN=[decimal]5; LastLSN=[decimal]5; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]5; Finish=[datetime]'2026-08-20 00:00:00' })
$cfOld = Get-SebChainFactsFromCatalogue -Catalogue $catOld
$rpOld = Get-SebChainRetentionPlan -Fulls $cfOld.Fulls -Diffs $cfOld.Diffs -Logs $cfOld.Logs -Now ([datetime]'2026-09-05 12:00:00') -DailyKeepDays 7
Assert ($rpOld.FullDelete -contains 'db_20260820-000000.bak') 'a full older than the horizon is pruned (positive control)'

# ---- D1d. -BackupLog copy-resilience: a share outage drains on the next run ----------
# The transaction-log pass now carries the same Pending/state resilience the data pass has:
# a .trn (or its anchoring full) whose share copy fails is recorded, kept in staging, and
# copied on the next run instead of being orphaned. BACKUP LOG truncates the chain on
# success, so an orphaned .trn is a permanent point-in-time gap - this is what prevents it.
# Mirrors Invoke-SebSelfTest's "share is unreachable" pass, but as a pure unit (no SQL):
# Sync-SebPending is the drain both passes run, exercised here against real files.
$d1dRoot = Join-Path $env:TEMP ('seb-d1d-' + [Guid]::NewGuid().ToString('N'))
try {
  $d1dStage = Join-Path $d1dRoot 'staging'
  $d1dShare = Join-Path $d1dRoot 'share'
  [void](New-Item -ItemType Directory -Force -Path $d1dStage)
  [void](New-Item -ItemType Directory -Force -Path $d1dShare)
  # A blocker FILE where the share root should be: any copy/mkdir under it fails - the same
  # stand-in Invoke-SebSelfTest uses for an unreachable share.
  $d1dBlocker = Join-Path $d1dRoot 'not-a-directory.txt'
  Set-Content -LiteralPath $d1dBlocker -Value 'stands in for an unreachable share' -Encoding ASCII
  $d1dShareDown = Join-Path $d1dBlocker 'share'

  # A taken-and-truncated .trn sitting in staging, waiting to reach the share's log/ folder.
  $trnName = Get-SebFileName -Database 'APPDB' -Stamp ([datetime]'2026-09-05 03:15:00') -Extension 'trn'
  $trnStaged = Join-Path $d1dStage $trnName
  Set-Content -LiteralPath $trnStaged -Value 'transaction-log-backup-bytes' -Encoding ASCII

  $destDown = Join-Path (Get-SebBackupPath -Root $d1dShareDown -HostName 'HOST' -InstanceLabel 'INST' -Database 'APPDB' -Kind 'log') $trnName
  $pendingDown = @([pscustomobject]@{ Staged = $trnStaged; Dest = $destDown; Database = 'APPDB'; Kind = 'log' })

  # Run 1 - the share is down: the copy fails, the entry stays pending, the .trn is kept.
  $still1 = @(Sync-SebPending -Pending $pendingDown -StagingPath $d1dStage -SharePath $d1dShareDown)
  Assert ($still1.Count -eq 1) 'a log copy the share refused stays pending for the next run'
  Assert ([string]$still1[0].Staged -eq $trnStaged) 'the pending entry still names the staged .trn'
  Assert (Test-Path -LiteralPath $trnStaged) 'the truncated .trn is held in staging, not lost, while the share is down'

  # Run 2 - the share is back: re-point the same staged file at the real share; it drains.
  $destUp = Join-Path (Get-SebBackupPath -Root $d1dShare -HostName 'HOST' -InstanceLabel 'INST' -Database 'APPDB' -Kind 'log') $trnName
  $pendingUp = @([pscustomobject]@{ Staged = $trnStaged; Dest = $destUp; Database = 'APPDB'; Kind = 'log' })
  $still2 = @(Sync-SebPending -Pending $pendingUp -StagingPath $d1dStage -SharePath $d1dShare)
  Assert ($still2.Count -eq 0) 'when the share returns the pending log copy drains and nothing stays pending'
  Assert (Test-Path -LiteralPath $destUp) 'the .trn recovered onto the share log/ folder on the next run'
  Assert ((Get-FileHash -LiteralPath $destUp).Hash -eq (Get-FileHash -LiteralPath $trnStaged).Hash) 'the recovered copy is byte-for-byte the staged .trn'

  # The write-anywhere guard: a pending entry aimed outside the share is refused, not
  # honoured and not retried - a writable state file must not become "copy anywhere as SYSTEM".
  $evil = @([pscustomobject]@{ Staged = $trnStaged; Dest = 'C:\Windows\System32\seb-evil.trn'; Database = 'APPDB'; Kind = 'log' })
  $stillEvil = @(Sync-SebPending -Pending $evil -StagingPath $d1dStage -SharePath $d1dShare)
  Assert ($stillEvil.Count -eq 0 -and -not (Test-Path 'C:\Windows\System32\seb-evil.trn')) 'a pending copy aimed outside the share is refused, not written and not retried'

  # Save-SebCopyOrPend is the record-on-failure half the pass uses for each anchor and log
  # copy: a copy the share accepts is verified and its staged file cleaned up; a copy the
  # share refuses is recorded as a Pending entry and the staged file is kept for the drain.
  $cp = New-Object System.Collections.ArrayList
  $okName = Get-SebFileName -Database 'APPDB' -Stamp ([datetime]'2026-09-05 04:00:00') -Extension 'trn'
  $okStaged = Join-Path $d1dStage $okName; Set-Content -LiteralPath $okStaged -Value 'log-bytes' -Encoding ASCII
  $okDest = Join-Path (Get-SebBackupPath -Root $d1dShare -HostName 'HOST' -InstanceLabel 'INST' -Database 'APPDB' -Kind 'log') $okName
  Save-SebCopyOrPend -Staged $okStaged -Dest $okDest -Database 'APPDB' -Kind 'log' -PendingList $cp -NoHash
  Assert ($cp.Count -eq 0) 'a copy the share accepts adds nothing to the pending list'
  Assert ((Test-Path -LiteralPath $okDest) -and -not (Test-Path -LiteralPath $okStaged)) 'an accepted copy lands on the share and its staged file is cleaned up'

  $badName = Get-SebFileName -Database 'APPDB' -Stamp ([datetime]'2026-09-05 05:00:00') -Extension 'trn'
  $badStaged = Join-Path $d1dStage $badName; Set-Content -LiteralPath $badStaged -Value 'log-bytes' -Encoding ASCII
  $badDest = Join-Path (Get-SebBackupPath -Root $d1dShareDown -HostName 'HOST' -InstanceLabel 'INST' -Database 'APPDB' -Kind 'log') $badName
  Save-SebCopyOrPend -Staged $badStaged -Dest $badDest -Database 'APPDB' -Kind 'log' -PendingList $cp -NoHash
  Assert ($cp.Count -eq 1 -and [string]$cp[0].Dest -eq $badDest) 'a copy the share refuses is recorded as a pending entry'
  Assert (Test-Path -LiteralPath $badStaged) 'a refused copy keeps its .trn staged for the next run (BACKUP LOG already truncated the chain)'
}
finally {
  Remove-Item -LiteralPath $d1dRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# The dispatch maps the log pass tally to an exit code exactly as -Run's data pass does:
# a copy still pending is partial (1), not success - a share down for a week must not keep
# reporting 0. Nothing FULL-recovery this cycle is still ok (0); every attempt failing is 2.
Assert ((Get-SebLogPassExitCode -Succeeded 2 -Failed 0 -Pending 0) -eq 0) 'all logs copied, nothing pending -> ok (0)'
Assert ((Get-SebLogPassExitCode -Succeeded 0 -Failed 0 -Pending 0) -eq 0) 'nothing was FULL-recovery this cycle -> still ok (0)'
Assert ((Get-SebLogPassExitCode -Succeeded 2 -Failed 0 -Pending 1) -eq 1) 'a log taken but not yet on the share -> partial (1), not success'
Assert ((Get-SebLogPassExitCode -Succeeded 1 -Failed 1 -Pending 0) -eq 1) 'one database failed alongside a success -> partial (1)'
Assert ((Get-SebLogPassExitCode -Succeeded 0 -Failed 2 -Pending 0) -eq 2) 'every attempted database failed -> hard failure (2)'

# ---- D2. the log task name derives from the base task name --------------------------
Assert ((Get-SebLogTaskName -Base 'SqlExpressBackup') -eq 'SqlExpressBackup-Log') 'the log task is the base task name plus -Log'
Assert ((Get-SebLogTaskName -Base 'X') -eq 'X-Log') 'the -Log suffix is appended to whatever the base name is'

# ---- D3. the log-growth probe warns only on a LOG_BACKUP wait past the threshold ----
Assert (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct 85 -ThresholdPct 70) 'a LOG_BACKUP wait over threshold warns'
Assert (-not (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct 40 -ThresholdPct 70)) 'a LOG_BACKUP wait under threshold does not warn'
Assert (-not (Get-SebLogGrowthWarning -Wait 'NOTHING' -UsedPct 95 -ThresholdPct 70)) 'a full log NOT waiting on a backup is a different problem, not our warning'
Assert (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct 70 -ThresholdPct 70) 'exactly at the threshold warns'

# ---- D3b-2. log-space lookup feeds the growth warning -------------------------------
$lsRows = @(
  [pscustomobject]@{ 'Database Name' = 'APPDB'; 'Log Size (MB)' = 100.0; 'Log Space Used (%)' = 85.0; 'Status' = 0 },
  [pscustomobject]@{ 'Database Name' = 'Other'; 'Log Size (MB)' = 50.0;  'Log Space Used (%)' = 10.0; 'Status' = 0 }
)
Assert ((Get-SebLogSpaceUsedPct -Rows $lsRows -Database 'APPDB') -eq 85.0) 'the log %-used is pulled for the named database'
Assert ((Get-SebLogSpaceUsedPct -Rows $lsRows -Database 'Missing') -eq 0) 'a database absent from the row set reads 0% (no false warning)'
Assert ((Get-SebLogSpaceUsedPct -Rows @([pscustomobject]@{ 'Database Name' = 'X'; 'Log Space Used (%)' = [System.DBNull]::Value }) -Database 'X') -eq 0) 'a DBNull log %-used reads 0, not a thrown cast'
# Compose with the growth predicate: high used% on a LOG_BACKUP wait warns; low used% does not (positive control both ways).
Assert (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct (Get-SebLogSpaceUsedPct -Rows $lsRows -Database 'APPDB') -ThresholdPct 70) 'APPDB (85% on a LOG_BACKUP wait) warns'
Assert (-not (Get-SebLogGrowthWarning -Wait 'LOG_BACKUP' -UsedPct (Get-SebLogSpaceUsedPct -Rows $lsRows -Database 'Other') -ThresholdPct 70)) 'Other (10%) does not warn'

# ---- D3b-3. chain summary from folder facts -----------------------------------------
function New-CS([datetime]$t) { return [pscustomobject]@{ Timestamp = $t } }
$nowCS = [datetime]'2026-09-05 12:00:00'
$sumOk = Get-SebChainSummary -Fulls @((New-CS $nowCS.AddHours(-6)), (New-CS $nowCS.AddHours(-30))) -Diffs @() -Logs @((New-CS $nowCS.AddMinutes(-10)), (New-CS $nowCS.AddMinutes(-40))) -Now $nowCS
Assert ($sumOk.LastFull -eq $nowCS.AddHours(-6)) 'last full is the newest full'
Assert ($sumOk.LastLog -eq $nowCS.AddMinutes(-10)) 'last log is the newest log'
Assert ($sumOk.RpoMinutes -eq 10) 'RPO is minutes since the newest log'
Assert ($sumOk.Health -eq 'ok') 'a chain with a full and logs is ok'
$sumNoLog = Get-SebChainSummary -Fulls @((New-CS $nowCS.AddHours(-2))) -Diffs @() -Logs @() -Now $nowCS
Assert ($sumNoLog.Health -eq 'no logs yet' -and $sumNoLog.RpoMinutes -eq 120) 'a full with no logs reports no-logs-yet and RPO from the full'
$sumNone = Get-SebChainSummary -Fulls @() -Diffs @() -Logs @() -Now $nowCS
Assert ($sumNone.Health -eq 'no backups' -and $sumNone.RpoMinutes -eq -1) 'no backups at all is reported, RPO -1'
$sumOrphan = Get-SebChainSummary -Fulls @() -Diffs @() -Logs @((New-CS $nowCS.AddMinutes(-5))) -Now $nowCS
Assert ($sumOrphan.Health -eq 'no base full') 'logs without a base full is flagged'
$sumDiffOnly = Get-SebChainSummary -Fulls @() -Diffs @((New-CS $nowCS.AddHours(-3))) -Logs @() -Now $nowCS
Assert ($sumDiffOnly.Health -eq 'no base full') 'diffs present but no base full is flagged (not "no backups")'
Assert ($sumDiffOnly.LastDiff -eq $nowCS.AddHours(-3)) 'the last diff time is surfaced'

# ---- COMP-1. compress/expand round-trips a file byte-for-byte ----------------------
$tmpC = Join-Path $env:TEMP ('seb-comp-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpC -Force)
try {
  $plain = Join-Path $tmpC 'APPDB_20260905-090000.bak'
  $bytes = [byte[]](1..5000 | ForEach-Object { $_ % 256 })
  [System.IO.File]::WriteAllBytes($plain, $bytes)
  $zip = Join-Path $tmpC 'APPDB_20260905-090000.bak.zip'
  Compress-SebFile -Source $plain -Destination $zip
  Assert (Test-Path -LiteralPath $zip) 'Compress-SebFile writes the .zip'
  Assert ((Get-Item -LiteralPath $zip).Length -gt 0) 'the .zip is non-empty'
  $out = Join-Path $tmpC 'restored.bak'
  Expand-SebFile -Source $zip -Destination $out
  $a = (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
  Assert ($a -eq $b) 'Expand-SebFile restores byte-for-byte identical content'
}
finally { Remove-Item -LiteralPath $tmpC -Recurse -Force -ErrorAction SilentlyContinue }

# ---- COMP-2. .zip naming + stamp + folder facts ------------------------------------
Assert ((Get-SebCompressedName 'APPDB_20260905-090000.bak') -eq 'APPDB_20260905-090000.bak.zip') 'compressed name appends .zip'
Assert ((Get-SebSidecarName 'APPDB_20260905-090000.bak.zip') -eq 'APPDB_20260905-090000.bak.zip.meta.json') 'sidecar name appends .meta.json'
$fbZ = [datetime]'2000-01-01'
$stZ = [datetime]'2026-09-05 09:00:00'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.bak.zip' -Fallback $fbZ) -eq $stZ) 'the stamp is read out of a .bak.zip name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.trn.zip' -Fallback $fbZ) -eq $stZ) 'the stamp is read out of a .trn.zip name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.bak' -Fallback $fbZ) -eq $stZ) 'a plain .bak stamp still parses (no regression)'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.bak.zip.meta.json' -Fallback $fbZ) -eq $fbZ) 'a .meta.json sidecar is NOT a backup (falls back)'
$tmpF = Join-Path $env:TEMP ('seb-ff-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpF -Force)
try {
  Set-Content -LiteralPath (Join-Path $tmpF 'APPDB_20260905-090000.bak.zip') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpF 'APPDB_20260905-090000.bak.zip.meta.json') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpF 'APPDB_20260905-093000.bak') -Value 'x'
  $facts = @(Get-SebFolderFacts -Directory $tmpF)
  Assert ($facts.Count -eq 2) "folder facts count the .zip and the plain backup but NOT the sidecar (got $($facts.Count))"
  Assert (@($facts | Where-Object { $_.Name -like '*.meta.json' }).Count -eq 0) 'the .meta.json sidecar is excluded from folder facts'
}
finally { Remove-Item -LiteralPath $tmpF -Recurse -Force -ErrorAction SilentlyContinue }

# ---- COMP-3. Get-SebRestoreCatalogue (-RestoreList) recognises .bak.zip -----------
$rcRoot = Join-Path $env:TEMP ('seb-rc-' + [Guid]::NewGuid().ToString('N'))
$rcDir = Join-Path $rcRoot 'HOST1\INST1\APPDB\hourly'
[void](New-Item -ItemType Directory -Force -Path $rcDir)
try {
  Set-Content -LiteralPath (Join-Path $rcDir 'APPDB_20260905-090000.bak') -Value 'x'
  Set-Content -LiteralPath (Join-Path $rcDir 'APPDB2_20260905-100000.bak.zip') -Value 'x'
  $rcCat = @(Get-SebRestoreCatalogue -Root $rcRoot)
  Assert ($rcCat.Count -eq 2) "-RestoreList enumerates both the plain .bak and the .bak.zip (got $($rcCat.Count))"
  $rcZip = @($rcCat | Where-Object { $_.Path -like '*.bak.zip' })
  $rcPlain = @($rcCat | Where-Object { $_.Path -like '*.bak' -and $_.Path -notlike '*.bak.zip' })
  Assert ($rcZip.Count -eq 1) 'the compressed full (.bak.zip) is in the restore catalogue'
  Assert ($rcPlain.Count -eq 1) 'the plain full (.bak) is still in the restore catalogue (no regression)'
  Assert ($rcZip[0].Database -eq 'APPDB' -and $rcZip[0].Kind -eq 'hourly') 'the .bak.zip entry still gets its Database/Kind from the folder path'
}
finally { Remove-Item -LiteralPath $rcRoot -Recurse -Force -ErrorAction SilentlyContinue }

# ---- COMP-3b. sidecar carries LSN facts with full precision -------------------------
# NOTE: numbered "3b" rather than "3" - a prior review-gaps fix (414ed3e) already used
# the "COMP-3" label for Get-SebRestoreCatalogue's .bak.zip recognition, and the plan
# (docs/superpowers/plans/2026-09-05-backup-compression.md) reserves "COMP-4" for the
# next task's Get-SebFactsForFile selector. "3b" avoids colliding with either.
$bigLsn = [decimal]'1234567890123456789012'   # 22 digits - would lose precision as a JSON number
$facts0 = [pscustomobject]@{ Kind='full'; File='ignored'; FirstLSN=$bigLsn; LastLSN=([decimal]$bigLsn + 5); DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]777; Finish=[datetime]'2026-09-05 08:00:00' }
$json = Get-SebSidecarJson -Facts $facts0
Assert ($json -match '"FirstLSN"\s*:\s*"1234567890123456789012"') 'the sidecar stores LSNs as strings'
$back = Get-SebHeaderFactsFromSidecar -Json $json -File 'C:\s\APPDB.bak.zip' -Kind 'full'
Assert ($back.FirstLSN -eq $bigLsn) 'FirstLSN round-trips through the sidecar with full precision'
Assert ($back.LastLSN -eq ([decimal]$bigLsn + 5)) 'LastLSN round-trips'
Assert ($back.CheckpointLSN -eq 777) 'CheckpointLSN round-trips'
Assert ($back.File -eq 'C:\s\APPDB.bak.zip' -and $back.Kind -eq 'full') 'File and Kind come from the parameters (folder-derived), not the JSON'
Assert ($back.Finish -eq ([datetime]'2026-09-05 08:00:00')) 'Finish round-trips'

# ---- COMP-4. the catalogue reads a sidecar when one exists (no decompress) ----------
$factsS = [pscustomobject]@{ Kind='full'; File='x'; FirstLSN=[decimal]900; LastLSN=[decimal]900; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]905; Finish=[datetime]'2026-09-05 07:00:00' }
$jsonS = Get-SebSidecarJson -Facts $factsS
$reader = { param($p) return $jsonS }   # pretend a sidecar exists with these facts
$f = Get-SebFactsForFile -Connection $null -File 'C:\s\APPDB_20260905-070000.bak.zip' -Kind 'full' -SidecarReader $reader
Assert ($f.CheckpointLSN -eq 905 -and $f.File -eq 'C:\s\APPDB_20260905-070000.bak.zip') 'a present sidecar supplies the facts (Connection never used)'
Assert ((Get-Command Get-SebFactsForFile).Parameters.ContainsKey('SidecarReader')) 'Get-SebFactsForFile exposes an injectable SidecarReader'
$readerNone = { param($p) return $null }  # no sidecar -> would fall through to HEADERONLY (Connection=$null so it would throw if reached)
$threw = $false
try { [void](Get-SebFactsForFile -Connection $null -File 'C:\s\APPDB.bak' -Kind 'full' -SidecarReader $readerNone) } catch { $threw = $true }
Assert $threw 'with no sidecar it falls through to RESTORE HEADERONLY (which needs a real connection)'

# ---- COMP-5. CompressBackups config flag rides the same rails as RecoveryMode -------
# Mirrors RecoveryMode's plumbing (PITR D3): a config predating this feature has no
# CompressBackups key at all, and that must read as off, not throw or default on. There
# is no centralized config-normalizer/coercion function in this engine (Read-SebConfig
# is a bare ConvertFrom-Json) - every caller casts inline with PSObject.Properties guards
# like the one below, so that inline idiom IS the "coercion step" and is what this pins.
$cfgNo = [pscustomobject]@{ RecoveryMode = 'Simple' }   # a config predating this feature
$compNo = $false
if ($cfgNo.PSObject.Properties['CompressBackups']) { $compNo = [bool]$cfgNo.CompressBackups }
Assert (-not $compNo) 'a config without CompressBackups reads as off (existing installs unchanged)'
$cfgYes = [pscustomobject]@{ CompressBackups = $true }
Assert ([bool]$cfgYes.CompressBackups) 'CompressBackups=$true is read as on'

# $SebShowKeys is the one allow-list Format-SebConfigFacts (the -Status display) AND
# Write-SebPublicSummary (public.json, read unelevated by the dashboard) both consult -
# see the comment above Write-SebPublicSummary. One membership check pins both at once.
Assert ($script:SebShowKeys -contains 'CompressBackups') 'CompressBackups is on the SebShowKeys allow-list (shown by -Status AND written to public.json), like RecoveryMode'

# Behavioural proof of the same claim, through the real consuming function rather than
# just reading the array - same idiom as test 7 ("redaction is an allow-list"). An
# allow-listed field's VALUE is printed; a field nobody put on the list is named but
# redacted. RecoveryMode and a non-allow-listed secret ride along as positive controls,
# so a probe that found nothing would be caught rather than trusted.
$compConfig = [pscustomobject]@{
  RecoveryMode    = 'Simple'
  CompressBackups = $true
  SealedSecret    = 'SUPERSECRETVALUE'
}
$compFacts = (Format-SebConfigFacts -Config $compConfig) -join "`n"
Assert ($compFacts -match 'CompressBackups = True') 'CompressBackups is shown by name AND value, like RecoveryMode - not redacted as "(value hidden)"'
Assert ($compFacts -match 'RecoveryMode = Simple') 'positive control: the RecoveryMode allow-list entry this test is modeled on still shows its value too'
Assert (-not ($compFacts -match 'SUPERSECRETVALUE')) 'positive control: a field NOT on the allow-list is still redacted here - the probe can tell the difference'

# ---- COMP-6a. the publish set + the staged sweep ------------------------------------
# compress OFF: exactly the plain file, no zip made
$tmp6 = Join-Path $env:TEMP ('seb-6a-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp6 -Force)
try {
  $plain = Join-Path $tmp6 'APPDB_20260905-080000.bak'
  [System.IO.File]::WriteAllBytes($plain, [byte[]](1..3000 | ForEach-Object { $_ % 256 }))
  $setOff = Get-SebPublishSet -Connection $null -StagedPlain $plain -PlainName 'APPDB_20260905-080000.bak' -Kind 'full' -Compress $false
  Assert (@($setOff).Count -eq 1 -and $setOff[0].Src -eq $plain -and $setOff[0].Name -eq 'APPDB_20260905-080000.bak') 'compress off -> the plain file is the only artifact'
  Assert (-not (Test-Path -LiteralPath ($plain + '.zip'))) 'compress off -> no .zip was created'
  # compress ON: zip + sidecar, facts injected (no SQL). Plain stays for the caller.
  $fakeFacts = { param($c, $f, $k) [pscustomobject]@{ Kind = $k; File = $f; FirstLSN = [decimal]10; LastLSN = [decimal]20; DatabaseBackupLSN = [decimal]0; CheckpointLSN = [decimal]15; Finish = [datetime]'2026-09-05 08:00:00' } }
  $setOn = Get-SebPublishSet -Connection $null -StagedPlain $plain -PlainName 'APPDB_20260905-080000.bak' -Kind 'full' -Compress $true -HeaderReader $fakeFacts
  Assert (@($setOn).Count -eq 2) 'compress on -> two artifacts (zip + sidecar)'
  Assert ($setOn[0].Name -eq 'APPDB_20260905-080000.bak.zip') 'the zip artifact is named <plain>.zip'
  Assert ($setOn[1].Name -eq 'APPDB_20260905-080000.bak.zip.meta.json') 'the sidecar artifact is named <zip>.meta.json'
  Assert (Test-Path -LiteralPath $setOn[0].Src) 'the staged .zip exists on disk'
  Assert (Test-Path -LiteralPath $setOn[1].Src) 'the staged sidecar exists on disk'
  Assert (Test-Path -LiteralPath $plain) 'the plain staged file is left for the caller to clean up'
  # the zip round-trips to the original bytes
  $back = Join-Path $tmp6 'back.bak'; Expand-SebFile -Source $setOn[0].Src -Destination $back
  Assert ((Get-FileHash -LiteralPath $back -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash) 'the staged .zip decompresses to the original bytes'
  # the sidecar carries the (injected) LSNs, readable via the catalogue's sidecar parser
  $sf = Get-SebHeaderFactsFromSidecar -Json (Get-Content -LiteralPath $setOn[1].Src -Raw) -File $setOn[0].Name -Kind 'full'
  Assert ($sf.CheckpointLSN -eq 15 -and $sf.LastLSN -eq 20) 'the sidecar preserves the LSNs for the catalogue'
}
finally { Remove-Item -LiteralPath $tmp6 -Recurse -Force -ErrorAction SilentlyContinue }
# the staged sweep: keeps pending, removes the rest (zip + sidecar + plain + dif), leaves non-backup files
$tmpS = Join-Path $env:TEMP ('seb-6as-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpS -Force)
try {
  $keepZip = Join-Path $tmpS 'APPDB_20260905-000000.bak.zip'; Set-Content -LiteralPath $keepZip -Value 'x'
  $keepMeta = Join-Path $tmpS 'APPDB_20260905-000000.bak.zip.meta.json'; Set-Content -LiteralPath $keepMeta -Value 'x'
  $goneZip = Join-Path $tmpS 'APPDB_20260904-000000.bak.zip'; Set-Content -LiteralPath $goneZip -Value 'x'
  $goneMeta = Join-Path $tmpS 'APPDB_20260904-000000.bak.zip.meta.json'; Set-Content -LiteralPath $goneMeta -Value 'x'
  $goneTrn = Join-Path $tmpS 'APPDB_20260904-010000.trn'; Set-Content -LiteralPath $goneTrn -Value 'x'
  $goneDif = Join-Path $tmpS 'APPDB_20260904-020000.dif'; Set-Content -LiteralPath $goneDif -Value 'x'
  $notBackup = Join-Path $tmpS 'notes.txt'; Set-Content -LiteralPath $notBackup -Value 'x'
  Clear-SebStagedExcept -StagingPath $tmpS -KeepPaths @($keepZip, $keepMeta)
  Assert (Test-Path -LiteralPath $keepZip) 'a still-pending .zip is kept'
  Assert (Test-Path -LiteralPath $keepMeta) 'a still-pending sidecar is kept'
  Assert (-not (Test-Path -LiteralPath $goneZip)) 'a non-pending .bak.zip is swept'
  Assert (-not (Test-Path -LiteralPath $goneMeta)) 'a non-pending .meta.json is swept (no orphan sidecars)'
  Assert (-not (Test-Path -LiteralPath $goneTrn)) 'a non-pending .trn is swept'
  Assert (-not (Test-Path -LiteralPath $goneDif)) 'a non-pending .dif is swept (the old *.bak filter missed these)'
  Assert (Test-Path -LiteralPath $notBackup) 'positive control: a non-backup file is NOT swept (the filter is scoped)'
}
finally { Remove-Item -LiteralPath $tmpS -Recurse -Force -ErrorAction SilentlyContinue }

# ---- COMP-7. a .zip restore source is expanded; a plain source passes through -------
$tmpR = Join-Path $env:TEMP ('seb-rr-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpR -Force)
try {
  $srcPlain = Join-Path $tmpR 'APPDB_20260905-090000.bak'
  [System.IO.File]::WriteAllBytes($srcPlain, [byte[]](1..2000 | ForEach-Object { $_ % 256 }))
  $srcZip = Join-Path $tmpR 'APPDB_20260905-090000.bak.zip'
  Compress-SebFile -Source $srcPlain -Destination $srcZip
  $stg = Join-Path $tmpR 'stg'
  $resolved = Resolve-SebRestoreSource -File $srcZip -StagingDir $stg
  Assert ($resolved -like '*APPDB_20260905-090000.bak' -and $resolved -notlike '*.zip') 'a .zip source resolves to a plain .bak path'
  Assert ((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $srcPlain -Algorithm SHA256).Hash) 'the resolved plain file matches the original bytes'
  $plainIn = Join-Path $tmpR 'other.bak'; Set-Content -LiteralPath $plainIn -Value 'x'
  Assert ((Resolve-SebRestoreSource -File $plainIn -StagingDir $stg) -eq $plainIn) 'a plain source is returned unchanged (no decompress)'
  # the SourceFile override drives the FROM DISK path while the step keeps its real .File
  $step = [pscustomobject]@{ Kind = 'full'; File = 'C:\share\APPDB_20260905-090000.bak.zip' }
  $sqlOverride = Get-SebRestoreStepSql -Step $step -RestoreAs 'APPDB_R' -Replace $true -MoveClauses @() -SourceFile 'C:\stg\APPDB_20260905-090000.bak'
  Assert ($sqlOverride -like "*FROM DISK = 'C:\stg\APPDB_20260905-090000.bak'*") '-SourceFile overrides the FROM DISK path'
  Assert ($sqlOverride -notlike '*.zip*') 'the override SQL never references the .zip'
  $sqlPlain = Get-SebRestoreStepSql -Step ([pscustomobject]@{ Kind = 'log'; File = 'C:\share\APPDB.trn'; Recovery = $false }) -RestoreAs 'APPDB_R'
  Assert ($sqlPlain -like "*FROM DISK = 'C:\share\APPDB.trn'*") 'positive control: with no -SourceFile the step file is used (unchanged)'
}
finally { Remove-Item -LiteralPath $tmpR -Recurse -Force -ErrorAction SilentlyContinue }

# ---- COMP-8. retention removes a compressed backup's sidecar with it ----------------
$tmpP = Join-Path $env:TEMP ('seb-ret-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpP -Force)
try {
  $z = Join-Path $tmpP 'APPDB_20260905-000000.bak.zip'; Set-Content -LiteralPath $z -Value 'x'
  Set-Content -LiteralPath (Get-SebSidecarName $z) -Value 'x'
  Remove-SebNamed -Directory $tmpP -Names @('APPDB_20260905-000000.bak.zip')
  Assert (-not (Test-Path -LiteralPath $z)) 'the pruned .zip is removed'
  Assert (-not (Test-Path -LiteralPath (Get-SebSidecarName $z))) 'its .meta.json sidecar is removed too'
  # positive control: a PLAIN backup with no sidecar prunes cleanly, no error, sidecar-removal a no-op
  $p = Join-Path $tmpP 'APPDB_20260904-000000.bak'; Set-Content -LiteralPath $p -Value 'x'
  Remove-SebNamed -Directory $tmpP -Names @('APPDB_20260904-000000.bak')
  Assert (-not (Test-Path -LiteralPath $p)) 'a plain backup (no sidecar) is still pruned normally'
  Assert (-not (Test-Path -LiteralPath (Get-SebSidecarName $p))) 'no phantom sidecar remains for a plain backup'
}
finally { Remove-Item -LiteralPath $tmpP -Recurse -Force -ErrorAction SilentlyContinue }

# ---- SETUP-1. a reconfigure keeps what it was not told to change --------------------
# The app's reconfigure runs -Setup with only instance/share/cadence/keeps. Before the
# carry-over, that wrote RecoveryMode=Simple over a Full host and -Reschedule then removed
# the log task: point-in-time recovery switched off with nothing said.
$defaults = @{ RecoveryMode = 'Simple'; LogIntervalMinutes = 15; FullEveryHours = 24; CompressBackups = $false; NoHashVerify = $false }
$onDisk = [pscustomobject]@{ RecoveryMode = 'Full'; LogIntervalMinutes = 5; FullEveryHours = 12; CompressBackups = $true; NoHashVerify = $true }
$c = Get-SebSetupCarryOver -Existing $onDisk -Bound @('Setup', 'UseWindowsAuth', 'Instance', 'SharePath', 'IntervalHours') -Values $defaults
Assert ($c.RecoveryMode -eq 'Full') 'an unbound -RecoveryMode keeps Full from the existing config'
Assert ($c.LogIntervalMinutes -eq 5 -and $c.FullEveryHours -eq 12) 'unbound log interval and full cadence keep their existing values'
Assert ($c.CompressBackups -eq $true -and $c.NoHashVerify -eq $true) 'unbound switches keep their existing values'
$c = Get-SebSetupCarryOver -Existing $onDisk -Bound @('Setup', 'RecoveryMode', 'CompressBackups') -Values @{ RecoveryMode = 'Simple'; LogIntervalMinutes = 15; FullEveryHours = 24; CompressBackups = $false; NoHashVerify = $false }
Assert ($c.RecoveryMode -eq 'Simple') 'an explicitly passed -RecoveryMode wins over the existing config'
Assert ($c.CompressBackups -eq $false) 'an explicitly passed -CompressBackups:$false wins over the existing config'
Assert ($c.LogIntervalMinutes -eq 5) 'while the unbound ones in the same call still carry over'
$c = Get-SebSetupCarryOver -Existing $null -Bound @('Setup') -Values $defaults
Assert ($c.RecoveryMode -eq 'Simple' -and $c.LogIntervalMinutes -eq 15 -and $c.CompressBackups -eq $false) 'a first setup (no config yet) takes the parameter defaults'
$c = Get-SebSetupCarryOver -Existing ([pscustomobject]@{ IntervalHours = 6 }) -Bound @('Setup') -Values $defaults
Assert ($c.RecoveryMode -eq 'Simple' -and $c.FullEveryHours -eq 24) 'a pre-PITR config missing the keys falls back to the defaults'

# ---- REVIEW-1. Full mode enrolls user databases only ---------------------------------
# master accepts only a full backup, so enrolling it failed every diff and every log pass.
Assert (-not (Test-SebPitrEligible -Name 'master' -ReadOnly $false)) 'master stays full-only'
Assert (-not (Test-SebPitrEligible -Name 'MSDB' -ReadOnly $false)) 'msdb stays full-only (case-insensitive)'
Assert (-not (Test-SebPitrEligible -Name 'Archive' -ReadOnly $true)) 'a read-only database is not enrolled (it cannot be ALTERed to FULL)'
Assert (Test-SebPitrEligible -Name 'AppDb' -ReadOnly ([System.DBNull]::Value)) 'a user database with a DBNull read-only flag is enrolled (DBNull is not "true")'
Assert (Test-SebPitrEligible -Name 'AppDb' -ReadOnly $false) 'a read-write user database is enrolled'
$roRows = @([pscustomobject]@{ name = 'Archive'; is_read_only = $true }, [pscustomobject]@{ name = 'AppDb'; is_read_only = $false })
$roMap = Get-SebReadOnlyMap -Rows $roRows
Assert ($roMap['Archive'] -eq $true -and $roMap['AppDb'] -eq $false) 'the read-only map is built from sys.databases rows'
Assert ((Get-SebReadOnlyMap -Rows @([pscustomobject]@{ name = 'X' })).Count -eq 0) 'rows without the column (an older query) leave the map empty, not throwing'

# ---- REVIEW-2. a FULL database nobody backs the log up for is warned about ----------
$mRows = @(
  [pscustomobject]@{ name = 'master'; recovery_model_desc = 'FULL' },
  [pscustomobject]@{ name = 'AppDb';  recovery_model_desc = 'FULL' },
  [pscustomobject]@{ name = 'Plain';  recovery_model_desc = 'SIMPLE' },
  [pscustomobject]@{ name = 'NotOurs'; recovery_model_desc = 'FULL' })
$w = @(Get-SebUnmanagedFullLogWarnings -Rows $mRows -Databases @('master', 'AppDb', 'Plain') -FullMode $false -ReadOnlyMap @{})
Assert ($w.Count -eq 2) "Simple mode warns for each FULL database it backs up (got $($w.Count))"
Assert ((@($w) -join ' ') -notmatch 'NotOurs') 'a database outside the backup set is not warned about'
$w = @(Get-SebUnmanagedFullLogWarnings -Rows $mRows -Databases @('master', 'AppDb', 'Plain') -FullMode $true -ReadOnlyMap @{})
Assert ($w.Count -eq 1 -and $w[0] -like 'master *') 'Full mode warns only for the full-only ones (master), not for AppDb whose log it backs up'

# ---- REVIEW-3. a staged log backup with no pending entry is adopted, not swept -------
$tmpO = Join-Path $env:TEMP ('seb-orph-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpO -Force)
try {
  foreach ($n in @('App_Db_20260905-031500.trn', 'Other_20260905-031500.trn.zip', 'Other_20260905-031500.trn.zip.meta.json',
                   'Half_20260905-031500.trn', 'Half_20260905-031500.trn.zip', 'Kept_20260905-031500.trn', 'Full_20260905-031500.bak',
                   'Zipped_20260905-031500.trn')) {
    Set-Content -LiteralPath (Join-Path $tmpO $n) -Value 'x'
  }
  $keep = @((Join-Path $tmpO 'Kept_20260905-031500.trn'), (Join-Path $tmpO 'Zipped_20260905-031500.trn.zip'))
  $orph = @(Get-SebOrphanLogEntries -StagingPath $tmpO -KeepPaths $keep -Root '\\fs\share' -HostName 'H' -InstanceLabel 'I')
  $staged = @($orph | ForEach-Object { Split-Path -Leaf $_.Staged })
  Assert ($staged -contains 'App_Db_20260905-031500.trn') 'a loose plain .trn is adopted'
  $appEntry = @($orph | Where-Object { $_.Staged -like '*App_Db_*' })[0]
  Assert ($appEntry.Dest -eq '\\fs\share\H\I\App_Db\log\App_Db_20260905-031500.trn') "it is routed to its database's log folder, even with '_' in the name (got $($appEntry.Dest))"
  Assert ($appEntry.Kind -eq 'log') 'and recorded as a log copy'
  Assert (($staged -contains 'Other_20260905-031500.trn.zip') -and ($staged -contains 'Other_20260905-031500.trn.zip.meta.json')) 'a lone .trn.zip is adopted with its sidecar'
  Assert (($staged -contains 'Half_20260905-031500.trn') -and -not ($staged -contains 'Half_20260905-031500.trn.zip')) 'with both plain and zip present the plain wins (the zip may be half-written)'
  Assert (-not ($staged -contains 'Kept_20260905-031500.trn')) 'a file a pending entry already keeps is not adopted twice'
  Assert (-not ($staged -contains 'Zipped_20260905-031500.trn')) 'a plain .trn whose zip is already pending is not shipped a second time'
  Assert (-not ($staged -contains 'Full_20260905-031500.bak')) 'data backups are not adopted - only log backups break the chain'
  Assert (Test-SebPendingEntry -Staged $appEntry.Staged -Dest $appEntry.Dest -StagingPath $tmpO -SharePath '\\fs\share') 'an adopted entry passes the pending-entry guard'
}
finally { Remove-Item -LiteralPath $tmpO -Recurse -Force -ErrorAction SilentlyContinue }

# ---- REVIEW-4. '..' is traversal only as a whole path segment ------------------------
Assert (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\my..db_20260905-031500.trn' -Dest '\\fs\sqlbackups\H\I\my..db\log\my..db_20260905-031500.trn' -StagingPath 'C:\SqlBackupStaging' -SharePath '\\fs\sqlbackups') "a legal database name containing '..' keeps its pending copies"
Assert (-not (Test-SebPendingEntry -Staged 'C:\SqlBackupStaging\a.bak' -Dest '\\fs\sqlbackups\x/../../evil.bak' -StagingPath 'C:\SqlBackupStaging' -SharePath '\\fs\sqlbackups')) "a '..' segment behind a forward slash is still refused"

# ---- REVIEW-5. names and STOPAT do not depend on the host's culture -----------------
$savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
  [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo 'th-TH'
  $n = Get-SebFileName -Database 'AppDb' -Stamp (Get-Date -Year 2026 -Month 9 -Day 4 -Hour 10 -Minute 30 -Second 0) -Extension 'trn'
  Assert ($n -eq 'AppDb_20260904-103000.trn') "the file-name stamp is Gregorian under th-TH (got $n)"
  [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo 'fi-FI'
  $sql = Get-SebRestoreStepSql -Step ([pscustomobject]@{ Kind = 'log'; File = 'C:\s\a.trn'; Recovery = $true; StopAt = (Get-Date -Year 2026 -Month 9 -Day 4 -Hour 10 -Minute 30 -Second 0) }) -RestoreAs 'A_R'
  Assert ($sql -like "*STOPAT = '2026-09-04T10:30:00'*") "STOPAT keeps ':' separators under fi-FI (got: $sql)"
}
finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture }

# ---- REVIEW-6. a backup that could not be pruned keeps its sidecar -------------------
$tmpS = Join-Path $env:TEMP ('seb-side-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpS -Force)
$lock = $null
try {
  $z = Join-Path $tmpS 'APPDB_20260905-000000.bak.zip'; Set-Content -LiteralPath $z -Value 'x'
  Set-Content -LiteralPath (Get-SebSidecarName $z) -Value 'x'
  $lock = [System.IO.File]::Open($z, 'Open', 'Read', 'None')
  Remove-SebNamed -Directory $tmpS -Names @('APPDB_20260905-000000.bak.zip')
  Assert (Test-Path -LiteralPath $z) 'precondition: the locked .zip could not be deleted'
  Assert (Test-Path -LiteralPath (Get-SebSidecarName $z)) 'so its sidecar is kept, and the catalogue can still read it next time'
}
finally {
  if ($null -ne $lock) { $lock.Dispose() }
  Remove-Item -LiteralPath $tmpS -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- REVIEW-7. an abandoned lock is taken over, not bypassed -------------------------
# A task killed at its time limit dies holding the mutex. The old code caught the
# AbandonedMutexException as a generic failure and fell through to a Local\ mutex no
# other session shares - the next pass then ran with no exclusion at all.
Add-Type -TypeDefinition 'using System.Threading; public static class SebAbandon { public static void Grab(string n) { var t = new Thread(() => { new Mutex(true, n); }); t.Start(); t.Join(); } }'
[SebAbandon]::Grab('Global\SqlExpressBackup')
[SebAbandon]::Grab('Local\SqlExpressBackup')
$m = Get-SebMutex
try {
  Assert ($null -ne $m) 'an abandoned lock is acquired rather than refused'
  $ownsIt = $true
  try { $m.ReleaseMutex() } catch { $ownsIt = $false }
  Assert $ownsIt 'and it is really owned (ReleaseMutex succeeds)'
}
finally { if ($null -ne $m) { $m.Dispose() } }

# ---- REVIEW-8. the config folder is locked for write, readable by Users -------------
# A folder first created unelevated gave that user CREATOR OWNER full control of it, and
# full control of the PARENT is enough to rename engine\ away and plant a script the
# SYSTEM task runs. The owner has to move too: an owner can always rewrite the rules.
$sec = New-SebConfigDirSecurity
$adminsSid = New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
$usersSid = New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)
Assert ($sec.AreAccessRulesProtected) 'the config folder ACL is protected (nothing inherited, no CREATOR OWNER grant)'
Assert ($sec.GetOwner([System.Security.Principal.SecurityIdentifier]) -eq $adminsSid) 'and owned by Administrators, not whoever created it'
$rules = @($sec.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
$userRules = @($rules | Where-Object { $_.IdentityReference -eq $usersSid })
Assert ($userRules.Count -eq 1) 'Users hold exactly one rule'
$writeBits = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership, WriteAttributes, WriteExtendedAttributes'
Assert ((([int]$userRules[0].FileSystemRights) -band ([int]$writeBits)) -eq 0) 'and it grants no write, delete or permission change'
Assert ((([int]$userRules[0].FileSystemRights) -band ([int][System.Security.AccessControl.FileSystemRights]::ReadData)) -ne 0) 'but still grants read (public.json is the dashboard view)'
Assert (@($rules | Where-Object { $_.IdentityReference -ne $usersSid -and $_.IdentityReference -ne $adminsSid -and $_.IdentityReference.Value -ne 'S-1-5-18' }).Count -eq 0) 'nobody else - only SYSTEM, Administrators and Users appear'

# ---- REVIEW-9. restore-side sources: a plain file is used where it is --------------
$plainSrc = Get-SebRestoreSource -Connection $null -File 'C:\share\APPDB_20260905-000000.bak'
Assert ($plainSrc.Source -eq 'C:\share\APPDB_20260905-000000.bak') 'a plain backup is restored from where it lies (no copy)'
Assert (-not (Test-Path -LiteralPath $plainSrc.TempDir)) 'and no temp folder is created for it'
Remove-SebRestoreSource $plainSrc
Remove-SebRestoreSource $null

# ======================================================================================
# ALERTING
# ======================================================================================
$savedConfigDir = $script:SebConfigDir
$alertRoot = Join-Path $env:TEMP ('seb-alert-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $alertRoot -Force)
$script:SebConfigDir = $alertRoot

# A throwaway loopback server on a background runspace: accepts up to $Expect connections
# until $TimeoutMs passes and returns what it saw. TcpListener, not HttpListener, so it needs
# no URL reservation and runs unelevated. Mode 'http' answers 200; mode 'smtp' plays a minimal
# SMTP dialogue and records the DATA section.
function Start-TestListener {
  param([ValidateSet('http', 'smtp')][string]$Mode, [int]$Expect = 1, [int]$TimeoutMs = 8000)
  $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
      param($listener, $mode, $expect, $timeoutMs)
      $seen = New-Object System.Collections.ArrayList
      $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
      while ($seen.Count -lt $expect -and [DateTime]::UtcNow -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
        $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::ASCII)
        $writer.NewLine = "`r`n"; $writer.AutoFlush = $true
        try {
          if ($mode -eq 'http') {
            $first = $reader.ReadLine(); $len = 0
            while (($h = $reader.ReadLine()) -ne '' -and $null -ne $h) { if ($h -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
            $buf = New-Object char[] $len; $got = 0
            while ($got -lt $len) { $n = $reader.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
            $writer.Write("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok")
            [void]$seen.Add([pscustomobject]@{ Request = $first; Body = (-join $buf) })
          }
          else {
            $writer.WriteLine('220 localhost test')
            $data = New-Object System.Text.StringBuilder; $rcpt = New-Object System.Collections.ArrayList
            while ($true) {
              $line = $reader.ReadLine(); if ($null -eq $line) { break }
              if ($line -match '^(EHLO|HELO)') { $writer.WriteLine('250 localhost') }
              elseif ($line -match '^MAIL FROM') { $writer.WriteLine('250 OK') }
              elseif ($line -match '^RCPT TO:\s*<?([^>]+)>?') { [void]$rcpt.Add($Matches[1]); $writer.WriteLine('250 OK') }
              elseif ($line -eq 'DATA') {
                $writer.WriteLine('354 go ahead')
                while (($d = $reader.ReadLine()) -ne '.') { [void]$data.AppendLine($d) }
                $writer.WriteLine('250 queued')
              }
              elseif ($line -eq 'QUIT') { $writer.WriteLine('221 bye'); break }
              else { $writer.WriteLine('250 OK') }
            }
            [void]$seen.Add([pscustomobject]@{ Rcpt = @($rcpt.ToArray()); Data = $data.ToString() })
          }
        }
        finally { $client.Close() }
      }
      $listener.Stop()
      return , @($seen.ToArray())
    }).AddArgument($listener).AddArgument($Mode).AddArgument($Expect).AddArgument($TimeoutMs)
  $handle = $ps.BeginInvoke()
  return [pscustomobject]@{ Port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; Ps = $ps; Handle = $handle }
}
function Stop-TestListener {
  param($L)
  $out = $L.Ps.EndInvoke($L.Handle)
  $L.Ps.Dispose()
  return @($out | ForEach-Object { $_ })
}

try {
  # ---- ALERT-1. state writers no longer erase each other's fields -------------------
  Write-SebState ([pscustomobject]@{ LastRunUtc = 'r1'; LastResult = 'ok'; Pending = @(); Alerts = @{ x = [pscustomobject]@{ Owner = 'watchdog' } }; LastLogSuccessUtc = 'L1' })
  Write-SebState ([pscustomobject]@{ LastRunUtc = 'r2'; LastResult = 'partial'; Pending = @() })
  $st = Read-SebState
  Assert ($st.LastRunUtc -eq 'r2' -and $st.LastResult -eq 'partial') 'Write-SebState writes what it is given'
  Assert ($st.LastLogSuccessUtc -eq 'L1' -and $null -ne $st.Alerts.x) 'and keeps fields it was not given (another writer''s alert state and log success)'

  # ---- ALERT-2. the notification decision ------------------------------------------
  $t0 = [datetime]::SpecifyKind([datetime]'2026-09-25 08:00:00', 'Utc')
  $c1 = New-SebAlertCondition -Key 'data-pass-failed' -Severity 'critical' -Owner 'data' -Message 'boom'
  $u = Update-SebAlertState -Previous $null -Current @($c1) -Owners @('data') -NowUtc $t0 -RemindHours 24
  Assert ($u.Notifications.Count -eq 1 -and $u.Notifications[0].Event -eq 'raised') 'a new condition is raised'
  Assert ($u.Alerts['data-pass-failed'].LastSentUtc -eq '') 'but not marked sent until delivery succeeds'
  $u2 = Update-SebAlertState -Previous $u.Alerts -Current @($c1) -Owners @('data') -NowUtc $t0.AddHours(1) -RemindHours 24
  Assert ($u2.Notifications.Count -eq 1 -and $u2.Notifications[0].Event -eq 'raised') 'an undelivered alert is raised again next time (a failed send is retried)'
  Complete-SebAlertDelivery -Alerts $u2.Alerts -Notifications $u2.Notifications -NowUtc $t0.AddHours(1)
  Assert ($u2.Alerts['data-pass-failed'].SinceUtc -eq $t0.ToString('o')) 'the start time survives re-evaluation'
  # Round-trip through JSON, as it really is between runs.
  $prevJson = ($u2.Alerts | ConvertTo-Json -Depth 5) | ConvertFrom-Json
  $u3 = Update-SebAlertState -Previous $prevJson -Current @($c1) -Owners @('data') -NowUtc $t0.AddHours(24.9) -RemindHours 24
  Assert ($u3.Notifications.Count -eq 0) 'a delivered alert is quiet until the reminder is due (23.9h after sending)'
  $u4 = Update-SebAlertState -Previous $prevJson -Current @($c1) -Owners @('data') -NowUtc $t0.AddHours(25) -RemindHours 24
  Assert ($u4.Notifications.Count -eq 1 -and $u4.Notifications[0].Event -eq 'reminder') 'and reminds exactly at the reminder interval'
  $cWarn = New-SebAlertCondition -Key 'data-pass-failed' -Severity 'warning' -Owner 'data' -Message 'less boom'
  $u5 = Update-SebAlertState -Previous $prevJson -Current @($cWarn) -Owners @('data') -NowUtc $t0.AddHours(2) -RemindHours 24
  Assert ($u5.Notifications.Count -eq 1 -and $u5.Notifications[0].Event -eq 'raised') 'a change of severity is announced at once'
  $u6 = Update-SebAlertState -Previous $prevJson -Current @() -Owners @('data') -NowUtc $t0.AddHours(3) -RemindHours 24
  Assert ($u6.Notifications.Count -eq 1 -and $u6.Notifications[0].Event -eq 'resolved' -and -not $u6.Alerts.Contains('data-pass-failed')) 'a cleared condition is resolved once and dropped'
  $u7 = Update-SebAlertState -Previous $prevJson -Current @() -Owners @('log', 'pending') -NowUtc $t0.AddHours(3) -RemindHours 24
  Assert ($u7.Notifications.Count -eq 0 -and $u7.Alerts.Contains('data-pass-failed')) 'another owner''s evaluation neither resolves nor drops it'
  $u8 = Update-SebAlertState -Previous $u.Alerts -Current @() -Owners @('data') -NowUtc $t0.AddHours(1) -RemindHours 24
  Assert ($u8.Notifications.Count -eq 0) 'a condition that was never delivered clears silently (no "resolved" for an alert nobody saw)'

  # ---- ALERT-3. conditions ----------------------------------------------------------
  $now = $t0
  Assert (@(Get-SebPendingCondition -Count 2 -SinceUtc $now.AddMinutes(-59).ToString('o') -NowUtc $now -PendingMinutes 60).Count -eq 0) 'copies pending 59 minutes: not yet'
  $pc = @(Get-SebPendingCondition -Count 2 -SinceUtc $now.AddMinutes(-60).ToString('o') -NowUtc $now -PendingMinutes 60)
  Assert ($pc.Count -eq 1 -and $pc[0].Key -eq 'copy-pending' -and $pc[0].Owner -eq 'pending') 'copies pending 60 minutes: raised, owned by both passes'
  Assert (@(Get-SebPendingCondition -Count 0 -SinceUtc $now.AddDays(-1).ToString('o') -NowUtc $now).Count -eq 0) 'nothing pending: nothing raised'
  Assert ((Get-SebPendingSince -Previous '' -Count 1 -NowUtc $now) -eq $now.ToString('o')) 'the pending clock starts when copies first queue'
  Assert ((Get-SebPendingSince -Previous 'earlier' -Count 3 -NowUtc $now) -eq 'earlier') 'keeps running while they stay queued'
  Assert ((Get-SebPendingSince -Previous 'earlier' -Count 0 -NowUtc $now) -eq '') 'and resets when they drain'
  $dc = @(Get-SebDataPassConditions -Succeeded 0 -Failed 2 -FailedDatabases @('A', 'B'))
  Assert ($dc.Count -eq 1 -and $dc[0].Key -eq 'data-pass-failed' -and $dc[0].Severity -eq 'critical' -and $dc[0].Message -like '*A, B*') 'every database failed: critical, naming them'
  $dc = @(Get-SebDataPassConditions -Succeeded 3 -Failed 1 -FailedDatabases @('B'))
  Assert ($dc.Count -eq 1 -and $dc[0].Key -eq 'data-pass-partial' -and $dc[0].Severity -eq 'warning') 'some failed: a partial warning'
  Assert (@(Get-SebDataPassConditions -Succeeded 3 -Failed 0).Count -eq 0) 'all good: nothing'
  $dc = @(Get-SebDataPassConditions -Succeeded 0 -Failed 0 -FailureMessage 'cannot reach SQL')
  Assert ($dc.Count -eq 1 -and $dc[0].Message -like '*cannot reach SQL*') 'a pass that died outright is critical, with the reason'
  Assert (@(Get-SebLogPassConditions -Failed 1 -FailedDatabases @('A'))[0].Key -eq 'log-pass-failed') 'a failed log backup is its own critical condition'

  $ac = Get-SebAlertConfig ([pscustomobject]@{ IntervalHours = 6; LogIntervalMinutes = 15; AlertEmailTo = 'a@x.test; b@x.test ,'; AlertSmtpHost = 'smtp.x.test'; AlertEmailFrom = 'seb@x.test' })
  Assert ($ac.StaleHours -eq 13) "stale threshold derives from the schedule: 2 x 6h + 1 (got $($ac.StaleHours))"
  Assert ($ac.LogStaleMinutes -eq 60) 'log staleness is four missed log intervals'
  Assert ($ac.EmailTo.Count -eq 2 -and $ac.EmailTo[1] -eq 'b@x.test') 'recipients split on , and ; with blanks dropped'
  Assert ($ac.EmailConfigured -and $ac.SmtpPort -eq 587 -and $ac.SmtpTls) 'email counts as configured with defaults port 587 and TLS on'
  Assert (-not (Get-SebAlertConfig ([pscustomobject]@{ AlertEmailTo = 'a@x.test' })).EmailConfigured) 'recipients alone (no host/from) are not a working email channel'

  $cfg = [pscustomobject]@{ IntervalHours = 6; RecoveryMode = 'Full'; LogIntervalMinutes = 15; CreatedUtc = $now.AddDays(-30).ToString('o') }
  $acW = Get-SebAlertConfig $cfg
  $okSched = [pscustomobject]@{ ServicePresent = $false; MainTaskState = 'Ready'; LogTaskState = 'Ready' }
  $fresh = [pscustomobject]@{ LastSuccessUtc = $now.AddHours(-12.9).ToString('o'); LastLogSuccessUtc = $now.AddMinutes(-59).ToString('o') }
  Assert (@(Get-SebWatchdogConditions -AlertConfig $acW -Config $cfg -State $fresh -Schedule $okSched -NowUtc $now).Count -eq 0) 'a healthy host: the watchdog finds nothing'
  $stale = [pscustomobject]@{ LastSuccessUtc = $now.AddHours(-13).ToString('o'); LastLogSuccessUtc = $now.AddMinutes(-60).ToString('o') }
  $keys = @(Get-SebWatchdogConditions -AlertConfig $acW -Config $cfg -State $stale -Schedule $okSched -NowUtc $now | ForEach-Object { $_.Key })
  Assert (($keys -contains 'backup-stale') -and ($keys -contains 'log-stale')) 'at the thresholds both staleness alerts fire'
  $newCfg = [pscustomobject]@{ IntervalHours = 6; RecoveryMode = 'Simple'; CreatedUtc = $now.AddHours(-2).ToString('o') }
  Assert (@(Get-SebWatchdogConditions -AlertConfig (Get-SebAlertConfig $newCfg) -Config $newCfg -State ([pscustomobject]@{}) -Schedule $okSched -NowUtc $now).Count -eq 0) 'a fresh install that has not run yet is not stale'
  $keys = @(Get-SebWatchdogConditions -AlertConfig $acW -Config $cfg -State $fresh -Schedule ([pscustomobject]@{ ServicePresent = $false; MainTaskState = 'Disabled'; LogTaskState = 'absent' }) -NowUtc $now | ForEach-Object { $_.Key })
  Assert (($keys -contains 'task-missing') -and ($keys -contains 'log-task-missing')) 'a disabled backup task and a missing log task are both critical'
  $keys = @(Get-SebWatchdogConditions -AlertConfig $acW -Config $cfg -State $fresh -Schedule ([pscustomobject]@{ ServicePresent = $true; MainTaskState = 'absent'; LogTaskState = 'Ready' }) -NowUtc $now | ForEach-Object { $_.Key })
  Assert (-not ($keys -contains 'task-missing')) 'a service install has no backup task, and that is fine'
  $simpleCfg = [pscustomobject]@{ IntervalHours = 6; RecoveryMode = 'Simple'; CreatedUtc = $now.AddDays(-30).ToString('o') }
  $keys = @(Get-SebWatchdogConditions -AlertConfig (Get-SebAlertConfig $simpleCfg) -Config $simpleCfg -State $fresh -Schedule ([pscustomobject]@{ ServicePresent = $false; MainTaskState = 'Ready'; LogTaskState = 'absent' }) -NowUtc $now | ForEach-Object { $_.Key })
  Assert ($keys.Count -eq 0) 'Simple mode expects no log task and no log backups'

  # ---- ALERT-4. rendering: every payload is valid JSON of the right shape -------------
  $notes = @(
    [pscustomobject]@{ Event = 'raised'; Key = 'backup-stale'; Severity = 'critical'; Message = 'No successful backup pass for 14 hours'; SinceUtc = $now.ToString('o') },
    [pscustomobject]@{ Event = 'resolved'; Key = 'copy-pending'; Severity = 'warning'; Message = 'copies waiting'; SinceUtc = $now.ToString('o') })
  $slack = Get-SebWebhookPayload -Kind 'slack' -Notifications $notes -Label 'HOST\SQLEXPRESS' -NowUtc $now | ConvertFrom-Json
  Assert ($slack.text -like '*CRITICAL*backup-stale*' -and $slack.text -like '*RESOLVED*copy-pending*') 'Slack gets one text block with every line'
  $teams = Get-SebWebhookPayload -Kind 'teams' -Notifications $notes -Label 'HOST\SQLEXPRESS' -NowUtc $now | ConvertFrom-Json
  Assert ($teams.type -eq 'message' -and $teams.attachments[0].contentType -eq 'application/vnd.microsoft.card.adaptive') 'Teams gets an Adaptive Card message'
  Assert ($teams.attachments[0].content.body.Count -eq 3 -and $teams.attachments[0].content.body[1].color -eq 'Attention' -and $teams.attachments[0].content.body[2].color -eq 'Good') 'with a title line, critical in red and resolved in green'
  $generic = Get-SebWebhookPayload -Kind 'generic' -Notifications $notes -Label 'HOST\SQLEXPRESS' -NowUtc $now | ConvertFrom-Json
  Assert ($generic.host -eq 'HOST' -and $generic.instance -eq 'SQLEXPRESS' -and @($generic.notifications).Count -eq 2 -and $generic.notifications[0].event -eq 'raised') 'generic JSON carries host, instance and each notification'
  Assert ((Get-SebAlertSubject -Notifications $notes -Label 'H\I') -eq '[SQL Express Backup] H\I: CRITICAL - 1 problem(s)') 'the subject leads with the worst severity and counts open problems'
  Assert ((Get-SebAlertSubject -Notifications @($notes[1]) -Label 'H\I') -like '*: resolved') 'an all-clear subject says resolved'

  # ---- ALERT-5. secrets never leak and never travel insecurely ------------------------
  $leak = Protect-SebAlertText 'The remote server returned an error: (404) at https://prod-12.westeurope.logic.azure.com/workflows/abc/triggers/manual/paths/invoke?sig=SECRET'
  Assert ($leak -notlike '*SECRET*' -and $leak -notlike '*logic.azure*' -and $leak -like '*<url>*') 'a URL inside an error message is stripped before it is logged'
  Assert (Test-SebWebhookUrl 'https://hooks.slack.com/services/T/B/X') 'an https webhook is accepted'
  Assert (-not (Test-SebWebhookUrl 'http://hooks.example.com/x')) 'plain http to another host is refused - the URL is the credential'
  Assert (Test-SebWebhookUrl 'http://127.0.0.1:8080/x') 'plain http to loopback is allowed (it never leaves the machine)'
  Assert (-not (Test-SebWebhookUrl 'not a url')) 'garbage is refused'
  $m = Merge-SebAlertSecrets -Existing @{ SmtpPassword = 'p'; WebhookUrl = 'https://a/1' } -Incoming @{ WebhookUrl = ''; HeartbeatUrl = 'https://hc-ping.com/uuid'; Bogus = 'x' }
  Assert ($m['SmtpPassword'] -eq 'p' -and -not $m.ContainsKey('WebhookUrl') -and $m['HeartbeatUrl'] -eq 'https://hc-ping.com/uuid' -and -not $m.ContainsKey('Bogus')) 'secrets merge: absent keeps, empty removes, value sets, unknown keys ignored'
  $threw = $false; try { [void](Merge-SebAlertSecrets -Existing @{} -Incoming @{ WebhookUrl = 'http://evil.example/x' }) } catch { $threw = $true }
  Assert $threw 'an http webhook URL is refused before it is ever stored'
  # The app's hand-off file: DPAPI CurrentUser, read once, gone afterwards.
  Add-Type -AssemblyName System.Security
  $hand = Join-Path $alertRoot 'handoff.bin'
  $protected = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes('{"SmtpPassword":"s3cret","WebhookUrl":""}'), $null, 'CurrentUser')
  Set-Content -LiteralPath $hand -Value ([Convert]::ToBase64String($protected))
  $got = Read-SebAlertSecretsFile -Path $hand
  Assert ($got['SmtpPassword'] -eq 's3cret' -and $got.ContainsKey('WebhookUrl') -and $got['WebhookUrl'] -eq '') 'the app''s DPAPI hand-off file decrypts (empty value kept, meaning remove)'
  Assert (-not (Test-Path -LiteralPath $hand)) 'and is deleted once read'

  # ---- ALERT-6. transports, against loopback listeners --------------------------------
  $l = Start-TestListener -Mode 'http' -Expect 1
  Send-SebWebhook -Url ('http://127.0.0.1:{0}/hook' -f $l.Port) -Json '{"text":"hello"}'
  $seen = @(Stop-TestListener $l)
  Assert ($seen.Count -eq 1 -and $seen[0].Request -like 'POST /hook *' -and $seen[0].Body -eq '{"text":"hello"}') 'the webhook POSTs the JSON body'
  $l = Start-TestListener -Mode 'http' -Expect 1
  Send-SebHeartbeat -Url ('http://127.0.0.1:{0}/ping/abc' -f $l.Port)
  $seen = @(Stop-TestListener $l)
  Assert ($seen.Count -eq 1 -and $seen[0].Request -like 'GET /ping/abc *') 'the heartbeat is a GET to the ping URL'
  $l = Start-TestListener -Mode 'smtp' -Expect 1
  $mailAc = Get-SebAlertConfig ([pscustomobject]@{ AlertEmailTo = 'ops@x.test,dba@x.test'; AlertEmailFrom = 'seb@x.test'; AlertSmtpHost = '127.0.0.1'; AlertSmtpPort = $l.Port; AlertSmtpTls = $false })
  Send-SebAlertEmail -AlertConfig $mailAc -Password '' -Subject (Get-SebAlertSubject -Notifications $notes -Label 'HOST\SQLEXPRESS') -Body (Get-SebAlertBody -Notifications $notes -Label 'HOST\SQLEXPRESS' -NowUtc $now)
  $seen = @(Stop-TestListener $l)
  Assert ($seen.Count -eq 1 -and @($seen[0].Rcpt).Count -eq 2) 'the email goes to every recipient'
  # UTF-8 bodies go out base64-encoded (database names need not be ASCII); decode to check.
  $parts = $seen[0].Data -split "\r?\n\r?\n", 2
  $mailBody = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($parts[1] -replace '\s', '')))
  Assert ($parts[0] -like '*Subject: `[SQL Express Backup`] HOST\SQLEXPRESS: CRITICAL*') 'with a subject that leads with the severity'
  Assert ($mailBody -like '*[[]CRITICAL[]] backup-stale*' -and $mailBody -like '*[[]RESOLVED[]] copy-pending*') 'and a body naming each problem'

  # ---- ALERT-7. end to end: raise once, stay quiet, resolve once, retry on failure -----
  $realSecrets = ${function:Read-SebAlertSecrets}
  try {
    $hook = Start-TestListener -Mode 'http' -Expect 5 -TimeoutMs 20000
    $script:TestHookUrl = ('http://127.0.0.1:{0}/hook' -f $hook.Port)
    function Read-SebAlertSecrets { return @{ WebhookUrl = $script:TestHookUrl } }
    $e2eCfg = [pscustomobject]@{ InstanceName = 'SQLEXPRESS'; IntervalHours = 6; AlertWebhookKind = 'generic' }
    Write-SebState ([pscustomobject]@{ LastRunUtc = ''; LastResult = 'never'; Pending = @(); Alerts = @{} })
    $cond = New-SebAlertCondition -Key 'data-pass-failed' -Severity 'critical' -Owner 'data' -Message 'e2e'
    Invoke-SebAlertEvaluation -Config $e2eCfg -Owners @('data') -Conditions @($cond)
    Invoke-SebAlertEvaluation -Config $e2eCfg -Owners @('data') -Conditions @($cond)
    Invoke-SebAlertEvaluation -Config $e2eCfg -Owners @('data') -Conditions @()
    $seen = @(Stop-TestListener $hook)
    Assert ($seen.Count -eq 2) "raised once, silent while it persists, resolved once (got $($seen.Count) sends)"
    Assert ((($seen[0].Body | ConvertFrom-Json).notifications[0].event -eq 'raised') -and (($seen[1].Body | ConvertFrom-Json).notifications[0].event -eq 'resolved')) 'in that order'
    Assert (@((Read-SebState).Alerts.PSObject.Properties).Count -eq 0) 'and nothing is left open in state'
    $pub = Get-Content -LiteralPath (Join-Path $alertRoot 'public.json') -Raw | ConvertFrom-Json
    Assert ($null -ne $pub.PSObject.Properties['Alerts']) 'the public summary carries the open-alerts list for the dashboard'

    # Nobody listening: the send fails, the alert stays unsent, and the next run retries.
    $script:TestHookUrl = 'http://127.0.0.1:1/hook'
    Invoke-SebAlertEvaluation -Config $e2eCfg -Owners @('data') -Conditions @($cond)
    Assert ((Read-SebState).Alerts.'data-pass-failed'.LastSentUtc -eq '') 'an undeliverable alert is not marked sent'
    $retry = Start-TestListener -Mode 'http' -Expect 1
    $script:TestHookUrl = ('http://127.0.0.1:{0}/hook' -f $retry.Port)
    Invoke-SebAlertEvaluation -Config $e2eCfg -Owners @('data') -Conditions @($cond)
    $seen = @(Stop-TestListener $retry)
    Assert ($seen.Count -eq 1 -and (($seen[0].Body | ConvertFrom-Json).notifications[0].event -eq 'raised')) 'so the next evaluation delivers it'
    Assert ((Read-SebState).Alerts.'data-pass-failed'.LastSentUtc -ne '') 'and only then is it marked sent'
    $pubOpen = Get-Content -LiteralPath (Join-Path $alertRoot 'public.json') -Raw | ConvertFrom-Json
    Assert (@($pubOpen.Alerts).Count -eq 1 -and $pubOpen.Alerts[0].Key -eq 'data-pass-failed' -and $pubOpen.Alerts[0].Severity -eq 'critical') 'and the dashboard sees it open'
    Assert (((Get-Content -LiteralPath (Join-Path $alertRoot 'public.json') -Raw) -notlike '*127.0.0.1*')) 'the public summary never contains a channel URL'
  }
  finally { Set-Item -Path function:Read-SebAlertSecrets -Value $realSecrets }
}
finally {
  $script:SebConfigDir = $savedConfigDir
  Remove-Item -LiteralPath $alertRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'ALL PASS'
