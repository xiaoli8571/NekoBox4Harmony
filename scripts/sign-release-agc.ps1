param(
  [string]$SourceRepo = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
  [string]$ProfileName = 'NekoBoxRelease.p7b',
  [string]$CertDir = '',
  [string]$OutSuffix = 'release-signed',
  [switch]$SkipVerifyFingerprint
)
# Sign a freshly built UNSIGNED NekoBox .app (official hvigor assembleApp skeleton) with
# the AGC shared release material, verifying BOTH layers, and publish to dist\.
#
# Why this exists instead of just using hvigor's own signingConfigs: build-profile.json5
# holds a machine-local DEBUG signing config. assembleHap/assembleApp therefore produce
# DEBUG-signed artifacts, which install fine over hdc but are rejected by AppGallery
# ("detected as a debug build"). Distribution packages must be signed with the AGC
# release certificate. This script reproduces the workflow that produced the delivered
# 2.1.6 / 2.1.7 / 2.1.8 / 2.1.9 .app files (based on FormatGo\sign-formatgo-package.ps1).
#
# Material (NOT in the repo; located by auto-detect under C:\Worker unless -CertDir given):
#   <CertDir>\General.p12          keystore, alias "general" (private key)
#   <CertDir>\General.cer          AGC release certificate chain (applied from General.csr)
#   <CertDir>\NekoBoxRelease.p7b   release profile for com.nekobox.app.jynxen
# Password comes from env AGC_KEY_PASSWORD only -- never written to disk or the repo.
#
# NOTE: keep this file ASCII-only -- Windows PowerShell 5.1 reads .ps1 as ANSI and
# mangles non-ASCII literals. Run it with pwsh 7 or Windows PowerShell.
$ErrorActionPreference = 'Stop'
$java = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe'
$tool = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$project = $SourceRepo
$appJson = Get-Content (Join-Path $project 'AppScope/app.json5') -Raw
$versionName = [regex]::Match($appJson, '"versionName":\s*"([^"]+)"').Groups[1].Value
$versionCode = [regex]::Match($appJson, '"versionCode":\s*([0-9]+)').Groups[1].Value
if (-not $versionName) { throw 'cannot read versionName from AppScope/app.json5' }
$dist = Join-Path $SourceRepo 'dist'
New-Item -ItemType Directory $dist -Force | Out-Null

function Invoke-SignTool {
  param([string[]]$ToolArgs)
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $script:toolLines = & $java -jar $tool @ToolArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $eap }
  if ($code -ne 0) {
    ($script:toolLines | Select-String 'ERROR' | Select-Object -First 8) | ForEach-Object { Write-Host $_.Line }
    throw ("sign tool failed (exit " + $code + '): ' + $ToolArgs[0])
  }
  return $script:toolLines
}

if (-not $env:AGC_KEY_PASSWORD) { throw 'Set AGC_KEY_PASSWORD locally before running.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path $env:TEMP ('nekobox-sign-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work -Force | Out-Null
try {
  # The certificate directory name is Chinese, so it is never spelled out as a literal --
  # that keeps this file ASCII-only and encoding-proof.
  if (-not $CertDir) {
    $hit = @(Get-ChildItem 'C:\Worker' -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName 'General.p12') })
    if ($hit.Count -eq 0) { throw 'cannot locate the AGC certificate directory under C:\Worker (no General.p12 found); pass -CertDir' }
    if ($hit.Count -gt 1) { throw 'multiple certificate directories contain General.p12; pass -CertDir explicitly' }
    $CertDir = $hit[0].FullName
  }
  $keystore = Join-Path $CertDir 'General.p12'
  $profile = Join-Path $CertDir $ProfileName
  if (-not (Test-Path $keystore)) { throw "missing keystore: $keystore" }
  if (-not (Test-Path $profile)) { throw "missing profile: $profile" }
  $appCert = @(Get-ChildItem (Join-Path $CertDir '*.cer') -File | Select-Object -First 1).FullName
  if (-not $appCert) { throw ('missing app cert in ' + $CertDir) }

  $workKeystore = Join-Path $work 'sign.p12'
  Copy-Item $keystore $workKeystore -Force
  $common = @('-mode','localSign','-keyAlias','general','-keyPwd',$env:AGC_KEY_PASSWORD,
    '-keystorePwd',$env:AGC_KEY_PASSWORD,'-signAlg','SHA256withECDSA',
    '-appCertFile',$appCert,'-profileFile',$profile,'-keystoreFile',$workKeystore)

  $inApp = @(Get-ChildItem (Join-Path $project 'build/outputs/default') -Filter '*-unsigned.app' -File | Select-Object -First 1).FullName
  if (-not $inApp) { throw "missing unsigned app under $project\build\outputs\default (run assembleApp first)" }
  Write-Host ("unsigned .app: " + $inApp)

  $outApp = Join-Path $dist ("NekoBox-$versionName-$OutSuffix.app")
  $outHap = Join-Path $dist ("NekoBox-$versionName-$OutSuffix.hap")

  $payload = Join-Path $work 'payload'
  New-Item -ItemType Directory $payload -Force | Out-Null
  [System.IO.Compression.ZipFile]::ExtractToDirectory($inApp, $payload)
  $haps = @(Get-ChildItem $payload -Filter '*.hap' -File)
  if ($haps.Count -ne 1) { throw ('Expected exactly one HAP in app pack, found ' + $haps.Count) }
  $innerHap = $haps[0].FullName

  # The .app skeleton ships the HAP *unsigned*; read minAPIVersion from it before signing.
  $zip = [System.IO.Compression.ZipFile]::OpenRead($innerHap)
  try {
    $reader = [System.IO.StreamReader]::new($zip.GetEntry('module.json').Open())
    try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
  } finally { $zip.Dispose() }
  $api = [string]$module.app.minAPIVersion
  if (-not $api) { throw 'Missing minAPIVersion' }
  $buildMode = [string]$module.app.buildMode
  Write-Host ("inner HAP: minAPIVersion=$api buildMode=$buildMode versionName=" + $module.app.versionName)
  if ($buildMode -ne 'release') { throw ("inner HAP buildMode is '$buildMode', expected 'release' -- rebuild with -p buildMode=release") }

  # Layer 1: inner HAP, with -compatibleVersion pinned to the module's minAPIVersion.
  Invoke-SignTool (@('sign-app') + $common + @('-compatibleVersion', $api, '-inFile', $innerHap, '-outFile', $innerHap)) | Out-Null
  Invoke-SignTool @('verify-app','-inFile',$innerHap,'-outCertChain',(Join-Path $work 'hap-cert.cer'),'-outProfile',(Join-Path $work 'hap-profile.p7b')) | Out-Null
  Write-Host 'inner HAP: signed + verified'
  Copy-Item $innerHap $outHap -Force

  # Layer 2: repack (includeBaseDirectory=false keeps entry-default.hap at the root) then sign the shell.
  $repacked = Join-Path $work 'repacked.app'
  [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $repacked, [System.IO.Compression.CompressionLevel]::Optimal, $false)
  Invoke-SignTool (@('sign-app') + $common + @('-inFile', $repacked, '-outFile', $outApp)) | Out-Null
  Invoke-SignTool @('verify-app','-inFile',$outApp,'-outCertChain',(Join-Path $work 'app-cert.cer'),'-outProfile',(Join-Path $work 'app-profile.p7b')) | Out-Null
  Write-Host '.app shell: signed + verified'

  # Fingerprint assertion: verify-app only checks structure and digest -- it passes even
  # for a debug certificate (it reports the chain from the profile). Compare the OUTER
  # leaf against the AGC release cert to prove the release key really signed it.
  if (-not $SkipVerifyFingerprint) {
    $kt = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin\keytool.exe'
    if (-not (Test-Path $kt)) { throw "missing keytool: $kt" }
    function Get-Fingerprints {
      param([string]$Cer)
      $out = & $kt -printcert -file $Cer 2>&1 | ForEach-Object { "$_" }
      $lines = @($out | Select-String 'SHA256:')
      # Collapse each "SHA256: AA:BB:.." to just the hex, then sort for set comparison.
      return @($lines | ForEach-Object { (($_ -split 'SHA256:')[1]).Trim() } | Sort-Object -Unique)
    }
    $expect = @(Get-Fingerprints $appCert)
    if ($expect.Count -eq 0) { throw 'could not read release certificate fingerprint' }
    foreach ($layer in @(@('outer .app', (Join-Path $work 'app-cert.cer')), @('inner HAP', (Join-Path $work 'hap-cert.cer')))) {
      $got = @(Get-Fingerprints $layer[1])
      if ($got.Count -eq 0) { throw ("could not read " + $layer[0] + ' certificate chain') }
      $diff = @($expect | Where-Object { $got -notcontains $_ })
      if ($diff.Count -gt 0) {
        throw ($layer[0] + ' was NOT signed with the AGC release certificate -- missing fingerprint(s) ' + ($diff -join ',') + '; got ' + ($got -join ','))
      }
      Write-Host ($layer[0] + ': release certificate chain confirmed')
    }
    Write-Host ('release cert fingerprints: ' + ($expect -join ' '))
  }

  Write-Host ''
  Get-FileHash $outApp, $outHap -Algorithm SHA256 | ForEach-Object { Write-Host ($_.Hash + '  ' + $_.Path) }
  Write-Host ''
  Write-Host ("DONE  " + $outApp)
  Write-Host ("DONE  " + $outHap)
} finally {
  $common = $null
  Remove-Item Env:AGC_KEY_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
