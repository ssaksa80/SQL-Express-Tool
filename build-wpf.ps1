# Build the WPF shell with the in-box C# compiler - no .NET SDK, no MSBuild, no
# packages. Code-first WPF (no XAML), so csc alone is enough.
#
# -SelfSign creates/reuses a self-signed certificate and signs the output, which on a
# CrowdStrike Falcon estate is the difference between the binary launching and being
# blocked (measured: unsigned 0/3, self-signed 3/3). A CA certificate is still the
# answer for distribution beyond the build host.
param(
  [string]$OutDir = 'dist-wpf',
  [switch]$SelfSign,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function Say($m) { if (-not $Quiet) { Write-Host $m } }

$fw     = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319'
$csc    = Join-Path $fw 'csc.exe'
$wpflib = Join-Path $fw 'WPF'
if (-not (Test-Path $csc))    { throw "in-box csc not found at $csc" }
if (-not (Test-Path $wpflib)) { throw "WPF assemblies not found at $wpflib" }

$out = Join-Path $here $OutDir
New-Item -ItemType Directory -Force $out | Out-Null
$exe = Join-Path $out 'SqlExpressBackup.exe'

$sources = @(
  (Join-Path $here 'wpf\App.cs'),
  (Join-Path $here 'wpf\Settings.cs'),
  (Join-Path $here 'wpf\Theme.cs'),
  (Join-Path $here 'wpf\Ui.cs'),
  (Join-Path $here 'wpf\Engine.cs'),
  (Join-Path $here 'wpf\GlowBar.cs'),
  (Join-Path $here 'wpf\LogPane.cs'),
  (Join-Path $here 'wpf\ModernView.cs'),
  (Join-Path $here 'wpf\DbaView.cs'),
  (Join-Path $here 'wpf\RestoreWindow.cs'),
  (Join-Path $here 'wpf\Install.cs'),
  (Join-Path $here 'wpf\FirstRun.cs')
)
$manifest = Join-Path $here 'wpf\app.manifest'

Say '== compiling WPF shell (in-box csc, C# 5) =='
$args = @(
  '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
  ('/lib:' + $wpflib),
  '/reference:PresentationFramework.dll', '/reference:PresentationCore.dll',
  '/reference:WindowsBase.dll', '/reference:System.Xaml.dll',
  '/reference:System.Web.Extensions.dll', '/reference:System.Windows.Forms.dll',
  # The PowerShell engine is embedded so the exe is self-contained: portable and
  # installed modes both extract it beside themselves.
  ('/resource:' + (Join-Path $here 'Invoke-SqlExpressBackup.ps1') + ',SqlExpressBackup.engine.ps1'),
  ('/win32manifest:' + $manifest),
  ('/out:' + $exe)
) + $sources

& $csc @args
if ($LASTEXITCODE -ne 0) { throw 'csc failed' }
if (-not (Test-Path $exe)) { throw 'no exe produced' }
Say ('  built    : ' + $exe + '  (' + [math]::Round((Get-Item $exe).Length / 1KB) + ' KB)')

if ($SelfSign) {
  $subject = 'CN=SQL Express Backup (self-signed)'
  $cert = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
      Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) }) |
      Select-Object -First 1
  if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
      -CertStoreLocation Cert:\CurrentUser\My -KeyUsage DigitalSignature `
      -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(1) -HashAlgorithm SHA256
    Say ('  self-signed: created ' + $subject)
  }
  $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256
  Say ('  signed   : ' + $sig.Status + ' (self-signed launches past endpoint protection; not distributable)')
}

Say 'done.'
