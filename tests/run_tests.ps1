# Runs every *_test.ps1 in this directory and fails if any test fails. Windows
# counterpart of running the tests/*_test.sh files one by one.
$failed = 0
foreach ($test in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*_test.ps1' | Sort-Object Name)) {
  Write-Output "== $($test.Name)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
  if ($LASTEXITCODE -ne 0) {
    Write-Output "   FAIL ($LASTEXITCODE)"
    $failed++
  }
}
if ($failed -gt 0) {
  Write-Output "$failed test file(s) failed"
  exit 1
}
Write-Output 'all tests passed'
exit 0
