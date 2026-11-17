# Shared Portable Factory gate. GitHub Actions itself creates one downloadable ZIP
# containing the native app folder, so users only extract the artifact once.
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

# Contract: portable-output/<app-id>/App.exe, *.dll, resources/, etc.
# No nested ZIP, no NSIS portable self-extractor and no installer.
if (@($manifest.formats).Count -ne 1 -or $manifest.formats[0] -ne 'folder') {
  throw 'Registered app must produce exactly one unpacked folder'
}
$payload = Join-Path $OutputDir $AppId
if (-not (Test-Path -LiteralPath $payload -PathType Container)) {
  throw "Missing extracted application folder: $payload"
}
$folders = @(Get-ChildItem -LiteralPath $OutputDir -Directory)
if ($folders.Count -ne 1 -or $folders[0].Name -ne $AppId) {
  throw "Output must contain one folder named $AppId"
}
if (@(Get-ChildItem -LiteralPath $OutputDir -File).Count -ne 0) {
  throw 'Unexpected root files from adapter; only the app directory is allowed'
}
$rootExecutables = @(Get-ChildItem -LiteralPath $payload -File -Filter '*.exe')
if ($rootExecutables.Count -ne 1) {
  throw "Expected exactly one desktop EXE at the app folder root, found $($rootExecutables.Count)"
}
$resources = Join-Path $payload 'resources/app.asar'
if (-not (Test-Path -LiteralPath $resources -PathType Leaf)) {
  throw 'Electron resources/app.asar missing: cannot start packaged desktop app'
}
$files = @(Get-ChildItem -LiteralPath $payload -File -Recurse -Force)
$nativeDlls = @($files | Where-Object { $_.Extension -eq '.dll' })
if ($nativeDlls.Count -eq 0) {
  throw 'Native Electron DLLs are missing from the unpacked application'
}
$payloadSize = [long]0
foreach ($file in $files) { $payloadSize += $file.Length }
$minSize = [int]$manifest.min_size_mb
if ($payloadSize -lt ($minSize * 1MB)) {
  throw "Unpacked application is smaller than minimum $minSize MiB"
}
Write-Host "Directory payload: $($files.Count) files, $($nativeDlls.Count) DLLs, $([Math]::Round($payloadSize/1MB, 1)) MiB"

$smokeResult = 'not-verified'
$notes = [string]$manifest.smoke.reason
$logDir = Join-Path $env:RUNNER_TEMP 'portable-factory-diagnostics'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if ($manifest.smoke.mode -eq 'folder-process') {
  $expectedExe = [string]$manifest.smoke.executable
  if ($rootExecutables[0].Name -ne $expectedExe) {
    throw "Expected desktop EXE $expectedExe, got $($rootExecutables[0].Name)"
  }
  foreach ($entry in $manifest.smoke.env.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable([string]$entry.Name, [string]$entry.Value, 'Process')
  }
  $startupLog = Join-Path $logDir 'bootstrap.log'
  if ($manifest.smoke.startup_log_env) {
    [Environment]::SetEnvironmentVariable([string]$manifest.smoke.startup_log_env, $startupLog, 'Process')
  }
  $p = Start-Process -FilePath $rootExecutables[0].FullName -WorkingDirectory $payload -PassThru -ErrorAction Stop
  Write-Host "Windows folder smoke: started PID $($p.Id) from $payload"
  Start-Sleep -Seconds ([int]$manifest.smoke.wait_seconds)
  $p.Refresh()
  $live = @(Get-CimInstance Win32_Process -Filter "Name = '$($manifest.smoke.process_name)'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($payload, [StringComparison]::OrdinalIgnoreCase)
  })
  $live | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $logDir 'processes.json') -Encoding utf8
  if ($live.Count -eq 0) { throw 'Windows smoke failed: application process did not remain alive' }
  if ($manifest.smoke.startup_log_marker) {
    if (-not (Test-Path -LiteralPath $startupLog)) { throw 'Electron bootstrap log missing' }
    $bootLog = Get-Content -LiteralPath $startupLog -Raw
    if (-not $bootLog.Contains([string]$manifest.smoke.startup_log_marker)) {
      throw 'Required Electron bootstrap marker missing'
    }
  }
  $smokeResult = 'process-smoke-passed'
  $notes = 'Unpacked app launched on a Windows CI runner and passed its configured process/bootstrap check. Interactive GUI, profile portability, and launch latency on user hardware remain unverified.'
  Write-Host "Folder-process smoke passed: $($live.Count) app processes"
} elseif ($manifest.smoke.mode -eq 'not-verified') {
  Write-Host "::warning::No runtime smoke test for $($AppId): $notes"
} else {
  throw "Unsupported runtime smoke mode $($manifest.smoke.mode)"
}

$version = [string]$env:PORTABLE_APP_VERSION
if (-not $version) { throw 'Build adapter did not set PORTABLE_APP_VERSION' }
$checksumLines = [System.Collections.Generic.List[string]]::new()
foreach ($file in ($files | Sort-Object FullName)) {
  $relative = $file.FullName.Substring($OutputDir.Length).TrimStart([char]'\', [char]'/').Replace('\', '/')
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $checksumLines.Add("$hash  $relative")
}
[System.IO.File]::WriteAllLines(
  (Join-Path $OutputDir 'SHA256SUMS.txt'),
  $checksumLines,
  [System.Text.UTF8Encoding]::new($false)
)
$provenance = [ordered]@{
  schema = 2
  app_id = $manifest.id
  app_name = $manifest.display_name
  app_version = $version
  platform = $manifest.target
  packaging = 'unpacked-folder'
  artifact_extraction_steps = 1
  root_executable = "$AppId/$($rootExecutables[0].Name)"
  payload_file_count = $files.Count
  payload_size_bytes = $payloadSize
  upstream_repository = $manifest.upstream_repo
  upstream_ref = $SourceRef
  upstream_commit = $SourceSha
  factory_commit = $FactorySha
  build_utc = [DateTime]::UtcNow.ToString('o')
  code_signing = 'unsigned'
  profile_isolation = 'not-guaranteed'
  smoke_status = $smokeResult
  smoke_limitations = $notes
}
$provenance | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir 'BUILD-INFO.json') -Encoding utf8
@(
  'One-step unpacked Windows desktop portable.'
  'Extract the GitHub Actions artifact ZIP to a writable directory. Then run:'
  "  $AppId/$($rootExecutables[0].Name)"
  'Keep the EXE, DLLs, resources and other files in the same app directory.'
  'Never run the executable from inside an archive manager.'
  'The application does not require an installer or a runtime self-extraction step.'
  'Application settings, credentials, CLIs and OS integrations can still use your Windows profile.'
  "Upstream: https://github.com/$($manifest.upstream_repo) @ $SourceSha"
  "Smoke status: $smokeResult"
  "Limitations: $notes"
  'Unsigned binaries may trigger Windows SmartScreen. Do not disable antivirus protection.'
) | Set-Content -LiteralPath (Join-Path $OutputDir 'PORTABILITY.txt') -Encoding utf8

if ($env:GITHUB_STEP_SUMMARY) {
  @(
    "## $($manifest.display_name) Windows folder portable"
    ''
    '| Field | Value |'
    '| --- | --- |'
    "| Root executable | $AppId/$($rootExecutables[0].Name) |"
    "| Payload | $($files.Count) files / $([Math]::Round($payloadSize/1MB, 1)) MiB |"
    '| Packaging | Folder directly inside one GitHub Actions artifact ZIP |'
    "| Source | $($manifest.upstream_repo) @ $SourceSha |"
    "| Version | $version |"
    "| Runtime smoke | $smokeResult |"
    '| GUI tested | No |'
    '| Signed | No |'
  ) | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
Write-Host "Folder payload verified, file checksums and BUILD-INFO.json recorded."
