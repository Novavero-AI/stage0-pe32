# SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional permission under GNU GPL version 3 section 7:
# see LICENSE.EXCEPTION in the root of this project.
#
# Runs kaem's own tests, mescc-tools/Kaem/test, against the kaem.exe the chain
# built, and checks every output against the hashes in test.answers. Each test
# and its flags come from mescc-tools/Kaem/test.sh, read line by line, so a
# test added there runs here too. Run it after x86\mescc-tools-mini.cmd, with
# PowerShell 7:
#
#     pwsh x86\kaem-test.ps1
#
# The tests that run printf find it on the search path. Git for Windows has one
# in its usr\bin, which a default install leaves off the search path.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Some tests expect kaem to fail. Its exit status is checked below, so
# PowerShell must not turn a nonzero one into an error.
$PSNativeCommandUseErrorActionPreference = $false

$artifact = Join-Path $PSScriptRoot 'artifact'
$kaemSource = Join-Path $PSScriptRoot '..\mescc-tools\Kaem'
$work = Join-Path $artifact 'kaem-test'
# test10 starts a second kaem as ../bin/kaem, so bin sits beside the work
# directory, and holds kaem under that bare name as well as kaem.exe.
$bin = Join-Path $artifact 'bin'

# test.sh runs each test with one line of this shape:
#   LANG=C ../bin/kaem [--flag ...] -f "test/testNN/kaem.test" >| "test/results/testNN-output" [2>&1]
$testLine = '^LANG=C \.\./bin/kaem (?:(?<flag>--[a-z-]+) )*-f "(?<script>[^"]+)" >\| "(?<output>[^"]+)"(?<stderr> 2>&1)?$'
# and its other lines are these, none of which runs a test. A line that is
# neither is a change to test.sh this script has to learn about.
$otherLine = '^(#.*|echo "[^"]*"|\. \.\./sha256\.sh|sha256_check test/test\.answers|)$'

# kaem's tests leave it exiting 0, or 1 where a test makes it fail.
# Anything else is a crash, and a crashed kaem leaves an empty output, the same
# as the tests that expect none.
$kaemStatuses = @(0, 1)

$tests = foreach ($line in Get-Content (Join-Path $kaemSource 'test.sh')) {
    $m = [regex]::Match($line, $testLine)
    if ($m.Success) {
        [pscustomobject]@{
            Flags  = @($m.Groups['flag'].Captures | ForEach-Object { $_.Value })
            Script = $m.Groups['script'].Value
            Output = $m.Groups['output'].Value
            Stderr = $m.Groups['stderr'].Success
        }
    } elseif ($line -notmatch $otherLine) {
        throw "mescc-tools/Kaem/test.sh has a line this script does not understand: $line"
    }
}
if (-not $tests) { throw 'mescc-tools/Kaem/test.sh runs no tests' }

Remove-Item -Recurse -Force $work, $bin -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work, $bin | Out-Null
Copy-Item -Recurse (Join-Path $kaemSource 'test') (Join-Path $work 'test')
New-Item -ItemType Directory (Join-Path $work 'test\results') | Out-Null
Copy-Item (Join-Path $artifact 'kaem.exe') (Join-Path $bin 'kaem.exe')
Copy-Item (Join-Path $artifact 'kaem.exe') (Join-Path $bin 'kaem')

$crashed = 0
$mismatched = 0
$savedLang = $env:LANG
$env:LANG = 'C'
Push-Location $work
try {
    foreach ($test in $tests) {
        # cmd.exe, not PowerShell, does the redirection: it writes kaem's
        # bytes to the file unchanged. /d keeps AutoRun commands out of it.
        $command = @('..\bin\kaem.exe') + $test.Flags + @('-f', $test.Script, '>', ($test.Output -replace '/', '\'))
        if ($test.Stderr) { $command += '2>&1' }
        cmd /d /c ($command -join ' ')
        $status = $LASTEXITCODE
        if ($kaemStatuses -notcontains $status) {
            "CRASH $($test.Output): kaem exited with {0} (0x{0:x8})" -f $status
            $crashed++
        }
    }

    foreach ($line in Get-Content 'test\test.answers') {
        $want, $file = $line -split '\s+', 2
        $got = (Get-FileHash -Algorithm SHA256 $file).Hash
        if ($got -eq $want) {
            "ok    $file"
        } else {
            "FAIL  $file"
            "      expected $want"
            "      got      $($got.ToLowerInvariant()), from:"
            Get-Content -Raw $file
            $mismatched++
        }
    }
} finally {
    Pop-Location
    $env:LANG = $savedLang
}

if ($crashed + $mismatched -ne 0) {
    throw "kaem's tests failed: $crashed crashed, $mismatched did not match test.answers"
}
# The hashes and exit statuses are the verdict. $LASTEXITCODE still holds the
# last kaem run's status, which a test that expects kaem to fail would leave
# nonzero.
exit 0
