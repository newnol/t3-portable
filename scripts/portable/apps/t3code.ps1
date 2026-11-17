# Portable Factory adapter: pingdotgg/t3code (Windows x64).
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$OutputDir,
  [Parameter(Mandatory)][string]$SourceRef,
  [Parameter(Mandatory)][string]$SourceSha
)
$ErrorActionPreference = 'Stop'
$SourceDir = (Resolve-Path $SourceDir).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
function Assert-Exit([string]$Step) {
  if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit code $LASTEXITCODE)" }
}
Push-Location $SourceDir
try {
  $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
  $env:T3CODE_DISABLE_AUTO_UPDATE = 'true'
  $env:CI = 'true'
  vp install
  Assert-Exit 'vp install'
  
  # Upstream NSIS size policy expects <80 unpacked files. The portable
  # target observed 89 files on v0.1.9. Patch only that call site, fail closed
  # when upstream changes, and retain all native/runtime validation checks.
  $script = (Resolve-Path 'scripts/build-desktop-artifact.ts').Path
  $source = [System.IO.File]::ReadAllText($script).Replace("`r`n", "`n")
  $needle = "      targetArch: options.arch,`n      appVersion,`n      expectWslRuntime:"
  $replacement = "      targetArch: options.arch,`n      appVersion,`n      fileLimit: options.target === `"zip`" ? 100 : undefined,`n      expectWslRuntime:"
  if (-not $source.Contains($needle) -or $source.IndexOf($needle) -ne $source.LastIndexOf($needle)) {
    throw 'T3 Code upstream validator changed; review portable compatibility patch'
  }
  [System.IO.File]::WriteAllText($script, $source.Replace($needle, $replacement), [System.Text.UTF8Encoding]::new($false))
  
  $version = [string](Get-Content 'apps/desktop/package.json' -Raw | ConvertFrom-Json).version
  $versionArgs = @()
  if ($SourceRef -match '^v([0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?)$') {
    $version = $Matches[1]
    $versionArgs = @('--build-version', $version)
  }
  "PORTABLE_APP_VERSION=$version" >> $env:GITHUB_ENV
  # The upstream build script performs native/runtime validation, then
  # packages an ordinary ZIP. Expanding it now avoids any runtime unpack step.
  vp run dist:desktop:artifact --platform win --target zip --arch x64 --output-dir release-folder --verbose @versionArgs
  Assert-Exit 'vp Windows folder ZIP artifact'
  $dir = Join-Path $SourceDir 'release-folder'
  $archive = @(Get-ChildItem -LiteralPath $dir -File -Filter 'T3-Code-*-x64.zip')
  if ($archive.Count -ne 1) { throw "Expected one Windows desktop ZIP, found $($archive.Count)" }
  $target = Join-Path $OutputDir 't3code'
  if (Test-Path $target) { throw 'Output folder already exists; refusing to mix builds' }
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Expand-Archive -LiteralPath $archive[0].FullName -DestinationPath $target -Force
  $exes = @(Get-ChildItem -LiteralPath $target -File -Filter '*.exe')
  if ($exes.Count -ne 1) { throw "Expected one root desktop executable, found $($exes.Count)" }
  if (-not (Test-Path (Join-Path $target 'resources/app.asar'))) {
    throw 'T3 Code desktop ZIP missing resources/app.asar'
  }
  Write-Host "Staged T3 Code $version as an unpacked folder ($($exes[0].Name) plus DLLs/resources); GUI not verified"
} finally {
  Pop-Location
}
