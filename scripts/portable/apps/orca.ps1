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
  # Build a standard Electron directory. No NSIS portable wrapper:
  # the user extracts the GitHub artifact once and launches Orca.exe.
  pnpm exec electron-builder --config config/electron-builder.config.cjs --win zip --x64 --publish never --config.directories.output=dist-folder
  Assert-Exit 'electron-builder Windows ZIP / unpacked directory'

  $dist = Join-Path $SourceDir 'dist-folder'
  $unpacked = Join-Path $dist 'win-unpacked'
  if (-not (Test-Path (Join-Path $unpacked 'Orca.exe'))) { throw 'Orca.exe missing from win-unpacked' }
  if (-not (Test-Path (Join-Path $unpacked 'resources/app.asar'))) { throw 'Electron app.asar missing from Orca payload' }
  # ORCA's upstream runtime tree can contain SSH library test fixtures.
  # Remove credential-shaped *test fixtures* only. Never remove runtime files.
  $modules = Join-Path $unpacked 'resources/node_modules'
  if (Test-Path -LiteralPath $modules -PathType Container) {
    $fixtureNames = @('.env', '.env.local', '.env.production', '.npmrc', '.pypirc', 'id_rsa', 'id_ed25519')
    $fixtureFolders = @('test', 'tests', '__tests__', 'fixtures')
    $sensitiveFixtures = @(Get-ChildItem -LiteralPath $modules -File -Recurse -Force | Where-Object {
      $relative = $_.FullName.Substring($modules.Length).TrimStart([char]'\', [char]'/').Replace('\', '/').ToLowerInvariant()
      $parts = $relative.Split([char]'/')
      $inTestTree = @($parts | Where-Object { $_ -in $fixtureFolders }).Count -gt 0
      $filename = $_.Name.ToLowerInvariant()
      $inTestTree -and ($filename -in $fixtureNames -or $_.Extension.ToLowerInvariant() -in @('.p12', '.pfx'))
    })
    foreach ($fixture in $sensitiveFixtures) {
      Write-Host "Removing non-runtime test credential fixture: $($fixture.FullName.Substring($modules.Length))"
      Remove-Item -LiteralPath $fixture.FullName -Force -ErrorAction Stop
    }
  }
  $target = Join-Path $OutputDir 'orca'
  if (Test-Path $target) { throw 'Output folder already exists; refusing to mix builds' }
  Copy-Item -LiteralPath $unpacked -Destination $target -Recurse -Force -ErrorAction Stop
  if (-not (Test-Path (Join-Path $target 'Orca.exe'))) { throw 'Failed to stage Orca folder payload' }
  Write-Host "Staged Orca $version as a native directory with DLLs and resources (no runtime extraction)"
} finally {
  Pop-Location
}
