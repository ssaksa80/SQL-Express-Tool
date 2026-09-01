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

Write-Host 'ALL PASS'
