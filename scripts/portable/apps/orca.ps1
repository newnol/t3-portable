# Portable Factory adapter: stablyai/orca (Windows x64).
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
  $version = [string](Get-Content package.json -Raw | ConvertFrom-Json).version
  if ($SourceRef -match '^v[0-9]+[.][0-9]+[.][0-9]+$' -and $SourceRef.Substring(1) -ne $version) {
    throw "Selected upstream tag $SourceRef does not match Orca package version $version"
  }
  "PORTABLE_APP_VERSION=$version" >> $env:GITHUB_ENV
  "ORCA_BUILD_COMMIT=$SourceSha" >> $env:GITHUB_ENV
  $env:ORCA_BUILD_COMMIT = $SourceSha
  $env:ORCA_REQUIRE_ORCAD_TEMPLATE = '0'
  $env:NODE_OPTIONS = '--max-old-space-size=4096'
  $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
  $env:CI = 'true'

  pnpm install --frozen-lockfile
  Assert-Exit 'pnpm install'
  pnpm -C mobile install --frozen-lockfile
  Assert-Exit 'pnpm mobile install'
  pnpm run build:release
  Assert-Exit 'pnpm build:release'
  pnpm run ensure:electron-runtime
  Assert-Exit 'pnpm ensure:electron-runtime'
  pnpm exec electron-builder --config config/electron-builder.config.cjs --win portable zip --x64 --publish never --config.directories.output=dist-portable
  Assert-Exit 'electron-builder portable and zip'

  $dir = Join-Path $SourceDir 'dist-portable'
  $exe = @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File)
  $zip = @(Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File)
  if ($exe.Count -ne 1 -or $zip.Count -ne 1) { throw "Expected one portable EXE and one folder ZIP; got $($exe.Count) exe, $($zip.Count) zip" }
  if (-not (Test-Path (Join-Path $dir 'win-unpacked/Orca.exe'))) { throw 'Orca.exe missing from win-unpacked' }
  Copy-Item -LiteralPath $exe[0].FullName -Destination (Join-Path $OutputDir "Orca-$version-Windows-x64-portable.exe") -ErrorAction Stop
  Copy-Item -LiteralPath $zip[0].FullName -Destination (Join-Path $OutputDir "Orca-$version-Windows-x64-folder.zip") -ErrorAction Stop
  Write-Host "Staged Orca portable v$version with EXE and folder ZIP"
} finally {
  Pop-Location
}
