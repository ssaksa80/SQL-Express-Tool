#requires -version 5.1
<#
.SYNOPSIS
  Builds dist/SqlExpressBackup.exe - the portable operator console for the
  SQL Express backup.

.DESCRIPTION
  Uses csc.exe from the .NET Framework, which is present on every Windows install
  since 4.0. No SDK, no package restore, no network. That is deliberate: the thing
  being built is a tool you carry to a server that has nothing on it, so the build
  must not need anything either.

  A native WinForms window - no browser, no local web server, no page to lock
  down. WinForms is in the box on the .NET Framework, so there is still nothing to
  install. The exe embeds the backup engine itself and needs nothing beside it.

  THE OUTPUT IS NOT COMMITTED
  dist/ is gitignored. The source and this script are the reviewable
  artifacts; a binary in the tree is neither reviewable nor trustworthy. Rebuild it
  whenever you need it - this takes about a second.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\build-app.ps1
#>
[CmdletBinding()]
param(
  [string]$OutDir,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Say([string]$t) { if (-not $Quiet) { Write-Host $t } }

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

# Newest first: a machine with 4.8 installed still reports the v4.0.30319 folder,
# which is the compiler we want. v3.5 cannot compile this and is filtered out.
$cscCandidates = @(
  (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
  (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
  throw ("no csc.exe found. Looked in: " + ($cscCandidates -join '; ') +
    ". The .NET Framework 4 compiler ships with Windows; on a stripped image, install the .NET Framework feature.")
}
Say ("compiler : " + $csc)

$engine = Join-Path $root 'Invoke-SqlExpressBackup.ps1'
$sources = @(
  (Join-Path $appDir 'SqlExpressBackupApp.cs'),
  (Join-Path $appDir 'MainForm.cs')
)

$required = @{ 'engine' = $engine }
foreach ($s in $sources) { $required[(Split-Path -Leaf $s)] = $s }
foreach ($k in $required.Keys) {
  if (-not (Test-Path -LiteralPath $required[$k])) { throw ("missing $k at " + $required[$k]) }
}

# The engine is embedded, so a stale or broken copy would ship inside the exe.
# Parse it here rather than discovering it on a server at 2am.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$null, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
  throw ("the backup engine does not parse ({0} error(s)) - refusing to embed it" -f @($parseErrors).Count)
}

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$exe = Join-Path $OutDir 'SqlExpressBackup.exe'

# /target:winexe so double-clicking does not flash a console window. The console the
# operator sees is the elevated PowerShell one, which is deliberate and visible.
$cscArgs = @(
  '/nologo'
  '/target:winexe'
  '/platform:anycpu'
  '/optimize+'
  '/warnaserror-'
  '/reference:System.Windows.Forms.dll'
  '/reference:System.Drawing.dll'
  ('/out:' + $exe)
  ('/resource:' + $engine + ',Invoke-SqlExpressBackup.ps1')
) + $sources

Say 'compiling...'
$out = & $csc @cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  $out | ForEach-Object { Write-Host $_ }
  throw ("csc.exe failed with exit code $LASTEXITCODE")
}
$out | Where-Object { "$_" -match 'warning' } | ForEach-Object { Say ("  " + $_) }

$size = [long]((Get-Item -LiteralPath $exe).Length / 1KB)
Say ''
Say ("built    : $exe  (${size} KB)")
Say  'portable : copy that one file anywhere - it carries its UI and the engine'
Say  'run      : double-click it - it opens a window. No browser, no listener.'
Say  'note     : it is unsigned, so EDR may quarantine it. The PowerShell path'
Say  '           (Invoke-SqlExpressBackup.ps1) always works and is the supported one.'
