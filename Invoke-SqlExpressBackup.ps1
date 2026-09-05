#requires -version 5.1
<#
.SYNOPSIS
  Backs up every database on this host's SQL Server instance to a file share, on a
  6-hour schedule that runs unattended forever.

.DESCRIPTION
  SQL Server Express has no SQL Agent, so it has no native scheduled backup. This
  supplies the schedule from Windows instead - as a Scheduled Task or as an NSSM
  service - and does the parts a naive BACKUP DATABASE loop gets wrong.

  DELIBERATELY STANDALONE: it dot-sources nothing and needs no bundle, so an
  operator can copy this one file to a server and run it, on a box that may never
  receive an application deployment at all.

  WHAT IT ACTUALLY GUARANTEES
    * SQL writes every .bak to a LOCAL staging folder first, and it is proved with
      RESTORE VERIFYONLY before it counts. A share outage therefore costs you the
      offsite copy, not the backup - the verified file is still on disk and the
      next run copies it up before starting anything new.
    * Retention is 3 rolling copies per database plus one archive per calendar day.
      The daily promotion asks "does today already have one?" rather than matching
      a schedule time, because a clock match silently produces NO daily for a day
      whose midnight run was missed - rebooting host, share down, overrunning pass.
    * One failing database does not abort the pass. Exit code says how it went:
      0 = every database was backed up AND landed on the share, 1 = partial (a
      database failed, or a copy is still waiting for the share), 2 = none did.

  THE CREDENTIAL
    Sealed the same way server/src/crypto/masterKey.js seals the app's master key,
    so this host has one crypto story rather than two. A 32-byte key is protected
    with DPAPI LocalMachine plus secondary entropy; the password is then AES-256-CBC
    encrypted under that key and authenticated with HMAC-SHA256 (encrypt-then-MAC).
    AesGcm does not exist on .NET Framework 4.8, which is what PowerShell 5.1 has;
    this is the strongest in-box equivalent.

    Be clear about the limit: any administrator or SYSTEM process on THIS host can
    reverse the sealing, because an unattended service has to be able to. What it
    buys you is that the files are worthless anywhere else - DPAPI LocalMachine
    binds them to this machine. That is also why -Setup steers you toward a login
    holding only dbcreator + db_backupoperator instead of sa.

    The password is never a command-line argument, never logged, and never becomes
    a managed string: it travels SecureString -> SqlCredential, and every byte
    buffer it passes through is zeroed in a finally.

  EVERY MODE NEEDS AN ELEVATED CONSOLE
    The key files are ACL'd to SYSTEM and Administrators with inheritance off, so a
    non-elevated process cannot read them even when the user is an administrator -
    a filtered token does not carry the group. -Status is included in that, because
    it reads the same locked config. The check is up front and says so; without it
    -Setup writes the files, locks them, and then fails reading its own key back.

.EXAMPLE
  Double-click deploy\Backup-SqlExpress.cmd and choose [1] Self test.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -SelfTest
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Setup
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Install -As Task
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Run
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SqlExpressBackup.ps1 -Status
#>
[CmdletBinding()]
param(
  [switch]$Setup,
  [switch]$Install,
  [ValidateSet('Task', 'Service')]
  [string]$As = 'Task',
  [switch]$Run,
  [switch]$Loop,                  # service mode: keep running, one pass per interval
  [switch]$BackupLog,             # transaction-log-only pass for FULL-recovery databases
  [switch]$Status,
  [switch]$Reschedule,            # change interval/retention in config and re-register the schedule
  [switch]$SelfTest,
  [switch]$RestoreList,
  [string]$RestoreInspect,
  [string]$RestoreVerify,
  [switch]$RestoreRun,
  [string]$RestoreFrom,
  [string]$RestoreAs,
  [string]$RestoreDataDir,
  [string]$RestoreLogDir,
  [switch]$RestoreReplace,
  [switch]$RestoreRestrictedUser,
  [switch]$RestoreCloseConnections,
  [string]$RestoreRecoveryState = 'RECOVERY',
  [switch]$RestoreToPoint,
  [string]$Database,
  [datetime]$StopAt,
  [switch]$FullInstall,
  [string]$ShareName = 'SqlBackups',
  [string]$ShareFolder = 'C:\SqlBackups',
  [switch]$Uninstall,
  [switch]$Purge,                 # with -Uninstall: also delete config and key material
  [string]$Instance,              # pin an instance instead of being asked
  [string]$SharePath,
  [string]$StagingPath,
  [int]$IntervalHours = 6,
  [int]$HourlyKeep = 3,
  [int]$DailyKeepDays = 7,
  [ValidateSet('Simple', 'Full')]
  [string]$RecoveryMode = 'Simple', # point-in-time recovery mode; -Reschedule still gates on ContainsKey, so omitting it there means "leave as-is"
  [int]$LogIntervalMinutes = 15,    # Full mode only: how often -BackupLog runs; same ContainsKey gating in -Reschedule
  [int]$FullEveryHours = 24,        # Full mode only: how often the data pass takes a full instead of a diff; same ContainsKey gating in -Reschedule
  [switch]$CompressBackups,       # zip every .bak/.dif/.trn to the share, with a facts sidecar; same ContainsKey gating in -Reschedule
  [switch]$UseWindowsAuth,
  [switch]$NoHashVerify,          # verify copies by length only (very large databases)
  [string]$NssmPath,
  [string]$ConfigDir = "$env:ProgramData\SqlExpressBackup",
  [switch]$DotSourceOnly          # for tests: define the functions, do nothing
)

$ErrorActionPreference = 'Stop'

$script:SebTaskName    = 'SqlExpressBackup'
$script:SebServiceName = 'SqlExpressBackup'
$script:SebEventSource = 'SqlExpressBackup'
$script:SebConfigDir   = $ConfigDir
$script:SebCompression = 'unknown'   # unknown | on | off, probed once per pass

# The ONLY config keys whose VALUES are ever printed. Everything else is reported
# by name with the value replaced. A config file grows fields over time and the
# next one added may well be a secret; an allow-list stays correct when that
# happens, a deny-list does not.
$script:SebShowKeys = @(
  'Instance', 'InstanceName', 'DataSource', 'SharePath', 'StagingPath',
  'IntervalHours', 'HourlyKeep', 'DailyKeepDays', 'RecoveryMode', 'LogIntervalMinutes',
  'FullEveryHours', 'CompressBackups', 'SqlUser', 'UseWindowsAuth',
  'NoHashVerify', 'CreatedUtc', 'Version'
)


# ---------------------------------------------------------------------------
# Windows PowerShell must not search PowerShell 7's module directories.
#
# Installing PowerShell 7 puts its Modules folders on the MACHINE-WIDE
# PSModulePath, ahead of Windows PowerShell's own. A 5.1 process then discovers
# PS7's manifest for a shipped module first, cannot load it because it targets
# Core, and the cmdlets inside it simply do not exist - reported as "the command
# was found in the module 'X', but the module could not be loaded".
#
# It hit Set-Acl first and Get-FileHash immediately after, so fixing it cmdlet by
# cmdlet is whack-a-mole; the search path is the actual fault. Whether it bites at
# all depends on the PSModulePath the process inherits, which is why it appears
# when the one-click launcher starts powershell.exe from cmd and NOT when the same
# script is started from an existing PowerShell session.
function Initialize-SebModulePath {
  if ($PSVersionTable.PSEdition -ne 'Desktop') { return }
  $own = (Join-Path $PSHOME 'Modules').TrimEnd('\')
  $keep = New-Object System.Collections.ArrayList
  [void]$keep.Add($own)
  foreach ($entry in ($env:PSModulePath -split ';')) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $trimmed = $entry.TrimEnd('\')
    if ($trimmed -ieq $own) { continue }
    # Anything under a PowerShell 7 installation is Core-only.
    if ($trimmed -imatch '\\PowerShell\\7[^\\]*\\Modules$') { continue }
    if ($trimmed -imatch '\\Program Files\\PowerShell\\Modules$') { continue }
    [void]$keep.Add($trimmed)
  }
  $env:PSModulePath = ($keep -join ';')
}

# Belt and braces for the same fault: load a shipped module straight out of
# $PSHOME when the command it provides is still missing. Idempotent.
function Import-SebShippedModule {
  param([string]$Command, [string]$Module)
  if (Get-Command $Command -ErrorAction SilentlyContinue) { return }
  Import-Module (Join-Path $PSHOME (Join-Path 'Modules' $Module)) -ErrorAction Stop
}

Initialize-SebModulePath

# =====================================================================
# Pure helpers. No I/O, no clock, no registry - every branch is driven
# directly by deploy/test/sqlexpress-backup.test.ps1.
# =====================================================================

# SQL returns NULL as DBNull, which is NOT $null and is truthy in PowerShell. Every
# nullable column read below goes through here first, or "-not $row.col" silently
# means the opposite of what it reads like.
function Get-SebValue {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.DBNull]) { return $null }
  return $Value
}

# Database names may legally contain characters that are illegal in a path.
function Get-SebSafeName {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return '_' }
  $safe = $Name -replace '[\\/:*?"<>|]', '_'
  $safe = $safe.Trim().TrimEnd('.')
  if ([string]::IsNullOrWhiteSpace($safe)) { return '_' }
  return $safe
}

function Get-SebQuotedName {
  param([string]$Name)
  return '[' + ($Name -replace '\]', ']]') + ']'
}

function Get-SebSqlLiteral {
  param([string]$Text)
  return "'" + ($Text -replace "'", "''") + "'"
}

# Which databases are worth backing up, given sys.databases-shaped rows.
#   tempdb  - cannot be backed up at all.
#   model   - a template; nothing in it is worth a restore.
#   master and msdb ARE included: without them a rebuilt instance has lost every
#           login and job, which is exactly the situation you are restoring in.
# Snapshots are derived files, and a standby database is already someone else's
# log-shipping target - backing either up produces a file you cannot use.
function Select-SebDatabase {
  param([object[]]$Rows = @())
  $excluded = @('tempdb', 'model')
  $keep = New-Object System.Collections.ArrayList
  foreach ($row in $Rows) {
    $name = [string](Get-SebValue $row.name)
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ($excluded -contains $name.ToLowerInvariant()) { continue }

    $state = Get-SebValue $row.state
    if ($null -eq $state -or [int]$state -ne 0) { continue }          # 0 = ONLINE

    $source = Get-SebValue $row.source_database_id
    if ($null -ne $source -and [int]$source -gt 0) { continue }       # a snapshot

    $standby = Get-SebValue $row.is_in_standby
    if ($null -ne $standby -and [bool]$standby) { continue }

    [void]$keep.Add($name)
  }
  return , @($keep.ToArray())
}

function Get-SebBackupPath {
  param(
    [string]$Root,
    [string]$HostName,
    [string]$InstanceLabel,
    [string]$Database,
    [ValidateSet('hourly', 'daily', 'diff', 'log')]
    [string]$Kind
  )
  $path = Join-Path $Root (Get-SebSafeName $HostName)
  $path = Join-Path $path (Get-SebSafeName $InstanceLabel)
  $path = Join-Path $path (Get-SebSafeName $Database)
  return (Join-Path $path $Kind)
}

function Get-SebFileName {
  param([string]$Database, [datetime]$Stamp, [ValidateSet('bak','dif','trn')][string]$Extension = 'bak')
  return ('{0}_{1}.{2}' -f (Get-SebSafeName $Database), $Stamp.ToString('yyyyMMdd-HHmmss'), $Extension)
}

function Get-SebCompressedName { param([string]$PlainName) return ($PlainName + '.zip') }
function Get-SebSidecarName { param([string]$Name) return ($Name + '.meta.json') }

# Trust the name over the mtime. Copying a file to a share can move LastWriteTime,
# and retention that sorts on a timestamp the copy rewrote will delete the wrong
# file. The stamp is baked into the name at BACKUP time and never changes after.
function Get-SebStampFromName {
  param([string]$Name, [datetime]$Fallback)
  $match = [regex]::Match($Name, '_(\d{8})-(\d{6})\.(bak|dif|trn)(\.zip)?$')
  if (-not $match.Success) { return $Fallback }
  $parsed = [datetime]::MinValue
  $ok = [datetime]::TryParseExact(
    ($match.Groups[1].Value + $match.Groups[2].Value),
    'yyyyMMddHHmmss',
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::None,
    [ref]$parsed)
  if ($ok) { return $parsed }
  return $Fallback
}

# The whole retention decision, as one pure function.
#
# HourlyFiles is the list as it will be AFTER this pass writes its file, so the
# caller appends the new one before calling. DailyFiles is the list as it is NOW,
# before any promotion - the promotion decision is this function's to make.
#
# Returns PromoteToDaily plus the exact names to delete from each folder.
function Get-SebRetentionPlan {
  param(
    [object[]]$HourlyFiles = @(),
    [object[]]$DailyFiles = @(),
    [datetime]$Now,
    [int]$HourlyKeep = 3,
    [int]$DailyKeepDays = 7
  )
  if ($HourlyKeep -lt 1) { $HourlyKeep = 1 }
  if ($DailyKeepDays -lt 1) { $DailyKeepDays = 1 }

  $hourly = @($HourlyFiles | Sort-Object -Property Timestamp -Descending)
  $hourlyDelete = @()
  if ($hourly.Count -gt $HourlyKeep) {
    $hourlyDelete = @($hourly[$HourlyKeep..($hourly.Count - 1)] | ForEach-Object { $_.Name })
  }

  $daily = @($DailyFiles | Sort-Object -Property Timestamp -Descending)
  $today = @($daily | Where-Object { $_.Timestamp.Date -eq $Now.Date })
  $promote = ($today.Count -eq 0)

  # A promotion consumes one of the slots, so the existing files compete for one
  # fewer. Without this the folder sits at DailyKeepDays + 1 for the rest of the day.
  $promoteCount = 0
  if ($promote) { $promoteCount = 1 }
  $keepExisting = $DailyKeepDays - $promoteCount
  if ($keepExisting -lt 0) { $keepExisting = 0 }

  $dailyDelete = @()
  if ($daily.Count -gt $keepExisting) {
    $dailyDelete = @($daily[$keepExisting..($daily.Count - 1)] | ForEach-Object { $_.Name })
  }

  return [pscustomobject]@{
    PromoteToDaily = $promote
    HourlyDelete   = @($hourlyDelete)
    DailyDelete    = @($dailyDelete)
  }
}

# Chain-safe retention for FULL-recovery databases. Keep the oldest full that is still
# newer than the horizon (that is the base a restore to the oldest recoverable point
# needs) and every full newer than it; keep every diff/log whose LastLSN reaches into or
# past that retained full (i.e. still needed to roll it forward). Prune only segments
# that end strictly before the retained full begins. If every full is already at or
# before the horizon, keep the single newest one instead - never leave zero fulls. GFS
# (a later feature) layers extra "keep" rules on top of this floor.
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
  $fullsSorted = @($Fulls | Sort-Object -Property Timestamp, FirstLSN)   # oldest first
  if ($fullsSorted.Count -eq 0) { return $result }

  $horizon = $Now.AddDays(-1 * $DailyKeepDays)
  # The oldest full we must keep: the OLDEST full that is still newer than the horizon
  # anchors the window - it is the base a restore to the oldest recoverable point needs,
  # so it and every full newer than it are kept, and every full older than it is
  # prunable. If every full is already at or before the horizon, keep the single newest
  # one instead - never leave zero fulls.
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

# Render a config object for human eyes. Allow-list only; see $SebShowKeys.
function Format-SebConfigFacts {
  param($Config)
  $lines = New-Object System.Collections.ArrayList
  if ($null -eq $Config) { return , @() }
  foreach ($prop in @($Config.PSObject.Properties)) {
    if ($script:SebShowKeys -contains $prop.Name) {
      [void]$lines.Add(('   {0} = {1}' -f $prop.Name, $prop.Value))
    }
    else {
      [void]$lines.Add(('   {0} = (value hidden)' -f $prop.Name))
    }
  }
  return , @($lines.ToArray())
}

# Instance discovery. The registry and service lookups are injected so this is
# testable on a machine with no SQL Server on it at all.
function Get-SebInstanceList {
  param(
    [scriptblock]$RegistryReader,
    [scriptblock]$ServiceReader,
    [string]$HostName = $env:COMPUTERNAME
  )
  if (-not $RegistryReader) {
    $RegistryReader = { param([string]$Path) Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue }
  }
  if (-not $ServiceReader) {
    $ServiceReader = { param([string]$Name) Get-Service -Name $Name -ErrorAction SilentlyContinue }
  }

  $names = & $RegistryReader 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
  if ($null -eq $names) { return , @() }

  $found = New-Object System.Collections.ArrayList
  foreach ($prop in @($names.PSObject.Properties)) {
    if ($prop.Name -like 'PS*') { continue }
    $instanceName = $prop.Name
    $instanceId = [string]$prop.Value
    if ([string]::IsNullOrWhiteSpace($instanceId)) { continue }

    $edition = ''
    $version = ''
    $setup = & $RegistryReader ('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\' + $instanceId + '\Setup')
    if ($null -ne $setup) {
      if ($setup.PSObject.Properties['Edition']) { $edition = [string]$setup.Edition }
      if ($setup.PSObject.Properties['Version']) { $version = [string]$setup.Version }
    }

    $serviceName = 'MSSQLSERVER'
    $dataSource = $HostName
    if ($instanceName -ne 'MSSQLSERVER') {
      $serviceName = 'MSSQL$' + $instanceName
      $dataSource = $HostName + '\' + $instanceName
    }

    $serviceStatus = 'not-found'
    $service = & $ServiceReader $serviceName
    if ($null -ne $service) { $serviceStatus = [string]$service.Status }

    [void]$found.Add([pscustomobject]@{
        InstanceName  = $instanceName
        InstanceId    = $instanceId
        Edition       = $edition
        Version       = $version
        ServiceName   = $serviceName
        ServiceStatus = $serviceStatus
        DataSource    = $dataSource
        IsExpress     = ($edition -match 'Express')
      })
  }
  return , @($found.ToArray())
}

# =====================================================================
# Sealing. Protect-/Unprotect-SebBytes are pure given a key, so the
# round-trip and the tamper rejection are both testable without DPAPI.
# =====================================================================

function Get-SebSubKey {
  param([byte[]]$Master, [string]$Label)
  $mac = New-Object System.Security.Cryptography.HMACSHA256(, $Master)
  try { return $mac.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Label)) }
  finally { $mac.Dispose() }
}

function Test-SebFixedTimeEqual {
  param([byte[]]$Left, [byte[]]$Right)
  if ($null -eq $Left -or $null -eq $Right) { return $false }
  if ($Left.Length -ne $Right.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $Left.Length; $i++) { $diff = $diff -bor ($Left[$i] -bxor $Right[$i]) }
  return ($diff -eq 0)
}

# Layout: [version 1][IV 16][ciphertext][HMAC-SHA256 32], base64.
# Encrypt-then-MAC over version+IV+ciphertext, with separate keys derived for
# encryption and authentication so neither is used for two purposes.
function Protect-SebBytes {
  param(
    [Parameter(Mandatory = $true)][byte[]]$Plain,
    [Parameter(Mandatory = $true)][byte[]]$Master
  )
  $encKey = Get-SebSubKey -Master $Master -Label 'seb-enc-v1'
  $macKey = Get-SebSubKey -Master $Master -Label 'seb-mac-v1'
  $aes = [System.Security.Cryptography.Aes]::Create()
  try {
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $encKey
    $aes.GenerateIV()

    $encryptor = $aes.CreateEncryptor()
    try { $cipher = $encryptor.TransformFinalBlock($Plain, 0, $Plain.Length) }
    finally { $encryptor.Dispose() }

    $body = New-Object byte[] (1 + $aes.IV.Length + $cipher.Length)
    $body[0] = 1
    [System.Array]::Copy($aes.IV, 0, $body, 1, $aes.IV.Length)
    [System.Array]::Copy($cipher, 0, $body, 1 + $aes.IV.Length, $cipher.Length)

    $mac = New-Object System.Security.Cryptography.HMACSHA256(, $macKey)
    try { $tag = $mac.ComputeHash($body) } finally { $mac.Dispose() }

    $sealed = New-Object byte[] ($body.Length + $tag.Length)
    [System.Array]::Copy($body, 0, $sealed, 0, $body.Length)
    [System.Array]::Copy($tag, 0, $sealed, $body.Length, $tag.Length)
    return [Convert]::ToBase64String($sealed)
  }
  finally {
    [System.Array]::Clear($encKey, 0, $encKey.Length)
    [System.Array]::Clear($macKey, 0, $macKey.Length)
    $aes.Dispose()
  }
}

function Unprotect-SebBytes {
  param(
    [Parameter(Mandatory = $true)][string]$Blob,
    [Parameter(Mandatory = $true)][byte[]]$Master
  )
  $sealed = [Convert]::FromBase64String($Blob)
  if ($sealed.Length -lt (1 + 16 + 32 + 16)) {
    throw 'sealed value is too short to be a valid seal'
  }

  $macKey = Get-SebSubKey -Master $Master -Label 'seb-mac-v1'
  $encKey = Get-SebSubKey -Master $Master -Label 'seb-enc-v1'
  $aes = [System.Security.Cryptography.Aes]::Create()
  try {
    $bodyLength = $sealed.Length - 32
    $body = New-Object byte[] $bodyLength
    [System.Array]::Copy($sealed, 0, $body, 0, $bodyLength)
    $tag = New-Object byte[] 32
    [System.Array]::Copy($sealed, $bodyLength, $tag, 0, 32)

    # Authenticate BEFORE decrypting. Decrypting first and checking after leaks a
    # padding oracle, and returns attacker-chosen bytes on the paths that forget.
    $mac = New-Object System.Security.Cryptography.HMACSHA256(, $macKey)
    try { $expected = $mac.ComputeHash($body) } finally { $mac.Dispose() }
    if (-not (Test-SebFixedTimeEqual $expected $tag)) {
      throw 'sealed value failed its integrity check - it was truncated, corrupted or tampered with'
    }
    if ($body[0] -ne 1) { throw ('unsupported seal version {0}' -f $body[0]) }

    $iv = New-Object byte[] 16
    [System.Array]::Copy($body, 1, $iv, 0, 16)
    $cipherLength = $bodyLength - 17
    $cipher = New-Object byte[] $cipherLength
    [System.Array]::Copy($body, 17, $cipher, 0, $cipherLength)

    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $encKey
    $aes.IV = $iv
    $decryptor = $aes.CreateDecryptor()
    try { return $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length) }
    finally { $decryptor.Dispose() }
  }
  finally {
    [System.Array]::Clear($macKey, 0, $macKey.Length)
    [System.Array]::Clear($encKey, 0, $encKey.Length)
    $aes.Dispose()
  }
}

# String forms exist so the round-trip is directly testable. The live credential
# path never uses them - it goes SecureString to SecureString.
function Protect-SebString {
  param([Parameter(Mandatory = $true)][string]$Plain, [Parameter(Mandatory = $true)][byte[]]$Master)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
  try { return Protect-SebBytes -Plain $bytes -Master $Master }
  finally { [System.Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-SebString {
  param([Parameter(Mandatory = $true)][string]$Blob, [Parameter(Mandatory = $true)][byte[]]$Master)
  $bytes = Unprotect-SebBytes -Blob $Blob -Master $Master
  try { return [System.Text.Encoding]::UTF8.GetString($bytes) }
  finally { [System.Array]::Clear($bytes, 0, $bytes.Length) }
}

function Protect-SebSecureString {
  param(
    [Parameter(Mandatory = $true)][System.Security.SecureString]$Secret,
    [Parameter(Mandatory = $true)][byte[]]$Master
  )
  $bstr = [IntPtr]::Zero
  $chars = $null
  $bytes = $null
  try {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    $length = [System.Runtime.InteropServices.Marshal]::ReadInt32($bstr, -4) / 2
    $chars = New-Object char[] $length
    for ($i = 0; $i -lt $length; $i++) {
      $chars[$i] = [char][System.Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2)
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($chars)
    return Protect-SebBytes -Plain $bytes -Master $Master
  }
  finally {
    if ($null -ne $chars) { [System.Array]::Clear($chars, 0, $chars.Length) }
    if ($null -ne $bytes) { [System.Array]::Clear($bytes, 0, $bytes.Length) }
    if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
}

function Unprotect-SebSecureString {
  param(
    [Parameter(Mandatory = $true)][string]$Blob,
    [Parameter(Mandatory = $true)][byte[]]$Master
  )
  $bytes = Unprotect-SebBytes -Blob $Blob -Master $Master
  $chars = $null
  try {
    $chars = [System.Text.Encoding]::UTF8.GetChars($bytes)
    $secure = New-Object System.Security.SecureString
    foreach ($char in $chars) { $secure.AppendChar($char) }
    $secure.MakeReadOnly()
    return $secure
  }
  finally {
    if ($null -ne $chars) { [System.Array]::Clear($chars, 0, $chars.Length) }
    [System.Array]::Clear($bytes, 0, $bytes.Length)
  }
}

# SYSTEM and Administrators, inheritance off. These files are the whole point of
# the exercise; leaving them to inherit whatever ProgramData hands out is not a
# decision anyone made on purpose.
# The .bak is created by the SQL Server SERVICE ACCOUNT, not by whoever runs this
# script. On Express that account is normally a virtual account - NT Service\MSSQL$
# plus the instance name - which is a member of nothing and therefore has no write
# access to a folder an administrator just created. Assuming "SQL can obviously
# write to a local folder" is how this fails on every install with
# "Operating system error 5(Access is denied.)" and nothing else to go on.
# The account a service runs as, out of the registry. Same value Win32_Service
# reports in StartName, and the registry is where the SCM keeps it.
#
# This exists for speed, and the margin is not marginal. Win32_Service took 12.6
# SECONDS on the first call on this host and 3.4 on later ones; the registry read is
# 21ms warm. WMI is heavily instrumented by endpoint protection, so every query pays
# for that inspection, and this call sits on the critical path of both setup and the
# self test. It was measured, not guessed: a live self test spent four and a half
# minutes between two adjacent log lines, and this was the line.
function Get-SebServiceAccountFromRegistry {
  param([string]$ServiceName, [scriptblock]$Reader)
  if ([string]::IsNullOrWhiteSpace($ServiceName)) { return '' }
  # A service name is a registry KEY name, so it cannot contain a separator. Refuse
  # rather than sanitise: there is then no escaping to reason about.
  #
  # -LiteralPath below already makes traversal impossible, so this guard is belt and
  # braces - and that made its first test VACUOUS, which the mutation check caught:
  # removing the guard changed no result, because the path never resolved either way.
  # The seam exists so the guard's real behaviour can be asserted: it must refuse
  # BEFORE touching the registry at all, which is observable even when both paths
  # would return the same empty string.
  if ($ServiceName.Contains([char]92) -or $ServiceName.Contains('/')) { return '' }
  $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $ServiceName
  try {
    if ($Reader) { $v = & $Reader $key }
    else { $v = (Get-ItemProperty -LiteralPath $key -Name 'ObjectName' -ErrorAction SilentlyContinue).ObjectName }
    if ($null -eq $v) { return '' }
    return [string]$v
  }
  catch { return '' }
}

function Get-SebServiceAccount {
  param([string]$ServiceName, [scriptblock]$ServiceQuery)
  # An injected query wins outright - that is how the suite drives this without a
  # real service, and a fast path that ignored it would make those tests vacuous.
  if ($ServiceQuery) {
    $service = & $ServiceQuery $ServiceName
    if ($null -eq $service) { return '' }
    return [string]$service.StartName
  }

  $fromRegistry = Get-SebServiceAccountFromRegistry -ServiceName $ServiceName
  if (-not [string]::IsNullOrWhiteSpace($fromRegistry)) { return $fromRegistry }

  # Fall back to WMI rather than concluding the service has no account. An empty
  # answer here means staging never gets granted, which is the defect that makes
  # every backup fail with operating system error 5 - worth three slow seconds.
  $service = Get-CimInstance -ClassName Win32_Service `
    -Filter ("Name='" + ($ServiceName -replace "'", "''") + "'") -ErrorAction SilentlyContinue
  if ($null -eq $service) { return '' }
  return [string]$service.StartName
}

# Win32_Service reports the built-in accounts under names an ACL rule will not
# accept. Everything else - a virtual account, a domain account - is already in the
# form NTAccount wants.
function Get-SebAclIdentity {
  param([string]$StartName)
  if ([string]::IsNullOrWhiteSpace($StartName)) { return '' }
  $name = $StartName.Trim()
  if ($name -eq 'LocalSystem' -or $name -eq '.\LocalSystem') { return 'NT AUTHORITY\SYSTEM' }
  if ($name -eq 'LocalService') { return 'NT AUTHORITY\LOCAL SERVICE' }
  if ($name -eq 'NetworkService') { return 'NT AUTHORITY\NETWORK SERVICE' }
  return $name
}

# Staging is NOT a secret store, so it does not get Set-SebSecretAcl's two-identity
# lockdown: the SQL service account has to be able to create files here, and the
# account running the pass has to be able to read and delete them.
function Set-SebStagingAcl {
  param([string]$Path, [string]$SqlAccount, [string[]]$AlsoGrant = @())
  Import-SebShippedModule -Command 'Set-Acl' -Module 'Microsoft.PowerShell.Security'
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $none = [System.Security.AccessControl.PropagationFlags]::None
  foreach ($sid in @(
      (New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)),
      (New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)))) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, 'Allow')))
  }
  foreach ($extra in (@($SqlAccount) + @($AlsoGrant))) {
    if ([string]::IsNullOrWhiteSpace($extra)) { continue }
    $account = New-Object System.Security.Principal.NTAccount($extra)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'Modify', $inherit, $none, 'Allow')))
  }
  Set-Acl -Path $Path -AclObject $acl
}

# Prove it rather than assert it. A real BACKUP is the only thing that actually
# answers "can the engine write here" - a probe file written by THIS process proves
# nothing, because this process is not the one that writes the .bak. model is the
# smallest database on any instance, and COPY_ONLY means the probe disturbs no
# differential base.
function Test-SebStagingWritable {
  param($Connection, [string]$Staging, [string]$SqlAccount)
  $probe = Join-Path $Staging ('seb-write-probe-' + [Guid]::NewGuid().ToString('N') + '.bak')
  try {
    Invoke-SebSqlNonQuery -Connection $Connection -Sql (
      'BACKUP DATABASE [model] TO DISK = {0} WITH COPY_ONLY, INIT, FORMAT' -f (Get-SebSqlLiteral $probe))
  }
  catch {
    if ($_.Exception.Message -match 'Operating system error 5') {
      throw ("SQL Server cannot write to the staging folder '$Staging'. The .bak is created by the SQL " +
        "Server service account (" + $SqlAccount + "), not by you, so that account needs Modify there. " +
        "Setup tried to grant it and the engine still refused - check that the folder is on a local " +
        "drive the service account can reach. Original error: " + $_.Exception.Message)
    }
    throw
  }
  finally {
    # Never let the cleanup throw. The probe file is created by the SQL service
    # account, so removing it can fail on rights - and a throw here replaces the
    # real diagnostic with an unrelated one from the finally block.
    try { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch { }
  }
}

function Set-SebSecretAcl {
  param([string]$Path)
  Import-SebShippedModule -Command 'Set-Acl' -Module 'Microsoft.PowerShell.Security'
  $isContainer = Test-Path -LiteralPath $Path -PathType Container

  # Build a FRESH security object rather than reading the existing one and editing
  # it. Two reasons, both of which have bitten:
  #   * Get-Acl reads the audit section too, and Set-Acl then tries to write it
  #     back. That needs SeSecurityPrivilege, which even an elevated console does
  #     not necessarily hold - so the call fails with a privilege error about a
  #     section nobody asked to change.
  #   * FileInfo.GetAccessControl() is an instance method on .NET Framework and was
  #     removed on .NET Core, so that route works under 5.1 and breaks under pwsh 7.
  # A fresh object touches only the access rules, so Set-Acl writes only the DACL,
  # and SetAccessRuleProtection($true, $false) means the result is exactly the two
  # rules below with nothing inherited behind them.
  if ($isContainer) { $acl = New-Object System.Security.AccessControl.DirectorySecurity }
  else { $acl = New-Object System.Security.AccessControl.FileSecurity }
  $acl.SetAccessRuleProtection($true, $false)
  $sids = @(
    (New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)),
    (New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null))
  )
  $inherit = [System.Security.AccessControl.InheritanceFlags]::None
  if ($isContainer) {
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  }
  foreach ($sid in $sids) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      $sid, 'FullControl', $inherit, [System.Security.AccessControl.PropagationFlags]::None, 'Allow')
    $acl.AddAccessRule($rule)
  }
  Set-Acl -Path $Path -AclObject $acl
}

# Every mode needs elevation, and it is better to say so than to let the operator
# discover it as "Access to the path is denied" three steps into -Setup - by which
# point the key files exist, are locked, and cannot be read back by the process
# that just wrote them. SYSTEM passes this check too: its token carries
# BUILTIN\Administrators enabled, which is what runs the scheduled pass.
function Test-SebElevated {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SebElevated {
  param([string]$Mode, [scriptblock]$ElevationCheck)
  $check = $ElevationCheck
  if (-not $check) { $check = { Test-SebElevated } }
  if (& $check) { return }
  throw ("-$Mode needs an elevated console. The sealed credential is deliberately readable " +
    "only by SYSTEM and Administrators, and registering the schedule to run as SYSTEM needs " +
    "elevation as well. Re-run this from a 'Run as administrator' prompt.")
}

function Get-SebKeyPath { return (Join-Path $script:SebConfigDir 'key.bin') }
function Get-SebEntropyPath { return (Join-Path $script:SebConfigDir 'key.entropy') }
function Get-SebCredPath { return (Join-Path $script:SebConfigDir 'cred.dat') }
function Get-SebConfigPath { return (Join-Path $script:SebConfigDir 'config.json') }
function Get-SebStatePath { return (Join-Path $script:SebConfigDir 'state.json') }
function Get-SebPublicPath { return (Join-Path $script:SebConfigDir 'public.json') }
function Get-SebLogDir { return (Join-Path $script:SebConfigDir 'logs') }

# The secondary entropy sits beside the key on purpose, and it is worth being
# honest about what that does and does not buy. It does NOT stop an administrator
# here - they have both files. It DOES stop any other process on this machine from
# calling Unprotect on a stolen key.bin, which a LocalMachine blob with no entropy
# would otherwise permit outright.
function Get-SebMasterKey {
  param([switch]$Create)
  Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
  $keyPath = Get-SebKeyPath
  $entropyPath = Get-SebEntropyPath

  if ((Test-Path -LiteralPath $keyPath) -and (Test-Path -LiteralPath $entropyPath)) {
    $sealed = [System.IO.File]::ReadAllBytes($keyPath)
    $entropy = [System.IO.File]::ReadAllBytes($entropyPath)
    try {
      return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $sealed, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    catch {
      throw ("DPAPI could not open $keyPath on this machine. The seal is machine-bound: " +
        "if this host was rebuilt or the files were copied from another server, the sealed " +
        "credential cannot be recovered - re-run -Setup. (" + $_.Exception.Message + ')')
    }
  }

  if (-not $Create) { throw "no sealed key at $keyPath - run -Setup first" }

  $master = New-Object byte[] 32
  $entropy = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($master); $rng.GetBytes($entropy) } finally { $rng.Dispose() }

  $sealed = [System.Security.Cryptography.ProtectedData]::Protect(
    $master, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
  [System.IO.File]::WriteAllBytes($keyPath, $sealed)
  [System.IO.File]::WriteAllBytes($entropyPath, $entropy)
  [System.Array]::Clear($entropy, 0, $entropy.Length)
  Set-SebSecretAcl $keyPath
  Set-SebSecretAcl $entropyPath
  return $master
}

# =====================================================================
# Logging
# =====================================================================

function Write-SebLog {
  param(
    [string]$Message,
    [ValidateSet('INFO', 'WARN', 'ERROR')]
    [string]$Level = 'INFO'
  )
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  if ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
  elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
  else { Write-Host $line }

  $logDir = Get-SebLogDir
  try {
    if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
    $file = Join-Path $logDir ('backup-{0}.log' -f (Get-Date -Format 'yyyyMM'))
    Add-Content -LiteralPath $file -Value $line -Encoding ASCII
  }
  catch {
    # A log that cannot be written must not take the backup down with it.
    Write-Host ('   (log write failed: {0})' -f $_.Exception.Message)
  }

  if ($Level -ne 'INFO') {
    try {
      if (-not [System.Diagnostics.EventLog]::SourceExists($script:SebEventSource)) {
        New-EventLog -LogName Application -Source $script:SebEventSource -ErrorAction Stop
      }
      $entryType = 'Warning'
      if ($Level -eq 'ERROR') { $entryType = 'Error' }
      Write-EventLog -LogName Application -Source $script:SebEventSource -EntryType $entryType -EventId 9001 -Message $Message -ErrorAction Stop
    }
    catch {
      # Source registration needs admin. Not fatal - the file log still has it.
    }
  }
}

function Remove-SebOldLog {
  param([int]$KeepMonths = 6)
  $logDir = Get-SebLogDir
  if (-not (Test-Path -LiteralPath $logDir)) { return }
  $cutoff = (Get-Date).AddMonths(-$KeepMonths)
  Get-ChildItem -LiteralPath $logDir -Filter 'backup-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# =====================================================================
# Config and state
# =====================================================================

# A NON-SECRET summary, readable without elevation.
#
# config.json is locked to SYSTEM + Administrators, which is right for a file that
# sits beside a sealed credential - but it means an unelevated dashboard cannot show
# even the share path or the last run result. Rather than loosen the real config,
# write a second file containing ONLY the keys already on the display allow-list,
# plus the run summary. Same allow-list as Format-SebConfigFacts, so a field added
# to config.json in future is excluded from BOTH by default rather than leaking into
# this one. Nothing here is a secret and nothing here is read back as authority.
function Write-SebPublicSummary {
  param($Config, $State)
  $public = New-Object psobject
  if ($null -ne $Config) {
    foreach ($prop in @($Config.PSObject.Properties)) {
      if ($script:SebShowKeys -contains $prop.Name) {
        Add-Member -InputObject $public -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
      }
    }
  }
  if ($null -ne $State) {
    Add-Member -InputObject $public -MemberType NoteProperty -Name 'LastRunUtc' -Value $State.LastRunUtc -Force
    Add-Member -InputObject $public -MemberType NoteProperty -Name 'LastResult' -Value $State.LastResult -Force
    Add-Member -InputObject $public -MemberType NoteProperty -Name 'PendingCount' -Value (@($State.Pending).Count) -Force
  }
  Add-Member -InputObject $public -MemberType NoteProperty -Name 'HostName' -Value $env:COMPUTERNAME -Force
  Add-Member -InputObject $public -MemberType NoteProperty -Name 'WrittenUtc' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force
  try {
    $public | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-SebPublicPath) -Encoding ASCII
  }
  catch {
    # A dashboard convenience must never take a backup down with it.
    Write-Host ('   (could not write the public summary: {0})' -f $_.Exception.Message)
  }
}

function Read-SebConfig {
  $path = Get-SebConfigPath
  if (-not (Test-Path -LiteralPath $path)) { throw "no config at $path - run -Setup first" }
  return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Write-SebConfig {
  param($Config)
  $path = Get-SebConfigPath
  $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding ASCII
  Set-SebSecretAcl $path
  # Deliberately AFTER the lockdown, and deliberately not locked itself.
  Write-SebPublicSummary -Config $Config -State (Read-SebState)
}

function Read-SebState {
  $path = Get-SebStatePath
  if (-not (Test-Path -LiteralPath $path)) {
    return [pscustomobject]@{ LastRunUtc = ''; LastResult = 'never'; Pending = @() }
  }
  try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
  catch { return [pscustomobject]@{ LastRunUtc = ''; LastResult = 'unreadable'; Pending = @() } }
}

function Write-SebState {
  param($State)
  $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-SebStatePath) -Encoding ASCII
  # NOT ACL'd. Locking it stops an unelevated -SelfTest rewriting its own throwaway
  # state, and it was never the right control anyway: what matters is that the pass
  # does not act on paths it reads back. See Test-SebPendingEntry.
  $cfg = $null
  try { $cfg = Read-SebConfig } catch { $cfg = $null }
  Write-SebPublicSummary -Config $cfg -State $State
}

# =====================================================================
# SQL
# =====================================================================

function New-SebSqlConnection {
  param(
    [string]$DataSource,
    [string]$User,
    [System.Security.SecureString]$Password,
    [switch]$WindowsAuth,
    [int]$TimeoutSec = 15
  )
  $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
  $builder['Data Source'] = $DataSource
  $builder['Initial Catalog'] = 'master'
  $builder['Connect Timeout'] = $TimeoutSec
  $builder['Application Name'] = 'SqlExpressBackup'

  if ($WindowsAuth) {
    $builder['Integrated Security'] = $true
    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $connection.Open()
    return $connection
  }

  # SqlCredential, not "User ID=...;Password=..." in the connection string. The
  # password stays a SecureString the whole way in, so it never lands in a managed
  # string that a crash dump or a transcript could pick up.
  if (-not $Password.IsReadOnly()) { $Password.MakeReadOnly() }
  $credential = New-Object System.Data.SqlClient.SqlCredential($User, $Password)
  $connection = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString, $credential)
  $connection.Open()
  return $connection
}

function Invoke-SebSqlTable {
  param($Connection, [string]$Sql, [int]$TimeoutSec = 60)
  $command = $Connection.CreateCommand()
  try {
    $command.CommandText = $Sql
    $command.CommandTimeout = $TimeoutSec
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table = New-Object System.Data.DataTable
    [void]$adapter.Fill($table)
    return , @($table.Rows)
  }
  finally { $command.Dispose() }
}

function Invoke-SebSqlNonQuery {
  param($Connection, [string]$Sql, [int]$TimeoutSec = 0)
  $command = $Connection.CreateCommand()
  try {
    $command.CommandText = $Sql
    $command.CommandTimeout = $TimeoutSec   # 0 = no limit; a BACKUP can take hours
    [void]$command.ExecuteNonQuery()
  }
  finally { $command.Dispose() }
}

# Pull every SQL error number out of a failed call. PowerShell wraps the
# SqlException in a MethodInvocationException, so the real one is down the
# InnerException chain.
# ---------------------------------------------------------------------------
# Progress, emitted as machine-readable lines on stdout.
#
# The console parses these to drive a real progress bar; a human reading the log
# sees them too and they are meant to be legible either way. Deliberately a plain
# text protocol rather than anything structured: the engine has to keep working when
# it is run by hand in a console with nothing parsing it at all.
#
# SQL Server reports backup percentage through informational messages when the
# statement carries WITH STATS. Those arrive on the connection's InfoMessage event,
# not in any result set, so the handler below is the only way to see them.
function Write-SebProgress {
  param([string]$Database, [int]$Percent, [string]$Stage)
  Write-Host ('[PROGRESS] db=' + $Database + ' pct=' + $Percent + ' stage=' + $Stage)
}

function Write-SebStage {
  param([string]$Database, [string]$Stage)
  Write-Host ('[STAGE] db=' + $Database + ' stage=' + $Stage)
}

function Write-SebJob {
  param([int]$Index, [int]$Total, [string]$Database)
  Write-Host ('[JOB] index=' + $Index + ' total=' + $Total + ' db=' + $Database)
}

# Percent messages look like "10 percent processed." in English and are localized
# elsewhere, so the digits are taken and the words ignored.
function Get-SebPercentFromMessage {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return -1 }
  $m = [regex]::Match($Message, '(\d{1,3})\s*(?:percent|%)')
  if (-not $m.Success) { return -1 }
  $v = [int]$m.Groups[1].Value
  if ($v -lt 0 -or $v -gt 100) { return -1 }
  return $v
}

function Get-SebSqlErrorNumbers {
  param($ErrorRecord)
  $ex = $ErrorRecord.Exception
  while ($null -ne $ex -and -not ($ex -is [System.Data.SqlClient.SqlException])) { $ex = $ex.InnerException }
  if ($null -eq $ex) { return , @() }
  $numbers = New-Object System.Collections.ArrayList
  foreach ($e in $ex.Errors) { [void]$numbers.Add([int]$e.Number) }
  return , @($numbers.ToArray())
}

# Decide "this edition cannot compress backups" from the ERROR NUMBER, not the
# text. 1844 is stable across versions; the wording is not - SQL Server 2025 says
# "is not supported on Express Edition (64-bit)" where older servers said "is not
# supported in this edition of SQL Server" - and it is localized besides, so a text
# match fails in two independent ways. Matching text was exactly this bug: every
# backup on Express rethrew instead of falling back, so nothing was ever backed up
# on the one edition this script exists for. The text check survives only as a
# fallback for a driver that hands back no error collection.
function Test-SebCompressionUnsupported {
  param([int[]]$Numbers = @(), [string]$Message = '')
  if ($Numbers -contains 1844) { return $true }
  if ($Message -match '(?i)compression.*not supported') { return $true }
  return $false
}

# 4214 = no current full backup: the log chain has no base yet. A pure predicate,
# mirroring Test-SebCompressionUnsupported, so the decision is testable without SQL.
function Test-SebLogNeedsBase {
  param([int[]]$Numbers = @())
  return ($Numbers -contains 4214)
}

# Probe the edition up front so the first backup of a pass is not a guaranteed
# failure. EngineEdition 4 is Express, which has no backup compression at all.
function Get-SebEngineEdition {
  param($Connection)
  $rows = Invoke-SebSqlTable -Connection $Connection -Sql "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS e"
  if (@($rows).Count -eq 0) { return 0 }
  $value = Get-SebValue $rows[0].e
  if ($null -eq $value) { return 0 }
  return [int]$value
}

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
  # STATS makes SQL emit a percentage as it goes; without it the connection stays
  # silent until the backup finishes and there is nothing to show.
  $with = @('INIT', 'FORMAT', 'CHECKSUM', 'STATS = 5', ('NAME = ' + $label))
  if ($Kind -eq 'diff') { $with = @('DIFFERENTIAL') + $with }
  if ($Compress) { $with = $with + @('COMPRESSION') }
  $verb = 'BACKUP DATABASE'
  if ($Kind -eq 'log') { $verb = 'BACKUP LOG' }
  return ('{0} {1} TO DISK = {2} WITH {3}' -f $verb, $quoted, $literal, ($with -join ', '))
}

# Subscribe to InfoMessage, run a body, and ALWAYS unsubscribe. Forgetting the remove
# leaks a delegate on the connection, and the connection is reused for every database in
# a pass: a leaked handler fires again on the next database's BACKUP and, because it
# reads the script-scoped current database, duplicates that database's [PROGRESS] lines -
# once more for every stale handler, so the noise grows across the pass. Pairing add and
# remove in one try/finally makes the removal run on every exit - a value, an early
# return, or a throw. Kept as its own function so the pairing is testable with a fake
# connection that counts add_InfoMessage/remove_InfoMessage, without a live SQL Server.
function Invoke-SebWithInfoHandler {
  param($Connection, $Handler, [scriptblock]$Body)
  $Connection.add_InfoMessage($Handler)
  try { & $Body }
  finally { $Connection.remove_InfoMessage($Handler) }
}

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
  # The whole attempt - first try, error classification, and the uncompressed retry -
  # runs inside the handler wrapper so the delegate is removed on every one of those
  # exit paths, not only after the fallback retry the way it once was.
  Invoke-SebWithInfoHandler -Connection $Connection -Handler $handler -Body {
    try {
      Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
      if ($script:SebCompression -eq 'unknown') { $script:SebCompression = 'on' }
      return
    }
    catch {
      $numbers = Get-SebSqlErrorNumbers $_
      $message = $_.Exception.Message
      # 3201 is "Cannot open backup device". On this script that is almost always the
      # SQL service account lacking rights on the staging folder, which is worth
      # saying outright rather than leaving as "Operating system error 5".
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
    Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
  }
}

# BACKUP LOG. Error 4214 ("no current database backup") means the log chain has no
# base yet - the caller anchors with a full and retries. Everything else propagates.
function Invoke-SebBackupLog {
  param($Connection, [string]$Database, [string]$TargetFile)
  $sql = Get-SebBackupSql -Kind 'log' -Database $Database -TargetFile $TargetFile -Compress $false
  try { Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql }
  catch {
    $numbers = Get-SebSqlErrorNumbers $_
    if (Test-SebLogNeedsBase -Numbers $numbers) {
      # 4214 = no current full backup: the log chain has no base yet. Signal the caller
      # (by string - one internal signal needs no custom exception type) to anchor + retry.
      Write-SebLog ('a log backup found no base backup - the caller will anchor with a full') 'INFO'
      throw 'SEB_LOG_NO_BASE'
    }
    throw
  }
}

function Get-SebRecoveryFullSql {
  param([string]$Database)
  return ('ALTER DATABASE {0} SET RECOVERY FULL' -f (Get-SebQuotedName $Database))
}

function Test-SebNeedsRecoveryFull {
  param([string]$Model)
  return ($Model -ne 'FULL')
}

function Get-SebRecoveryModelSql {
  param([string]$Database)
  return ('SELECT recovery_model_desc AS m FROM sys.databases WHERE name = {0}' -f (Get-SebSqlLiteral $Database))
}

# No rows, or a row whose model is NULL (offline/inaccessible), both mean "we cannot see
# it," which must read the same as already-FULL: do nothing to it. Get-SebValue turns
# DBNull into $null so the [string] cast below never sees DBNull (which stringifies to '').
function Get-SebRecoveryModelFromRows {
  param([object[]]$Rows = @())
  $raw = if (@($Rows).Count -gt 0) { Get-SebValue $Rows[0].m } else { $null }
  if ($null -eq $raw) { return 'FULL' }
  return [string]$raw
}

# Idempotent. Reads the model, changes it only if needed, and returns $true when it
# changed (so the caller knows a fresh anchoring full is now required).
function Set-SebRecoveryFull {
  param($Connection, [string]$Database)
  $rows = Invoke-SebSqlTable -Connection $Connection -Sql (Get-SebRecoveryModelSql -Database $Database)
  $model = Get-SebRecoveryModelFromRows -Rows $rows
  if (-not (Test-SebNeedsRecoveryFull -Model $model)) { return $false }
  Invoke-SebSqlNonQuery -Connection $Connection -Sql (Get-SebRecoveryFullSql -Database $Database)
  Write-SebLog ('recovery model of {0} set to FULL' -f $Database) 'INFO'
  return $true
}

function Test-SebBackupFile {
  param($Connection, [string]$TargetFile)
  $sql = 'RESTORE VERIFYONLY FROM DISK = {0} WITH CHECKSUM' -f (Get-SebSqlLiteral $TargetFile)
  Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
}

# =====================================================================
# Copy and retention
# =====================================================================

function Copy-SebVerified {
  param([string]$Source, [string]$Destination, [switch]$NoHash)
  Import-SebShippedModule -Command 'Get-FileHash' -Module 'Microsoft.PowerShell.Utility'
  $dir = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force

  $sourceLength = (Get-Item -LiteralPath $Source).Length
  $destLength = (Get-Item -LiteralPath $Destination).Length
  if ($sourceLength -ne $destLength) {
    throw ('copy of {0} is {1} bytes, source is {2}' -f $Destination, $destLength, $sourceLength)
  }
  if ($NoHash) { return }

  $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
  $destHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
  if ($sourceHash -ne $destHash) { throw ('copy of {0} does not match the source hash' -f $Destination) }
}

# Zip a single file (entry named after the source leaf). In-box System.IO.Compression,
# NOT Compress-Archive (its ~2GB limit fails large .bak). CreateEntryFromFile streams;
# .NET selects Zip64 automatically for entries over 4GB.
function Compress-SebFile {
  param([string]$Source, [string]$Destination)
  # ZipArchiveMode/CompressionLevel live in System.IO.Compression, NOT in
  # System.IO.Compression.FileSystem (that one only adds the ZipFile/ZipFileExtensions
  # static helpers). PowerShell's type resolution does not walk assembly references, so
  # loading only the FileSystem assembly leaves ZipArchiveMode unresolved - both are
  # needed, and Add-Type is idempotent so loading either twice in a process is harmless.
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
  $entry = Split-Path -Leaf $Source
  $zip = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
  try { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $Source, $entry, [System.IO.Compression.CompressionLevel]::Optimal) }
  finally { $zip.Dispose() }
}

# Extract the single entry of a .zip to a plain file.
function Expand-SebFile {
  param([string]$Source, [string]$Destination)
  # Same split-assembly reason as Compress-SebFile: load both.
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Source)
  try {
    $entries = @($zip.Entries)
    if ($entries.Count -eq 0) { throw ('the archive is empty: {0}' -f $Source) }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $Destination, $true)
  }
  finally { $zip.Dispose() }
}

function Get-SebFolderFacts {
  param([string]$Directory)
  if (-not (Test-Path -LiteralPath $Directory)) { return @() }
  $items = Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -cmatch '\.(bak|dif|trn)(\.zip)?$' }
  $facts = foreach ($item in $items) {
    [pscustomobject]@{
      Name      = $item.Name
      FullName  = $item.FullName
      Timestamp = (Get-SebStampFromName -Name $item.Name -Fallback $item.LastWriteTime)
    }
  }
  # NO unary comma here. Every caller wraps this in @(...), and @( ,@(x) ) yields an
  # array whose single element is the array - so Count is 1 however many files there
  # are, nothing ever exceeds HourlyKeep, and retention silently never runs. Plain
  # @($facts) is correct for zero, one and many under a caller that wraps.
  return @($facts)
}

# A staged .bak must not be deleted while a pending copy still points at it - that
# is the only source for a copy the share has not accepted yet. This can bite when
# two passes land in the same second (a manual -Run right after a scheduled one):
# the stamp has one-second resolution, so the second pass reuses the staged name,
# and deleting after its own copy succeeds takes the first pass's source with it.
# The pass reads Pending back out of state.json and copies staged files to the
# destinations it names. Trusting that turns a writable state file into a "copy this
# anywhere, as SYSTEM" primitive - so the paths are checked against the configured
# folders instead, and anything outside them is refused and reported rather than
# quietly honoured. Validating what is read beats locking who can write it: it holds
# even if the file is tampered with by something that CAN write it.
function Test-SebPendingEntry {
  param([string]$Staged, [string]$Dest, [string]$StagingPath, [string]$SharePath)
  if ([string]::IsNullOrWhiteSpace($Staged) -or [string]::IsNullOrWhiteSpace($Dest)) { return $false }
  if ([string]::IsNullOrWhiteSpace($StagingPath) -or [string]::IsNullOrWhiteSpace($SharePath)) { return $false }
  if ($Staged.Contains('..') -or $Dest.Contains('..')) { return $false }
  # The trailing separator is the whole point: without it 'C:\StagingEvil\x.bak'
  # starts with 'C:\Staging' as a plain string and walks straight through.
  $stagedRoot = $StagingPath.TrimEnd('\') + '\'
  $destRoot = $SharePath.TrimEnd('\') + '\'
  if (-not $Staged.StartsWith($stagedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  if (-not $Dest.StartsWith($destRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  return $true
}

function Test-SebStagedStillNeeded {
  param([string]$Staged, [object[]]$Pending = @())
  foreach ($item in $Pending) {
    if ($null -eq $item) { continue }
    if ([string]$item.Staged -eq $Staged) { return $true }
  }
  return $false
}

function Remove-SebNamed {
  param([string]$Directory, [string[]]$Names)
  foreach ($name in @($Names)) {
    $path = Join-Path $Directory $name
    try {
      Remove-Item -LiteralPath $path -Force -ErrorAction Stop
      Write-SebLog ('pruned {0}' -f $path)
    }
    catch {
      Write-SebLog ('could not prune {0}: {1}' -f $path, $_.Exception.Message) 'WARN'
    }
  }
}

# Drain a Pending list once: for each {Staged,Dest} whose paths both stay inside the
# configured staging and share folders (Test-SebPendingEntry - a writable state file is
# otherwise a "copy anywhere as SYSTEM" primitive), copy the staged file to its destination.
# Returns the entries that still could not be copied, to be written back to state and retried
# next run. File I/O only - no SQL, no state access - so the -BackupLog pass and the data pass
# can share it and it is unit testable. Mirrors the drain Invoke-SebPass runs inline up top.
function Sync-SebPending {
  param([object[]]$Pending = @(), [string]$StagingPath, [string]$SharePath, [switch]$NoHash)
  $still = New-Object System.Collections.ArrayList
  foreach ($item in $Pending) {
    if ($null -eq $item) { continue }
    $staged = [string]$item.Staged
    $dest = [string]$item.Dest
    if (-not (Test-SebPendingEntry -Staged $staged -Dest $dest -StagingPath $StagingPath -SharePath $SharePath)) {
      Write-SebLog ('refusing a pending entry that points outside the configured folders: {0} -> {1}' -f $staged, $dest) 'WARN'
      continue
    }
    if (-not (Test-Path -LiteralPath $staged)) { continue }
    try {
      Copy-SebVerified -Source $staged -Destination $dest -NoHash:$NoHash
      Write-SebLog ('recovered {0}' -f $dest)
    }
    catch {
      Write-SebLog ('still cannot copy {0}: {1}' -f $dest, $_.Exception.Message) 'WARN'
      [void]$still.Add($item)
    }
  }
  return @($still.ToArray())
}

# Copy one freshly-staged backup to the share, or record it for the next run's drain. On
# success the staged file is removed (unless a still-pending entry names it too); on failure
# it is kept in staging and added to $PendingList as {Staged,Dest,Database,Kind}. The
# -BackupLog pass calls this for its log copy and its anchoring-full copy, so a share that
# refuses either leaves it recorded and retryable instead of orphaning a .trn whose BACKUP
# LOG already truncated the chain. Mirrors the copy-or-pend block in Invoke-SebPass.
function Save-SebCopyOrPend {
  param([string]$Staged, [string]$Dest, [string]$Database, [string]$Kind, $PendingList, [switch]$NoHash)
  try {
    Copy-SebVerified -Source $Staged -Destination $Dest -NoHash:$NoHash
    Write-SebLog ('copied to {0}' -f $Dest)
    if (Test-SebStagedStillNeeded -Staged $Staged -Pending @($PendingList.ToArray())) {
      Write-SebLog ('keeping {0} in staging - an earlier copy of it is still waiting for the share' -f $Staged)
    }
    else {
      Remove-Item -LiteralPath $Staged -Force -ErrorAction SilentlyContinue
    }
  }
  catch {
    Write-SebLog ('share copy failed for {0}: {1} - kept in staging for the next run' -f $Dest, $_.Exception.Message) 'WARN'
    [void]$PendingList.Add([pscustomobject]@{ Staged = $Staged; Dest = $Dest; Database = $Database; Kind = $Kind })
  }
}

# Artifacts to publish to the share for one verified plain staged backup. Off -> just the
# plain file. On -> the .zip plus its .meta.json sidecar (LSN facts read from the plain file
# BEFORE zipping, so the catalogue can read them without decompressing). Returns @({Src;Name})
# in copy order; the plain staged file is left for the caller's own staged cleanup. HeaderReader
# is injectable for testing; it defaults to a real RESTORE HEADERONLY of the plain file.
function Get-SebPublishSet {
  param($Connection, [string]$StagedPlain, [string]$PlainName, [string]$Kind, [bool]$Compress, [scriptblock]$HeaderReader)
  if (-not $Compress) {
    return @([pscustomobject]@{ Src = $StagedPlain; Name = $PlainName })
  }
  if (-not $HeaderReader) { $HeaderReader = { param($c, $f, $k) Get-SebRestoreHeaderFacts -Connection $c -File $f -Kind $k } }
  $facts = & $HeaderReader $Connection $StagedPlain $Kind
  $stagedZip = $StagedPlain + '.zip'
  Compress-SebFile -Source $StagedPlain -Destination $stagedZip
  $stagedMeta = Get-SebSidecarName $stagedZip
  Set-Content -LiteralPath $stagedMeta -Value (Get-SebSidecarJson -Facts $facts) -Encoding ASCII
  $zipName = Get-SebCompressedName $PlainName
  return @(
    [pscustomobject]@{ Src = $stagedZip;  Name = $zipName }
    [pscustomobject]@{ Src = $stagedMeta; Name = (Get-SebSidecarName $zipName) }
  )
}

# Remove staged backup artifacts (.bak/.dif/.trn, their .zip variants, and .meta.json
# sidecars) that no pending copy still points at - a backstop for the copy path's own
# cleanup, run before a pass stages new files. Never removes a path in KeepPaths (a staged
# source a still-pending entry needs). Case-insensitive on the extension so a differently-
# cased staged name is not missed by a destructive sweep.
function Clear-SebStagedExcept {
  param([string]$StagingPath, [string[]]$KeepPaths = @())
  Get-ChildItem -LiteralPath $StagingPath -File -ErrorAction SilentlyContinue |
    Where-Object { ($_.Name -match '\.(bak|dif|trn)(\.zip)?$' -or $_.Name -match '\.meta\.json$') -and $KeepPaths -notcontains $_.FullName } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# =====================================================================
# The pass
# =====================================================================

function Get-SebMutex {
  # Global\ needs SeCreateGlobalPrivilege, which SYSTEM has and an unelevated
  # operator does not. Fall back rather than refuse to run by hand.
  foreach ($prefix in @('Global\', 'Local\')) {
    try {
      $created = $false
      $mutex = New-Object System.Threading.Mutex($true, ($prefix + 'SqlExpressBackup'), [ref]$created)
      if (-not $created) {
        $held = $mutex.WaitOne(0)
        if (-not $held) { $mutex.Dispose(); return $null }
      }
      return $mutex
    }
    catch {
      continue
    }
  }
  return $null
}

# How many hours old the newest full backup in a folder's facts is, as of Now. Infinity
# when there is no full yet, so Get-SebBackupKindDue always reads that as "a full is due."
# Only .bak entries count, plain or the .bak.zip a compressed pass writes - a .dif or
# .trn sitting in the same folder facts is not a base, zipped or not.
function Get-SebHoursSinceNewestFull {
  param([object[]]$Facts = @(), [datetime]$Now)
  $fulls = @($Facts | Where-Object { $_.Name -match '\.bak(\.zip)?$' })
  if ($fulls.Count -eq 0) { return [double]::PositiveInfinity }
  $newest = @($fulls | Sort-Object Timestamp)[-1]
  return ($Now - $newest.Timestamp).TotalHours
}

# Which kind of backup a data pass should take: a full when the newest full is at least
# FullEveryHours old (or none exists), otherwise a differential off that full.
function Get-SebBackupKindDue {
  param([double]$HoursSinceFull, [int]$FullEveryHours = 24)
  if ($HoursSinceFull -ge $FullEveryHours) { return 'full' }
  return 'diff'
}

# Map a -BackupLog tally to a process exit code, exactly as Invoke-SebPass maps a data pass:
# nothing succeeded although something was attempted is a total failure (2); a copy still
# pending or a database that failed alongside a success is partial (1); a clean run - including
# "nothing was FULL recovery this cycle" (0 succeeded, 0 failed) - is ok (0). A pending copy is
# NOT success: the log was taken but the offsite copy, the whole point, has not happened yet.
function Get-SebLogPassExitCode {
  param([int]$Succeeded, [int]$Failed, [int]$Pending)
  if ($Succeeded -eq 0 -and $Failed -gt 0) { return 2 }
  if ($Failed -gt 0 -or $Pending -gt 0) { return 1 }
  return 0
}

# A database waiting on LOG_BACKUP with its log file most of the way full is the
# transaction log growing because nothing has truncated it yet - exactly what Full
# recovery without a running log-backup task looks like. Any OTHER wait (or the same
# wait below threshold) is a different problem and not this warning's job to catch.
# Pure so the threshold boundary is provable without a real database anywhere near full.
function Get-SebLogGrowthWarning {
  param([string]$Wait, [double]$UsedPct, [double]$ThresholdPct = 70)
  return ($Wait -eq 'LOG_BACKUP' -and $UsedPct -ge $ThresholdPct)
}

# Pull one database's "Log Space Used (%)" out of a DBCC SQLPERF(LOGSPACE) row set.
# Returns 0 when the database isn't found or the value is null (no false warning).
function Get-SebLogSpaceUsedPct {
  param([object[]]$Rows = @(), [string]$Database)
  foreach ($r in $Rows) {
    if ([string](Get-SebValue $r.'Database Name') -eq $Database) {
      return [double](Get-SebValue $r.'Log Space Used (%)')
    }
  }
  return 0
}

# Summarize one database's backup chain from its share folder facts (each an object
# with a .Timestamp, as Get-SebFolderFacts returns). RPO is whole minutes since the
# newest log - or since the newest full when there is no log yet, since that full IS
# the most recent recovery point in that case. Health names the shapes that matter
# operationally: nothing on the share at all, a log with no full underneath it to
# restore onto first (the base full was deleted or never taken), a full sitting alone
# waiting on its first log, or an ordinary chain. Pure so the RPO and health boundaries
# are provable without a share, a database, or a clock anywhere near real.
function Get-SebChainSummary {
  param([object[]]$Fulls = @(), [object[]]$Diffs = @(), [object[]]$Logs = @(), [datetime]$Now)
  $lastFull = $null; $lastDiff = $null; $lastLog = $null
  if (@($Fulls).Count -gt 0) { $lastFull = (@($Fulls | Sort-Object Timestamp)[-1]).Timestamp }
  if (@($Diffs).Count -gt 0) { $lastDiff = (@($Diffs | Sort-Object Timestamp)[-1]).Timestamp }
  if (@($Logs).Count  -gt 0) { $lastLog  = (@($Logs  | Sort-Object Timestamp)[-1]).Timestamp }
  $rpoAnchor = $lastLog
  if ($null -eq $rpoAnchor) { $rpoAnchor = $lastFull }
  $rpoMin = -1
  if ($null -ne $rpoAnchor) { $rpoMin = [int][math]::Round(($Now - $rpoAnchor).TotalMinutes) }
  $health = 'ok'
  if ($null -eq $lastFull) {
    if ($null -ne $lastLog -or $null -ne $lastDiff) { $health = 'no base full' } else { $health = 'no backups' }
  }
  elseif ($null -eq $lastLog) { $health = 'no logs yet' }
  return [pscustomobject]@{ LastFull = $lastFull; LastDiff = $lastDiff; LastLog = $lastLog; RpoMinutes = $rpoMin; Health = $health }
}

# The -BackupLog task: one transaction-log backup of every FULL-recovery user database,
# staged locally then copied to the share's log/ folder. If a database has no base yet
# (SEB_LOG_NO_BASE), anchor it with a full first, then retry the log.
#
# One database's failure does not abort the rest of the pass (mirrors Invoke-SebPass's
# per-database isolation via $succeeded/$failed), and a failed database's staged file is
# left in place rather than deleted - this pass gets no drain-and-retry of its own (that
# is tracked separately), so removing it on failure would make the loss silent instead
# of just loud. Only the success path cleans up the files it already copied and verified.
function Invoke-SebBackupLogPass {
  param(
    $Connection,
    [string]$Root,
    [string]$HostName,
    [string]$InstanceLabel,
    [string]$StagingPath,
    [string]$OnlyDatabase = '',
    [switch]$NoHash
  )
  # Drain first, exactly as Invoke-SebPass does: a share that came back catches up before
  # this pass stages anything new, so a long outage cannot let staging grow unbounded. The
  # Pending list lives in the same state.json the data pass uses, and both passes run under
  # the same Get-SebMutex, so this read-drain-write is race-free against the data pass.
  $state = Read-SebState
  $pending = @($state.Pending)
  $pendingList = New-Object System.Collections.ArrayList
  if ($pending.Count -gt 0) {
    Write-SebLog ('{0} copy(s) pending from earlier runs - draining first' -f $pending.Count)
    foreach ($item in @(Sync-SebPending -Pending $pending -StagingPath $StagingPath -SharePath $Root -NoHash:$NoHash)) {
      [void]$pendingList.Add($item)
    }
    # A staged file no surviving pending entry points at has reached the share and is done
    # with. This sweep runs BEFORE anything is staged this pass, so a database that fails
    # below still leaves its own staged file in place - the loud evidence D1a keeps.
    $keepPaths = @($pendingList.ToArray() | ForEach-Object { [string]$_.Staged })
    Get-ChildItem -LiteralPath $StagingPath -File -ErrorAction SilentlyContinue |
      Where-Object { ($_.Extension -eq '.trn' -or $_.Extension -eq '.bak') -and $keepPaths -notcontains $_.FullName } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  }

  $rows = Invoke-SebSqlTable -Connection $Connection -Sql @'
SELECT d.name, d.state, d.source_database_id, d.is_in_standby
FROM sys.databases AS d
'@
  $databases = Select-SebDatabase -Rows $rows
  if (-not [string]::IsNullOrWhiteSpace($OnlyDatabase)) {
    $databases = @($databases | Where-Object { $_ -eq $OnlyDatabase })
    if ($databases.Count -eq 0) { throw ("database '$OnlyDatabase' is not on this instance, or is not eligible for backup") }
  }

  $succeeded = 0
  $failed = 0
  foreach ($db in $databases) {
    try {
      $modelRows = Invoke-SebSqlTable -Connection $Connection -Sql (Get-SebRecoveryModelSql -Database $db)
      # Get-SebRecoveryModelFromRows defaults an unreadable/offline database to 'FULL' -
      # correct for Set-SebRecoveryFull (nothing to change if we cannot see it), wrong
      # here: it would send an unreadable database into a doomed backup attempt instead
      # of just skipping it. Read the raw value and require a confirmed FULL.
      $raw = if (@($modelRows).Count -gt 0) { Get-SebValue $modelRows[0].m } else { $null }
      if ($null -eq $raw -or [string]$raw -ne 'FULL') { continue }

      $stamp = Get-Date
      $logName = Get-SebFileName -Database $db -Stamp $stamp -Extension 'trn'
      $logStaged = Join-Path $StagingPath $logName
      try { Invoke-SebBackupLog -Connection $Connection -Database $db -TargetFile $logStaged }
      catch {
        if ("$_" -notmatch 'SEB_LOG_NO_BASE') { throw }
        Write-SebLog ('anchoring {0} with a full before its first log backup' -f $db) 'INFO'
        $anchorName = Get-SebFileName -Database $db -Stamp $stamp
        $anchorStaged = Join-Path $StagingPath $anchorName
        Invoke-SebBackupDatabase -Connection $Connection -Database $db -TargetFile $anchorStaged -Kind 'full'
        Test-SebBackupFile -Connection $Connection -TargetFile $anchorStaged
        $anchorDest = Join-Path (Get-SebBackupPath -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $db -Kind 'hourly') $anchorName
        # The anchor is the log chain's base. If the share refuses it, record and keep it
        # (do not orphan it) and still take the log: the base is safe locally, and the anchor
        # and the log then drain to the share together on the next run.
        Save-SebCopyOrPend -Staged $anchorStaged -Dest $anchorDest -Database $db -Kind 'hourly' -PendingList $pendingList -NoHash:$NoHash
        Invoke-SebBackupLog -Connection $Connection -Database $db -TargetFile $logStaged
      }
      $logDest = Join-Path (Get-SebBackupPath -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $db -Kind 'log') $logName
      # BACKUP LOG has already truncated the chain, so a refused copy must not throw the .trn
      # away: record it and keep it staged for the next run's drain instead of losing the
      # interval. A pending copy is not a per-database failure - the log itself was taken.
      Save-SebCopyOrPend -Staged $logStaged -Dest $logDest -Database $db -Kind 'log' -PendingList $pendingList -NoHash:$NoHash
      Write-SebLog ('log backup of {0} taken' -f $db) 'INFO'
      $succeeded++
    }
    catch {
      $failed++
      Write-SebLog ('{0} FAILED: {1}' -f $db, $_.Exception.Message) 'ERROR'
    }
  }

  # Persist the merged Pending so the next run drains it. Pending is all this pass owns of
  # state.json - preserve the data pass's LastRunUtc/LastResult, which drive the status view.
  Write-SebState ([pscustomobject]@{
      LastRunUtc = $state.LastRunUtc
      LastResult = $state.LastResult
      Pending    = @($pendingList.ToArray())
    })
  return [pscustomobject]@{ Succeeded = $succeeded; Failed = $failed; Pending = $pendingList.Count }
}

function Invoke-SebPass {
  param($Config)

  $isFullMode = ([string]$Config.RecoveryMode -eq 'Full')
  $fullEveryHours = 24
  if ($Config.PSObject.Properties['FullEveryHours']) { $fullEveryHours = [int]$Config.FullEveryHours }

  $staging = $Config.StagingPath
  if (-not (Test-Path -LiteralPath $staging)) {
    [void](New-Item -ItemType Directory -Path $staging -Force)
    # Recreated because someone deleted it. A bare new folder grants the SQL service
    # account nothing, and every BACKUP then fails with OS error 5.
    try { Set-SebStagingAcl -Path $staging -SqlAccount ([string]$Config.SqlServiceAccount) }
    catch { Write-SebLog ('could not re-grant staging permissions: {0}' -f $_.Exception.Message) 'WARN' }
  }

  $state = Read-SebState
  $pending = @($state.Pending)
  $noHash = [bool]$Config.NoHashVerify

  # Drain first. A share that came back should catch up before this pass adds to
  # the pile, otherwise a long outage means staging grows until the disk fills.
  if ($pending.Count -gt 0) {
    Write-SebLog ('{0} copy(s) pending from earlier runs - draining first' -f $pending.Count)
    $stillPending = New-Object System.Collections.ArrayList
    foreach ($item in $pending) {
      if (-not (Test-SebPendingEntry -Staged ([string]$item.Staged) -Dest ([string]$item.Dest) `
            -StagingPath $staging -SharePath ([string]$Config.SharePath))) {
        Write-SebLog ('refusing a pending entry that points outside the configured folders: {0} -> {1}' -f $item.Staged, $item.Dest) 'WARN'
        continue
      }
      if (-not (Test-Path -LiteralPath $item.Staged)) { continue }
      try {
        Copy-SebVerified -Source $item.Staged -Destination $item.Dest -NoHash:$noHash
        Write-SebLog ('recovered {0}' -f $item.Dest)
      }
      catch {
        Write-SebLog ('still cannot copy {0}: {1}' -f $item.Dest, $_.Exception.Message) 'WARN'
        [void]$stillPending.Add($item)
      }
    }
    $pending = @($stillPending.ToArray())
    # Staged files with no pending entry left are done with.
    $keepPaths = @($pending | ForEach-Object { $_.Staged })
    Get-ChildItem -LiteralPath $staging -Filter '*.bak' -File -ErrorAction SilentlyContinue |
      Where-Object { $keepPaths -notcontains $_.FullName } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  }

  $password = $null
  $connection = $null
  $succeeded = 0
  $failed = 0
  try {
    if ($Config.UseWindowsAuth) {
      $connection = New-SebSqlConnection -DataSource $Config.DataSource -WindowsAuth
    }
    else {
      $master = Get-SebMasterKey
      try {
        $blob = Get-Content -LiteralPath (Get-SebCredPath) -Raw
        $password = Unprotect-SebSecureString -Blob $blob.Trim() -Master $master
      }
      finally { [System.Array]::Clear($master, 0, $master.Length) }
      $connection = New-SebSqlConnection -DataSource $Config.DataSource -User $Config.SqlUser -Password $password
    }
    Write-SebLog ('connected to {0}' -f $Config.DataSource)

    if ($script:SebCompression -eq 'unknown') {
      $engine = Get-SebEngineEdition -Connection $connection
      if ($engine -eq 4) {
        $script:SebCompression = 'off'
        Write-SebLog 'Express Edition - backup compression is not available, so it is not attempted'
      }
    }

    $rows = Invoke-SebSqlTable -Connection $connection -Sql @'
SELECT d.name, d.state, d.source_database_id, d.is_in_standby
FROM sys.databases AS d
'@
    $databases = Select-SebDatabase -Rows $rows
    $only = ''
    if ($Config.PSObject.Properties['OnlyDatabase']) { $only = [string]$Config.OnlyDatabase }
    if (-not [string]::IsNullOrWhiteSpace($only)) {
      $databases = @($databases | Where-Object { $_ -eq $only })
      if ($databases.Count -eq 0) { throw ("database '$only' is not on this instance, or is not eligible for backup") }
    }
    if ($databases.Count -eq 0) { throw 'no eligible databases found on this instance' }
    Write-SebLog ('{0} database(s) to back up: {1}' -f $databases.Count, ($databases -join ', '))

    # Space check before SQL is asked to do anything, so a shortfall is a sentence
    # rather than a half-written .bak and a cryptic engine error.
    $sizeRows = Invoke-SebSqlTable -Connection $connection -Sql @'
SELECT DB_NAME(database_id) AS name, SUM(CAST(size AS bigint)) * 8 / 1024 AS mb
FROM sys.master_files
GROUP BY database_id
'@
    $sizes = @{}
    foreach ($row in $sizeRows) {
      $dbName = [string](Get-SebValue $row.name)
      if ($dbName) { $sizes[$dbName] = [long](Get-SebValue $row.mb) }
    }
    $totalMb = 0
    $largestMb = 0
    foreach ($db in $databases) {
      if ($sizes.ContainsKey($db)) {
        $totalMb += $sizes[$db]
        if ($sizes[$db] -gt $largestMb) { $largestMb = $sizes[$db] }
      }
    }
    $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $staging).Path))
    $freeMb = [long]($drive.AvailableFreeSpace / 1MB)
    if ($freeMb -lt ($largestMb * 1.2)) {
      throw ('staging drive has {0} MB free; the largest database alone needs about {1} MB' -f $freeMb, [long]($largestMb * 1.2))
    }
    if ($freeMb -lt ($totalMb * 1.1)) {
      Write-SebLog ('staging drive has {0} MB free against {1} MB of databases - fine while the share is up, tight if it goes down' -f $freeMb, $totalMb) 'WARN'
    }

    $stamp = Get-Date
    $hostName = $env:COMPUTERNAME
    $instanceLabel = $Config.InstanceName
    $pendingList = New-Object System.Collections.ArrayList
    foreach ($item in $pending) { [void]$pendingList.Add($item) }

    # Log-growth WARN inputs, read ONCE per pass rather than once per database: both
    # queries already return every database's row in a single result set, so the
    # per-database work below is a local lookup, not a second SQL round trip. Full
    # mode only - Simple mode never runs a log-backup task, so warning that one is
    # overdue would be noise about a task that was never supposed to be running.
    $logWaitByDb = @{}
    $logSpaceRows = @()
    if ($isFullMode) {
      $logWaitRows = Invoke-SebSqlTable -Connection $connection -Sql 'SELECT name, log_reuse_wait_desc FROM sys.databases'
      foreach ($row in $logWaitRows) {
        $dbName = [string](Get-SebValue $row.name)
        if ($dbName) { $logWaitByDb[$dbName] = [string](Get-SebValue $row.log_reuse_wait_desc) }
      }
      $logSpaceRows = @(Invoke-SebSqlTable -Connection $connection -Sql 'DBCC SQLPERF(LOGSPACE)')
    }

    $dbIndex = 0
    foreach ($database in $databases) {
      $dbIndex++
      $staged = $null
      try {
        $kind = 'full'
        if ($isFullMode) {
          $justSwitched = Set-SebRecoveryFull -Connection $connection -Database $database
          $fullDir = Get-SebBackupPath -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database -Kind 'hourly'
          $hoursSinceFull = Get-SebHoursSinceNewestFull -Facts @(Get-SebFolderFacts -Directory $fullDir) -Now $stamp
          $kind = Get-SebBackupKindDue -HoursSinceFull $hoursSinceFull -FullEveryHours $fullEveryHours
          # A database only just switched to FULL has no base for a differential yet - anchor with a full.
          if ($justSwitched) { $kind = 'full' }
        }
        $ext = 'bak'
        if ($kind -eq 'diff') { $ext = 'dif' }
        $fileName = Get-SebFileName -Database $database -Stamp $stamp -Extension $ext
        $staged = Join-Path $staging $fileName
        Write-SebJob -Index $dbIndex -Total $databases.Count -Database $database
        Write-SebLog ('backing up {0}' -f $database)
        Write-SebStage -Database $database -Stage 'backup'
        Invoke-SebBackupDatabase -Connection $connection -Database $database -TargetFile $staged -Kind $kind
        Write-SebStage -Database $database -Stage 'verify'
        Test-SebBackupFile -Connection $connection -TargetFile $staged
        $sizeMb = [long]((Get-Item -LiteralPath $staged).Length / 1MB)
        Write-SebLog ('{0} backed up and verified ({1} MB)' -f $database, $sizeMb)

        if ($isFullMode) {
          # Full mode: route a full to hourly/, a diff to diff/. NO count-based pruning here -
          # chain-safe retention over full+diff+log is a separate task (D1c); until then these
          # accumulate rather than risk a prune that strands a log the chain still needs.
          $destKind = 'hourly'
          if ($kind -eq 'diff') { $destKind = 'diff' }
          $destDir = Get-SebBackupPath -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database -Kind $destKind
          $dest = Join-Path $destDir $fileName
          Write-SebStage -Database $database -Stage ('copy-' + $kind)
          $copyOk = $true
          try {
            Copy-SebVerified -Source $staged -Destination $dest -NoHash:$noHash
            Write-SebLog ('copied to {0}' -f $dest)
            if (Test-SebStagedStillNeeded -Staged $staged -Pending @($pendingList.ToArray())) {
              Write-SebLog ('keeping {0} in staging - an earlier copy of it is still waiting for the share' -f $staged)
            }
            else {
              Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            }
          }
          catch {
            $copyOk = $false
            Write-SebLog ('share copy failed for {0}: {1} - kept in staging for the next run' -f $dest, $_.Exception.Message) 'WARN'
            [void]$pendingList.Add([pscustomobject]@{ Staged = $staged; Dest = $dest; Database = $database; Kind = $destKind })
          }

          # Chain-safe pruning: never delete a full/diff/log a retained recovery point still
          # needs (Get-SebChainRetentionPlan guarantees this). Runs only in Full mode; Simple
          # keeps its hourly/daily count-based retention untouched. Gated to full+copied passes:
          # chain-retention eligibility only changes when a full lands or ages out (~daily), so
          # re-reading every backup header on a diff-only pass is wasted work, and when the share
          # copy above just failed the catalogue read would only hammer a share that is already
          # down - skip it here and let the next successful full pass prune instead.
          if ($kind -eq 'full' -and $copyOk) {
            Write-SebStage -Database $database -Stage 'retention'
            $catFull = @(Get-SebPointCatalogue -Connection $connection -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database)
            $chainFacts = Get-SebChainFactsFromCatalogue -Catalogue $catFull
            $rplan = Get-SebChainRetentionPlan -Fulls $chainFacts.Fulls -Diffs $chainFacts.Diffs -Logs $chainFacts.Logs -Now $stamp -DailyKeepDays ([int]$Config.DailyKeepDays)
            foreach ($entry in $catFull) {
              $leaf = Split-Path -Leaf $entry.File
              $prune = ($entry.Kind -eq 'full' -and $rplan.FullDelete -contains $leaf) -or `
                       ($entry.Kind -eq 'diff' -and $rplan.DiffDelete -contains $leaf) -or `
                       ($entry.Kind -eq 'log'  -and $rplan.LogDelete  -contains $leaf)
              if ($prune) {
                Remove-Item -LiteralPath $entry.File -Force -ErrorAction SilentlyContinue
                Write-SebLog ('pruned {0}' -f $leaf) 'INFO'
              }
            }
          }

          # Log-growth WARN: this database is FULL recovery (isFullMode forced it above)
          # and waiting on LOG_BACKUP with its log mostly full means the -BackupLog task
          # has stalled. WARN only - auto-taking a catch-up log here would hide a stopped
          # or misconfigured task instead of surfacing it; this pass's job is the data
          # backup, not the log. Probed from the once-per-pass caches read before the
          # loop; kept inside this per-database try so a probe failure cannot abort the
          # rest of the pass.
          $logWait = ''
          if ($logWaitByDb.ContainsKey($database)) { $logWait = $logWaitByDb[$database] }
          $usedPct = Get-SebLogSpaceUsedPct -Rows $logSpaceRows -Database $database
          if (Get-SebLogGrowthWarning -Wait $logWait -UsedPct $usedPct) {
            Write-SebLog ('WARNING: {0} log is {1}% full and waiting on a log backup - is the -BackupLog task running?' -f $database, $usedPct) 'WARN'
          }
        }
        else {
          $hourlyDir = Get-SebBackupPath -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database -Kind 'hourly'
          $dailyDir = Get-SebBackupPath -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database -Kind 'daily'

          $hourlyFacts = @(Get-SebFolderFacts -Directory $hourlyDir)
          $hourlyFacts += [pscustomobject]@{ Name = $fileName; FullName = (Join-Path $hourlyDir $fileName); Timestamp = $stamp }
          $dailyFacts = @(Get-SebFolderFacts -Directory $dailyDir)
          $plan = Get-SebRetentionPlan -HourlyFiles $hourlyFacts -DailyFiles $dailyFacts -Now $stamp `
            -HourlyKeep ([int]$Config.HourlyKeep) -DailyKeepDays ([int]$Config.DailyKeepDays)

          Write-SebStage -Database $database -Stage 'copy'
          $targets = @(@{ Dir = $hourlyDir; Kind = 'hourly' })
          if ($plan.PromoteToDaily) { $targets += @{ Dir = $dailyDir; Kind = 'daily' } }

          $copiedAll = $true
          foreach ($target in $targets) {
            $dest = Join-Path $target.Dir $fileName
            try {
              Copy-SebVerified -Source $staged -Destination $dest -NoHash:$noHash
              Write-SebLog ('copied to {0}' -f $dest)
            }
            catch {
              $copiedAll = $false
              Write-SebLog ('share copy failed for {0}: {1} - kept in staging for the next run' -f $dest, $_.Exception.Message) 'WARN'
              [void]$pendingList.Add([pscustomobject]@{
                  Staged = $staged; Dest = $dest; Database = $database; Kind = $target.Kind
                })
            }
          }

          if ($copiedAll) {
            Remove-SebNamed -Directory $hourlyDir -Names $plan.HourlyDelete
            Remove-SebNamed -Directory $dailyDir -Names $plan.DailyDelete
            if (Test-SebStagedStillNeeded -Staged $staged -Pending @($pendingList.ToArray())) {
              Write-SebLog ('keeping {0} in staging - an earlier copy of it is still waiting for the share' -f $staged)
            }
            else {
              Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            }
          }
        }
        $succeeded++
      }
      catch {
        $failed++
        Write-SebLog ('{0} FAILED: {1}' -f $database, $_.Exception.Message) 'ERROR'
        if ($staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
      }
    }

    # A pending copy is NOT success. The database was backed up and verified, but the
    # offsite copy - the entire point - has not happened. Reporting 0 here means a
    # share that has been down for a week reports success every six hours.
    $result = 'ok'
    if ($pendingList.Count -gt 0 -or ($failed -gt 0 -and $succeeded -gt 0)) { $result = 'partial' }
    if ($succeeded -eq 0) { $result = 'failed' }
    Write-SebState ([pscustomobject]@{
        LastRunUtc = (Get-Date).ToUniversalTime().ToString('o')
        LastResult = $result
        Pending    = @($pendingList.ToArray())
      })

    Write-SebLog ('pass finished: {0} succeeded, {1} failed, {2} copy(s) pending' -f $succeeded, $failed, $pendingList.Count)
    Remove-SebOldLog
    if ($succeeded -eq 0) { return 2 }
    if ($failed -gt 0 -or $pendingList.Count -gt 0) { return 1 }
    return 0
  }
  finally {
    if ($null -ne $connection) { $connection.Dispose() }
    if ($null -ne $password) { $password.Dispose() }
  }
}

# =====================================================================
# Scheduling
# =====================================================================

function Get-SebScriptPath {
  if ($PSCommandPath) { return $PSCommandPath }
  return (Join-Path $PSScriptRoot 'Invoke-SqlExpressBackup.ps1')
}

function Get-SebRunArguments {
  param([string]$ScriptPath, [string]$ConfigDirectory, [switch]$Looping)
  $tail = '-Run'
  if ($Looping) { $tail = '-Run -Loop' }
  return ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1} -ConfigDir "{2}"' -f $ScriptPath, $tail, $ConfigDirectory)
}

function Get-SebScheduleState {
  $task = Get-ScheduledTask -TaskName $script:SebTaskName -ErrorAction SilentlyContinue
  $service = Get-Service -Name $script:SebServiceName -ErrorAction SilentlyContinue
  return [pscustomobject]@{
    TaskPresent    = ($null -ne $task)
    TaskState      = $(if ($null -ne $task) { [string]$task.State } else { 'absent' })
    ServicePresent = ($null -ne $service)
    ServiceState   = $(if ($null -ne $service) { [string]$service.Status } else { 'absent' })
  }
}

# A task that runs as SYSTEM must not execute a script a non-admin can rewrite.
# The console extracts its engine copy under the user's own profile, which is right
# for something run as that user - and completely wrong as the target of a SYSTEM
# task. So the install, which is already elevated, places its own copy somewhere only
# SYSTEM and Administrators can write, and registers THAT path.
function Copy-SebEngineForService {
  param([string]$ScriptPath)
  $dir = Join-Path $script:SebConfigDir 'engine'
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  Set-SebSecretAcl $dir
  $target = Join-Path $dir 'Invoke-SqlExpressBackup.ps1'
  if ((Resolve-Path -LiteralPath $ScriptPath).Path -ine $target) {
    Copy-Item -LiteralPath $ScriptPath -Destination $target -Force
  }
  Set-SebSecretAcl $target
  return $target
}

# The log-backup task is named off the main task's name, so anything that already
# knows $script:SebTaskName (Reschedule, Uninstall) can derive the second task's
# name without a second script variable to keep in sync with the first.
function Get-SebLogTaskName {
  param([string]$Base)
  return ($Base + '-Log')
}

function Install-SebTask {
  param([string]$ScriptPath, [string]$ConfigDirectory, [int]$Hours)
  $ScriptPath = Copy-SebEngineForService -ScriptPath $ScriptPath
  Write-SebLog ('the scheduled task will run {0} - writable only by SYSTEM and Administrators' -f $ScriptPath)
  $arguments = Get-SebRunArguments -ScriptPath $ScriptPath -ConfigDirectory $ConfigDirectory
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

  # Two triggers on purpose. The repeating one carries the 6-hour cadence; the
  # at-startup one means a host that was off through a scheduled slot backs up when
  # it returns instead of waiting for the next slot. Omitting RepetitionDuration is
  # what makes the repetition indefinite.
  $repeating = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours $Hours)
  $atStartup = New-ScheduledTaskTrigger -AtStartup

  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours $Hours) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)

  [void](Register-ScheduledTask -TaskName $script:SebTaskName -Action $action `
      -Trigger @($repeating, $atStartup) -Principal $principal -Settings $settings -Force)
  Write-SebLog ('scheduled task "{0}" registered - every {1} hour(s) as SYSTEM, and at every boot' -f $script:SebTaskName, $Hours)

  # A second SYSTEM task, registered ONLY for a Full-recovery install: -BackupLog
  # takes a transaction-log backup every few minutes, so the recovery point never
  # drifts far behind "now". RecoveryMode and LogIntervalMinutes are config keys a
  # LATER feature (D3) adds - an install made before that, or a Simple-recovery
  # install, has neither key, and that must read as Simple (no log task) rather
  # than throw. Same guard style as Invoke-SebPass uses for this same key.
  $config = Read-SebConfig
  $isFullMode = ([string]$config.RecoveryMode -eq 'Full')
  if ($isFullMode) {
    $logMinutes = 15
    if ($config.PSObject.Properties['LogIntervalMinutes']) { $logMinutes = [int]$config.LogIntervalMinutes }

    $logTaskName = Get-SebLogTaskName -Base $script:SebTaskName
    # Same script path, same "-NoProfile ... -File" shape, same -ConfigDir as the
    # main task's action above - only the mode flag changes.
    $logArguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -BackupLog -ConfigDir "{1}"' -f $ScriptPath, $ConfigDirectory)
    $logAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $logArguments
    # Stagger the log task's start off the main task's so their firings do not stay
    # harmonically locked (a 6h interval is a multiple of 15min); otherwise the coincident
    # tick would lose the shared mutex to the main pass every interval and skip a log backup.
    $logOffset = 2 + [math]::Ceiling($logMinutes / 2)
    $logTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($logOffset) -RepetitionInterval (New-TimeSpan -Minutes $logMinutes)
    $logSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
      -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    [void](Register-ScheduledTask -TaskName $logTaskName -Action $logAction `
        -Trigger $logTrigger -Principal $principal -Settings $logSettings -Force)
    Write-SebLog ('scheduled task "{0}" registered - every {1} minute(s), transaction-log backups for Full-recovery databases' -f $logTaskName, $logMinutes)
  }
}

function Resolve-SebNssm {
  param([string]$Explicit)
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath $Explicit)) { throw "no nssm.exe at $Explicit" }
    return (Resolve-Path -LiteralPath $Explicit).Path
  }
  $onPath = Get-Command 'nssm.exe' -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  throw 'nssm.exe was not found on PATH. Pass -NssmPath, or use -As Task, which needs no extra binary.'
}

function Install-SebService {
  param([string]$ScriptPath, [string]$ConfigDirectory, [int]$Hours, [string]$Nssm)
  $ScriptPath = Copy-SebEngineForService -ScriptPath $ScriptPath
  $arguments = Get-SebRunArguments -ScriptPath $ScriptPath -ConfigDirectory $ConfigDirectory -Looping
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $logDir = Get-SebLogDir
  if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }

  & $Nssm install $script:SebServiceName $powershell | Out-Null
  & $Nssm set $script:SebServiceName AppParameters $arguments | Out-Null
  & $Nssm set $script:SebServiceName AppDirectory (Split-Path -Parent $ScriptPath) | Out-Null
  & $Nssm set $script:SebServiceName ObjectName 'LocalSystem' | Out-Null
  & $Nssm set $script:SebServiceName Start 'SERVICE_AUTO_START' | Out-Null
  & $Nssm set $script:SebServiceName AppStdout (Join-Path $logDir 'service.out.log') | Out-Null
  & $Nssm set $script:SebServiceName AppStderr (Join-Path $logDir 'service.err.log') | Out-Null
  & $Nssm set $script:SebServiceName AppRotateFiles 1 | Out-Null
  & $Nssm set $script:SebServiceName Description "Backs up every SQL Server database on this host to a file share every $Hours hour(s)." | Out-Null
  Start-Service -Name $script:SebServiceName
  Write-SebLog ('service "{0}" installed and started - one pass every {1} hour(s)' -f $script:SebServiceName, $Hours)

  # A second SYSTEM task, registered ONLY for a Full-recovery install: -BackupLog
  # takes a transaction-log backup every few minutes, so the recovery point never
  # drifts far behind "now". RecoveryMode and LogIntervalMinutes are config keys a
  # LATER feature (D3) adds - an install made before that, or a Simple-recovery
  # install, has neither key, and that must read as Simple (no log task) rather
  # than throw. Same guard style as Invoke-SebPass uses for this same key. The log
  # backup is always a scheduled task, even for a Service install - the main loop
  # runs as the NSSM service, but -BackupLog is a separate short-lived invocation,
  # same as the Task install registers below.
  $config = Read-SebConfig
  $isFullMode = ([string]$config.RecoveryMode -eq 'Full')
  if ($isFullMode) {
    $logMinutes = 15
    if ($config.PSObject.Properties['LogIntervalMinutes']) { $logMinutes = [int]$config.LogIntervalMinutes }

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $logTaskName = Get-SebLogTaskName -Base $script:SebTaskName
    # Same script path, same "-NoProfile ... -File" shape, same -ConfigDir as the
    # Task install's log action - only the mode flag changes.
    $logArguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -BackupLog -ConfigDir "{1}"' -f $ScriptPath, $ConfigDirectory)
    $logAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $logArguments
    # Stagger the log task's start off the main pass's so their firings do not stay
    # harmonically locked (a 6h interval is a multiple of 15min); otherwise the coincident
    # tick would lose the shared mutex to the main pass every interval and skip a log backup.
    $logOffset = 2 + [math]::Ceiling($logMinutes / 2)
    $logTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($logOffset) -RepetitionInterval (New-TimeSpan -Minutes $logMinutes)
    $logSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
      -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    [void](Register-ScheduledTask -TaskName $logTaskName -Action $logAction `
        -Trigger $logTrigger -Principal $principal -Settings $logSettings -Force)
    Write-SebLog ('scheduled task "{0}" registered - every {1} minute(s), transaction-log backups for Full-recovery databases' -f $logTaskName, $logMinutes)
  }
}

function Uninstall-SebSchedule {
  param([string]$Nssm)
  $state = Get-SebScheduleState
  if ($state.TaskPresent) {
    Unregister-ScheduledTask -TaskName $script:SebTaskName -Confirm:$false
    Write-SebLog ('scheduled task "{0}" removed' -f $script:SebTaskName)
  }
  # A Simple-recovery install never created this second task, so finding it absent
  # here is the ordinary case, not an error worth surfacing.
  $logTaskName = Get-SebLogTaskName -Base $script:SebTaskName
  if (Get-ScheduledTask -TaskName $logTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $logTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-SebLog ('scheduled task "{0}" removed' -f $logTaskName)
  }
  if ($state.ServicePresent) {
    try { Stop-Service -Name $script:SebServiceName -Force -ErrorAction SilentlyContinue } catch { }
    $resolved = $Nssm
    if (-not $resolved) {
      $found = Get-Command 'nssm.exe' -ErrorAction SilentlyContinue
      if ($found) { $resolved = $found.Source }
    }
    if ($resolved) { & $resolved remove $script:SebServiceName confirm | Out-Null }
    else { & sc.exe delete $script:SebServiceName | Out-Null }
    Write-SebLog ('service "{0}" removed' -f $script:SebServiceName)
  }
  if (-not $state.TaskPresent -and -not $state.ServicePresent) {
    Write-SebLog 'nothing scheduled - nothing to remove'
  }
}

# =====================================================================
# Modes
# =====================================================================

function Invoke-SebSetup {
  param([string]$PinnedInstance, [string]$Share, [string]$Staging, [int]$Hours, [int]$Hourly, [int]$DailyDays, [switch]$WindowsAuth, [switch]$SkipHash, [string]$RecoveryMode = 'Simple', [int]$LogIntervalMinutes = 15, [int]$FullEveryHours = 24, [switch]$CompressBackups)

  if (-not (Test-Path -LiteralPath $script:SebConfigDir)) {
    [void](New-Item -ItemType Directory -Path $script:SebConfigDir -Force)
  }
  # NOT locked as a whole, deliberately. Every secret in here is locked individually -
  # key.bin, key.entropy, cred.dat, config.json, state.json and engine\ - and locking
  # the directory on top of that only takes public.json down with it, which is the one
  # file an unelevated dashboard is supposed to be able to read. It also stopped the
  # console starting at all, since it could no longer open its own state directory.

  Write-Host ''
  Write-Host '== Instances on this host ============================================='
  $instances = Get-SebInstanceList
  if ($instances.Count -eq 0) {
    throw 'no SQL Server instance found in the registry on this host'
  }
  for ($i = 0; $i -lt $instances.Count; $i++) {
    Write-Host ('  [{0}] {1}  edition={2} version={3} service={4}' -f `
        $i, $instances[$i].DataSource, $instances[$i].Edition, $instances[$i].Version, $instances[$i].ServiceStatus)
  }

  $chosen = $null
  if ($PinnedInstance) {
    $chosen = $instances | Where-Object { $_.InstanceName -eq $PinnedInstance -or $_.DataSource -eq $PinnedInstance } | Select-Object -First 1
    if (-not $chosen) { throw "instance '$PinnedInstance' is not one of the instances found above" }
  }
  elseif ($instances.Count -eq 1) {
    $chosen = $instances[0]
    Write-Host ('  -> only one instance; using {0}' -f $chosen.DataSource)
  }
  else {
    $answer = Read-Host 'Which instance number'
    $index = 0
    if (-not [int]::TryParse($answer, [ref]$index) -or $index -lt 0 -or $index -ge $instances.Count) {
      throw "that is not one of the numbers offered"
    }
    $chosen = $instances[$index]
  }

  if (-not $Share) { $Share = Read-Host 'UNC path of the backup share (e.g. \\fileserver\sqlbackups)' }
  if ([string]::IsNullOrWhiteSpace($Share)) { throw 'a share path is required' }
  if (-not $Staging) { $Staging = 'C:\SqlBackupStaging' }

  Write-Host ''
  Write-Host '== Credential ========================================================='
  $sqlUser = ''
  if (-not $WindowsAuth) {
    Write-Host '  A dedicated login with dbcreator + db_backupoperator is enough for this,'
    Write-Host '  and is a much smaller loss than sa if the sealed file is ever recovered.'
    $sqlUser = Read-Host 'SQL login name'
    if ([string]::IsNullOrWhiteSpace($sqlUser)) { throw 'a login name is required' }
    $secret = Read-Host 'Password' -AsSecureString
    if ($secret.Length -eq 0) { throw 'an empty password is not accepted' }
  }

  Write-Host ''
  Write-Host '== Proving it works before anything is written ========================'
  $connection = $null
  $sqlAccount = Get-SebAclIdentity (Get-SebServiceAccount -ServiceName $chosen.ServiceName)
  try {
    if ($WindowsAuth) {
      $connection = New-SebSqlConnection -DataSource $chosen.DataSource -WindowsAuth
    }
    else {
      $connection = New-SebSqlConnection -DataSource $chosen.DataSource -User $sqlUser -Password $secret
    }
    $version = Invoke-SebSqlTable -Connection $connection -Sql 'SELECT @@VERSION AS v'
    Write-Host ('  connected: {0}' -f ([string]$version[0].v).Split("`n")[0].Trim())

    if ($WindowsAuth) {
      $identity = Test-SebScheduledIdentity -Connection $connection
      if (-not $identity.Ok) { throw $identity.Reason }
      Write-Host ('  scheduled identity checked: ' + $identity.Reason)
    }

    if (-not (Test-Path -LiteralPath $Staging)) { [void](New-Item -ItemType Directory -Path $Staging -Force) }
    if ([string]::IsNullOrWhiteSpace($sqlAccount)) {
      Write-Host ('  WARNING: could not read the service account of {0}; staging permissions NOT granted' -f $chosen.ServiceName)
    }
    else {
      Set-SebStagingAcl -Path $Staging -SqlAccount $sqlAccount
      Write-Host ('  staging folder ready: {0}   (Modify granted to {1})' -f $Staging, $sqlAccount)
    }
    Test-SebStagingWritable -Connection $connection -Staging $Staging -SqlAccount $sqlAccount
    Write-Host '  SQL Server proved it can write there - a real COPY_ONLY backup of model succeeded'
  }
  finally {
    if ($null -ne $connection) { $connection.Dispose() }
  }

  # Two probes, because the difference between them is the whole diagnosis. The
  # caller's access is only ever informational: the backups do not run as the caller.
  $callerOk = $true
  $callerWhy = ''
  $probe = Join-Path $Share ('.seb-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    Set-Content -LiteralPath $probe -Value 'probe' -Encoding ASCII -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  }
  catch { $callerOk = $false; $callerWhy = $_.Exception.Message }

  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  Write-Host ('  share as you ({0}): {1}' -f $me, $(if ($callerOk) { 'writable' } else { 'NOT writable - ' + $callerWhy }))

  Write-Host '  checking the share as SYSTEM, which is what the scheduled backup uses...'
  $sysProbe = Test-SebShareWritableAsSystem -Share $Share
  if ($sysProbe.Ok) {
    Write-Host ('  share is writable by SYSTEM: {0}' -f $Share)
  }
  elseif ($sysProbe.Inconclusive) {
    Write-Host ('  WARNING: could not confirm SYSTEM can write to the share ({0}).' -f $sysProbe.Detail)
    Write-Host '           Setup continues; the first scheduled run will show the truth.'
  }
  else {
    $extra = ''
    if ($callerOk) {
      $extra = " You CAN write to it yourself, which is exactly why this check exists: " +
      "the backup does not run as you. Grant the machine account (or Domain Computers) " +
      "write access on the share and on the folder behind it, then run setup again."
    }
    throw ((Get-SebShareDenialMessage -Share $Share -Account (Get-SebMachineAccount) `
          -MachineAccount (Get-SebMachineAccount) -Original $sysProbe.Detail) + $extra)
  }

  if (-not $WindowsAuth) {
    $master = Get-SebMasterKey -Create
    try {
      $blob = Protect-SebSecureString -Secret $secret -Master $master
      Set-Content -LiteralPath (Get-SebCredPath) -Value $blob -Encoding ASCII
      Set-SebSecretAcl (Get-SebCredPath)
    }
    finally {
      [System.Array]::Clear($master, 0, $master.Length)
      $secret.Dispose()
    }
    Write-Host '  credential sealed (DPAPI LocalMachine key, AES-256-CBC + HMAC-SHA256 payload)'
  }

  Write-SebConfig ([pscustomobject]@{
      Version       = 1
      DataSource    = $chosen.DataSource
      InstanceName  = $chosen.InstanceName
      Edition       = $chosen.Edition
      SharePath     = $Share
      StagingPath   = $Staging
      IntervalHours = $Hours
      HourlyKeep    = $Hourly
      DailyKeepDays = $DailyDays
      RecoveryMode       = $RecoveryMode
      LogIntervalMinutes = $LogIntervalMinutes
      FullEveryHours     = $FullEveryHours
      CompressBackups    = [bool]$CompressBackups
      SqlUser       = $sqlUser
      SqlServiceAccount = $sqlAccount
      UseWindowsAuth = [bool]$WindowsAuth
      NoHashVerify  = [bool]$SkipHash
      CreatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    })

  Write-Host ''
  Write-Host ('Setup complete. Config in {0}' -f $script:SebConfigDir)
  Write-Host 'Next:  -Install -As Task     (or -As Service, which needs nssm.exe)'
}

# "Access is denied" on its own is the least useful thing a backup tool can say.
# It does not name the path, the account, or which of the several things setup
# touches was refused - and this is the tool whose entire premise is being
# debuggable during a change window. Built as a pure function so the wording is
# tested rather than only seen when it is already 2am.
# Quote a string for a PowerShell single-quoted literal.
function Get-SebPsLiteral {
  param([string]$Text)
  return "'" + ($Text -replace "'", "''") + "'"
}

# Can the account that will ACTUALLY run the backups write to the share?
#
# This used to probe as whoever ran -Setup, which is nobody in the real picture: the
# scheduled task runs as SYSTEM and reaches a network share as the MACHINE account.
# Testing the elevated operator is wrong in both directions - it fails when the
# machine account is fine, and passes when it is not, which is the worse half. Seen
# on a share granting BUILTIN\Users: the operator could write, the machine account
# could not, and a caller-side probe would have greenlit an install whose every
# backup then failed to copy.
#
# So run the probe where the work happens. Setup is already elevated, so it can
# register a short-lived task as SYSTEM, have that try the write, and read back what
# happened. Slower than a local file write, and the only version that answers the
# question that matters.
# The script the SYSTEM probe task runs, as lines. Pulled out as its own function
# because it is generated code, and generated code that is never parsed is a guess.
#
# EVERY concatenation is parenthesised, and that is not style. In PowerShell the
# comma binds TIGHTER than +, so inside @( ... ) an unparenthesised
# 'text ' + $x + ' more' splits into three array elements instead of one string. The
# file then has "Set-Content -LiteralPath" on one line and the path on the next,
# which still parses - it just runs Set-Content with no path and then tries to run
# "-Value" as a command. The probe would have reported that SYSTEM cannot write no
# matter what the permissions actually were, and blocked every setup.
function Get-SebShareProbeBody {
  param([string]$ProbeFile, [string]$ResultFile)
  $p = Get-SebPsLiteral $ProbeFile
  $r = Get-SebPsLiteral $ResultFile
  return @(
    '$ErrorActionPreference = ''Stop''',
    'try {',
    ('  Set-Content -LiteralPath ' + $p + ' -Value ''probe'' -Encoding ASCII'),
    ('  Remove-Item -LiteralPath ' + $p + ' -Force -ErrorAction SilentlyContinue'),
    ('  Set-Content -LiteralPath ' + $r + ' -Value ''OK'' -Encoding ASCII'),
    '}',
    'catch {',
    ('  Set-Content -LiteralPath ' + $r + ' -Value ("FAIL " + $_.Exception.Message) -Encoding ASCII'),
    '}'
  )
}

function Test-SebShareWritableAsSystem {
  param([string]$Share, [int]$TimeoutSec = 120)

  $taskName = 'SqlExpressBackup-ShareProbe'
  $id = [Guid]::NewGuid().ToString('N')
  $resultFile = Join-Path $script:SebConfigDir ('shareprobe-' + $id + '.txt')
  $scriptFile = Join-Path $script:SebConfigDir ('shareprobe-' + $id + '.ps1')
  $probeFile = Join-Path $Share ('.seb-systemprobe-' + $id + '.tmp')

  $body = Get-SebShareProbeBody -ProbeFile $probeFile -ResultFile $resultFile
  Set-Content -LiteralPath $scriptFile -Value $body -Encoding ASCII

  try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptFile + '"')
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    [void](Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force)
    Start-ScheduledTask -TaskName $taskName
    $probeRun = Wait-SebScheduledRun -TaskName $taskName -TimeoutSec $TimeoutSec

    if (-not $probeRun.Completed) {
      return [pscustomobject]@{ Ok = $false; Inconclusive = $true; Detail = 'the probe task did not finish in time' }
    }
    if (-not (Test-Path -LiteralPath $resultFile)) {
      return [pscustomobject]@{ Ok = $false; Inconclusive = $true; Detail = 'the probe task ran but wrote no result' }
    }
    $text = (Get-Content -LiteralPath $resultFile -Raw).Trim()
    if ($text -eq 'OK') { return [pscustomobject]@{ Ok = $true; Inconclusive = $false; Detail = 'SYSTEM wrote to the share' } }
    return [pscustomobject]@{ Ok = $false; Inconclusive = $false; Detail = ($text -replace '^FAIL\s*', '') }
  }
  finally {
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-SebShareDenialMessage {
  param([string]$Share, [string]$Account, [string]$MachineAccount, [string]$Original)
  $msg = "cannot write to the share '$Share' as $Account"
  if (-not [string]::IsNullOrWhiteSpace($Original)) { $msg += " - $Original" }
  $msg += ". Nothing has been changed."
  $msg += " Check that this account has write access to the share AND to the folder behind it;"
  $msg += " a share can grant Full while NTFS underneath refuses."
  if (-not [string]::IsNullOrWhiteSpace($MachineAccount)) {
    $msg += " The scheduled backup will reach it as $MachineAccount, not as you, so that account needs the same access."
  }
  return $msg
}

function Get-SebMachineAccount {
  param([string]$Domain = $env:USERDOMAIN, [string]$Computer = $env:COMPUTERNAME)
  if ([string]::IsNullOrWhiteSpace($Computer)) { return '' }
  if ([string]::IsNullOrWhiteSpace($Domain) -or ($Domain -ieq $Computer)) { return ($Computer + '$') }
  return ($Domain + '\' + $Computer + '$')
}

function Get-SebUncPath {
  param([string]$HostName, [string]$ShareName)
  return ('\\' + $HostName + '\' + $ShareName)
}

# The identity that will actually run every backup is NOT the operator running
# -Setup. Under Windows authentication the scheduled task connects as the account
# it runs as - SYSTEM - so proving the operator can log in proves nothing about
# the thing that does the work. Without this check, setup passes cleanly and every
# run afterwards fails at six-hour intervals with a login error nobody is watching.
function Get-SebLoginProbeSql {
  param([string]$LoginName)
  $literal = Get-SebSqlLiteral $LoginName
  return @"
SELECT sp.name AS name,
       sp.is_disabled AS is_disabled,
       IS_SRVROLEMEMBER('sysadmin', sp.name) AS is_sysadmin,
       IS_SRVROLEMEMBER('dbcreator', sp.name) AS is_dbcreator
FROM sys.server_principals AS sp
WHERE sp.name = $literal AND sp.type IN ('U', 'G')
"@
}

function Test-SebLoginUsable {
  param([object[]]$Rows = @(), [string]$LoginName)
  if (@($Rows).Count -eq 0) {
    return [pscustomobject]@{
      Ok     = $false
      Reason = ("SQL Server has no login for $LoginName, so the scheduled backup would fail every time it ran. " +
        "Create it on the instance: CREATE LOGIN [$LoginName] FROM WINDOWS; " +
        "ALTER SERVER ROLE [dbcreator] ADD MEMBER [$LoginName];  (or use a SQL login instead of -UseWindowsAuth)")
    }
  }
  $row = $Rows[0]
  $disabled = Get-SebValue $row.is_disabled
  if ($null -ne $disabled -and [bool]$disabled) {
    return [pscustomobject]@{ Ok = $false; Reason = "the login $LoginName exists but is DISABLED: ALTER LOGIN [$LoginName] ENABLE;" }
  }
  $sysadmin = [int](Get-SebValue $row.is_sysadmin)
  $dbcreator = [int](Get-SebValue $row.is_dbcreator)
  if ($sysadmin -ne 1 -and $dbcreator -ne 1) {
    return [pscustomobject]@{
      Ok     = $false
      Reason = ("the login $LoginName exists but holds neither sysadmin nor dbcreator, so it cannot back up every " +
        "database: ALTER SERVER ROLE [dbcreator] ADD MEMBER [$LoginName];")
    }
  }
  return [pscustomobject]@{ Ok = $true; Reason = "$LoginName can log in and has the rights to back up" }
}

function Test-SebScheduledIdentity {
  param($Connection, [string]$LoginName = 'NT AUTHORITY\SYSTEM')
  $rows = Invoke-SebSqlTable -Connection $Connection -Sql (Get-SebLoginProbeSql -LoginName $LoginName)
  return (Test-SebLoginUsable -Rows $rows -LoginName $LoginName)
}

# Create a folder on this host and share it over SMB.
#
# Be clear about what this is worth: a share on the SAME machine is not an offsite
# copy. If this disk or this host dies, the backup dies with it. It is useful for
# proving the whole UNC path end to end and as a staging point to mirror elsewhere;
# it is not disaster recovery. Point -SharePath at a different server when you can.
#
# SYSTEM reaching \\thishost\share over the loopback authenticates as the COMPUTER
# account, not as SYSTEM, so the machine account is what has to be granted on both
# the share and the file system.
# The folder ACL, built and returned rather than applied. Separated because applying
# it needs a real folder and elevation, and a rule that can only be checked by an
# administrator on a live host is a rule nobody checks. This way the composition is
# asserted directly - see deploy of the SQL service read grant in the test suite.
function New-SebShareAcl {
  param([string]$MachineAccount, [string]$SqlAccount)
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $none = [System.Security.AccessControl.PropagationFlags]::None
  foreach ($sid in @(
      (New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)),
      (New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)))) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, 'Allow')))
  }
  if (-not [string]::IsNullOrWhiteSpace($MachineAccount)) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object System.Security.Principal.NTAccount($MachineAccount)), 'Modify', $inherit, $none, 'Allow')))
  }
  # Read, not Modify: SQL must be able to RESTORE from here and nothing more. It
  # writes through staging, so it has no business altering what is already archived.
  if (-not [string]::IsNullOrWhiteSpace($SqlAccount)) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object System.Security.Principal.NTAccount($SqlAccount)), 'ReadAndExecute', $inherit, $none, 'Allow')))
  }
  return $acl
}

# The SQL service account has to be granted READ here too, and that is not symmetry
# for its own sake. Backups are written by SQL into staging and copied here by the
# engine, so the copies land owned by the engine and SQL cannot open them - which
# nothing notices, because BACKUP never reads them back. It surfaces the first time
# somebody tries to RESTORE, which is the worst possible moment to find out. Found
# by an actual restore drill, not by review: every backup verified, every pass
# green, and RESTORE FILELISTONLY still failed with operating system error 5.
#
# It needs granting in TWO places, and the identities are not interchangeable. Over
# a LOCAL loopback UNC the service presents as its own virtual account, so that
# account needs both the share and the file system. Reaching a REMOTE share it
# presents as the computer account instead. Grant only one and exactly one of those
# two paths is broken.
# Share-level permissions the backups need, applied idempotently. Separated so the
# reuse path and the create path grant exactly the same thing - the bug this fixes
# was the two drifting apart, with only the create path granting the SQL service.
function Grant-SebShareAccess {
  param([string]$ShareName, [string]$MachineAccount, [string]$SqlAccount)
  Import-SebShippedModule -Command 'Grant-SmbShareAccess' -Module 'SmbShare'
  if (-not [string]::IsNullOrWhiteSpace($MachineAccount)) {
    [void](Grant-SmbShareAccess -Name $ShareName -AccountName $MachineAccount -AccessRight Full -Force -ErrorAction SilentlyContinue)
  }
  if (-not [string]::IsNullOrWhiteSpace($SqlAccount)) {
    [void](Grant-SmbShareAccess -Name $ShareName -AccountName $SqlAccount -AccessRight Read -Force -ErrorAction SilentlyContinue)
  }
}

function New-SebLocalShare {
  param(
    [string]$FolderPath,
    [string]$ShareName,
    [string]$MachineAccount = (Get-SebMachineAccount),
    [string]$SqlAccount
  )
  Import-SebShippedModule -Command 'Set-Acl' -Module 'Microsoft.PowerShell.Security'
  Import-SebShippedModule -Command 'Get-SmbShare' -Module 'SmbShare'

  if (-not (Test-Path -LiteralPath $FolderPath)) {
    [void](New-Item -ItemType Directory -Path $FolderPath -Force)
    Write-SebLog ('created backup folder {0}' -f $FolderPath)
  }

  Set-Acl -Path $FolderPath -AclObject (New-SebShareAcl -MachineAccount $MachineAccount -SqlAccount $SqlAccount)

  $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
  if ($null -ne $existing) {
    $existingPath = [string]$existing.Path
    if ($existingPath.TrimEnd('\') -ine $FolderPath.TrimEnd('\')) {
      throw ("a share named '$ShareName' already exists on this host and points at '$existingPath', not '$FolderPath'. " +
        'Remove it or choose another -ShareName rather than repointing something that may be in use.')
    }
    Write-SebLog ("share '{0}' already exists at {1} - reusing it" -f $ShareName, $FolderPath)
    # Reusing a share must NOT mean reusing its permissions unquestioned. The rule
    # that the SQL service needs read to RESTORE was added after some shares already
    # existed, so a re-setup over an old share left restore-from-UNC broken while the
    # NTFS ACL (re-applied above) looked fine - the exact split that made a backup
    # readable locally and unreadable over its own share. Grant-SmbShareAccess is
    # idempotent, so the grants are re-applied every time rather than only at
    # creation. This is what the else branch does for a NEW share; the two must match.
    Grant-SebShareAccess -ShareName $ShareName -MachineAccount $MachineAccount -SqlAccount $SqlAccount
  }
  else {
    $full = @('BUILTIN\Administrators')
    if (-not [string]::IsNullOrWhiteSpace($MachineAccount)) { $full += $MachineAccount }
    $params = @{ Name = $ShareName; Path = $FolderPath; FullAccess = $full; Description = 'SQL Express backups' }
    if (-not [string]::IsNullOrWhiteSpace($SqlAccount)) { $params['ReadAccess'] = @($SqlAccount) }
    [void](New-SmbShare @params)
    Write-SebLog ("shared {0} as '{1}', full access to {2}{3}" -f $FolderPath, $ShareName, ($full -join ' and '),
      $(if (-not [string]::IsNullOrWhiteSpace($SqlAccount)) { ", read to $SqlAccount" } else { '' }))
  }

  return (Get-SebUncPath -HostName $env:COMPUTERNAME -ShareName $ShareName)
}

# Wait for a scheduled task to finish and hand back what it returned.
#
# This exists so the full install can prove the backup works AS SYSTEM. Running a
# pass in-process proves only that the elevated administrator could do it, and the
# administrator is not the account that will run it every six hours: SYSTEM
# reaching \\thishost\share over the loopback authenticates as the COMPUTER
# account, and its SQL login is a different principal too. Proving the wrong
# identity is how a scheduled job passes its install and then fails forever.
#
# The state reader and the sleeper are injected so the polling is testable without
# a real task and without actually waiting.
function Wait-SebScheduledRun {
  param(
    [string]$TaskName,
    [int]$TimeoutSec = 900,
    [scriptblock]$StateReader,
    [scriptblock]$ResultReader,
    [scriptblock]$Sleeper
  )
  if (-not $StateReader) { $StateReader = { param($n) [string](Get-ScheduledTask -TaskName $n -ErrorAction Stop).State } }
  if (-not $ResultReader) { $ResultReader = { param($n) [int](Get-ScheduledTaskInfo -TaskName $n -ErrorAction Stop).LastTaskResult } }
  if (-not $Sleeper) { $Sleeper = { param($sec) Start-Sleep -Seconds $sec } }

  $waited = 0
  $step = 3
  while ($waited -lt $TimeoutSec) {
    $state = & $StateReader $TaskName
    if ($state -ne 'Running') {
      return [pscustomobject]@{ Completed = $true; Result = (& $ResultReader $TaskName); WaitedSec = $waited }
    }
    & $Sleeper $step
    $waited += $step
  }
  return [pscustomobject]@{ Completed = $false; Result = $null; WaitedSec = $waited }
}

# Turn a task result code into something an operator can act on. The codes are the
# script's own exit codes, because that is what Task Scheduler records.
function Get-SebRunVerdict {
  param($Completed, $Result)
  if (-not $Completed) {
    return 'still running after the wait - it is not stuck, large databases simply take a while. Check -Status later.'
  }
  if ($null -eq $Result) { return 'finished, but Task Scheduler recorded no result code.' }
  switch ([int]$Result) {
    0 { return 'every database was backed up and landed on the share.' }
    1 { return 'PARTIAL - a database failed, or a copy is still waiting for the share. Run -Status and read the log.' }
    2 { return 'FAILED - nothing was backed up. Run -Status and read the log.' }
    default { return ('the task exited with code ' + $Result + ' - it did not get as far as reporting a backup result. Read the log.') }
  }
}

function Write-SebCheck {
  param([bool]$Ok, [string]$What)
  if ($Ok) { $script:SebStPass++; Write-Host ('  [ OK ] ' + $What) }
  else { $script:SebStFail++; Write-Host ('  [FAIL] ' + $What) -ForegroundColor Red }
  # Also report the step as a stage. The self test spends minutes on preparation -
  # resolving the service account, proving staging is writable with a real backup -
  # all of it before any [JOB] marker exists. Without this the console sat at
  # '(preparing) 0%' for over five minutes while working perfectly, which is the same
  # fault as a finished job drawing an empty bar: the readout cannot tell the
  # operator apart from a hang.
  $short = $What
  if ($short.Length -gt 58) { $short = $short.Substring(0, 55) + '...' }
  Write-SebStage -Database '' -Stage $short
}

# A complete live proof against the real engine, in a throwaway location, on a
# database this creates and drops. It exists because the unit suite cannot see the
# things that actually break an install: whether the SQL service account can write
# to staging, whether this edition rejects COMPRESSION, whether retention prunes
# real files, and whether the file on the share genuinely restores.
#
# It never touches an existing database - the pass is scoped by OnlyDatabase - and
# it needs no elevation, because it works in a folder it creates and owns and
# connects with the caller's own Windows credentials.
# ---------------------------------------------------------------------------
# RESTORE
#
# The console drives these. They deliberately live here rather than in the window,
# because the engine already performs HEADERONLY, FILELISTONLY and RESTORE ... WITH
# MOVE inside the self test, and that code is exercised on every run. A second
# implementation in C# would be two things that must agree forever about relocation
# and recovery state, and they would diverge at the worst possible time.
#
# Output is JSON on one line, because the caller is a program. Everything a human
# needs is already in the log.

# What a restore needs to know, readable WITHOUT elevation.
#
# Restoring requires sysadmin on the instance, which is a SQL right - it does not
# require local administrator, and demanding one to get the other would be a lie
# about what the operation needs. config.json is deliberately locked to SYSTEM and
# Administrators because it holds sealed credentials; public.json carries the same
# instance and share paths for exactly this kind of reader.
function Read-SebRestoreContext {
  try {
    $cfg = Read-SebConfig
    return [pscustomobject]@{ DataSource = [string]$cfg.DataSource; SharePath = [string]$cfg.SharePath }
  }
  catch {
    $p = Get-SebPublicPath
    if (-not (Test-Path -LiteralPath $p)) {
      throw 'no configuration found. Run -Setup first, or start the console as an administrator if the settings exist but cannot be read.'
    }
    $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    return [pscustomobject]@{ DataSource = [string]$j.DataSource; SharePath = [string]$j.SharePath }
  }
}

# A UNC pointing at THIS host, resolved to the folder behind it.
#
# The local-share setup grants the SMB share to Administrators and the machine
# account, which is what the SYSTEM scheduled task needs - and means an ordinary
# operator is refused at the share even though they can read the folder perfectly
# well. Restoring is not an administrative act, so being blocked by a share ACL that
# exists for the scheduler would be an accident, not a policy.
function Resolve-SebLocalShare {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root) -or $Root.Length -lt 3 -or $Root[0] -ne [char]92 -or $Root[1] -ne [char]92) { return $Root }
  $sep = [char]92
  $parts = @($Root.TrimStart($sep).Split($sep))
  if ($parts.Count -lt 2) { return $Root }
  $host_ = $parts[0]
  if ($host_ -ne $env:COMPUTERNAME -and $host_ -ne 'localhost' -and $host_ -ne '.') { return $Root }
  try {
    Import-SebShippedModule -Command 'Get-SmbShare' -Module 'SmbShare'
    $share = Get-SmbShare -Name $parts[1] -ErrorAction SilentlyContinue
    if ($null -eq $share) { return $Root }
    $local = [string]$share.Path
    if ($parts.Count -gt 2) {
      $rest = ($parts[2..($parts.Count - 1)]) -join $sep
      if (-not [string]::IsNullOrWhiteSpace($rest)) { $local = [System.IO.Path]::Combine($local, $rest) }
    }
    if (Test-Path -LiteralPath $local) { return $local }
  }
  catch { }
  return $Root
}

function Get-SebRestoreCatalogue {
  param([string]$Root)
  $sets = @()
  if ([string]::IsNullOrWhiteSpace($Root)) { return $sets }
  # Prefer the UNC, because that is what the scheduler writes and what the operator
  # sees in the settings - but fall back to the folder behind it rather than
  # reporting no backups exist when the truth is this account cannot open the share.
  try { if (-not (Test-Path -LiteralPath $Root)) { $Root = Resolve-SebLocalShare -Root $Root } }
  catch { $Root = Resolve-SebLocalShare -Root $Root }
  try { if (-not (Test-Path -LiteralPath $Root)) { return $sets } }
  catch { return $sets }
  # <root>\<host>\<instance>\<database>\<kind>\<db>_<stamp>.bak (or .bak.zip, compressed)
  foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.bak(\.zip)?$' })) {
    $kind = Split-Path -Leaf (Split-Path -Parent $f.FullName)
    $db = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $f.FullName))
    $stamp = Get-SebStampFromName -Name $f.Name -Fallback $f.LastWriteTime
    $sets += [pscustomobject]@{
      Database = $db
      Kind     = $kind
      Path     = $f.FullName
      Bytes    = $f.Length
      TakenUtc = $stamp.ToUniversalTime().ToString('o')
    }
  }
  return @($sets | Sort-Object Database, @{ Expression = 'TakenUtc'; Descending = $true })
}

# Can the SQL SERVICE read this file? Not can the operator - those are different
# accounts, and the difference is the fault a restore drill found: every backup
# verified, every pass green, and RESTORE FILELISTONLY refused with operating system
# error 5 because the copies were written by the engine and never granted to SQL.
#
# Asked BEFORE the operator commits to anything, because the symptom reads as a
# corrupt backup and is not.
function Test-SebRestoreReadable {
  param($Connection, [string]$Path)
  try {
    [void](Invoke-SebSqlTable -Connection $Connection -Sql ('RESTORE FILELISTONLY FROM DISK = {0}' -f (Get-SebSqlLiteral $Path)))
    return @{ Ok = $true; Reason = '' }
  }
  catch {
    $m = [string]$_.Exception.Message
    if ($m -match 'operating system error 5' -or $m -match 'Access is denied') {
      return @{ Ok = $false; Reason = 'denied' }
    }
    return @{ Ok = $false; Reason = $m }
  }
}

function Get-SebRestoreInspect {
  param($Connection, [string]$Path)
  $readable = Test-SebRestoreReadable -Connection $Connection -Path $Path
  $result = [ordered]@{
    Path = $Path; Readable = $readable.Ok; ReadReason = $readable.Reason
    Database = ''; TakenUtc = ''; Compressed = $false; Files = @(); Verified = $null; Error = ''
  }
  if (-not $readable.Ok) { return $result }
  try {
    $h = Invoke-SebSqlTable -Connection $Connection -Sql ('RESTORE HEADERONLY FROM DISK = {0}' -f (Get-SebSqlLiteral $Path))
    if ($h.Count -gt 0) {
      $result.Database = [string](Get-SebValue $h[0].DatabaseName)
      $finish = Get-SebValue $h[0].BackupFinishDate
      if ($finish) { $result.TakenUtc = ([datetime]$finish).ToUniversalTime().ToString('o') }
      $result.Compressed = ([long](Get-SebValue $h[0].CompressedBackupSize) -lt [long](Get-SebValue $h[0].BackupSize))
    }
    $fl = Invoke-SebSqlTable -Connection $Connection -Sql ('RESTORE FILELISTONLY FROM DISK = {0}' -f (Get-SebSqlLiteral $Path))
    $files = @()
    foreach ($row in $fl) {
      $files += [pscustomobject]@{
        LogicalName = [string](Get-SebValue $row.LogicalName)
        Type        = [string](Get-SebValue $row.Type)
        SizeBytes   = [long](Get-SebValue $row.Size)
      }
    }
    $result.Files = $files
  }
  catch { $result.Error = [string]$_.Exception.Message }
  return $result
}

# The physical target paths a restore would write, one per file in Files order: the
# .mdf / .ndf / .ldf leaves under the chosen data and log directories. Both the MOVE
# clauses and the pre-restore clobber check derive from THIS single source, so the
# clobber check tests the exact paths the restore will write. It used to re-parse the
# path back out of the generated 'MOVE x TO ''path''' T-SQL, which mangled any path
# containing a quote (the doubled '' survived) or the literal ' TO ' (split wrongly) -
# so the check could look at the wrong file and let RESTORE overwrite a real database.
function Get-SebRestoreTargets {
  param($Files, [string]$TargetName, [string]$DataDir, [string]$LogDir)
  $targets = @()
  $dataIndex = 0
  foreach ($f in @($Files)) {
    $isLog = ([string]$f.Type -eq 'L')
    $dir = if ($isLog) { $LogDir } else { $DataDir }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $DataDir }
    # The first data file is <name>.mdf; further ones must not collide with it.
    if ($isLog) { $leaf = $TargetName + '_log.ldf' }
    elseif ($dataIndex -eq 0) { $leaf = $TargetName + '.mdf'; $dataIndex++ }
    else { $leaf = ($TargetName + '_' + $dataIndex + '.ndf'); $dataIndex++ }
    # [IO.Path]::Combine, not Join-Path. Join-Path RESOLVES the path and throws
    # "a drive with the name 'D' does not exist" for any drive this machine lacks -
    # and the machine building the statement is not necessarily the one that will run
    # it. Restoring to another instance is a first-class case; failing because the
    # console cannot see the target's drive letters would be absurd.
    $targets += [System.IO.Path]::Combine($dir, $leaf)
  }
  return $targets
}

# The MOVE clauses. Two folders is the common case - all data files to one, the log
# to another - which is how NetWorker frames it and is markedly better than editing
# one row per file. Per-file override sits on top of that, not instead of it.
function Get-SebRestoreMoveClauses {
  param($Files, [string]$TargetName, [string]$DataDir, [string]$LogDir)
  $targets = @(Get-SebRestoreTargets -Files $Files -TargetName $TargetName -DataDir $DataDir -LogDir $LogDir)
  $moves = @()
  $i = 0
  foreach ($f in @($Files)) {
    $moves += ('MOVE {0} TO {1}' -f (Get-SebSqlLiteral ([string]$f.LogicalName)), (Get-SebSqlLiteral ([string]$targets[$i])))
    $i++
  }
  return $moves
}

function Get-SebRestoreSql {
  param(
    [string]$Path, [string]$TargetName, $Files,
    [string]$DataDir, [string]$LogDir,
    [string]$RecoveryState = 'RECOVERY',
    [bool]$Replace = $false, [bool]$RestrictedUser = $false
  )
  $with = @()
  $with += Get-SebRestoreMoveClauses -Files $Files -TargetName $TargetName -DataDir $DataDir -LogDir $LogDir
  $state = $RecoveryState.ToUpperInvariant()
  if ($state -ne 'RECOVERY' -and $state -ne 'NORECOVERY' -and $state -ne 'STANDBY') { $state = 'RECOVERY' }
  $with += $state
  if ($Replace) { $with += 'REPLACE' }
  if ($RestrictedUser) { $with += 'RESTRICTED_USER' }
  $with += 'STATS = 5'
  return ('RESTORE DATABASE {0} FROM DISK = {1} WITH {2}' -f
    (Get-SebQuotedName $TargetName), (Get-SebSqlLiteral $Path), ($with -join ', '))
}

# Pure. Map one RESTORE HEADERONLY row to a catalogue fact. Every field goes through
# Get-SebValue so a NULL column arrives as $null (not DBNull, which [decimal] throws on).
# CheckpointLSN is what a differential's DatabaseBackupLSN points at, so the restore
# planner needs it to match a diff to its base full.
function Get-SebHeaderFactsFromRow {
  param($Row, [string]$File, [string]$Kind)
  if ($null -eq $Row) { return $null }
  $finish = Get-SebValue $Row.BackupFinishDate
  # A header with no finish time cannot be placed on the restore timeline - treat it as
  # unusable (corrupt/truncated header) and skip it, rather than crash the [datetime] cast.
  if ($null -eq $finish) { return $null }
  return [pscustomobject]@{
    Kind = $Kind
    File = $File
    FirstLSN = [decimal](Get-SebValue $Row.FirstLSN)
    LastLSN = [decimal](Get-SebValue $Row.LastLSN)
    DatabaseBackupLSN = [decimal](Get-SebValue $Row.DatabaseBackupLSN)
    CheckpointLSN = [decimal](Get-SebValue $Row.CheckpointLSN)
    Finish = [datetime]$finish
  }
}

# Serialize a catalogue fact to sidecar JSON. LSNs are strings so numeric(25,0) precision
# survives ConvertFrom-Json (which would coerce a big JSON number to a lossy double).
function Get-SebSidecarJson {
  param($Facts)
  $o = [ordered]@{
    Kind              = [string]$Facts.Kind
    FirstLSN          = [string]$Facts.FirstLSN
    LastLSN           = [string]$Facts.LastLSN
    DatabaseBackupLSN = [string]$Facts.DatabaseBackupLSN
    CheckpointLSN     = [string]$Facts.CheckpointLSN
    Finish            = $Facts.Finish.ToString('o')
  }
  return (ConvertTo-Json $o -Compress)
}

# Parse sidecar JSON back into the same fact shape Get-SebHeaderFactsFromRow produces.
# File and Kind come from the caller (folder-derived), matching the HEADERONLY path.
#
# Finish is parsed with an EXPLICIT invariant-culture, round-trip-kind parse rather than
# a plain [datetime] cast. ToString('o') above is always invariant/Gregorian, but the
# implicit [datetime] cast on the way back uses the CURRENT culture's calendar - on a
# host set to a non-Gregorian calendar (Thai Buddhist, UmAlQura, etc.) that silently
# reads the same digits as a different year. This script runs unattended on whatever
# locale the server has, so the parse must not depend on it.
function Get-SebHeaderFactsFromSidecar {
  param([string]$Json, [string]$File, [string]$Kind)
  $o = ConvertFrom-Json $Json
  $finish = [datetime]::Parse(
    [string]$o.Finish,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind)
  return [pscustomobject]@{
    Kind              = $Kind
    File              = $File
    FirstLSN          = [decimal]$o.FirstLSN
    LastLSN           = [decimal]$o.LastLSN
    DatabaseBackupLSN = [decimal]$o.DatabaseBackupLSN
    CheckpointLSN     = [decimal]$o.CheckpointLSN
    Finish            = $finish
  }
}

# Impure. Read one backup file's header and map it. RESTORE HEADERONLY returns a
# FirstLSN/LastLSN/DatabaseBackupLSN/CheckpointLSN/BackupFinishDate row per backup set.
function Get-SebRestoreHeaderFacts {
  param($Connection, [string]$File, [string]$Kind)
  $rows = Invoke-SebSqlTable -Connection $Connection -Sql ('RESTORE HEADERONLY FROM DISK = {0}' -f (Get-SebSqlLiteral $File))
  if ($rows.Count -eq 0) { return $null }
  return Get-SebHeaderFactsFromRow -Row $rows[0] -File $File -Kind $Kind
}

# Facts for one share file: if a .meta.json sidecar sits beside it (a compressed backup),
# read the facts from the sidecar (no decompress); otherwise RESTORE HEADERONLY the plain
# file. SidecarReader is injectable for testing (defaults to reading the sidecar file).
function Get-SebFactsForFile {
  param($Connection, [string]$File, [string]$Kind, [scriptblock]$SidecarReader)
  $sidecar = Get-SebSidecarName $File
  if (-not $SidecarReader) {
    $SidecarReader = { param([string]$p) if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) } else { return $null } }
  }
  $json = & $SidecarReader $sidecar
  if ($null -ne $json) { return (Get-SebHeaderFactsFromSidecar -Json $json -File $File -Kind $Kind) }
  return (Get-SebRestoreHeaderFacts -Connection $Connection -File $File -Kind $Kind)
}

# Impure. Enumerate a database's backup folders on the share and read each file's header
# into a catalogue for Get-SebRestorePlan. Fulls live in hourly/ and daily/, diffs in
# diff/, logs in log/.
function Get-SebPointCatalogue {
  param($Connection, [string]$Root, [string]$HostName, [string]$InstanceLabel, [string]$Database)
  $cat = New-Object System.Collections.ArrayList
  $map = @{ hourly = 'full'; daily = 'full'; diff = 'diff'; log = 'log' }
  foreach ($folderKind in $map.Keys) {
    $dir = Get-SebBackupPath -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $Database -Kind $folderKind
    foreach ($fact in @(Get-SebFolderFacts -Directory $dir)) {
      try {
        $h = Get-SebFactsForFile -Connection $Connection -File $fact.FullName -Kind $map[$folderKind]
        if ($null -ne $h) { [void]$cat.Add($h) }
      }
      catch {
        Write-SebLog ('skipping an unreadable backup header in the ' + $folderKind + ' folder') 'WARN'
      }
    }
  }
  return @($cat.ToArray())
}

# Pure. Turn a Get-SebPointCatalogue result into the {Name;Timestamp;FirstLSN;LastLSN}
# facts Get-SebChainRetentionPlan expects, split by kind. Name is the file leaf so the
# retention plan's delete lists can be matched back to files by leaf name.
function Get-SebChainFactsFromCatalogue {
  param([object[]]$Catalogue = @())
  $mk = {
    param($e)
    [pscustomobject]@{ Name = (Split-Path -Leaf $e.File); Timestamp = $e.Finish; FirstLSN = $e.FirstLSN; LastLSN = $e.LastLSN }
  }
  return [pscustomobject]@{
    Fulls = @($Catalogue | Where-Object { $_.Kind -eq 'full' } | ForEach-Object { & $mk $_ })
    Diffs = @($Catalogue | Where-Object { $_.Kind -eq 'diff' } | ForEach-Object { & $mk $_ })
    Logs  = @($Catalogue | Where-Object { $_.Kind -eq 'log' }  | ForEach-Object { & $mk $_ })
  }
}

# Pure. Given a catalogue for ONE database and a target time, return the ordered
# restore steps (full -> optional diff -> contiguous logs, last one STOPAT+RECOVERY),
# or an { Error } describing why the target is not recoverable. LSNs are decimals.
function Get-SebRestorePlan {
  param([object[]]$Catalogue = @(), [datetime]$StopAt)
  $fulls = @($Catalogue | Where-Object { $_.Kind -eq 'full' } | Sort-Object Finish, FirstLSN)
  $eligible = @($fulls | Where-Object { $_.Finish -le $StopAt })
  if ($eligible.Count -eq 0) {
    return [pscustomobject]@{ Error = ('target is before the earliest full backup (earliest recoverable: {0:yyyy-MM-dd HH:mm:ss})' -f $fulls[0].Finish) }
  }
  $base = $eligible[$eligible.Count - 1]
  $steps = New-Object System.Collections.ArrayList
  [void]$steps.Add([pscustomobject]@{ Kind = 'full'; File = $base.File; Recovery = $false; StopAt = $null })

  $chainLsn = [decimal]$base.LastLSN
  # A differential's database_backup_lsn records its base full's CHECKPOINT LSN, not
  # the full's first LSN - those two only coincide when the database was idle for the
  # whole full backup. Matching on FirstLSN silently drops every diff for a database
  # that took writes during its full.
  $diffs = @($Catalogue | Where-Object {
      $_.Kind -eq 'diff' -and [decimal]$_.DatabaseBackupLSN -eq [decimal]$base.CheckpointLSN -and $_.Finish -le $StopAt
    } | Sort-Object Finish, FirstLSN)
  if ($diffs.Count -gt 0) {
    $diff = $diffs[$diffs.Count - 1]
    [void]$steps.Add([pscustomobject]@{ Kind = 'diff'; File = $diff.File; Recovery = $false; StopAt = $null })
    $chainLsn = [decimal]$diff.LastLSN
  }

  # Keyed on LastLSN, not FirstLSN: a log that STARTS before the chain point but ENDS
  # past it (e.g. bracketing a differential's LSN, the L1 case) is still the next log
  # that must be applied - filtering on FirstLSN would wrongly exclude it.
  $logs = @($Catalogue | Where-Object { $_.Kind -eq 'log' -and [decimal]$_.LastLSN -gt $chainLsn } | Sort-Object { [decimal]$_.FirstLSN })
  $spanning = $null
  $prevLast = $chainLsn
  foreach ($log in $logs) {
    if ([decimal]$log.FirstLSN -gt $prevLast) {
      return [pscustomobject]@{ Error = ('gap in the log chain: no backup bridges LSN {0} to {1} ({2}) - the chain is broken and this point cannot be restored' -f $prevLast, $log.FirstLSN, $log.File) }
    }
    if ($log.Finish -ge $StopAt) { $spanning = $log; break }
    [void]$steps.Add([pscustomobject]@{ Kind = 'log'; File = $log.File; Recovery = $false; StopAt = $null })
    $prevLast = [decimal]$log.LastLSN
  }
  if ($null -eq $spanning) {
    $latest = if ($logs.Count -gt 0) { $logs[$logs.Count - 1].Finish } elseif ($diffs.Count -gt 0) { $diffs[$diffs.Count - 1].Finish } else { $base.Finish }
    return [pscustomobject]@{ Error = ('target is after the newest log backup (latest recoverable: {0:yyyy-MM-dd HH:mm:ss})' -f $latest) }
  }
  [void]$steps.Add([pscustomobject]@{ Kind = 'log'; File = $spanning.File; Recovery = $true; StopAt = $StopAt })
  return [pscustomobject]@{ Steps = @($steps.ToArray()) }
}

# Pure. The RESTORE T-SQL for one plan step. Full carries WITH NORECOVERY, plus REPLACE
# only when the caller asks for it - a fresh restore-as-new-name has no files of its own
# to overwrite, but a re-run (e.g. after a corrected -StopAt) does, and must not
# silently replace them without -Replace - plus the MOVE clauses that relocate the files
# to the new name; diff/log continue the chain; the final (Recovery) log recovers WITH
# STOPAT at the target instant. ISO 8601 STOPAT so SQL parses it unambiguously
# regardless of server locale.
function Get-SebRestoreStepSql {
  param($Step, [string]$RestoreAs, [bool]$Replace = $false, [string[]]$MoveClauses = @())
  $target = Get-SebQuotedName $RestoreAs
  $literal = Get-SebSqlLiteral $Step.File
  if ($Step.Kind -eq 'full') {
    $with = @('NORECOVERY')
    if ($Replace) { $with += 'REPLACE' }
    $with += $MoveClauses
    return ('RESTORE DATABASE {0} FROM DISK = {1} WITH {2}' -f $target, $literal, ($with -join ', '))
  }
  if ($Step.Kind -eq 'diff') {
    return ('RESTORE DATABASE {0} FROM DISK = {1} WITH NORECOVERY' -f $target, $literal)
  }
  if ($Step.Recovery) {
    $stop = Get-SebSqlLiteral ($Step.StopAt.ToString('yyyy-MM-ddTHH:mm:ss'))
    return ('RESTORE LOG {0} FROM DISK = {1} WITH STOPAT = {2}, RECOVERY' -f $target, $literal, $stop)
  }
  return ('RESTORE LOG {0} FROM DISK = {1} WITH NORECOVERY' -f $target, $literal)
}

# Impure. Build the catalogue, plan the point-in-time restore, and run each step. The
# catalogue call is @()-wrapped so a single-fact catalogue is not collapsed to a scalar.
#
# The file list for the full step comes from Get-SebRestoreInspect (RESTORE
# FILELISTONLY) against that step's OWN backup file - the same call the -RestoreRun
# dispatch makes against -RestoreFrom - fetched ONCE and reused both for the
# pre-existence guard below and for the full step's MOVE clauses, so the guard checks
# the exact files the restore is about to write. An unreadable file or an empty file
# list must stop the restore here rather than issue a REPLACE with no MOVE clauses,
# which would restore data/log files back onto their ORIGINAL paths - silently
# overwriting whatever already lives there.
#
# Before any step runs: refuse to clobber a file already on disk unless -Replace says
# to - the same guard -RestoreRun runs, over the same Get-SebRestoreTargets paths. This
# is what makes a re-run with a corrected -StopAt fail loudly instead of silently
# overwriting the first attempt's files. -CloseConnections runs the same SINGLE_USER
# WITH ROLLBACK IMMEDIATE -RestoreRun runs, for the same reason: an open connection to
# the target name blocks the restore outright.
function Invoke-SebRestoreToPoint {
  param($Connection, [string]$Root, [string]$HostName, [string]$InstanceLabel,
        [string]$Database, [string]$RestoreAs, [datetime]$StopAt,
        [string]$DataDir, [string]$LogDir,
        [bool]$Replace = $false, [bool]$CloseConnections = $false)
  $cat = @(Get-SebPointCatalogue -Connection $Connection -Root $Root -HostName $HostName -InstanceLabel $InstanceLabel -Database $Database)
  $plan = Get-SebRestorePlan -Catalogue $cat -StopAt $StopAt
  if ($plan.Error) { throw ('cannot restore to that point in time: ' + $plan.Error) }

  $fullStep = $plan.Steps | Where-Object { $_.Kind -eq 'full' } | Select-Object -First 1
  $fullInfo = Get-SebRestoreInspect -Connection $Connection -Path $fullStep.File
  if (-not $fullInfo.Readable -or @($fullInfo.Files).Count -eq 0) {
    throw ('cannot read the file list for {0}: {1}' -f $fullStep.File, $fullInfo.ReadReason)
  }

  foreach ($target in @(Get-SebRestoreTargets -Files $fullInfo.Files -TargetName $RestoreAs -DataDir $DataDir -LogDir $LogDir)) {
    if ((Test-Path -LiteralPath $target) -and -not $Replace) {
      throw ('{0} already exists. Restoring would overwrite a file that may belong to another database. Choose a different name, or move that file first.' -f $target)
    }
  }

  if ($CloseConnections) {
    try { Invoke-SebSqlNonQuery -Connection $Connection -Sql ('ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE' -f (Get-SebQuotedName $RestoreAs)) }
    catch { }
  }

  $total = $plan.Steps.Count
  $i = 0
  foreach ($step in $plan.Steps) {
    $i++
    Write-SebStage -Database $RestoreAs -Stage ('restore ' + $step.Kind + ' ' + $i + '/' + $total)
    $moves = @()
    if ($step.Kind -eq 'full') { $moves = @(Get-SebRestoreMoveClauses -Files $fullInfo.Files -TargetName $RestoreAs -DataDir $DataDir -LogDir $LogDir) }
    $sql = Get-SebRestoreStepSql -Step $step -RestoreAs $RestoreAs -Replace $Replace -MoveClauses $moves
    Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
  }
  Write-SebStage -Database $RestoreAs -Stage 'restore complete'
}

function Invoke-SebSelfTest {
  param([string]$PinnedInstance, [string]$WorkRoot)

  $script:SebStPass = 0
  $script:SebStFail = 0
  $script:SebCompression = 'unknown'
  $testDb = 'SqlExpressBackup_SelfTest'
  $restoredDb = $testDb + '_Restored'

  if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $env:TEMP ('seb-selftest-' + [Guid]::NewGuid().ToString('N'))
  }
  $share = Join-Path $WorkRoot 'share'
  $staging = Join-Path $WorkRoot 'staging'
  $cfgDir = Join-Path $WorkRoot 'cfg'
  $savedConfigDir = $script:SebConfigDir
  $connection = $null

  Write-Host ''
  Write-Host '== SELF TEST =========================================================='
  Write-Host ('   working folder: ' + $WorkRoot)
  Write-Host ''

  try {
    foreach ($d in @($WorkRoot, $share, $staging, $cfgDir)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    $script:SebConfigDir = $cfgDir

    # 1. discovery
    $instances = @(Get-SebInstanceList)
    Write-SebCheck ($instances.Count -gt 0) ('found {0} SQL instance(s) on this host' -f $instances.Count)
    if ($instances.Count -eq 0) { throw 'no SQL Server instance on this host - nothing to test' }
    $chosen = $instances[0]
    if ($PinnedInstance) {
      $chosen = $instances | Where-Object { $_.InstanceName -eq $PinnedInstance -or $_.DataSource -eq $PinnedInstance } | Select-Object -First 1
      if (-not $chosen) { throw "instance '$PinnedInstance' was not found on this host" }
    }
    Write-Host ('         using {0}  ({1}, {2})' -f $chosen.DataSource, $chosen.Edition, $chosen.Version)

    # 2. connect as the caller
    $connection = New-SebSqlConnection -DataSource $chosen.DataSource -WindowsAuth
    Write-SebCheck $true ('connected to {0} with Windows authentication' -f $chosen.DataSource)

    $roles = Invoke-SebSqlTable -Connection $connection -Sql "SELECT IS_SRVROLEMEMBER('dbcreator') AS dbc, IS_SRVROLEMEMBER('sysadmin') AS sa"
    $mayCreate = (([int](Get-SebValue $roles[0].dbc) -eq 1) -or ([int](Get-SebValue $roles[0].sa) -eq 1))
    Write-SebCheck $mayCreate 'this login may create a database (needed to make a throwaway one)'
    if (-not $mayCreate) { throw 'self-test needs dbcreator or sysadmin to create its own scratch database' }

    # 3. staging permissions - the defect that breaks every untested install
    $sqlAccount = Get-SebAclIdentity (Get-SebServiceAccount -ServiceName $chosen.ServiceName)
    Write-SebCheck (-not [string]::IsNullOrWhiteSpace($sqlAccount)) ('SQL service account resolved: {0}' -f $sqlAccount)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Set-SebStagingAcl -Path $staging -SqlAccount $sqlAccount -AlsoGrant @($me)
    Set-SebStagingAcl -Path $share -SqlAccount $sqlAccount -AlsoGrant @($me)
    Test-SebStagingWritable -Connection $connection -Staging $staging -SqlAccount $sqlAccount
    Write-SebCheck $true 'SQL Server can write to the staging folder (proved with a real backup)'

    # 4. a scratch database with known contents
    Invoke-SebSqlNonQuery -Connection $connection -Sql "USE master; IF DB_ID('$testDb') IS NOT NULL BEGIN ALTER DATABASE [$testDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$testDb]; END"
    Invoke-SebSqlNonQuery -Connection $connection -Sql "CREATE DATABASE [$testDb]"
    Invoke-SebSqlNonQuery -Connection $connection -Sql "USE [$testDb]; CREATE TABLE dbo.Probe(id int identity primary key, payload char(400) not null); INSERT dbo.Probe(payload) SELECT TOP 5000 'x' FROM sys.all_columns a CROSS JOIN sys.all_columns b"
    Invoke-SebSqlNonQuery -Connection $connection -Sql 'USE master'
    $seeded = [int](Get-SebValue (Invoke-SebSqlTable -Connection $connection -Sql "SELECT COUNT(*) AS n FROM [$testDb].dbo.Probe")[0].n)
    Write-SebCheck ($seeded -eq 5000) ('scratch database [{0}] created with {1} rows' -f $testDb, $seeded)

    $cfg = [pscustomobject]@{
      DataSource        = $chosen.DataSource
      InstanceName      = $chosen.InstanceName
      SharePath         = $share
      StagingPath       = $staging
      IntervalHours     = 6
      HourlyKeep        = 3
      DailyKeepDays     = 7
      SqlUser           = ''
      UseWindowsAuth    = $true
      NoHashVerify      = $false
      SqlServiceAccount = $sqlAccount
      OnlyDatabase      = $testDb
    }
    $hourlyDir = Get-SebBackupPath -Root $share -HostName $env:COMPUTERNAME -InstanceLabel $chosen.InstanceName -Database $testDb -Kind 'hourly'
    $dailyDir = Get-SebBackupPath -Root $share -HostName $env:COMPUTERNAME -InstanceLabel $chosen.InstanceName -Database $testDb -Kind 'daily'

    # 5. one real pass
    Write-Host ''
    Write-Host '   -- pass 1: a real backup -------------------------------------------'
    $rc = Invoke-SebPass -Config $cfg
    Write-SebCheck ($rc -eq 0) ('pass returned {0} (0 = everything backed up and copied)' -f $rc)
    Write-SebCheck ((@(Get-SebFolderFacts -Directory $hourlyDir)).Count -eq 1) 'one backup landed in hourly'
    Write-SebCheck ((@(Get-SebFolderFacts -Directory $dailyDir)).Count -eq 1) "and today's daily archive was promoted"
    Write-SebCheck ((@(Get-ChildItem -LiteralPath $staging -Filter '*.bak' -File)).Count -eq 0) 'staging was drained after the copy was verified'

    # 6. retention, against real files
    Write-Host ''
    Write-Host '   -- pass 2: retention under pressure ---------------------------------'
    $seedFile = (Get-ChildItem -LiteralPath $hourlyDir -Filter '*.bak' -File | Select-Object -First 1).FullName
    foreach ($h in @(6, 12, 18, 24)) {
      Copy-Item -LiteralPath $seedFile -Destination (Join-Path $hourlyDir (Get-SebFileName -Database $testDb -Stamp (Get-Date).AddHours(-$h)))
    }
    foreach ($d in 1..8) {
      Copy-Item -LiteralPath $seedFile -Destination (Join-Path $dailyDir (Get-SebFileName -Database $testDb -Stamp (Get-Date).AddDays(-$d)))
    }
    $oldest = Get-SebFileName -Database $testDb -Stamp (Get-Date).AddHours(-24)
    Write-Host ('         seeded hourly={0} daily={1}' -f (@(Get-SebFolderFacts -Directory $hourlyDir)).Count, (@(Get-SebFolderFacts -Directory $dailyDir)).Count)
    Start-Sleep -Seconds 1
    [void](Invoke-SebPass -Config $cfg)
    $hourlyNow = @(Get-SebFolderFacts -Directory $hourlyDir)
    $dailyNow = @(Get-SebFolderFacts -Directory $dailyDir)
    Write-SebCheck ($hourlyNow.Count -eq 3) ('hourly pruned to HourlyKeep=3 (now {0})' -f $hourlyNow.Count)
    Write-SebCheck ($dailyNow.Count -eq 7) ('daily pruned to DailyKeepDays=7 (now {0})' -f $dailyNow.Count)
    Write-SebCheck (@($hourlyNow | ForEach-Object { $_.Name }) -notcontains $oldest) 'the oldest hourly backup is the one that went'

    # 7. a share it cannot reach
    Write-Host ''
    Write-Host '   -- pass 3: the share is unreachable ---------------------------------'
    $blocker = Join-Path $WorkRoot 'not-a-directory.txt'
    Set-Content -LiteralPath $blocker -Value 'stands in for an unreachable share' -Encoding ASCII
    $cfgBad = $cfg.PSObject.Copy()
    $cfgBad.SharePath = Join-Path $blocker 'share'
    Start-Sleep -Seconds 1
    $rcBad = Invoke-SebPass -Config $cfgBad
    $stBad = Read-SebState
    Write-SebCheck ($rcBad -eq 1) ('pass returned {0} (1 = backed up, but not yet on the share)' -f $rcBad)
    Write-SebCheck (@($stBad.Pending).Count -gt 0) ('{0} copy(s) recorded as pending' -f @($stBad.Pending).Count)
    Write-SebCheck ((@(Get-ChildItem -LiteralPath $staging -Filter '*.bak' -File)).Count -gt 0) 'the verified backup is held in staging, not thrown away'

    # 8. the only question that finally matters
    Write-Host ''
    Write-Host '   -- does the file on the share actually restore? ----------------------'
    $newest = Get-ChildItem -LiteralPath $hourlyDir -Filter '*.bak' -File | Sort-Object Name -Descending | Select-Object -First 1
    $header = Invoke-SebSqlTable -Connection $connection -Sql ('RESTORE HEADERONLY FROM DISK = ' + (Get-SebSqlLiteral $newest.FullName))
    Write-SebCheck ([int](Get-SebValue $header[0].BackupType) -eq 1) 'the file on the share is a FULL backup'
    Write-SebCheck ([bool](Get-SebValue $header[0].HasBackupChecksums)) 'it carries backup checksums'
    $fileList = Invoke-SebSqlTable -Connection $connection -Sql ('RESTORE FILELISTONLY FROM DISK = ' + (Get-SebSqlLiteral $newest.FullName))
    $moves = @()
    foreach ($f in $fileList) {
      $ext = '.mdf'
      if ([string](Get-SebValue $f.Type) -eq 'L') { $ext = '.ldf' }
      $logical = [string](Get-SebValue $f.LogicalName)
      $moves += ('MOVE ' + (Get-SebSqlLiteral $logical) + ' TO ' + (Get-SebSqlLiteral (Join-Path $staging ($restoredDb + '_' + (Get-SebSafeName $logical) + $ext))))
    }
    Invoke-SebSqlNonQuery -Connection $connection -Sql ("RESTORE DATABASE [$restoredDb] FROM DISK = " + (Get-SebSqlLiteral $newest.FullName) + ' WITH ' + ($moves -join ', ') + ', RECOVERY')
    $back = [int](Get-SebValue (Invoke-SebSqlTable -Connection $connection -Sql "SELECT COUNT(*) AS n FROM [$restoredDb].dbo.Probe")[0].n)
    Write-SebCheck ($back -eq 5000) ('restored from the share copy and read back {0} of 5000 rows' -f $back)
  }
  finally {
    if ($null -ne $connection) {
      foreach ($d in @($restoredDb, $testDb)) {
        try { Invoke-SebSqlNonQuery -Connection $connection -Sql "USE master; IF DB_ID('$d') IS NOT NULL BEGIN ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d]; END" }
        catch { Write-Host ('  note: could not drop ' + $d + ' - ' + $_.Exception.Message) }
      }
      $connection.Dispose()
    }
    try { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $script:SebConfigDir = $savedConfigDir
  }

  Write-Host ''
  Write-Host '== RESULT ============================================================='
  Write-Host ('   {0} checks passed, {1} failed' -f $script:SebStPass, $script:SebStFail)
  Write-Host ('   scratch database dropped, working folder removed')
  if ($script:SebStFail -gt 0) {
    Write-Host '   SELF TEST FAILED' -ForegroundColor Red
    return 1
  }
  Write-Host '   SELF TEST PASSED - this host can back up, retain, and restore.' -ForegroundColor Green
  return 0
}

function Show-SebStatus {
  Write-Host ''
  Write-Host '== Config ============================================================='
  $config = $null
  try { $config = Read-SebConfig } catch { Write-Host ('   ' + $_.Exception.Message) }
  if ($null -ne $config) {
    $factLines = Format-SebConfigFacts -Config $config
    foreach ($line in $factLines) { Write-Host $line }
  }

  Write-Host ''
  Write-Host '== Schedule ==========================================================='
  $schedule = Get-SebScheduleState
  Write-Host ('   scheduled task : {0}' -f $schedule.TaskState)
  Write-Host ('   service        : {0}' -f $schedule.ServiceState)

  Write-Host ''
  Write-Host '== Last run ==========================================================='
  $state = Read-SebState
  Write-Host ('   at      : {0}' -f $state.LastRunUtc)
  Write-Host ('   result  : {0}' -f $state.LastResult)
  Write-Host ('   pending : {0} copy(s) waiting for the share' -f @($state.Pending).Count)

  if ($null -eq $config) { return }

  # Same warning the data pass raises mid-run, surfaced here too so a WARN nobody was
  # watching the console for is still one -Status call away. Full mode only, mirroring
  # Invoke-SebPass: Simple mode never runs a log-backup task, so nothing here would be
  # anything but noise about a task that was never supposed to be running. A SQL probe
  # failure (server unreachable, stale credential) must not take the rest of -Status
  # down with it, so it is caught and reported as a line rather than thrown.
  $recoveryMode = 'Simple'
  if ($config.PSObject.Properties['RecoveryMode']) { $recoveryMode = [string]$config.RecoveryMode }
  if ($recoveryMode -eq 'Full') {
    Write-Host ''
    Write-Host '== Log growth =========================================================='
    $statusConnection = $null
    try {
      if ($config.UseWindowsAuth) {
        $statusConnection = New-SebSqlConnection -DataSource $config.DataSource -WindowsAuth
      }
      else {
        $master = Get-SebMasterKey
        try {
          $blob = Get-Content -LiteralPath (Get-SebCredPath) -Raw
          $statusPassword = Unprotect-SebSecureString -Blob $blob.Trim() -Master $master
        }
        finally { [System.Array]::Clear($master, 0, $master.Length) }
        $statusConnection = New-SebSqlConnection -DataSource $config.DataSource -User $config.SqlUser -Password $statusPassword
      }

      # The same two SQL inputs the data pass reads, read once here too: recovery_model_desc
      # (which databases are FULL) rides along with log_reuse_wait_desc on one sys.databases
      # round trip, and DBCC SQLPERF(LOGSPACE) is the second and last query.
      $dbRows = Invoke-SebSqlTable -Connection $statusConnection -Sql @'
SELECT name, state, source_database_id, is_in_standby, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
'@
      $eligible = Select-SebDatabase -Rows $dbRows
      $waitByDb = @{}
      $modelByDb = @{}
      foreach ($row in $dbRows) {
        $dbName = [string](Get-SebValue $row.name)
        if (-not $dbName) { continue }
        $modelByDb[$dbName] = [string](Get-SebValue $row.recovery_model_desc)
        $waitByDb[$dbName] = [string](Get-SebValue $row.log_reuse_wait_desc)
      }
      $logSpaceRows = @(Invoke-SebSqlTable -Connection $statusConnection -Sql 'DBCC SQLPERF(LOGSPACE)')
      $fullDatabases = @($eligible | Where-Object { $modelByDb.ContainsKey($_) -and $modelByDb[$_] -eq 'FULL' })

      if ($fullDatabases.Count -eq 0) {
        Write-Host '   no FULL-recovery databases found'
      }
      else {
        foreach ($db in $fullDatabases) {
          $wait = ''
          if ($waitByDb.ContainsKey($db)) { $wait = $waitByDb[$db] }
          $usedPct = Get-SebLogSpaceUsedPct -Rows $logSpaceRows -Database $db
          if (Get-SebLogGrowthWarning -Wait $wait -UsedPct $usedPct) {
            Write-Host ('   [WARN] {0,-30} {1}% full, waiting on a log backup - is the -BackupLog task running?' -f $db, $usedPct)
          }
          else {
            Write-Host ('   {0,-30} log healthy ({1}% used)' -f $db, $usedPct)
          }

          # Same share layout the data pass writes to and "On the share" below reads back -
          # Get-SebBackupPath applies the same Get-SebSafeName folding to host/instance/db
          # that the pass used when it wrote these files, so this resolves to the same
          # folder even when a name needed sanitizing. Read-only: three folder listings,
          # reduced by the pure Get-SebChainSummary. Inside the same try this whole section
          # is already wrapped in, so a share that has gone unreachable mid-loop reports on
          # the single 'could not probe' line below rather than aborting the rest of -Status.
          $fullFacts = @(Get-SebFolderFacts -Directory (Get-SebBackupPath -Root $config.SharePath -HostName $env:COMPUTERNAME -InstanceLabel $config.InstanceName -Database $db -Kind 'hourly'))
          $diffFacts = @(Get-SebFolderFacts -Directory (Get-SebBackupPath -Root $config.SharePath -HostName $env:COMPUTERNAME -InstanceLabel $config.InstanceName -Database $db -Kind 'diff'))
          $logFacts  = @(Get-SebFolderFacts -Directory (Get-SebBackupPath -Root $config.SharePath -HostName $env:COMPUTERNAME -InstanceLabel $config.InstanceName -Database $db -Kind 'log'))
          $chain = Get-SebChainSummary -Fulls $fullFacts -Diffs $diffFacts -Logs $logFacts -Now (Get-Date)

          $lastFullText = 'none'
          if ($null -ne $chain.LastFull) { $lastFullText = $chain.LastFull.ToString('yyyy-MM-dd HH:mm') }
          $lastLogText = 'none'
          if ($null -ne $chain.LastLog) { $lastLogText = $chain.LastLog.ToString('yyyy-MM-dd HH:mm') }
          $rpoText = 'n/a'
          if ($chain.RpoMinutes -ge 0) { $rpoText = ('{0} min' -f $chain.RpoMinutes) }
          Write-Host ('     {0}: model=FULL  last full={1}  last log={2}  RPO={3}  health={4}' -f $db, $lastFullText, $lastLogText, $rpoText, $chain.Health)
        }
      }
    }
    catch {
      Write-Host ('   could not probe log growth: {0}' -f $_.Exception.Message)
    }
    finally {
      if ($null -ne $statusConnection) { $statusConnection.Close() }
    }
  }

  Write-Host ''
  Write-Host '== On the share ======================================================='
  $root = Join-Path (Join-Path $config.SharePath (Get-SebSafeName $env:COMPUTERNAME)) (Get-SebSafeName $config.InstanceName)
  if (-not (Test-Path -LiteralPath $root)) {
    Write-Host ('   {0} is not reachable or has nothing in it yet' -f $root)
    return
  }
  foreach ($dbDir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    $hourly = @(Get-SebFolderFacts -Directory (Join-Path $dbDir.FullName 'hourly'))
    $daily = @(Get-SebFolderFacts -Directory (Join-Path $dbDir.FullName 'daily'))
    $newest = 'none'
    if ($hourly.Count -gt 0) {
      $newest = ($hourly | Sort-Object Timestamp -Descending | Select-Object -First 1).Timestamp.ToString('yyyy-MM-dd HH:mm')
    }
    Write-Host ('   {0,-30} hourly={1} daily={2} newest={3}' -f $dbDir.Name, $hourly.Count, $daily.Count, $newest)
  }
}

# =====================================================================

if ($DotSourceOnly) { return }

$exitCode = 0
$mutex = $null
try {
  if ($Setup) {
    Assert-SebElevated -Mode 'Setup'
    Invoke-SebSetup -PinnedInstance $Instance -Share $SharePath -Staging $StagingPath `
      -Hours $IntervalHours -Hourly $HourlyKeep -DailyDays $DailyKeepDays `
      -WindowsAuth:$UseWindowsAuth -SkipHash:$NoHashVerify `
      -RecoveryMode $RecoveryMode -LogIntervalMinutes $LogIntervalMinutes -FullEveryHours $FullEveryHours `
      -CompressBackups:$CompressBackups
  }
  elseif ($Install) {
    Assert-SebElevated -Mode 'Install'
    $config = Read-SebConfig
    $schedule = Get-SebScheduleState
    if ($schedule.TaskPresent -or $schedule.ServicePresent) {
      throw ('already scheduled (task={0}, service={1}). Run -Uninstall first; a host must not carry both.' -f $schedule.TaskState, $schedule.ServiceState)
    }
    $scriptPath = Get-SebScriptPath
    if ($As -eq 'Task') {
      Install-SebTask -ScriptPath $scriptPath -ConfigDirectory $script:SebConfigDir -Hours ([int]$config.IntervalHours)
    }
    else {
      Install-SebService -ScriptPath $scriptPath -ConfigDirectory $script:SebConfigDir -Hours ([int]$config.IntervalHours) -Nssm (Resolve-SebNssm -Explicit $NssmPath)
    }
  }
  elseif ($Reschedule) {
    # Change the interval and/or retention already configured, then re-register the
    # schedule so a new interval takes effect. Only the values actually passed are
    # changed; everything else in config is left as it is. Elevated: it rewrites the
    # locked config and re-registers a SYSTEM task.
    Assert-SebElevated -Mode 'Reschedule'
    $config = Read-SebConfig
    if ($PSBoundParameters.ContainsKey('IntervalHours')) { $config.IntervalHours = [int]$IntervalHours }
    if ($PSBoundParameters.ContainsKey('HourlyKeep'))    { $config.HourlyKeep    = [int]$HourlyKeep }
    if ($PSBoundParameters.ContainsKey('DailyKeepDays')) { $config.DailyKeepDays = [int]$DailyKeepDays }
    # Add-Member -Force, not plain assignment: every config.json written before this
    # feature existed has none of these three properties, and PowerShell throws
    # "property ... cannot be found" assigning a property that is not already there -
    # unlike IntervalHours/HourlyKeep/DailyKeepDays above, which Setup has always
    # written. Force makes this the same call whether the property is new or already
    # present, so a second -Reschedule behaves exactly like the first.
    if ($PSBoundParameters.ContainsKey('RecoveryMode')) { Add-Member -InputObject $config -MemberType NoteProperty -Name 'RecoveryMode' -Value $RecoveryMode -Force }
    if ($PSBoundParameters.ContainsKey('LogIntervalMinutes')) { Add-Member -InputObject $config -MemberType NoteProperty -Name 'LogIntervalMinutes' -Value ([int]$LogIntervalMinutes) -Force }
    if ($PSBoundParameters.ContainsKey('FullEveryHours')) { Add-Member -InputObject $config -MemberType NoteProperty -Name 'FullEveryHours' -Value ([int]$FullEveryHours) -Force }
    # Add-Member -Force, same reason as RecoveryMode/LogIntervalMinutes/FullEveryHours above:
    # a pre-D3 (or pre-this-feature) config.json has no CompressBackups property, and plain
    # assignment throws on a ConvertFrom-Json object for a property that is not already there.
    # $CompressBackups is a [switch]; persist its .IsPresent (a real bool), not the switch
    # object itself - ConvertTo-Json would not serialize a SwitchParameter as a plain true/false.
    if ($PSBoundParameters.ContainsKey('CompressBackups')) { Add-Member -InputObject $config -MemberType NoteProperty -Name 'CompressBackups' -Value $CompressBackups.IsPresent -Force }
    Write-SebConfig -Config $config
    $schedule = Get-SebScheduleState
    $scriptPath = Get-SebScriptPath
    if ($schedule.ServicePresent) {
      Install-SebService -ScriptPath $scriptPath -ConfigDirectory $script:SebConfigDir -Hours ([int]$config.IntervalHours) -Nssm (Resolve-SebNssm -Explicit $NssmPath)
    }
    else {
      if ($schedule.TaskPresent) {
        try { Unregister-ScheduledTask -TaskName $script:SebTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
      }
      Install-SebTask -ScriptPath $scriptPath -ConfigDirectory $script:SebConfigDir -Hours ([int]$config.IntervalHours)
    }
    # Reconcile the log task after either install path: switching away from Full removes it.
    # Install-SebService/Install-SebTask (above) read the config just written and stand the
    # log task up when RecoveryMode is now Full, but each only ever ADDS that task - this
    # depends only on $config.RecoveryMode, not on which branch just ran, so it runs once
    # here for both. Same existence-guarded Unregister-ScheduledTask idiom Uninstall-SebSchedule
    # uses; a Simple config that never had the task is the ordinary case, not an error.
    if ([string]$config.RecoveryMode -ne 'Full') {
      $logTaskName = Get-SebLogTaskName -Base $script:SebTaskName
      if (Get-ScheduledTask -TaskName $logTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $logTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-SebLog ('scheduled task "{0}" removed' -f $logTaskName)
      }
    }
    # RecoveryMode/LogIntervalMinutes/FullEveryHours are read back off $config rather than
    # off the -Reschedule parameters themselves: a call that did not pass one of them must
    # echo the value already on disk, not that parameter's own default. Same PSObject.Properties
    # guard (and the same defaults) Invoke-SebPass and Install-SebTask use for these same keys,
    # since a pre-D3 config on disk may still have none of them.
    $echoRecoveryMode = 'Simple'
    if ($config.PSObject.Properties['RecoveryMode']) { $echoRecoveryMode = [string]$config.RecoveryMode }
    $echoLogIntervalMinutes = 15
    if ($config.PSObject.Properties['LogIntervalMinutes']) { $echoLogIntervalMinutes = [int]$config.LogIntervalMinutes }
    $echoFullEveryHours = 24
    if ($config.PSObject.Properties['FullEveryHours']) { $echoFullEveryHours = [int]$config.FullEveryHours }
    $echoCompressBackups = $false
    if ($config.PSObject.Properties['CompressBackups']) { $echoCompressBackups = [bool]$config.CompressBackups }
    Write-Host (ConvertTo-Json @{
        Ok                 = $true
        IntervalHours      = [int]$config.IntervalHours
        HourlyKeep         = [int]$config.HourlyKeep
        DailyKeepDays      = [int]$config.DailyKeepDays
        RecoveryMode       = $echoRecoveryMode
        LogIntervalMinutes = $echoLogIntervalMinutes
        FullEveryHours     = $echoFullEveryHours
        CompressBackups    = $echoCompressBackups
      } -Compress)
  }
  elseif ($RestoreList) {
    $config = Read-SebRestoreContext
    $root = [string]$config.SharePath
    $reason = ''
    $sets = @()
    try { $sets = @(Get-SebRestoreCatalogue -Root $root) }
    catch { $reason = [string]$_.Exception.Message }
    if ($sets.Count -eq 0 -and $reason -eq '') {
      $resolved = Resolve-SebLocalShare -Root $root
      $readable = $false
      try { $readable = Test-Path -LiteralPath $resolved } catch { }
      if (-not $readable) { $reason = ('this account cannot read {0}' -f $root) }
    }
    Write-Host (ConvertTo-Json @{ Root = $root; Sets = @($sets); Reason = $reason } -Depth 4 -Compress)
  }
  elseif (-not [string]::IsNullOrWhiteSpace($RestoreInspect)) {
    $config = Read-SebRestoreContext
    $connection = New-SebSqlConnection -DataSource ([string]$config.DataSource) -WindowsAuth
    try { Write-Host (ConvertTo-Json (Get-SebRestoreInspect -Connection $connection -Path $RestoreInspect) -Depth 4 -Compress) }
    finally { $connection.Close() }
  }
  elseif (-not [string]::IsNullOrWhiteSpace($RestoreVerify)) {
    $config = Read-SebRestoreContext
    $connection = New-SebSqlConnection -DataSource ([string]$config.DataSource) -WindowsAuth
    try {
      Write-SebStage -Database '' -Stage 'verifying backup media'
      Invoke-SebSqlNonQuery -Connection $connection -Sql ('RESTORE VERIFYONLY FROM DISK = {0} WITH CHECKSUM' -f (Get-SebSqlLiteral $RestoreVerify))
      Write-Host (ConvertTo-Json @{ Ok = $true; Error = '' } -Compress)
    }
    catch { Write-Host (ConvertTo-Json @{ Ok = $false; Error = [string]$_.Exception.Message } -Compress); $exitCode = 1 }
    finally { $connection.Close() }
  }
  elseif ($RestoreRun) {
    if ([string]::IsNullOrWhiteSpace($RestoreFrom)) { throw '-RestoreRun needs -RestoreFrom <path to .bak>' }
    if ([string]::IsNullOrWhiteSpace($RestoreAs)) { throw '-RestoreRun needs -RestoreAs <database name>' }
    $config = Read-SebRestoreContext
    $connection = New-SebSqlConnection -DataSource ([string]$config.DataSource) -WindowsAuth
    try {
      $info = Get-SebRestoreInspect -Connection $connection -Path $RestoreFrom
      if (-not $info.Readable) {
        throw ('SQL Server cannot read {0}. This is a PERMISSION fault, not a corrupt backup: the file is read by the SQL service account, not by you. Grant that account read on the folder. The symptom is identical to a damaged file, which is why it is checked before anything is committed.' -f $RestoreFrom)
      }
      if (@($info.Files).Count -eq 0) { throw ('no files listed in {0} - it is not a usable backup set' -f $RestoreFrom) }

      $dataDir = $RestoreDataDir
      if ([string]::IsNullOrWhiteSpace($dataDir)) {
        $rows = Invoke-SebSqlTable -Connection $connection -Sql "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS p"
        if (@($rows).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string](Get-SebValue $rows[0].p))) {
          throw 'could not determine the instance default data path; pass -RestoreDataDir <folder> explicitly'
        }
        $dataDir = [string](Get-SebValue $rows[0].p)
      }
      $logDir = $RestoreLogDir
      if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = $dataDir }

      # Refuse to clobber a file already on disk. RESTORE overwrites without asking,
      # and the file it overwrites may belong to a database nobody mentioned here. The
      # paths come straight from Get-SebRestoreTargets - the same source the MOVE clauses
      # use - so the check tests the exact files the restore will write.
      foreach ($target in @(Get-SebRestoreTargets -Files $info.Files -TargetName $RestoreAs -DataDir $dataDir -LogDir $logDir)) {
        if ((Test-Path -LiteralPath $target) -and -not $RestoreReplace) {
          throw ('{0} already exists. Restoring would overwrite a file that may belong to another database. Choose a different name, or move that file first.' -f $target)
        }
      }

      if ($RestoreCloseConnections) {
        try { Invoke-SebSqlNonQuery -Connection $connection -Sql ('ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE' -f (Get-SebQuotedName $RestoreAs)) }
        catch { }
      }

      Write-SebJob -Index 1 -Total 1 -Database $RestoreAs
      Write-SebStage -Database $RestoreAs -Stage 'backup'
      $sql = Get-SebRestoreSql -Path $RestoreFrom -TargetName $RestoreAs -Files $info.Files -DataDir $dataDir -LogDir $logDir -RecoveryState $RestoreRecoveryState -Replace:([bool]$RestoreReplace) -RestrictedUser:([bool]$RestoreRestrictedUser)
      Write-SebLog ('restoring {0} from {1}' -f $RestoreAs, $RestoreFrom)

      # Percent comes from SQL itself, exactly as it does for BACKUP.
      $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
        param($eventSender, $eventArgs)
        $pct = Get-SebPercentFromMessage $eventArgs.Message
        if ($pct -ge 0) { Write-SebProgress -Database $script:SebProgressDb -Percent $pct -Stage 'backup' }
      }
      $script:SebProgressDb = $RestoreAs
      $connection.add_InfoMessage($handler)
      try { Invoke-SebSqlNonQuery -Connection $connection -Sql $sql }
      finally { $connection.remove_InfoMessage($handler) }

      Write-SebStage -Database $RestoreAs -Stage 'verify'
      $ok = $true
      $checkMessage = ''
      if ($RestoreRecoveryState.ToUpperInvariant() -eq 'RECOVERY') {
        try { Invoke-SebSqlNonQuery -Connection $connection -Sql ('DBCC CHECKDB({0}) WITH NO_INFOMSGS' -f (Get-SebQuotedName $RestoreAs)) }
        catch { $ok = $false; $checkMessage = [string]$_.Exception.Message }
      }
      else { $checkMessage = 'left in ' + $RestoreRecoveryState.ToUpperInvariant() + ' - CHECKDB cannot run until the database is recovered' }

      Write-SebStage -Database $RestoreAs -Stage 'finished'
      Write-SebLog ('restore finished: {0}' -f $RestoreAs)
      Write-Host (ConvertTo-Json @{ Ok = $ok; Database = $RestoreAs; Check = $checkMessage } -Compress)
      if (-not $ok) { $exitCode = 1 }
    }
    finally { $connection.Close() }
  }
  elseif ($RestoreToPoint) {
    if ([string]::IsNullOrWhiteSpace($Database)) { throw '-RestoreToPoint needs -Database <name>' }
    if ([string]::IsNullOrWhiteSpace($RestoreAs)) { throw '-RestoreToPoint needs -RestoreAs <database name>' }
    if ($StopAt -eq [datetime]::MinValue) { throw '-RestoreToPoint requires -StopAt <datetime>' }
    $config = Read-SebRestoreContext
    $connection = New-SebSqlConnection -DataSource ([string]$config.DataSource) -WindowsAuth
    try {
      # Read-SebRestoreContext is unelevated and exposes only DataSource/SharePath - it
      # does not carry the instance's folder label (the InstanceName the backup cycle
      # used to build the share path via Get-SebBackupPath). Get-SebInstanceList maps
      # DataSource back to that InstanceName; it is the same registry-backed lookup
      # -Setup and -SelfTest already use to choose an instance, and it needs no
      # elevation, so this stays consistent with every other -Restore* mode.
      $instances = @(Get-SebInstanceList)
      $chosen = $instances | Where-Object { $_.DataSource -eq $config.DataSource } | Select-Object -First 1
      if (-not $chosen) { throw ('could not resolve the SQL instance for {0} - is it registered on this host?' -f $config.DataSource) }

      $dataDir = $RestoreDataDir
      if ([string]::IsNullOrWhiteSpace($dataDir)) {
        $rows = Invoke-SebSqlTable -Connection $connection -Sql "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS p"
        if (@($rows).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string](Get-SebValue $rows[0].p))) {
          throw 'could not determine the instance default data path; pass -RestoreDataDir <folder> explicitly'
        }
        $dataDir = [string](Get-SebValue $rows[0].p)
      }
      $logDir = $RestoreLogDir
      if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = $dataDir }

      Write-SebJob -Index 1 -Total 1 -Database $RestoreAs
      Invoke-SebRestoreToPoint -Connection $connection -Root $config.SharePath -HostName $env:COMPUTERNAME -InstanceLabel $chosen.InstanceName `
        -Database $Database -RestoreAs $RestoreAs -StopAt $StopAt -DataDir $dataDir -LogDir $logDir `
        -Replace:([bool]$RestoreReplace) -CloseConnections:([bool]$RestoreCloseConnections)

      Write-SebLog ('point-in-time restore finished: {0} -> {1} @ {2}' -f $Database, $RestoreAs, $StopAt)
      Write-Host (ConvertTo-Json @{ Ok = $true; Database = $RestoreAs; Check = 'not verified by the engine - run DBCC CHECKDB separately' } -Compress)
    }
    finally { $connection.Close() }
  }
  elseif ($Uninstall) {
    Assert-SebElevated -Mode 'Uninstall'
    Uninstall-SebSchedule -Nssm $NssmPath
    if ($Purge) {
      foreach ($path in @((Get-SebCredPath), (Get-SebKeyPath), (Get-SebEntropyPath), (Get-SebConfigPath), (Get-SebStatePath))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
      }
      Write-SebLog 'config and key material purged - backups on the share were not touched'
    }
  }
  elseif ($FullInstall) {
    Assert-SebElevated -Mode 'FullInstall'
    Write-Host ''
    Write-Host '== 1/5  local share ==================================================='
    Write-Host '   NOTE: a share on THIS host is not an offsite copy. If this disk dies'
    Write-Host '   the backups die with it. Re-run -Setup against a real file server'
    Write-Host '   when you have one; everything else stays as it is.'
    $unc = New-SebLocalShare -FolderPath $ShareFolder -ShareName $ShareName -SqlAccount $sqlAccount
    Write-Host ('   share ready: ' + $unc)

    Write-Host ''
    Write-Host '== 2/5  setup ========================================================='
    Invoke-SebSetup -PinnedInstance $Instance -Share $unc -Staging $StagingPath `
      -Hours $IntervalHours -Hourly $HourlyKeep -DailyDays $DailyKeepDays `
      -WindowsAuth -SkipHash:$NoHashVerify `
      -RecoveryMode $RecoveryMode -LogIntervalMinutes $LogIntervalMinutes -FullEveryHours $FullEveryHours `
      -CompressBackups:$CompressBackups

    Write-Host ''
    Write-Host '== 3/5  schedule ======================================================'
    $cfg = Read-SebConfig
    $already = Get-SebScheduleState
    if ($already.TaskPresent -or $already.ServicePresent) {
      Write-Host ('   already scheduled (task={0}, service={1}) - leaving it alone' -f $already.TaskState, $already.ServiceState)
    }
    else {
      Install-SebTask -ScriptPath (Get-SebScriptPath) -ConfigDirectory $script:SebConfigDir -Hours ([int]$cfg.IntervalHours)
    }

    Write-Host ''
    Write-Host '== 4/5  first backup, run BY THE SCHEDULER AS SYSTEM =================='
    Write-Host '   Not an in-process run on purpose: that would prove only that this'
    Write-Host '   administrator can do it. SYSTEM is the account that will run it every'
    Write-Host '   six hours, and it reaches the share as the machine account.'
    Start-ScheduledTask -TaskName $script:SebTaskName
    # NOT $run. This script has a [switch]$Run parameter, so $run is already a typed
    # variable in this scope and assigning an object to it fails with a MetadataError
    # that names SwitchParameter and points at the assignment, not at anything that
    # looks like the cause. It made -FullInstall report failure after it had actually
    # succeeded, and it is the same collision that broke the test suite - where it
    # arrives via the dot-source, which brings this param block into the caller's scope.
    $taskRun = Wait-SebScheduledRun -TaskName $script:SebTaskName -TimeoutSec 900
    $verdict = Get-SebRunVerdict -Completed $taskRun.Completed -Result $taskRun.Result
    Write-Host ('   after {0}s: {1}' -f $taskRun.WaitedSec, $verdict)
    if ($taskRun.Completed -and $null -ne $taskRun.Result) { $exitCode = [int]$taskRun.Result }

    Write-Host ''
    Write-Host '== 5/5  status ========================================================'
    Show-SebStatus
  }
  elseif ($SelfTest) {
    $exitCode = Invoke-SebSelfTest -PinnedInstance $Instance -WorkRoot $StagingPath
  }
  elseif ($Status) {
    Assert-SebElevated -Mode 'Status'
    Show-SebStatus
  }
  elseif ($BackupLog) {
    # Mirrors -Run/Invoke-SebPass's own setup/teardown: same elevation gate (this reads
    # the same locked config, and the SQL-auth branch reads the sealed credential too),
    # same shared mutex (the anchor path writes a .bak into the same hourly/ folder
    # -Run uses, so the two passes must not run at once - one stands down instead), same
    # Windows-vs-SQL-auth connection pattern, same dispose-in-finally shape.
    Assert-SebElevated -Mode 'BackupLog'
    $config = Read-SebConfig
    $mutex = Get-SebMutex
    if ($null -eq $mutex) {
      Write-SebLog 'another backup pass is already running - this one is standing down' 'WARN'
      exit 0
    }
    $only = ''
    if ($config.PSObject.Properties['OnlyDatabase']) { $only = [string]$config.OnlyDatabase }
    $noHash = [bool]$config.NoHashVerify

    $password = $null
    $connection = $null
    try {
      if ($config.UseWindowsAuth) {
        $connection = New-SebSqlConnection -DataSource $config.DataSource -WindowsAuth
      }
      else {
        $master = Get-SebMasterKey
        try {
          $blob = Get-Content -LiteralPath (Get-SebCredPath) -Raw
          $password = Unprotect-SebSecureString -Blob $blob.Trim() -Master $master
        }
        finally { [System.Array]::Clear($master, 0, $master.Length) }
        $connection = New-SebSqlConnection -DataSource $config.DataSource -User $config.SqlUser -Password $password
      }
      Write-SebLog ('connected to {0}' -f $config.DataSource)

      $result = Invoke-SebBackupLogPass -Connection $connection -Root $config.SharePath -HostName $env:COMPUTERNAME `
        -InstanceLabel $config.InstanceName -StagingPath $config.StagingPath -OnlyDatabase $only -NoHash:$noHash
      Write-SebLog ('log pass finished: {0} succeeded, {1} failed, {2} copy(s) pending' -f $result.Succeeded, $result.Failed, $result.Pending)

      # Mirror -Run/Invoke-SebPass's ok/partial/failed -> exit-code mapping (Get-SebLogPassExitCode):
      # nothing succeeded although something was attempted is a total failure (2); a database that
      # failed OR a copy still pending alongside a success is partial (1); zero of both - including
      # "nothing was FULL recovery this cycle" - is ok (0). A pending copy is NOT success: the log
      # was taken but has not reached the share, so a week-long outage must not keep reporting 0.
      $ok = ($result.Failed -eq 0 -and $result.Pending -eq 0)
      Write-Host (ConvertTo-Json @{ Ok = $ok; Mode = 'BackupLog'; Succeeded = $result.Succeeded; Failed = $result.Failed; Pending = $result.Pending } -Compress)
      $exitCode = Get-SebLogPassExitCode -Succeeded $result.Succeeded -Failed $result.Failed -Pending $result.Pending
    }
    finally {
      if ($null -ne $connection) { $connection.Dispose() }
      if ($null -ne $password) { $password.Dispose() }
    }
  }
  else {
    Assert-SebElevated -Mode 'Run'
    $config = Read-SebConfig
    $mutex = Get-SebMutex
    if ($null -eq $mutex) {
      Write-SebLog 'another backup pass is already running - this one is standing down' 'WARN'
      exit 0
    }
    if ($Loop) {
      Write-SebLog ('service loop starting - one pass every {0} hour(s)' -f $config.IntervalHours)
      while ($true) {
        try { [void](Invoke-SebPass -Config $config) }
        catch { Write-SebLog ('pass threw: {0}' -f $_.Exception.Message) 'ERROR' }
        Start-Sleep -Seconds ([int]$config.IntervalHours * 3600)
      }
    }
    else {
      $exitCode = Invoke-SebPass -Config $config
    }
  }
}
catch {
  # Name the mode and any path the error carried. A bare message leaves the operator
  # guessing which of staging, the share, the config folder or the key file was
  # refused - they are four different problems with four different fixes.
  $failedMode = 'Run'
  foreach ($m in @('Setup', 'FullInstall', 'Install', 'Uninstall', 'Status', 'SelfTest', 'BackupLog')) {
    $v = Get-Variable -Name $m -ValueOnly -ErrorAction SilentlyContinue
    if ($v) { $failedMode = $m; break }
  }
  $detail = "$($_.Exception.Message)"
  $target = "$($_.CategoryInfo.TargetName)"
  if (-not [string]::IsNullOrWhiteSpace($target) -and ($detail -notlike ("*" + $target + "*"))) {
    $detail += "  [while touching: $target]"
  }
  Write-SebLog ("-$failedMode failed: $detail") 'ERROR'
  $exitCode = 2
}
finally {
  if ($null -ne $mutex) {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
  }
}

exit $exitCode
