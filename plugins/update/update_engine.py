#!/usr/bin/env python3
"""Update engine — slimmed-down bootstrap engine for the update plugin.

Only processes update.json — no layered manifests, no plugin discovery.
This prevents the full bootstrap engine from processing other plugins'
manifests (e.g. installing unreal-kit from a project's .claude/bootstrap.json).

Usage:
    update-engine --plugin-root /path/to/update --data-dir /path/to/data

    Or directly:
    python3 update_engine.py --plugin-root /path/to/update --data-dir /path/to/data
"""

import argparse
import json
import os
import sys


STALE_MARKETPLACES = ["update01", "update02", "update03", "update04", "update05"]


def _cleanup_stale_marketplaces(stale_names, action_entries, ok_entries, log_success):
    """Remove old update0x entries from known_marketplaces.json and installed_plugins.json."""
    plugins_dir = os.path.join(os.path.expanduser("~"), ".claude", "plugins")
    any_removed = False

    # Clean known_marketplaces.json
    km_path = os.path.join(plugins_dir, "known_marketplaces.json")
    try:
        with open(km_path, "r") as f:
            km = json.load(f)
        removed = [name for name in stale_names if name in km]
        if removed:
            for name in removed:
                del km[name]
            with open(km_path, "w") as f:
                json.dump(km, f, indent=2)
                f.write("\n")
            for name in removed:
                action_entries.append(f"stale marketplace: removed {name} from known_marketplaces.json")
            any_removed = True
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass

    # Clean installed_plugins.json
    ip_path = os.path.join(plugins_dir, "installed_plugins.json")
    try:
        with open(ip_path, "r") as f:
            ip = json.load(f)
        plugins = ip.get("plugins", {})
        stale_keys = [k for k in plugins if any(k == f"update@{name}" for name in stale_names)]
        if stale_keys:
            for key in stale_keys:
                del plugins[key]
            with open(ip_path, "w") as f:
                json.dump(ip, f, indent=2)
                f.write("\n")
            for key in stale_keys:
                action_entries.append(f"stale plugin: removed {key} from installed_plugins.json")
            any_removed = True
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass

    if not any_removed and log_success:
        ok_entries.append("stale marketplaces: none found")


def _check_goal_and_self_disable(marketplace_name, plugin_name, action_entries, ok_entries):
    """Check if plugins-kit:bootstrap is installed & enabled; if so, disable update06.

    Returns True if update06 should short-circuit (goal reached, self-disabled).
    Returns False if update06 should continue its normal manifest processing.
    """
    from bootstrap_lib.marketplace_lifecycle import check_plugin_installed, check_plugin_enabled

    target_ref = "plugins-kit:bootstrap"

    installed = check_plugin_installed(target_ref)
    if not installed.passed:
        return False

    enabled = check_plugin_enabled(target_ref)
    if not enabled.passed:
        return False

    # Goal reached — disable ourselves in settings.json
    self_ref_cli = f"{plugin_name}@{marketplace_name}"
    settings_path = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")

    try:
        with open(settings_path, "r") as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    except (json.JSONDecodeError, OSError):
        action_entries.append("self-disable: skipped (settings.json unreadable)")
        return False

    enabled_plugins = settings.setdefault("enabledPlugins", {})

    if enabled_plugins.get(self_ref_cli) is False:
        ok_entries.append(f"self-disable: already disabled ({self_ref_cli})")
        return True

    enabled_plugins[self_ref_cli] = False
    try:
        tmp_path = settings_path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, settings_path)
        action_entries.append(
            f"self-disable: {self_ref_cli} disabled in settings.json "
            f"(plugins-kit:bootstrap is installed and enabled)"
        )
    except OSError as e:
        action_entries.append(f"self-disable: FAILED to write settings.json ({e})")
        return False

    return True


def main():
    parser = argparse.ArgumentParser(description="Update engine")
    parser.add_argument("--plugin-root", required=True, help="Path to update plugin root")
    parser.add_argument("--data-dir", required=True, help="Path to update data directory")
    parser.add_argument("--hook-start-epoch", type=int, default=0, help="(unused, kept for compat)")
    parser.add_argument("--verbose", action="store_true", help="Show all entries including ok/cached")
    parser.add_argument("--console", action="store_true", help="Plain text output, no JSON/log writes")
    parser.add_argument("--background", action="store_true",
        help="Write display output to bootstrap_display.pending instead of stdout")
    args = parser.parse_args()

    # --console implies --verbose
    if args.console:
        args.verbose = True

    plugin_root = args.plugin_root
    data_dir = args.data_dir

    from bootstrap_lib.config import load_config
    from bootstrap_lib.platform_detect import detect_os
    from bootstrap_lib.log import write_log_block
    from bootstrap_lib.engine import (
        _process_self_setup,
        _activate_bootstrap_venv,
        _process_manifest,
        _read_new_log_entries,
        _update_display_marker,
        emit_success_response,
        emit_failure_response,
    )

    # Step 1: Load/migrate config
    defaults_dir = os.path.join(plugin_root, "defaults")
    config = load_config(data_dir, defaults_dir)

    current_os = detect_os()
    log_success = config.get("log_success_checks", False) or args.verbose
    all_failures = []
    action_entries = []
    ok_entries = []

    # Step 2: Read plugin identity
    plugin_json_path = os.path.join(plugin_root, ".claude-plugin", "plugin.json")
    plugin_name = "update"
    version = ""
    try:
        with open(plugin_json_path, "r") as f:
            pj = json.load(f)
            plugin_name = pj.get("name", "update")
            version = pj.get("version", "")
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass

    marketplace_name = os.path.basename(os.path.normpath(os.path.join(plugin_root, "..", "..")))
    version_suffix = f"@{version}" if version else ""
    label = f"{marketplace_name}:{plugin_name}{version_suffix}" if marketplace_name else f"{plugin_name}{version_suffix}"

    # Step 2b: Version change detection
    if version:
        last_version_file = os.path.join(data_dir, "last_version")
        try:
            with open(last_version_file, "r") as f:
                last_version = f.read().strip()
        except FileNotFoundError:
            last_version = ""
        if last_version and last_version != version:
            action_entries.append(f"updated: {last_version} -> {version}")
        elif not last_version:
            action_entries.append(f"installed: {version}")
        os.makedirs(data_dir, exist_ok=True)
        with open(last_version_file, "w") as f:
            f.write(version)

    # Step 2c: Self-disable check — skip heavy work if bootstrap is already active
    if _check_goal_and_self_disable(marketplace_name, plugin_name, action_entries, ok_entries):
        display_sections = [(label, list(action_entries), list(ok_entries))]

        if not args.console:
            shell_content = _read_new_log_entries(data_dir)
        else:
            shell_content = ""

        log_entries = action_entries + ok_entries
        if log_entries and not args.console:
            write_log_block(data_dir, label, log_entries)

        display_lines = []
        for header, actions, oks in display_sections:
            section_entries = list(actions)
            if log_success:
                section_entries.extend(oks)
            if section_entries:
                display_lines.append(f"--- {header} ---")
                display_lines.extend(section_entries)

        if args.console:
            for line in display_lines:
                print(line)
            return

        parts = []
        if shell_content:
            parts.append(shell_content)
        parts.extend(display_lines)
        display_content = "\n".join(parts)

        _update_display_marker(data_dir)

        output_file = os.path.join(data_dir, "bootstrap_display.pending") if args.background else None
        if display_content:
            emit_success_response(display_content, label=label, output_file=output_file)
        return

    # Step 3: Self-setup — no-op (config has no self_setup)
    self_setup = config.get("self_setup", {})
    failures = _process_self_setup(self_setup, current_os, data_dir, plugin_root, action_entries, ok_entries)
    if failures:
        all_failures.extend(failures)

    # Step 3b: Activate bootstrap venv site-packages so PyYAML is available
    _activate_bootstrap_venv(data_dir)

    # Load and process update.json (replaces Steps 3c, 3d, 4 from full engine)
    manifest_path = os.path.join(plugin_root, "update.json")
    try:
        with open(manifest_path, "r") as f:
            manifest = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError) as e:
        all_failures.append({
            "type": "manifest",
            "message": f"Failed to load update.json: {e}",
            "plugin": plugin_name,
        })
        manifest = {}

    if manifest:
        manifest_action = []
        manifest_ok = []
        failures = _process_manifest(
            manifest, current_os, data_dir, plugin_root,
            manifest_action, manifest_ok, plugin_name=plugin_name,
        )
        action_entries.extend(manifest_action)
        ok_entries.extend(manifest_ok)
        if failures:
            all_failures.extend(failures)

    # Clean up stale marketplace entries from previous update0x iterations
    _cleanup_stale_marketplaces(
        ["update01", "update02", "update03", "update04", "update05"],
        action_entries, ok_entries, log_success,
    )

    # Build display section
    display_sections = [(label, list(action_entries), list(ok_entries))]

    # Step 5: Read shell log entries BEFORE writing engine entries
    if not args.console:
        shell_content = _read_new_log_entries(data_dir)
    else:
        shell_content = ""

    # Step 6: Write log entries (skip in console mode)
    log_entries = action_entries + ok_entries
    if log_entries and not args.console:
        write_log_block(data_dir, label, log_entries)

    # Step 7: Build display — actions always, ok only if log_success
    display_lines = []
    for header, actions, oks in display_sections:
        section_entries = list(actions)
        if log_success:
            section_entries.extend(oks)
        if section_entries:
            display_lines.append(f"--- {header} ---")
            display_lines.extend(section_entries)

    if args.console:
        for line in display_lines:
            print(line)
        if all_failures:
            print(f"\n{label} -> {len(all_failures)} failure(s):")
            for f in all_failures:
                print(f"  - [{f['type']}] {f.get('name', f.get('message', ''))}")
        return

    # Build final display: shell entries + section entries
    parts = []
    if shell_content:
        parts.append(shell_content)
    parts.extend(display_lines)
    display_content = "\n".join(parts)

    # Update the log display marker
    _update_display_marker(data_dir)

    # Step 8: Emit results
    output_file = os.path.join(data_dir, "bootstrap_display.pending") if args.background else None
    if all_failures:
        emit_failure_response(all_failures, current_os, display_content, label=label, output_file=output_file)
    elif display_content:
        emit_success_response(display_content, label=label, output_file=output_file)
    # else: nothing to show — silent exit


if __name__ == "__main__":
    main()
