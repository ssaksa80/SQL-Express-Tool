# Run: powershell -NoProfile -ExecutionPolicy Bypass -File "test\backup-app.test.ps1"
#
# Guards app/* and build-app.ps1 - the native operator console.
#
# The previous version of this console served an HTML page from a loopback socket,
# and this suite drove it over HTTP. There is no socket now, so the shape of the
# testing changed with it: what is left to prove is that the window builds, that the
# engine lands in the right place, and that the things which caused real defects
# have not crept back.
#
# The one that matters most is WHERE the engine is extracted. This process runs
# unelevated on purpose, and ProgramData's default ACL lets a user rewrite what they
# create there - so extracting the engine into the machine-wide state directory and
# then pointing a SYSTEM task at it hands any non-admin a script SYSTEM runs every
# six hours. That is not hypothetical; it shipped, and it is why the check is here.
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "FAIL: $msg" } else { Write-Host "  PASS $msg" } }

$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'app'
$builder = Join-Path $root 'build-app.ps1'
$sources = @((Join-Path $appDir 'SqlExpressBackupApp.cs'), (Join-Path $appDir 'MainForm.cs'))

# ---- source guards ---------------------------------------------------------------
foreach ($f in ($sources + @($builder))) {
  Assert (Test-Path -LiteralPath $f) ((Split-Path -Leaf $f) + ' exists')
  Assert (-not ([IO.File]::ReadAllText($f) -match '[^\x00-\x7F]')) ((Split-Path -Leaf $f) + ' is pure ASCII')
}
# Comments only, stripped - this file's own header explains WHY there is no
# TcpListener any more, and a bare text match would happily fail on that sentence.
# The same trap caught the engine suite once already.
$cs = ($sources | ForEach-Object {
    (Get-Content -LiteralPath $_) | Where-Object { -not ($_.TrimStart().StartsWith('//')) }
  }) -join "`n"

# The whole reason for going native was to delete this surface. If any of it returns,
# so do the guards it needed: a token, a constant-time compare, an ACL on the file
# recording it, and a page to lock down.
foreach ($gone in @('TcpListener', 'HttpListener', 'AcceptTcpClient', 'FixedEquals', 'console-url')) {
  Assert (-not ($cs -match [regex]::Escape($gone))) "the app no longer contains $gone - there is no local server any more"
}
Assert (-not ($cs -match 'NewToken|RNGCryptoServiceProvider')) 'and no capability token, because nothing remote can reach it'

Assert ($cs -match 'System\.Windows\.Forms') 'it is a WinForms application'
Assert ($cs -match 'LocalApplicationData') 'the engine is extracted under the user profile'
Assert (-not ($cs -match 'Path\.Combine\(StateDir, "engine"\)')) 'and NOT into the machine-wide state directory, which a non-admin can rewrite'
Assert ($cs -match '(?s)ExtractEngine.*?Path\.Combine\(UserDir, "engine"\)') 'ExtractEngine targets UserDir explicitly'

$build = [IO.File]::ReadAllText($builder)
Assert ($build -match '/target:winexe') 'built as a windowed exe'
Assert ($build -match 'System\.Windows\.Forms\.dll') 'and links WinForms'
Assert (-not ($build -match 'gsap|index\.html|app\.css|app\.js')) 'the build embeds no web assets - they are gone'
Assert (-not ($build -match '(?i)requireAdministrator')) 'the exe does not demand elevation to start'
Assert ((Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -match 'dist/') 'the built exe is gitignored'

# ---- build and drive it ----------------------------------------------------------
# NOT %TEMP%. On this estate an unsigned binary built into the temp directory is
# quarantined within seconds - measured, not assumed: the build succeeds, the file
# exists, the launch fails with 'Access is denied', and three seconds later the file
# is gone entirely. The same bytes under the repository survive. Building here keeps
# the suite testing the application rather than the endpoint protection policy.
$outDir = Join-Path $root ('dist\.test-' + [Guid]::NewGuid().ToString('N'))
$exe = Join-Path $outDir 'SqlExpressBackup.exe'
$checkFile = Join-Path $outDir 'check.txt'
try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $builder -OutDir $outDir -Quiet 2>&1 | Out-Null
  Assert ($LASTEXITCODE -eq 0) "the build script succeeded (exit $LASTEXITCODE)"
  Assert (Test-Path -LiteralPath $exe) 'it produced SqlExpressBackup.exe'
  Assert ((Get-Item -LiteralPath $exe).Length -gt 60kb) 'and the exe carries the embedded engine'

  # An unsigned, freshly compiled binary that spawns elevated PowerShell is close to
  # a textbook EDR heuristic, and on this estate CrowdStrike does quarantine it. When
  # that happens the failure downstream is a baffling "Access is denied" from
  # Start-Process, so name it here instead of letting it masquerade as a bug.
  Start-Sleep -Milliseconds 400
  Assert (Test-Path -LiteralPath $exe) 'the exe still exists a moment after building (if this fails, EDR quarantined it)'

  $proc = $null
  try {
    $proc = Start-Process -FilePath $exe -ArgumentList '--check', "`"$checkFile`"" -PassThru -Wait -ErrorAction Stop
  }
  catch {
    $why = $_.Exception.Message
    # Look again, and look a moment later. Quarantine is not instantaneous: the file
    # can still be on disk when the launch is refused and be gone shortly after, so a
    # single check at the moment of failure reports 'Access is denied' and hides the
    # real cause.
    $goneNow = -not (Test-Path -LiteralPath $exe)
    Start-Sleep -Milliseconds 2500
    $goneAfter = -not (Test-Path -LiteralPath $exe)
    if ($goneNow -or $goneAfter) {
      throw ("FAIL: the exe was REMOVED after being built - endpoint protection quarantined it, " +
             "which is not a defect in the application. It is the unsigned-binary risk: this host " +
             "runs CrowdStrike Falcon and Defender, and an unsigned executable is deleted from some " +
             "locations within seconds of being written. Signing it, or excluding the build " +
             "location, is the fix. Original error: $why")
    }
    # Present but refusing to start is the SAME cause wearing a different hat: the
    # agent blocks execution instead of deleting the file. Both shapes are endpoint
    # protection reacting to an unsigned binary, and reporting the second as a plain
    # launch failure sends the next reader hunting for a bug in the application.
    if ($why -match 'Access is denied') {
      throw ("FAIL: the exe was built but refused permission to START. On this host that is " +
             "endpoint protection blocking an unsigned binary rather than a defect in the " +
             "application - the same cause as outright quarantine, which this suite has also " +
             "observed. It is intermittent and tracks antivirus definition updates. Signing the " +
             "exe, or excluding the build location, is the fix. Original error: $why")
    }
    throw "FAIL: could not launch the exe: $why"
  }
  Assert ($proc.ExitCode -eq 0) "--check exited 0 (got $($proc.ExitCode))"
  Assert (Test-Path -LiteralPath $checkFile) 'and wrote its findings'

  # The progress arithmetic, exercised in the REAL compiled binary rather than
  # reimplemented here. It runs without a window, a database or a backup, so it can
  # be asserted every run - and it is the arithmetic behind the bar an operator uses
  # to decide whether a job is stuck.
  $progFile = Join-Path $outDir 'progress.txt'
  $pp = Start-Process -FilePath $exe -ArgumentList '--check-progress', "`"$progFile`"" -PassThru -Wait -ErrorAction Stop
  Assert (Test-Path -LiteralPath $progFile) '--check-progress wrote its findings'
  $prog = Get-Content -LiteralPath $progFile -Raw
  $progPass = @([regex]::Matches($prog, '(?m)^PASS ')).Count
  $progFail = @([regex]::Matches($prog, '(?m)^FAIL ')).Count
  Assert ($progPass -gt 12) "the progress checks actually ran (got $progPass assertions) - a mode that silently does nothing would otherwise pass here"
  Assert ($progFail -eq 0) ("every progress assertion held (failed: " + (($prog -split "`r?`n" | Where-Object { $_ -like 'FAIL *' }) -join '; ') + ")")
  Assert ($prog -match 'PROGRESS-OK') 'and the run reported OK overall'
  Assert ($pp.ExitCode -eq 0) "--check-progress exited 0 (got $($pp.ExitCode))"

  # The specific defect this replaced: a finished job drew an EMPTY bar, so success
  # and never-started were indistinguishable. Pinned by name so it cannot regress
  # quietly into 'the bar is blank again'.
  Assert ($prog -match 'PASS finished is one') 'a finished job reports 100 percent, not a blank bar'
  Assert ($prog -match 'PASS and the monotonic clamp stops it') 'and the bar cannot walk backwards'

  $report = Get-Content -LiteralPath $checkFile -Raw
  Assert ($report -match 'CHECK-OK') "the smoke check reported OK ($($report -replace "`r?`n", ' | '))"
  Assert ($report -match 'engine-exists: true') 'the engine was extracted'
  Assert ($report -match 'form-built: true') 'the window was constructed - the layout does not throw'
  Assert ($report -match 'restore-form-built: true') 'and so was the RESTORE window - it can destroy a database, so its layout must not be the first thing anyone runs'
  Assert ($report -match ('host: ' + [regex]::Escape($env:COMPUTERNAME))) 'it identified this host'

  # The escalation guard, checked against the path it actually used rather than the
  # source that claims it.
  $enginePath = ([regex]::Match($report, 'engine: (.+)')).Groups[1].Value.Trim()
  Assert ($enginePath -like (Join-Path $env:LOCALAPPDATA '*')) "the engine lives under the user profile, not ProgramData (got '$enginePath')"
  Assert ($enginePath -notlike (Join-Path $env:ProgramData '*')) 'and definitely not where a SYSTEM task would run something a user can rewrite'
}
finally {
  Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'ALL PASS'
