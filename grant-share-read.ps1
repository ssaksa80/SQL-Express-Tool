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
  Write-Host "NOT ELEVATED. Open PowerShell as administrator, sign in as adminaccount, and re-run." -ForegroundColor Yellow
  try { Stop-Transcript | Out-Null } catch {}
  exit 2
}
Write-Host ("running as " + $id.Name)

# The SQL service account, out of the registry (fast, no WMI).
$svc = Get-CimInstance Win32_Service -Filter "Name LIKE 'MSSQL$%' AND Name NOT LIKE '%TELEMETRY%'" |
       Select-Object -First 1
$sqlAccount = $svc.StartName
if ([string]::IsNullOrWhiteSpace($sqlAccount)) { throw "could not resolve the SQL service account" }
Write-Host ("SQL service account: " + $sqlAccount)

$machine = "$env:USERDOMAIN\$env:COMPUTERNAME$"

Write-Host ''
Write-Host '== granting =='
Grant-SmbShareAccess -Name $ShareName -AccountName $machine     -AccessRight Full -Force | Out-Null
Grant-SmbShareAccess -Name $ShareName -AccountName $sqlAccount  -AccessRight Read -Force | Out-Null
Write-Host ("  $machine -> Full")
Write-Host ("  $sqlAccount -> Read")

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
