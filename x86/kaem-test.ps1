# Runs kaem's own tests, mescc-tools/Kaem/test, against the kaem.exe the chain
# built, the way mescc-tools/Kaem/test.sh runs them, and checks every output
# against the hashes in test.answers. Run it after x86\mescc-tools-mini.cmd.
# Four of the tests run printf, which kaem finds on the search path; Git for
# Windows provides one.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$artifact = Join-Path $PSScriptRoot 'artifact'
$suite = Join-Path $PSScriptRoot '..\mescc-tools\Kaem\test'
$work = Join-Path $artifact 'kaem-test'
# test10 starts a second kaem as ../bin/kaem, so bin sits beside the work
# directory, and holds kaem under that bare name as well as kaem.exe.
$bin = Join-Path $artifact 'bin'

# test.sh passes --non-strict to these, and sends stderr to the output too
# for those.
$nonStrict = @('05', '19')
$withStderr = @('04', '06', '14')

Remove-Item -Recurse -Force $work, $bin -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work, $bin | Out-Null
Copy-Item -Recurse $suite (Join-Path $work 'test')
New-Item -ItemType Directory (Join-Path $work 'test\results') | Out-Null
Copy-Item (Join-Path $artifact 'kaem.exe') (Join-Path $bin 'kaem.exe')
Copy-Item (Join-Path $artifact 'kaem.exe') (Join-Path $bin 'kaem')

Push-Location $work
try {
    foreach ($n in 0..20 | ForEach-Object { '{0:d2}' -f $_ }) {
        $mode = if ($nonStrict -contains $n) { '--non-strict -f' } else { '-f' }
        $redirect = "> test\results\test$n-output"
        if ($withStderr -contains $n) { $redirect += ' 2>&1' }
        # cmd.exe, not PowerShell, does the redirection: it writes kaem's
        # bytes to the file unchanged. Exit codes are not checked, as in
        # test.sh, where some of the tests expect kaem to fail.
        cmd /c "..\bin\kaem.exe $mode test/test$n/kaem.test $redirect"
    }

    $failed = 0
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
            $failed++
        }
    }
} finally {
    Pop-Location
}

if ($failed -ne 0) { throw "$failed of kaem's tests failed" }
# The hashes are the verdict. $LASTEXITCODE still holds the last kaem run's
# status, which a test that expects kaem to fail would leave nonzero.
exit 0
