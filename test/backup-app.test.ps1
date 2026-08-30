# Run: powershell -NoProfile -ExecutionPolicy Bypass -File "test\backup-app.test.ps1"
#
# Guards app/* and build-app.ps1 - the portable operator
# console for the SQL Express backup.
#
# This one BUILDS THE EXE AND DRIVES IT. A console that can launch elevated
# PowerShell is not something to guard with source greps: the properties that matter
# are runtime properties. Specifically:
#
#   1. It listens on loopback ONLY. A backup tool that quietly opens a port on the
#      LAN is a foothold, and "we passed IPAddress.Loopback" is a claim about source,
#      not about the socket. So the socket is actually probed from a routable address.
#   2. Every route needs the per-launch token. Without it any other local process, or
#      any page in the same browser, could read status and drive actions.
#   3. Nothing is fetched from off the machine. GSAP is served out of the exe.
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "FAIL: $msg" } else { Write-Host "  PASS $msg" } }

$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'app'
$webDir = Join-Path $appDir 'web'
$source = Join-Path $appDir 'SqlExpressBackupApp.cs'
$builder = Join-Path $root 'build-app.ps1'

# ---- source guards ---------------------------------------------------------------
foreach ($f in @($source, $builder, (Join-Path $webDir 'index.html'), (Join-Path $webDir 'app.css'), (Join-Path $webDir 'app.js'))) {
  Assert (Test-Path -LiteralPath $f) ((Split-Path -Leaf $f) + ' exists')
  $raw = [IO.File]::ReadAllText($f)
  Assert (-not ($raw -match '[^\x00-\x7F]')) ((Split-Path -Leaf $f) + ' is pure ASCII')
}

$web = @()
foreach ($f in @('index.html', 'app.css', 'app.js')) { $web += [IO.File]::ReadAllText((Join-Path $webDir $f)) }
$webAll = $web -join "`n"
# The console can start elevated PowerShell. It must not be able to pull code, fonts
# or anything else from off this machine.
Assert (-not ($webAll -match '(?i)https?://(?!127\.0\.0\.1)')) 'the UI references no external URL of any kind'
Assert (-not ($webAll -match '(?i)cdn\.|unpkg|jsdelivr|googleapis')) 'and no CDN by name'
Assert ($webAll -match "default-src 'none'") 'the page ships a restrictive Content-Security-Policy'
Assert ($webAll -match "script-src 'self'") 'scripts may only come from the app itself'

$cs = [IO.File]::ReadAllText($source)
Assert ($cs -match 'IPAddress\.Loopback') 'the listener is created against IPAddress.Loopback'
Assert (-not ($cs -match 'IPAddress\.Any')) 'and never against IPAddress.Any'
Assert (-not ($cs -match '(?i)requireAdministrator')) 'the exe does not demand elevation to start - the dashboard and self test must work without it'
Assert ($cs -match 'FixedEquals') 'the token is compared without an early-exit shortcut'

$build = [IO.File]::ReadAllText($builder)
Assert ($build -match '/target:winexe') 'built as a windowed exe, so double-clicking does not flash a console'
Assert ($build -match 'gsap\.min\.js') 'GSAP is embedded from the copy vendored in this repo'
Assert ((Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -match 'dist/') 'the built exe is gitignored - source is the reviewable artifact'

# ---- the contract INSIDE app.js ---------------------------------------------------
# Driving the HTTP API proves the server. It cannot prove the page: pollLog called
# get('/api/log', 'since=' + cursor) while get() was declared get(path) and silently
# dropped the second argument, so the server answered from cursor 0 every time and
# the log pane repeated its entire contents on every tick. Server-side everything was
# correct. This runs app.js under node against a stubbed browser and asserts what it
# actually asks for.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  $harness = Join-Path $webDir 'app.contract.js'
  Assert (Test-Path -LiteralPath $harness) 'the client contract harness exists'
  $contract = & $node.Source $harness 2>&1
  $contractText = ($contract | Out-String).Trim()
  Assert ($LASTEXITCODE -eq 0) "app.js keeps its internal contract ($contractText)"
  Assert ($contractText -match 'CONTRACT-OK') 'the harness ran to a verdict'
  Assert ($contractText -match 'since=') 'the log poll carries its cursor - without it the pane repeats forever'
  Assert ($contractText -match 't=TESTTOKEN') 'and every request carries the token'
}
else {
  Write-Host '  SKIP node not on PATH - cannot drive the app.js contract harness'
}

# ---- build ------------------------------------------------------------------------
$outDir = Join-Path $env:TEMP ('seb-app-' + [Guid]::NewGuid().ToString('N'))
$exe = Join-Path $outDir 'SqlExpressBackup.exe'
$endpoint = Join-Path $outDir 'endpoint.txt'
$proc = $null
try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $builder -OutDir $outDir -Quiet 2>&1 | Out-Null
  Assert ($LASTEXITCODE -eq 0) "the build script succeeded (exit $LASTEXITCODE)"
  Assert (Test-Path -LiteralPath $exe) 'it produced SqlExpressBackup.exe'
  Assert ((Get-Item -LiteralPath $exe).Length -gt 100kb) 'and the exe carries its embedded UI and engine'

  # ---- run it ---------------------------------------------------------------------
  $proc = Start-Process -FilePath $exe -ArgumentList '--no-browser', '--endpoint', "`"$endpoint`"" -PassThru
  $deadline = (Get-Date).AddSeconds(25)
  while (-not (Test-Path -LiteralPath $endpoint) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  Assert (Test-Path -LiteralPath $endpoint) 'the app came up and published its address'

  # The URL carries the token, and the token drives this console - which when the
  # console is elevated means driving an elevated process. So the file must not
  # inherit. On a tiered-admin site the admin profile can grant the matching standard
  # account FullControl - it does on this host - and an inherited ACL under
  # LOCALAPPDATA therefore handed a standard user the ELEVATED console's token. The
  # 401 gate was working perfectly and was beside the point, because the real token
  # was readable.
  $epAcl = Get-Acl -LiteralPath $endpoint
  Assert ($epAcl.AreAccessRulesProtected) 'the endpoint file does NOT inherit - a token must not pick up a permissive profile ACL'
  $epWho = @($epAcl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } | Sort-Object -Unique)
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  Assert ($epWho -contains $me) "the account that launched it can read it (grants: $($epWho -join ', '))"
  Assert ($epWho -contains 'NT AUTHORITY\SYSTEM') 'SYSTEM can read it'
  $strangers = @($epWho | Where-Object { $_ -ne $me -and $_ -ne 'NT AUTHORITY\SYSTEM' })
  Assert ($strangers.Count -eq 0) "and nobody else is granted at all (extra: $($strangers -join ', '))"

  $url = (Get-Content -LiteralPath $endpoint -Raw).Trim()
  Assert ($url -match '^http://127\.0\.0\.1:(\d+)/\?t=([0-9a-f]{64})$') "the address is loopback with a 256-bit token (got '$url')"
  $port = [int]$Matches[1]
  $token = $Matches[2]

  # 1. loopback ONLY. Probed from a routable address on this host, not asserted.
  $lan = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
      Select-Object -ExpandProperty IPAddress -First 1)
  if ($lan.Count -gt 0) {
    $reachable = $false
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $iar = $c.BeginConnect($lan[0], $port, $null, $null)
      $reachable = $iar.AsyncWaitHandle.WaitOne(2500) -and $c.Connected
      $c.Close()
    }
    catch { $reachable = $false }
    Assert (-not $reachable) "the port is NOT reachable on this host's own LAN address $($lan[0]) - loopback only"
  }
  else {
    Write-Host '  SKIP no routable IPv4 on this host to probe from'
  }

  # 2. the token gate, on an API route and on an asset
  foreach ($path in @('/api/status', '/assets/app.js', '/')) {
    $code = 0
    try { $code = (Invoke-WebRequest -Uri ("http://127.0.0.1:$port" + $path) -UseBasicParsing -TimeoutSec 10).StatusCode }
    catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 401) "$path without the token is refused (got $code)"
  }
  $code = 0
  try { $code = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/status?t=$('0' * 64)" -UseBasicParsing -TimeoutSec 10).StatusCode }
  catch { $code = [int]$_.Exception.Response.StatusCode }
  Assert ($code -eq 401) "a wrong token of the right length is refused (got $code)"

  # 3. with the token, it actually works
  $status = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/status?t=$token" -TimeoutSec 15
  Assert ($null -ne $status) 'status is served with the token'
  Assert ($status.hostName -eq $env:COMPUTERNAME) "status names this host (got '$($status.hostName)')"
  Assert ($null -ne $status.PSObject.Properties['configured']) 'status says whether the host is set up yet'
  Assert ($null -ne $status.PSObject.Properties['scheduleState']) 'status reports the scheduled task state'

  $page = Invoke-WebRequest -Uri "http://127.0.0.1:$port/?t=$token" -UseBasicParsing -TimeoutSec 15
  Assert ($page.Content -match [regex]::Escape($token)) 'the page is served with the live token substituted in'
  Assert (-not ($page.Content -match '__TOKEN__')) 'and no placeholder is left behind'

  $gsapLocal = (Get-Item -LiteralPath (Join-Path $root 'assets\gsap.min.js')).Length
  $gsapServed = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/assets/gsap.min.js?t=$token" -UseBasicParsing -TimeoutSec 20).RawContentLength
  Assert ($gsapServed -eq $gsapLocal) "GSAP is served from inside the exe, byte for byte ($gsapServed of $gsapLocal)"

  # 4. traversal out of the embedded asset namespace
  $code = 0
  try { $code = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/assets/..%2fweb.config?t=$token" -UseBasicParsing -TimeoutSec 10).StatusCode }
  catch { $code = [int]$_.Exception.Response.StatusCode }
  Assert ($code -eq 400 -or $code -eq 404) "an asset name trying to escape is refused (got $code)"

  # 5. the full install is the one action that creates a share, schedules a permanent
  #    job and starts backing up every database. Its guard must live on the SERVER:
  #    this endpoint is reachable by anything holding the token, so a confirmation
  #    that existed only in the page would not be a confirmation at all.
  #    Only the REFUSALS are exercised here - accepting would really install.
  function Post-Action([string]$body) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/action?t=$token" -Method Post `
        -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 10
      return [int]$r.StatusCode
    }
    catch { return [int]$_.Exception.Response.StatusCode }
  }

  $good = 'shareName=SqlBackups&shareFolder=C:\SqlBackups&interval=6&hourly=3&daily=7'
  Assert ((Post-Action ("action=fullinstall&" + $good)) -eq 400) 'full install with NO typed confirmation is refused'
  Assert ((Post-Action ("action=fullinstall&confirm=yes&" + $good)) -eq 400) 'full install with the wrong confirmation is refused'
  Assert ((Post-Action ("action=fullinstall&confirm=full+install&" + $good)) -eq 400) 'the confirmation is case-sensitive'
  Assert ((Post-Action 'action=fullinstall&confirm=FULL+INSTALL&shareName=bad%5Cname&shareFolder=C:\SqlBackups') -eq 400) 'a share name containing a path separator is refused'
  Assert ((Post-Action 'action=fullinstall&confirm=FULL+INSTALL&shareName=Sql+Backups&shareFolder=C:\SqlBackups') -eq 400) 'a share name containing a space is refused'
  Assert ((Post-Action 'action=fullinstall&confirm=FULL+INSTALL&shareName=SqlBackups&shareFolder=SqlBackups') -eq 400) 'a relative folder is refused - it would resolve against wherever the elevated shell started'
  Assert ((Post-Action 'action=fullinstall&confirm=FULL+INSTALL&shareName=SqlBackups&shareFolder=%5C%5Cother%5Cshare') -eq 400) 'a UNC folder is refused - this host cannot share what it does not own'
  Assert ((Post-Action 'action=fullinstall&confirm=FULL+INSTALL&shareName=SqlBackups&shareFolder=C:\a\..\b') -eq 400) 'a folder walking through .. is refused'
  Assert ((Post-Action 'action=nonsense') -eq 400) 'an unknown action is refused'

  # Nothing above may have STARTED anything - a refusal that still launched the
  # elevated child would be worse than no guard, because it would look safe.
  $afterLog = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/log?t=$token&since=0" -TimeoutSec 10
  $started = @($afterLog.lines | Where-Object { $_ -match 'fullinstall' })
  Assert ($started.Count -eq 0) "no refused request started anything (log mentions fullinstall $($started.Count) time(s))"
  Assert ($afterLog.idle -eq $true) 'and the app is still idle'

  # 6. it shuts down when asked, rather than lingering as an open port
  [void](Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/quit?t=$token" -Method Post -TimeoutSec 10)
  $gone = $proc.WaitForExit(15000)
  Assert $gone 'the app exits on Quit rather than leaving a listener running'
  $proc = $null
}
finally {
  if ($null -ne $proc) { try { $proc.Kill() } catch { } }
  Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'ALL PASS'
