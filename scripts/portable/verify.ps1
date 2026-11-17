# Shared Portable Factory artifact gate: structure, SHA-256, provenance, Windows process smoke.
param(
  [Parameter(Mandatory)][string]$AppId,
  [Parameter(Mandatory)][string]$OutputDir,
  [Parameter(Mandatory)][string]$SourceRef,
  [Parameter(Mandatory)][string]$SourceSha,
  [Parameter(Mandatory)][string]$FactorySha
)
$ErrorActionPreference = 'Stop'
$factory = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifest = Get-Content (Join-Path $factory "apps/$AppId.json") -Raw | ConvertFrom-Json
$OutputDir = (Resolve-Path $OutputDir).Path
$binary = @(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object { $_.Extension -in @('.exe', '.zip') })
$formats = @($manifest.formats)
$expectedCount = $formats.Count
if ($binary.Count -ne $expectedCount) {
  throw "Artifact count mismatch: expected $expectedCount ($($formats -join ',')), got $($binary.Count)"
}
foreach ($format in $formats) {
  $extension = if ($format -eq 'exe') { '.exe' } else { '.zip' }
  $matches = @($binary | Where-Object { $_.Extension -eq $extension })
  if ($matches.Count -ne 1) { throw "Expected one .$format artifact" }
  if ($matches[0].Length -lt 50MB) { throw "Artifact $($matches[0].Name) is unexpectedly small" }
}
$smokeResult = 'not-verified'
$notes = [string]$manifest.smoke.reason
$logDir = Join-Path $env:RUNNER_TEMP 'portable-factory-diagnostics'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if ($manifest.smoke.mode -eq 'folder-process') {
  $archive = @($binary | Where-Object Extension -eq '.zip')[0]
  Add-Type -AssemblyName System.IO.Compression
  $zip = [System.IO.Compression.ZipFile]::OpenRead($archive.FullName)
  try {
    $expectedExe = [string]$manifest.smoke.executable
    $exeEntries = @($zip.Entries | Where-Object { $_.FullName.Replace('\\','/') -eq $expectedExe })
    if ($exeEntries.Count -ne 1) { throw "ZIP must contain exactly one root $expectedExe" }
  } finally {
    $zip.Dispose()
  }
  $unpack = Join-Path $env:RUNNER_TEMP "portable-factory-smoke-$AppId"
  if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
  Expand-Archive -LiteralPath $archive.FullName -DestinationPath $unpack -Force
  $exePath = Join-Path $unpack $expectedExe
  if (-not (Test-Path $exePath)) { throw 'Unpacked app executable is missing' }
  $env:ORCA_BACKGROUND_LAUNCH = '1'
  $env:ORCA_STARTUP_DIAGNOSTICS = '1'
  $env:ORCA_STARTUP_DIAGNOSTICS_FILE = Join-Path $logDir 'bootstrap.log'
  $env:ORCA_DIAGNOSTICS_TOKEN_URL = ''
  $process = Start-Process -FilePath $exePath -WorkingDirectory $unpack -PassThru -ErrorAction Stop
  Write-Host "Windows smoke: started $exePath (PID $($process.Id))"
  Start-Sleep -Seconds ([int]$manifest.smoke.wait_seconds)
  $process.Refresh()
  $live = @(Get-CimInstance Win32_Process -Filter "Name = '$($manifest.smoke.process_name)'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($unpack, [StringComparison]::OrdinalIgnoreCase)
  })
  $live | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath | ConvertTo-Json -Depth 4 |
    Set-Content -Path (Join-Path $logDir 'processes.json') -Encoding utf8
  if ($live.Count -eq 0) { throw 'Windows startup smoke failed: no unpacked app process survived' }
  if (-not (Test-Path $env:ORCA_STARTUP_DIAGNOSTICS_FILE)) {
    throw 'Windows smoke did not reach Orca Electron bootstrap'
  }
  $bootLog = Get-Content -LiteralPath $env:ORCA_STARTUP_DIAGNOSTICS_FILE -Raw
  if (-not $bootLog.Contains('[bootstrap] bundle-enter')) {
    throw 'Windows smoke did not enter the Orca bootstrap bundle'
  }
  $smokeResult = 'process-smoke-passed'
  $notes = 'A Windows CI runner started the unpacked application and observed its bootstrap and live process. GUI visibility and user settings are not verified.'
  Write-Host "Windows smoke passed: $($live.Count) app processes"
  # The Windows runner is disposable; allow Actions to clean up child processes.
} elseif ($manifest.smoke.mode -eq 'not-verified') {
  Write-Host "::warning::No runtime smoke test for $AppId: $notes"
} else {
  throw "Unknown smoke mode $($manifest.smoke.mode)"
}

$version = $env:PORTABLE_APP_VERSION
if (-not $version) { throw 'Build adapter did not report PORTABLE_APP_VERSION' }
$checksums = foreach ($file in ($binary | Sort-Object Name)) {
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  "$hash  $($file.Name)"
}
[System.IO.File]::WriteAllLines((Join-Path $OutputDir 'SHA256SUMS.txt'), [string[]]$checksums, [System.Text.Encoding]::ASCII)
$record = [ordered]@{
  schema = 1
  app_id = $manifest.id
  app_name = $manifest.display_name
  app_version = $version
  platform = $manifest.target
  upstream_repository = $manifest.upstream_repo
  upstream_ref = $SourceRef
  upstream_commit = $SourceSha
  factory_commit = $FactorySha
  build_utc = [DateTime]::UtcNow.ToString('o')
  formats = $formats
  preferred_format = $manifest.preferred_format
  portability = $manifest.data_portability
  code_signing = 'unsigned'
  smoke_status = $smokeResult
  smoke_limitations = $notes
}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir 'BUILD-INFO.json') -Encoding utf8
@(
  "This application is not an installer."
  "Preferred download: $($manifest.preferred_format)"
  "Portable means no installation; application data, credentials, CLIs and OS integrations may not be portable."
  "Source: https://github.com/$($manifest.upstream_repo) @ $SourceSha"
  "Smoke status: $smokeResult"
  "Limitations: $notes"
  "Unverified unsigned binaries may be flagged by Windows SmartScreen. Never disable antivirus protection to run them."
) | Set-Content -LiteralPath (Join-Path $OutputDir 'PORTABILITY.txt') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) {
  @(
    "## $($manifest.display_name) Windows Portable"
    ""
    "| Field | Value |"
    "| --- | --- |"
    "| Source | $($manifest.upstream_repo) @ $SourceSha |"
    "| Version | $version |"
    "| Formats | $($formats -join ', ') |"
    "| Preferred | $($manifest.preferred_format) |"
    "| Runtime check | $smokeResult |"
    "| GUI tested | No |"
    "| Signing | Unsigned |"
  ) | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
Write-Host "Artifacts verified, SHA256SUMS.txt and BUILD-INFO.json recorded."
