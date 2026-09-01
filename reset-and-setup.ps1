# Nuke an existing install and lay down a fresh one, in the right order.
#
# Run this ELEVATED - as the admin account (t2-). It refuses to run otherwise
# rather than getting halfway and failing on the first privileged step.
#
# What it does, in order:
#   1. Uninstall any existing schedule (task or service). Idempotent - fine if none.
#   2. Purge config and sealed key material, so setup starts clean.
#   3. OPTIONALLY delete the existing .bak files - OFF by default. These may be the
#      only copies of a database, so deleting them is a separate, explicit choice,
#      never a side effect of "set up again".
#   4. Fresh setup + schedule, and one backup pass to prove it.
#
# It does NOT touch any OTHER host's backups. The tool is host-scoped, and this
# script only ever names this host's own share folder.
param(
  [string]$ShareName   = 'SqlBackups',
  [string]$ShareFolder = 'C:\SqlBackups',
  [int]$IntervalHours  = 6,
  [switch]$DeleteBackups,   # explicit opt-in: wipe existing .bak files first
  [switch]$KeepConfig       # skip the -Purge, keep the existing sealed config
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'Invoke-SqlExpressBackup.ps1'

# Everything this prints also goes here, world-readable, so the outcome can be read
# back even if the console output is lost. Written to the repo dir, which the
# ordinary account can read.
$transcript = Join-Path $here 'reset-last-run.log'
try { Start-Transcript -LiteralPath $transcript -Force | Out-Null } catch {}

function Sec($n) { Write-Host ''; Write-Host ("== " + $n + " " + ('=' * [Math]::Max(0, 62 - $n.Length))) }

# --- elevation gate --------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "NOT ELEVATED. Run this as the admin account (t2-):" -ForegroundColor Yellow
  Write-Host "  right-click PowerShell -> Run as administrator, sign in as adminaccount, then re-run this script."
  Write-Host ("current identity: " + $id.Name)
  try { ("NOT ELEVATED - ran as " + $id.Name + " at " + (Get-Date -Format o)) | Set-Content -LiteralPath $transcript } catch {}
  try { Stop-Transcript | Out-Null } catch {}
  exit 2
}
Write-Host ("running as " + $id.Name)

# --- refuse to race a live pass --------------------------------------------------
$busy = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
  Where-Object { $_.CommandLine -match 'Invoke-SqlExpressBackup' -and $_.ProcessId -ne $PID }
if ($busy) { Write-Host "A backup pass is running (pid $($busy.ProcessId)). Wait for it, then re-run." -ForegroundColor Yellow; exit 3 }

Sec 'teardown'
& powershell -NoProfile -ExecutionPolicy Bypass -File $engine -Uninstall
Write-Host ("uninstall exit " + $LASTEXITCODE + " (a non-zero here is fine if nothing was installed)")

if (-not $KeepConfig) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $engine -Uninstall -Purge
  Write-Host 'config and sealed key material purged'
}

if ($DeleteBackups) {
  Sec 'deleting existing backups (you asked for this)'
  if (Test-Path $ShareFolder) {
    $n = @(Get-ChildItem $ShareFolder -Recurse -Filter *.bak -EA SilentlyContinue).Count
    Write-Host ("removing " + $n + " .bak file(s) under " + $ShareFolder)
    Get-ChildItem $ShareFolder -Recurse -Filter *.bak -EA SilentlyContinue | Remove-Item -Force
  } else { Write-Host ("nothing to delete - " + $ShareFolder + " does not exist") }
} else {
  Write-Host ''
  Write-Host 'Existing backups kept. Pass -DeleteBackups to wipe them (irreversible).' -ForegroundColor DarkGray
}

Sec 'fresh setup'
& powershell -NoProfile -ExecutionPolicy Bypass -File $engine -FullInstall -ShareName $ShareName -ShareFolder $ShareFolder
$rc = $LASTEXITCODE
Write-Host ("full install exit " + $rc)

Sec 'result'
& powershell -NoProfile -ExecutionPolicy Bypass -File $engine -Status
try { Stop-Transcript | Out-Null } catch {}
Write-Host ''
Write-Host ("full output saved to " + $transcript)
exit $rc
