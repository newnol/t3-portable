#!/usr/bin/env python3
"""Validate portable app registry and resolve a reviewed upstream/ref for CI."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPS = ROOT / "apps"
ID = re.compile(r"^[a-z][a-z0-9-]{1,31}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
TOOLCHAINS = {"pnpm-bun-native", "vite-plus-rust"}
FORMATS = {"folder"}


def validate_ref(value: str) -> str:
    if not isinstance(value, str) or not REF.fullmatch(value):
        raise ValueError("Unsupported upstream ref syntax")
    if any(part in {"", ".", ".."} for part in value.split("/")) or value.endswith(".lock"):
        raise ValueError("Unsafe upstream ref")
    if ".." in value or "@{" in value or value.endswith("."):
        raise ValueError("Unsafe upstream ref")
    return value


def load_app(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    app_id = path.stem
    if not ID.fullmatch(app_id) or data.get("id") != app_id:
        raise ValueError(f"{path}: ID must exactly match its filename")
    if not isinstance(data.get("display_name"), str) or not data["display_name"]:
        raise ValueError(f"{path}: display_name is missing")
    if not REPO.fullmatch(data.get("upstream_repo", "")):
        raise ValueError(f"{path}: invalid upstream_repo")
    validate_ref(data.get("default_ref", ""))
    if data.get("toolchain") not in TOOLCHAINS:
        raise ValueError(f"{path}: unsupported toolchain")
    if data.get("target") != "windows-x64":
        raise ValueError(f"{path}: only windows-x64 is currently supported")
    formats = data.get("formats")
    if not isinstance(formats, list) or not formats or len(formats) != len(set(formats)):
        raise ValueError(f"{path}: formats must be a unique nonempty list")
    if formats != ["folder"] or data.get("preferred_format") != "folder":
        raise ValueError(f"{path}: Portable Factory requires a folder output (no self-extracting EXE)")
    min_size = data.get("min_size_mb")
    if not isinstance(min_size, int) or isinstance(min_size, bool) or not 1 <= min_size <= 4096:
        raise ValueError(f"{path}: min_size_mb must be an integer from 1 to 4096")
    smoke = data.get("smoke")
    if not isinstance(smoke, dict) or smoke.get("mode") not in {"folder-process", "not-verified"}:
        raise ValueError(f"{path}: unsupported smoke test mode")
    if smoke["mode"] == "folder-process":
        if not re.fullmatch(r"[A-Za-z0-9_.-]+[.]exe", smoke.get("executable", "")):
            raise ValueError(f"{path}: folder-process requires a safe root executable")
        if smoke.get("process_name") != smoke["executable"]:
            raise ValueError(f"{path}: process_name must match executable")
        if not isinstance(smoke.get("wait_seconds"), int) or not 5 <= smoke["wait_seconds"] <= 90:
            raise ValueError(f"{path}: invalid smoke wait_seconds")
        for key, value in smoke.get("env", {}).items():
            if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or not isinstance(value, str):
                raise ValueError(f"{path}: invalid smoke env declaration")
        log_env = smoke.get("startup_log_env", "")
        if log_env and (not re.fullmatch(r"[A-Z_][A-Z0-9_]*", log_env) or not smoke.get("startup_log_marker")):
            raise ValueError(f"{path}: invalid startup log marker config")
    if smoke["mode"] == "not-verified" and not smoke.get("reason"):
        raise ValueError(f"{path}: missing smoke limitation reason")
    adapter = ROOT / "scripts" / "portable" / "apps" / (app_id + ".ps1")
    if not adapter.is_file():
        raise ValueError(f"{path}: missing adapter {adapter.relative_to(ROOT)}")
    return data


def all_manifests() -> dict[str, dict]:
    files = sorted(APPS.glob("*.json"))
    if not files:
        raise ValueError("No registered apps")
    return {path.stem: load_app(path) for path in files}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate-all", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--app", default="")
    parser.add_argument("--ref", default="")
    args = parser.parse_args()
    try:
        apps = all_manifests()
        if args.validate_all:
            print(f"Validated {len(apps)} portable app manifests")
            return 0
        if args.list:
            for app in apps.values():
                print(f"{app['id']}: {app['display_name']} ({app['upstream_repo']} @ {app['default_ref']})")
            return 0
        if args.app not in apps:
            raise ValueError(f"Unknown app ID {args.app!r}; supported: {', '.join(apps)}")
        app = apps[args.app]
        source_ref = validate_ref(args.ref or app["default_ref"])
        values = {
            "app_id": app["id"],
            "display_name": app["display_name"],
            "upstream_repo": app["upstream_repo"],
            "upstream_ref": source_ref,
            "toolchain": app["toolchain"],
            "formats": ",".join(app["formats"]),
            "preferred_format": app["preferred_format"],
            "smoke_mode": app["smoke"]["mode"],
        }
        for key, value in values.items():
            print(f"{key}={value}")
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a", encoding="utf-8") as stream:
                for key, value in values.items():
                    stream.write(f"{key}={value}\n")
        return 0
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"Portable factory validation error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
