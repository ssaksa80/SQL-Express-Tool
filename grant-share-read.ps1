# Grant the SQL Server service READ on the backup share, so RESTORE can read a
# backup over its own UNC path. Run ELEVATED, as the admin account (t2-).
#
# This is the same grant a fresh setup now applies on the share-reuse path; it exists
# as a standalone so an already-installed host can be fixed without a full re-setup.
# It is idempotent - safe to run more than once.
param([string]$ShareName = 'SqlBackups')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here 'grant-last-run.log'
try { Start-Transcript -LiteralPath $log -Force | Out-Null } catch {}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  ("NOT ELEVATED - ran as " + $id.Name) | Set-Content -LiteralPath $log
  Write-Host "NOT ELEVATED. Open PowerShell as administrator, sign in as your administrator account, and re-run." -ForegroundColor Yellow
  try { Stop-Transcript | Out-Null } catch {}
  exit 2
}
Write-Host ("running as " + $id.Name)

# The SQL service account, straight from the registry - no WMI (the WQL filter with a
# literal $ in the service name is exactly what broke the first version of this).
# The service name comes from the configured instance: a named instance is
# MSSQL$<name>, the default instance is MSSQLSERVER.
$pubForSvc = Get-Content 'C:\ProgramData\SqlExpressBackup\public.json' -Raw | ConvertFrom-Json
$inst = [string]$pubForSvc.InstanceName
if ($inst -eq 'MSSQLSERVER' -or [string]::IsNullOrWhiteSpace($inst)) { $svcName = 'MSSQLSERVER' }
else { $svcName = 'MSSQL$' + $inst }
$svcKey = Join-Path 'HKLM:\SYSTEM\CurrentControlSet\Services' $svcName
$sqlAccount = (Get-ItemProperty -LiteralPath $svcKey -Name 'ObjectName' -ErrorAction Stop).ObjectName
if ([string]::IsNullOrWhiteSpace($sqlAccount)) { throw ('could not resolve the account for service ' + $svcName) }
Write-Host ('SQL service (' + $svcName + ') runs as: ' + $sqlAccount)

# Machine account WITHOUT a domain prefix - it resolves via the machine's own domain,
# and it sidesteps $env:USERDOMAIN, which is not dependable across an elevated logon.
$machine = $env:COMPUTERNAME + '$'

# Each grant stands alone. The machine account is usually already Full from setup, so
# its grant failing is not fatal; the SQL service Read is the one that must land, and
# it must not be blocked by anything before it.
Write-Host ''
Write-Host '== granting =='
foreach ($g in @(
    @{ Account = $machine;    Right = 'Full' },
    @{ Account = $sqlAccount; Right = 'Read' })) {
  try {
    Grant-SmbShareAccess -Name $ShareName -AccountName $g.Account -AccessRight $g.Right -Force -ErrorAction Stop | Out-Null
    Write-Host ("  " + $g.Account + " -> " + $g.Right + "  OK")
  } catch {
    Write-Host ("  " + $g.Account + " -> " + $g.Right + "  FAILED: " + $_.Exception.Message.Split([char]10)[0]) -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host '== share ACL now =='
Get-SmbShareAccess -Name $ShareName | ForEach-Object { Write-Host ("  {0,-40} {1} {2}" -f $_.AccountName, $_.AccessControlType, $_.AccessRight) }

# Prove it: can SQL now read a backup over the UNC path? This is the whole point -
# a grant that Get-SmbShareAccess shows but SQL still cannot use would be worthless.
Write-Host ''
Write-Host '== proving SQL can now read the share over UNC =='
$pub = Get-Content 'C:\ProgramData\SqlExpressBackup\public.json' -Raw | ConvertFrom-Json
$unc = $pub.SharePath
$sample = Get-ChildItem $unc -Recurse -Filter '*.bak' -EA SilentlyContinue | Select-Object -First 1
if ($sample) {
  try {
    $c = New-Object System.Data.SqlClient.SqlConnection ("Server=.\" + $pub.InstanceName + ";Database=master;Integrated Security=true;Connect Timeout=10")
    $c.Open()
    $cmd = $c.CreateCommand()
    $cmd.CommandText = "RESTORE FILELISTONLY FROM DISK = N'" + $sample.FullName.Replace("'","''") + "'"
    [void]$cmd.ExecuteReader()
    $c.Close()
    Write-Host ("  YES - SQL read " + (Split-Path $sample.FullName -Leaf) + " over the share. Restore-from-UNC works now.")
  } catch {
    Write-Host ("  STILL BLOCKED: " + $_.Exception.Message.Split([char]10)[0]) -ForegroundColor Yellow
  }
} else { Write-Host "  no .bak found under $unc to test with" }

try { Stop-Transcript | Out-Null } catch {}
Write-Host ''
Write-Host ("result saved to " + $log)
