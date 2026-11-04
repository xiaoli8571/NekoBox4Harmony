param(
  [string]$Package = '',
  [string]$Repo = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
  [string]$DevEcoHome = $env:DEVECO_HOME
)
# Pre-upload gate for AppGallery Connect (AGC) -- run this BEFORE uploading a .app.
#
# Why this exists (2026-11-02 incident):
#   uploading dist/NekoBox4Harmony-<ver>-unsigned.app to AGC fails with error 991
#   ("illegal package"). 991 is not a Profile problem (that is 993) and not a zip
#   parser problem (that is 996): it means the package carries no signing block.
#   The unsigned artifact that hvigor's assembleApp produces has no signature at all
#   ("No Hap Signing Block before ZIP Central Directory"), and the AGC release flow
#   additionally needs the INNER HAP signed, not only the outer .app shell.
#   verify-app is the same checker AGC uses, so gate locally instead of guessing.
#
# This script refuses (throws) unless ALL of the following hold:
#   1) file name does not contain "unsigned";
#   2) outer .app verify-app -> success (release signing block present);
#   3) inner HAP verify-app -> success;
#   4) inner HAP module.json: bundleName / versionCode / versionName match
#      AppScope/app.json5, and buildMode=release, debug=false;
#   5) pack.info packages[].name matches the inner HAP file name (else 996 territory).
#
# Usage:
#   pwsh -NoProfile -File scripts/verify-upload-package.ps1
#   pwsh -NoProfile -File scripts/verify-upload-package.ps1 -Package dist/NekoBox-2.7.0-release-signed.app
# Exit 0 = safe to upload; non-zero = DO NOT upload.
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI.
$ErrorActionPreference = 'Stop'
if (-not $DevEcoHome) { $DevEcoHome = 'C:\Program Files\Huawei\DevEco Studio' }
$java = Join-Path $DevEcoHome 'jbr\bin\java.exe'
$tool = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
foreach ($p in @($java, $tool)) {
  if (-not (Test-Path $p)) { throw "missing DevEco file: $p (set DEVECO_HOME)" }
}

$appJson = Get-Content (Join-Path $Repo 'AppScope/app.json5') -Raw
$expCode = [regex]::Match($appJson, '"versionCode":\s*([0-9]+)').Groups[1].Value
$expName = [regex]::Match($appJson, '"versionName":\s*"([^"]+)"').Groups[1].Value
$expBundle = [regex]::Match($appJson, '"bundleName":\s*"([^"]+)"').Groups[1].Value
if (-not $expCode -or -not $expName) { throw 'cannot read versionName/versionCode from AppScope/app.json5' }

if (-not $Package) { $Package = Join-Path $Repo ("dist/NekoBox-" + $expName + '-release-signed.app') }
if (-not (Test-Path $Package)) {
  throw ("package not found: " + $Package + " -- build assembleApp (release) then run scripts/sign-release-agc.ps1")
}
$leaf = Split-Path -Leaf $Package
if ($leaf -match '(?i)unsigned') {
  throw ("REFUSED: '" + $leaf + "' is UNSIGNED -> AGC will answer 991 (illegal package). " +
    "Run: pwsh -File scripts/sign-release-agc.ps1")
}

$work = Join-Path $env:TEMP ('nekobox-gate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work -Force | Out-Null
function Invoke-Verify {
  param([string]$File, [string]$Tag)
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $java -jar $tool verify-app -inFile $File `
      -outCertChain (Join-Path $work ($Tag + '.cer')) -outProfile (Join-Path $work ($Tag + '.p7b')) 2>&1 |
      ForEach-Object { "$_" }
  } finally { $ErrorActionPreference = $eap }
  $ok = @($out | Select-String 'verify-app success').Count -gt 0
  if (-not $ok) {
    ($out | Select-String 'ERROR' | Select-Object -First 6) | ForEach-Object { Write-Host $_.Line }
    throw ("verify-app FAILED for " + (Split-Path -Leaf $File) + " -- do not upload (AGC would reject it)")
  }
  return $out
}

try {
  Write-Host ("gate: " + $leaf)
  Invoke-Verify -File $Package -Tag 'outer' | Out-Null
  Write-Host '  PASS outer .app signature block (release)'

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Package)
  $hapName = $null
  foreach ($e in $zip.Entries) {
    if ($e.FullName -like '*.hap') {
      $hapName = $e.FullName
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $work $hapName), $true)
    }
  }
  $packInfoEntry = $zip.Entries | Where-Object { $_.FullName -eq 'pack.info' } | Select-Object -First 1
  $packInfo = $null
  if ($packInfoEntry) {
    $reader = New-Object System.IO.StreamReader($packInfoEntry.Open())
    $packInfo = $reader.ReadToEnd() | ConvertFrom-Json
    $reader.Close()
  }
  $zip.Dispose()
  if (-not $hapName) { throw 'no .hap inside the .app -- that is not a valid AGC package' }

  $hapPath = Join-Path $work $hapName
  Invoke-Verify -File $hapPath -Tag 'inner' | Out-Null
  Write-Host ('  PASS inner ' + $hapName + ' signature')

  $innerZip = [System.IO.Compression.ZipFile]::OpenRead($hapPath)
  $mjEntry = $innerZip.Entries | Where-Object { $_.FullName -eq 'module.json' } | Select-Object -First 1
  if (-not $mjEntry) { $innerZip.Dispose(); throw 'inner HAP has no module.json' }
  $r2 = New-Object System.IO.StreamReader($mjEntry.Open())
  $moduleJson = $r2.ReadToEnd() | ConvertFrom-Json
  $r2.Close()
  $innerZip.Dispose()

  $app = $moduleJson.app
  $problems = @()
  if ($app.bundleName -ne $expBundle) { $problems += ("bundleName " + $app.bundleName + " != " + $expBundle) }
  if ("$($app.versionCode)" -ne $expCode) { $problems += ("versionCode " + $app.versionCode + " != " + $expCode) }
  if ($app.versionName -ne $expName) { $problems += ("versionName " + $app.versionName + " != " + $expName) }
  if ($app.buildMode -ne 'release') { $problems += ("buildMode " + $app.buildMode + " != release (AppGallery rejects debug builds)") }
  if ($app.debug -ne $false) { $problems += 'debug != false' }
  if ($problems.Count -gt 0) { throw ('inner HAP metadata mismatch: ' + ($problems -join '; ')) }
  Write-Host ('  PASS inner module.json ' + $expBundle + ' ' + $expName + '/' + $expCode + ' buildMode=release debug=false')

  if ($packInfo) {
    $pkgs = @($packInfo.packages)
    $names = @($pkgs | ForEach-Object { $_.name })
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($hapName)
    if (-not ($names -contains $stem)) {
      throw ('pack.info packages[].name = [' + ($names -join ',') + '] does not match inner HAP name "' + $stem +
        '" -- AGC zip parser rejects that (996)')
    }
    Write-Host ('  PASS pack.info package name "' + $stem + '"')
  } else {
    Write-Host '  WARN no pack.info in .app'
  }

  Write-Host ''
  Write-Host ('OK  ' + $leaf + '  version=' + $expName + '/' + $expCode + '  bundle=' + $expBundle)
  Write-Host 'Safe to upload to AGC. Never upload the *-unsigned.app, and never re-upload a stale signed build.'
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
