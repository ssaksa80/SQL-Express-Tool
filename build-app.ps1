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

  The exe embeds its whole UI - page, stylesheet, script, the GSAP copy already
  vendored in docs/assets, and the backup engine itself. Nothing is fetched at
  runtime and nothing needs to sit beside the exe.

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
$webDir = Join-Path $appDir 'web'
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
$gsap = Join-Path $root 'assets\gsap.min.js'
$source = Join-Path $appDir 'SqlExpressBackupApp.cs'

$required = @{
  'engine'     = $engine
  'gsap'       = $gsap
  'source'     = $source
  'index.html' = (Join-Path $webDir 'index.html')
  'app.css'    = (Join-Path $webDir 'app.css')
  'app.js'     = (Join-Path $webDir 'app.js')
}
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

# The page assets are embedded, so a JavaScript syntax error would ship INSIDE the
# exe and only surface as a blank console on a server. csc cannot see them, so check
# them here. node is not required to build - if it is absent the gate is skipped and
# says so, rather than silently not running.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  $harness = Join-Path $webDir 'app.contract.js'
  if (Test-Path -LiteralPath $harness) {
    $contract = & $node.Source $harness 2>&1
    if ($LASTEXITCODE -ne 0) {
      $contract | ForEach-Object { Write-Host $_ }
      throw 'the page script failed its contract check - refusing to embed it'
    }
    Say 'page script: contract OK'
  }
}
else {
  Say 'page script: NOT checked (node is not on PATH)'
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
  ('/out:' + $exe)
  ('/resource:' + (Join-Path $webDir 'index.html') + ',index.html')
  ('/resource:' + (Join-Path $webDir 'app.css') + ',app.css')
  ('/resource:' + (Join-Path $webDir 'app.js') + ',app.js')
  ('/resource:' + $gsap + ',gsap.min.js')
  ('/resource:' + $engine + ',Invoke-SqlExpressBackup.ps1')
  $source
)

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
Say  'run      : double-click it, or run it and open the URL it writes to'
Say  '           %LOCALAPPDATA%\SqlExpressBackup\console-url.txt'
Say  '           (that file is restricted to the account that launched it - it'
Say  '            holds the token that drives the console)'
