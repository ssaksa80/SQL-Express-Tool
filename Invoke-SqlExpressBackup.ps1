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
  operator can copy this one file to a server and run it. Same reasoning as
  the standalone probe, and like the probe it is NOT staged into the bundle.

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
  [switch]$Status,
  [switch]$SelfTest,
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
  'IntervalHours', 'HourlyKeep', 'DailyKeepDays', 'SqlUser', 'UseWindowsAuth',
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
    [ValidateSet('hourly', 'daily')]
    [string]$Kind
  )
  $path = Join-Path $Root (Get-SebSafeName $HostName)
  $path = Join-Path $path (Get-SebSafeName $InstanceLabel)
  $path = Join-Path $path (Get-SebSafeName $Database)
  return (Join-Path $path $Kind)
}

function Get-SebFileName {
  param([string]$Database, [datetime]$Stamp)
  return ('{0}_{1}.bak' -f (Get-SebSafeName $Database), $Stamp.ToString('yyyyMMdd-HHmmss'))
}

# Trust the name over the mtime. Copying a file to a share can move LastWriteTime,
# and retention that sorts on a timestamp the copy rewrote will delete the wrong
# file. The stamp is baked into the name at BACKUP time and never changes after.
function Get-SebStampFromName {
  param([string]$Name, [datetime]$Fallback)
  $match = [regex]::Match($Name, '_(\d{8})-(\d{6})\.bak$')
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
function Get-SebServiceAccount {
  param([string]$ServiceName, [scriptblock]$ServiceQuery)
  $query = $ServiceQuery
  if (-not $query) {
    $query = {
      param([string]$Name)
      Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + ($Name -replace "'", "''") + "'") -ErrorAction SilentlyContinue
    }
  }
  $service = & $query $ServiceName
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

function Invoke-SebBackupDatabase {
  param($Connection, [string]$Database, [string]$TargetFile)
  $quoted = Get-SebQuotedName $Database
  $literal = Get-SebSqlLiteral $TargetFile
  $name = Get-SebSqlLiteral ($Database + ' full backup')
  $base = @('INIT', 'FORMAT', 'CHECKSUM', ('NAME = ' + $name))

  $withParts = $base
  if ($script:SebCompression -ne 'off') { $withParts = $base + @('COMPRESSION') }
  $sql = 'BACKUP DATABASE {0} TO DISK = {1} WITH {2}' -f $quoted, $literal, ($withParts -join ', ')

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

  $sql = 'BACKUP DATABASE {0} TO DISK = {1} WITH {2}' -f $quoted, $literal, ($base -join ', ')
  Invoke-SebSqlNonQuery -Connection $Connection -Sql $sql
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

function Get-SebFolderFacts {
  param([string]$Directory)
  if (-not (Test-Path -LiteralPath $Directory)) { return @() }
  $items = Get-ChildItem -LiteralPath $Directory -Filter '*.bak' -File -ErrorAction SilentlyContinue
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

function Invoke-SebPass {
  param($Config)

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

    foreach ($database in $databases) {
      $fileName = Get-SebFileName -Database $database -Stamp $stamp
      $staged = Join-Path $staging $fileName
      try {
        Write-SebLog ('backing up {0}' -f $database)
        Invoke-SebBackupDatabase -Connection $connection -Database $database -TargetFile $staged
        Test-SebBackupFile -Connection $connection -TargetFile $staged
        $sizeMb = [long]((Get-Item -LiteralPath $staged).Length / 1MB)
        Write-SebLog ('{0} backed up and verified ({1} MB)' -f $database, $sizeMb)

        $hourlyDir = Get-SebBackupPath -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database -Kind 'hourly'
        $dailyDir = Get-SebBackupPath -Root $Config.SharePath -HostName $hostName -InstanceLabel $instanceLabel -Database $database -Kind 'daily'

        $hourlyFacts = @(Get-SebFolderFacts -Directory $hourlyDir)
        $hourlyFacts += [pscustomobject]@{ Name = $fileName; FullName = (Join-Path $hourlyDir $fileName); Timestamp = $stamp }
        $dailyFacts = @(Get-SebFolderFacts -Directory $dailyDir)
        $plan = Get-SebRetentionPlan -HourlyFiles $hourlyFacts -DailyFiles $dailyFacts -Now $stamp `
          -HourlyKeep ([int]$Config.HourlyKeep) -DailyKeepDays ([int]$Config.DailyKeepDays)

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
        $succeeded++
      }
      catch {
        $failed++
        Write-SebLog ('{0} FAILED: {1}' -f $database, $_.Exception.Message) 'ERROR'
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
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
}

function Uninstall-SebSchedule {
  param([string]$Nssm)
  $state = Get-SebScheduleState
  if ($state.TaskPresent) {
    Unregister-ScheduledTask -TaskName $script:SebTaskName -Confirm:$false
    Write-SebLog ('scheduled task "{0}" removed' -f $script:SebTaskName)
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
  param([string]$PinnedInstance, [string]$Share, [string]$Staging, [int]$Hours, [int]$Hourly, [int]$DailyDays, [switch]$WindowsAuth, [switch]$SkipHash)

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

  $probe = Join-Path $Share ('.seb-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  Set-Content -LiteralPath $probe -Value 'probe' -Encoding ASCII
  Remove-Item -LiteralPath $probe -Force
  Write-Host ('  share is writable: {0}' -f $Share)

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
function New-SebLocalShare {
  param(
    [string]$FolderPath,
    [string]$ShareName,
    [string]$MachineAccount = (Get-SebMachineAccount)
  )
  Import-SebShippedModule -Command 'Set-Acl' -Module 'Microsoft.PowerShell.Security'
  Import-SebShippedModule -Command 'Get-SmbShare' -Module 'SmbShare'

  if (-not (Test-Path -LiteralPath $FolderPath)) {
    [void](New-Item -ItemType Directory -Path $FolderPath -Force)
    Write-SebLog ('created backup folder {0}' -f $FolderPath)
  }

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
  Set-Acl -Path $FolderPath -AclObject $acl

  $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
  if ($null -ne $existing) {
    $existingPath = [string]$existing.Path
    if ($existingPath.TrimEnd('\') -ine $FolderPath.TrimEnd('\')) {
      throw ("a share named '$ShareName' already exists on this host and points at '$existingPath', not '$FolderPath'. " +
        'Remove it or choose another -ShareName rather than repointing something that may be in use.')
    }
    Write-SebLog ("share '{0}' already exists at {1} - reusing it" -f $ShareName, $FolderPath)
  }
  else {
    $full = @('BUILTIN\Administrators')
    if (-not [string]::IsNullOrWhiteSpace($MachineAccount)) { $full += $MachineAccount }
    [void](New-SmbShare -Name $ShareName -Path $FolderPath -FullAccess $full -Description 'SQL Express backups')
    Write-SebLog ("shared {0} as '{1}', full access to {2}" -f $FolderPath, $ShareName, ($full -join ' and '))
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
      -WindowsAuth:$UseWindowsAuth -SkipHash:$NoHashVerify
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
    $unc = New-SebLocalShare -FolderPath $ShareFolder -ShareName $ShareName
    Write-Host ('   share ready: ' + $unc)

    Write-Host ''
    Write-Host '== 2/5  setup ========================================================='
    Invoke-SebSetup -PinnedInstance $Instance -Share $unc -Staging $StagingPath `
      -Hours $IntervalHours -Hourly $HourlyKeep -DailyDays $DailyKeepDays `
      -WindowsAuth -SkipHash:$NoHashVerify

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
  Write-SebLog $_.Exception.Message 'ERROR'
  $exitCode = 2
}
finally {
  if ($null -ne $mutex) {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
  }
}

exit $exitCode
