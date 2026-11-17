# Portable Windows Build Collection

> **New:** [Portable Factory v1](docs/portable-factory/README.md) — common CI framework for multiple desktop applications. Use [Actions → Portable Factory - Build App](../../actions/workflows/portable-factory.yml) with `app_id=orca` or `t3code`. The existing standalone workflows remain available during migration.

## Legacy T3 Code workflow

GitHub Actions build of the upstream [T3 Code](https://github.com/pingdotgg/t3code) desktop app for **Windows x64**, using electron-builder's `portable` target. This repository contains the **packaging workflow only**; it does not fork or modify the T3 Code application source.

## Download

1. Open [Actions → Build T3 Code Portable (Windows x64)](../../actions/workflows/build-portable.yml).
2. Open the most recent successful run.
3. Download the `T3-Code-Portable-Windows-x64` artifact.
4. Extract the Actions artifact ZIP.
5. Run `T3-Code-Portable-x64.exe` directly (no installer).

For an **opt-in local data directory**, run `Run-T3Code-Portable.cmd` from the same folder as the executable instead. This sets `T3CODE_HOME`, `APPDATA`, and `LOCALAPPDATA` to paths under `Data/`, and disables auto-updates. Back up the folder if using it for real projects.

> Portable executable does **not** mean every dependency or credential is portable. T3 Code relies on coding-agent CLIs or managed runtimes, provider authentication, Git, and other OS facilities. Windows-protected credentials may remain machine-specific. WSL features require the separate Linux runtime bundled in the upstream release pipeline; this workflow does not currently bundle it.

## Build

The workflow runs automatically when the workflow file itself changes on `main`. To run another build:

1. Visit [Run workflow](../../actions/workflows/build-portable.yml) and select **Run workflow**.
2. Set `upstream_ref` to a T3 Code release tag (default: `v0.1.9`), a full commit SHA, or `main`.
3. The workflow fetches the selected upstream source and runs:

   ```powershell
   vp install
   vp run dist:desktop:artifact --platform win --target portable --arch x64 --output-dir release-portable --verbose
   ```

4. It checks that exactly one x64 executable was produced, creates a SHA-256 checksum and `BUILD-INFO.txt`, and uploads the artifact. Artifacts are kept for **14 days**.

For reproducible builds, prefer an immutable tag or a full commit SHA over `main`. Source SHA is recorded in `BUILD-INFO.txt`.

## Output

```text
T3-Code-Portable-Windows-x64 (Actions artifact)
├── T3-Code-Portable-x64.exe
├── Run-T3Code-Portable.cmd
├── BUILD-INFO.txt
└── SHA256SUMS.txt
```

## Limitations and safety

- Windows x64 only; currently unsigned. Windows SmartScreen may show a warning for unrecognized executables.
- No Windows installer is created. The app is packaged from upstream source, not from an externally downloaded installer.
- A build success verifies packaging and basic Windows native loading checks in the upstream build script; it **does not** replace end-to-end GUI smoke testing on a clean Windows machine.
- `T3CODE_DISABLE_AUTO_UPDATE` is set by the local-data launcher. Running the EXE directly uses the app's normal settings.
- Optional `Data/` redirection covers T3 and Electron profile paths but not every agent's installation or OS credential store.
- No GitHub token or signing secrets are passed to the upstream build. Workflow permissions are `contents: read`.

All T3 Code source code remains subject to the upstream project's [MIT license](https://github.com/pingdotgg/t3code/blob/main/LICENSE).

---


### If the single EXE opens no window

The self-extracting `portable` target launches Orca from a temporary directory. Some systems may fail during its startup or block its unsigned binary. We also publish an **unpacked folder ZIP** (`Orca-Portable-Folder-Windows-x64`) as an alternative.

1. Download that artifact from the latest successful build and extract the GitHub Actions artifact ZIP.
2. Extract the inner `Orca-Portable-<version>-Windows-x64-folder.zip` into a normal writable directory, such as `D:\\Apps\\OrcaPortable`.
3. Start `Orca.exe` inside the extracted directory. Keep the `resources/`, DLLs, and other folders alongside it.

Do not run `Orca.exe` from inside the ZIP viewer. If Windows flags a downloaded unsigned executable, check Windows Security's protection history before deciding whether it is trusted; do not disable antivirus protections.

Troubleshooting from PowerShell, in the directory containing the EXE:

```powershell
$env:ORCA_STARTUP_DIAGNOSTICS = "1"
$env:ORCA_STARTUP_DIAGNOSTICS_FILE = "$PWD\\orca-startup.log"
.\\Orca.exe --enable-logging
```

Only share a sanitized log; traces can contain paths, workspace metadata, and other local details. A successful packaging job by itself is not proof that a desktop window opens.

## Orca portable (Windows x64)

Source: [stablyai/orca](https://github.com/stablyai/orca), the open-source multi-agent development environment.

This is an **independent** workflow alongside the T3 Code build. It fetches the selected upstream source and compiles a no-installer, single-file Windows executable with electron-builder's `portable` target.

1. Open [Actions → Build Orca Portable (Windows x64)](../../actions/workflows/build-orca-portable.yml).
2. For another version, choose **Run workflow** and enter `upstream_ref`. Default: `v1.4.261` (a known release tag).
3. After the run is **successful**, download the `Orca-Portable-Windows-x64` artifact and unzip it.
4. Start `Orca-Portable-<version>-Windows-x64.exe` directly. No installer is required.

The artifact also contains `SHA256SUMS.txt` and `BUILD-INFO.txt`, including the exact upstream Git SHA. Generated artifacts are retained for 14 days.

**Important:** Portable means the app is runnable without installation. Orca profiles, agent CLI installations, authentication credentials, SSH keys, external tools, and operating-system integration may still use standard Windows profile paths. This workflow does not claim a fully USB-isolated data directory or universal portability of credentials. These builds are **unsigned** and Windows SmartScreen may warn. No upstream code is permanently modified by the workflow; the build is not auto-published to GitHub Releases.

The two app workflows can be run independently, and the ORCA build does not change T3 Code artifacts.
