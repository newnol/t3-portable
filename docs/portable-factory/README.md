# Portable Factory v1 — Windows x64

Portable Factory is the **reusable CI/CD foundation** for compiling multiple upstream desktop applications into no-install Windows packages. It does **not** promise user-data isolation, signed binaries, or GUI compatibility just because a build succeeds.

## Architecture

```mermaid
flowchart LR
    A["Workflow dispatch<br/>app_id + optional ref"] --> B["Registry validator<br/>apps/*.json"]
    B --> C["Resolve upstream source<br/>tag or commit -> SHA"]
    C --> D["Windows runner<br/>toolchain + app adapter"]
    D --> E["Package output<br/>EXE / folder ZIP"]
    E --> F["Quality gate<br/>file structure, SHA-256"]
    F --> G{"Runtime smoke policy"}
    G -->|"folder-process"| H["Extract ZIP + launch<br/>process + bootstrap"]
    G -->|"not-verified"| I["Record limitation<br/>no false pass"]
    H --> J["Actions artifact<br/>14 days"]
    I --> J
    J -.-> K["Manual GUI acceptance<br/>before external release"]
```

Legend: solid lines are executed by CI; the dashed line is a **manual quality gate**, not an automated release. The upstream checkout is a separate trust boundary: its build scripts execute on disposable GitHub-hosted Windows runners with read-only repository permissions and no signing secrets.

## How to build any registered app

1. Go to [Actions → Portable Factory - Build App](../../actions/workflows/portable-factory.yml).
2. Choose **Run workflow** on the default branch.
3. Enter `app_id` and optionally `upstream_ref`:
   - `orca` → `stablyai/orca`, default `v1.4.261`
   - `t3code` → `pingdotgg/t3code`, default `v0.1.9`
4. Download the successful artifact named `<app_id>-Portable-Windows-x64`.

Prefer an exact reviewed commit SHA when reproducibility or supply-chain controls matter. A Git tag may be moved by an upstream maintainer. The resolved commit is always written to `BUILD-INFO.json`.

## Quality contract

| Check | Required | Note |
|---|---|---|
| Registry/schema and ref validation | Yes | Unknown apps/ref injection fail before checkout |
| Pin exact Git commit in provenance | Yes | Source repository, requested ref and resolved SHA |
| Build and native dependency validation | Yes | App-specific adapter |
| Output count/format/size and ZIP contents | Yes | Per-app manifest |
| SHA-256 checksum | Yes | `SHA256SUMS.txt` |
| Windows process/boot smoke | Per app | Orca ZIP tested; T3 Code explicitly `not-verified` |
| GUI appearance, login and workflows | Manual | CI runner cannot prove these |
| Code signing | Not yet | Artifacts are unsigned |
| GitHub Release publishing | Disabled | Requires explicit review and a separate approval/signing design |

Package contents include the EXE and/or ZIP plus:
```text
BUILD-INFO.json
SHA256SUMS.txt
PORTABILITY.txt
```

`Orca` prefers the **folder ZIP** because the self-extracting EXE previously failed to open a normal GUI on a Windows runner. Even when CI reports `process-smoke-passed`, this proves only that the unpacked app started as a process and reached the configured bootstrap marker. It does **not** prove an interactive GUI appeared. The app profile and credentials may still use Windows user directories.

## Add another application

1. Create `apps/<id>.json` by copying an existing manifest. Set `id`, `upstream_repo`, `default_ref`, `toolchain`, `formats`, `preferred_format`, `min_size_mb`, `data_portability`, and `smoke`.
2. Add `scripts/portable/apps/<id>.ps1`. The adapter **must accept** `-SourceDir`, `-OutputDir`, `-SourceRef`, `-SourceSha`, and write build packages directly into `OutputDir`. Set `PORTABLE_APP_VERSION=<version>` in `GITHUB_ENV`.
3. Use a supported toolchain (`pnpm-bun-native` or `vite-plus-rust`) or add an explicitly reviewed setup branch in `_portable-windows.yml` and extend `resolve.py`'s `TOOLCHAINS`.
4. Define `smoke.mode`: `folder-process` for a ZIP with a resident EXE, or `not-verified` with a clear reason. To test startup logs, supply optional `startup_log_env` and `startup_log_marker`; `env` defines launcher environment variables without hard-coding app logic.
5. Open a PR. `check-portable-factory.yml` checks every manifest, adapter syntax and GitHub Actions YAML. After review, use the new `app_id` through the same manual dispatcher. No new workflow YAML is needed for apps using an existing toolchain.

A typical app manifest:

```json
{
  "id": "example",
  "display_name": "Example",
  "upstream_repo": "example/example",
  "default_ref": "v1.0.0",
  "toolchain": "pnpm-bun-native",
  "target": "windows-x64",
  "formats": ["exe", "zip"],
  "preferred_format": "zip",
  "min_size_mb": 1,
  "data_portability": "no-install-only",
  "smoke": {
    "mode": "folder-process",
    "executable": "Example.exe",
    "process_name": "Example.exe",
    "wait_seconds": 20,
    "env": {}
  }
}
```

The example is illustrative: the app adapter must implement its *actual* build system, and a `folder-process` smoke should only be selected when the ZIP truly contains the target EXE at its root.

## Security and release policy

- GitHub permissions are **read-only** for builds, and checkout does not persist credentials. No release token, publisher token or signing key is passed into an upstream build script.
- The upstream source and its dependencies execute code on the Windows runner. Review new refs, dependency updates and third-party workflow actions before promoting a build. The SHA-256 file is a **consistency check**, not a code signature or supply-chain attestation.
- No automatic upstream tracking and no automatic GitHub Release are enabled. Approve a build manually only after Windows 10/11 GUI checks, malware review, path/credential checks, and any required signatures.
- The factory currently builds **Windows x64**. macOS/Linux, ARM64, signing, reproducible toolchain pinning and automatic release promotion are separate future features.
- Legacy workflows `build-portable.yml`, `build-orca-portable.yml` and `diagnose-orca-portable.yml` remain unchanged during the rollout. Migrate them only after both app adapters pass the new pipeline.
