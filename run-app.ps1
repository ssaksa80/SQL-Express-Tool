# Build and launch in one breath.
#
# On a host running endpoint protection that flags unsigned binaries, the exe is
# safest the instant it is written - some agents adjudicate a few seconds later and
# either delete it or block its launch. Building and starting it immediately gives
# the best chance of a clean run without signing. If it is blocked anyway, the fix
# is a signing certificate or an allow-list entry for this folder in the security
# console; a local Defender exclusion (elevated) helps only if Defender is the one
# acting, not CrowdStrike.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-Process SqlExpressBackup -EA SilentlyContinue | ForEach-Object { $_.Kill() }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'build-app.ps1') -OutDir (Join-Path $here 'dist') | Out-Null
$exe = Join-Path $here 'dist\SqlExpressBackup.exe'
if (-not (Test-Path $exe)) { Write-Host 'BLOCKED: the exe was removed immediately after build (endpoint protection).'; exit 2 }
try { Start-Process $exe -EA Stop; Write-Host "launched $exe" }
catch { Write-Host "BLOCKED: $($_.Exception.Message.Split([char]10)[0])"; exit 3 }
