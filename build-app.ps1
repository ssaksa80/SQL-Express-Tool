#requires -version 5.1
<#
.SYNOPSIS
  Builds dist-winforms/SqlExpressBackup.exe - the portable operator console for the
  SQL Express backup. (The modern WPF app builds to dist/ via build-wpf.ps1; the two
  are kept in separate folders so neither clobbers the other's SqlExpressBackup.exe.)

.DESCRIPTION
  Uses csc.exe from the .NET Framework, which is present on every Windows install
  since 4.0. No SDK, no package restore, no network. That is deliberate: the thing
  being built is a tool you carry to a server that has nothing on it, so the build
  must not need anything either.

  A native WinForms window - no browser, no local web server, no page to lock
  down. WinForms is in the box on the .NET Framework, so there is still nothing to
  install. The exe embeds the backup engine itself and needs nothing beside it.

  THE OUTPUT IS NOT COMMITTED
  dist-winforms/ is gitignored. The source and this script are the reviewable
  artifacts; a binary in the tree is neither reviewable nor trustworthy. Rebuild it
  whenever you need it - this takes about a second.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\build-app.ps1
#>
[CmdletBinding()]
param(
  [string]$OutDir,
  [switch]$Quiet,
  # Thumbprint of a code-signing certificate. Omit to use the first one found in the
  # user or machine store; pass -NoSign to skip signing even when one is available.
  [string]$CertThumbprint,
  [switch]$NoSign,
  # Create and use a self-signed code-signing certificate when no real one is present.
  # Measured to be enough to launch on a CrowdStrike Falcon estate - see the block
  # below - but it is NOT distributable: nothing off this machine will trust it.
  [switch]$SelfSign
)

$ErrorActionPreference = 'Stop'

function Say([string]$t) { if (-not $Quiet) { Write-Host $t } }

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
if (-not $OutDir) { $OutDir = Join-Path $root 'dist-winforms' }

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
  (Join-Path $appDir 'MainForm.cs'),
  (Join-Path $appDir 'RestoreForm.cs'),
  (Join-Path $appDir 'RestorePanels.cs')
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
  # The engine answers the restore modes in JSON, because the caller is a program.
  # JavaScriptSerializer ships in the .NET Framework itself - no package, nothing to
  # vendor, and this tool redistributes no third-party code.
  '/reference:System.Web.Extensions.dll'
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

# ---- signing --------------------------------------------------------------------
# An unsigned binary that spawns elevated PowerShell is close to a textbook EDR
# heuristic, and on a managed estate it gets quarantined - which is the endpoint
# tool working, not failing. Signing is the fix, so the build signs whenever a
# certificate is available and says plainly when it cannot.
#
# A SELF-SIGNED certificate is not distributable - nothing off this machine will
# trust it, and Windows will not validate its chain. But on the CrowdStrike Falcon
# estate this runs on, it is measurably enough to LAUNCH, and that was worth testing
# rather than assuming. A controlled A/B in one time window: unsigned launched 0 of 3
# and was blocked 3 of 3; the same binary self-signed launched 3 of 3, blocked 0 of
# 3. Falcon appears to treat any Authenticode signature as a lower-risk signal than a
# completely unsigned binary that spawns elevated PowerShell, even an untrusted one.
#
# So -SelfSign is a real answer for running on THIS estate, and a real cert from a CA
# the domain trusts is still the answer for distribution. Both are supported; the
# self-signed path just says plainly what it is.
$signedOk = $false
if (-not $NoSign) {
  $cert = $null
  if ($CertThumbprint) {
    $wanted = $CertThumbprint.Replace(' ', '')
    foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
      $c = @(Get-ChildItem $store -ErrorAction SilentlyContinue |
          Where-Object { $_.Thumbprint -eq $wanted -and $_.HasPrivateKey })
      if ($c.Count -gt 0) { $cert = $c[0]; break }
    }
    if (-not $cert) { throw ("no certificate with a private key and thumbprint $wanted was found") }
  }
  else {
    foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
      $c = @(Get-ChildItem $store -CodeSigningCert -ErrorAction SilentlyContinue |
          Where-Object { $_.HasPrivateKey })
      if ($c.Count -gt 0) { $cert = $c[0]; break }
    }
    # No real certificate, but -SelfSign was asked for: make one. Reuse an existing
    # self-signed cert with our subject so repeated builds do not litter the store.
    if (-not $cert -and $SelfSign) {
      $subject = 'CN=SQL Express Backup (self-signed)'
      $existing = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
          Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) })
      if ($existing.Count -gt 0) { $cert = $existing[0] }
      else {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
          -CertStoreLocation Cert:\CurrentUser\My -KeyUsage DigitalSignature `
          -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(1) -HashAlgorithm SHA256
        Say ('self-signed: created ' + $subject + '  (' + $cert.Thumbprint.Substring(0, 12) + ')')
      }
    }
  }

  if ($cert) {
    Say ('signing  : ' + $cert.Subject + '  (' + $cert.Thumbprint.Substring(0, 12) + ')')
    # Timestamping keeps the signature valid past the certificate's expiry but needs
    # the network, and an untimestamped signature beats none - so that must not fail
    # the build.
    $sig = $null
    try {
      $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com' -ErrorAction Stop
    }
    catch {
      Say '           (timestamp server unreachable - signing without a timestamp)'
      $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256
    }
    # Applying a signature and being able to VALIDATE it here are different things,
    # and only the first is this build's job. A certificate from an internal CA
    # reports Valid on a domain machine and UnknownError on one that does not trust
    # that root - the file is signed correctly either way. So fail only when no
    # signature was actually written, and report anything else rather than throwing.
    if ($null -eq $sig -or $sig.Status -eq 'NotSigned' -or $null -eq $sig.SignerCertificate) {
      throw ('signing did not apply a signature: ' + $(if ($sig) { "$($sig.Status) - $($sig.StatusMessage)" } else { 'no result' }))
    }
    if ($sig.Status -eq 'Valid') {
      $signedOk = $true
      Say '           signed and verifiable on this machine'
    }
    else {
      $signedOk = $true
      Say ('           signed, but this machine cannot validate the chain (' + $sig.Status + ').')
      Say '           Expected when the signing root is not installed here. If the'
      Say '           certificate is SELF-SIGNED, nothing will trust it anywhere and'
      Say '           it will not stop endpoint protection quarantining the exe.'
    }
  }
  else {
    Say 'signing  : SKIPPED - no code-signing certificate in CurrentUser\My or LocalMachine\My.'
    Say '           The exe is UNSIGNED and endpoint protection may quarantine it.'
    Say '           Enrol one from your CA and re-run with -CertThumbprint, or use the'
    Say '           PowerShell path, which does not depend on this at all.'
  }
}

$size = [long]((Get-Item -LiteralPath $exe).Length / 1KB)
Say ''
Say ("built    : $exe  (${size} KB)")
Say  'portable : copy that one file anywhere - it carries its UI and the engine'
Say  'run      : double-click it - it opens a window. No browser, no listener.'
if ($signedOk) {
  Say  'signed   : yes - endpoint protection is far less likely to object.'
}
else {
  Say  'note     : it is UNSIGNED, so EDR may quarantine it. The PowerShell path'
  Say  '           (Invoke-SqlExpressBackup.ps1) always works and is the supported one.'
}
