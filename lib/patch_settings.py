#!/usr/bin/env python3
"""Wire context-keeper into Claude Code's settings.json, or take it out.

  patch_settings.py --bin <path> [--window N] [--dry-run] [--remove]

Adds a PreCompact hook running `<bin> snapshot`, a SessionStart hook with
matcher "compact" running `<bin> restore`, and sets autoCompactWindow to N
(default 400000) unless the user already set a value. Entries are recognised
by the command ending in `context-keeper snapshot|restore`, so a re-run
changes nothing and --remove takes out ours only. A file about to change is
copied first to ~/.local/state/context-keeper-backups, three copies kept --
never beside it.
"""
import argparse
import glob
import json
import os
import shutil
import sys
import time

HOME = os.path.expanduser("~")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
BACKUPS = os.environ.get("CONTEXT_KEEPER_BACKUP_DIR") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"),
    "context-keeper-backups")
BACKUPS_KEPT = 3


def ours(cmd, verb):
    return isinstance(cmd, str) and cmd.rstrip().endswith(f"context-keeper {verb}")


def strip(blocks, verb):
    out = []
    for b in blocks or []:
        hooks = [h for h in b.get("hooks", []) if not ours(h.get("command"), verb)]
        if hooks:
            out.append({**b, "hooks": hooks})
    return out


def patch(data, binpath, window, remove):
    hooks = data.setdefault("hooks", {})
    pre = strip(hooks.get("PreCompact"), "snapshot")
    start = strip(hooks.get("SessionStart"), "restore")
    if not remove:
        pre.append({"matcher": "", "hooks": [
            {"type": "command", "command": f"{binpath} snapshot", "timeout": 30}]})
        start.append({"matcher": "compact", "hooks": [
            {"type": "command", "command": f"{binpath} restore", "timeout": 10}]})
        data.setdefault("autoCompactWindow", window)
    for key, val in (("PreCompact", pre), ("SessionStart", start)):
        if val:
            hooks[key] = val
        else:
            hooks.pop(key, None)
    return data


def backup(path, stamp):
    os.makedirs(BACKUPS, exist_ok=True)
    os.chmod(BACKUPS, 0o700)    # a copy of settings.json holds its env block
    rel = os.path.relpath(path, HOME) if path.startswith(HOME + os.sep) else path.lstrip(os.sep)
    base = os.path.join(BACKUPS, rel.replace(os.sep, "_"))
    shutil.copy2(path, f"{base}.bak.{stamp}")
    for stale in sorted(glob.glob(glob.escape(base) + ".bak.*"), reverse=True)[BACKUPS_KEPT:]:
        os.unlink(stale)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--window", type=int, default=400000)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()
    if not os.path.isdir(os.path.dirname(SETTINGS)):
        print("  claude: ~/.claude not found — skipped")
        return 0
    path = os.path.realpath(SETTINGS)
    before = "{}"
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            before = fh.read() or "{}"
    try:
        data = json.loads(before)
    except ValueError:
        print(f"  claude: {SETTINGS} is not valid JSON — not touched", file=sys.stderr)
        return 1
    after = patch(json.loads(before), a.bin, a.window, a.remove)
    if after == data:
        print("  = ~/.claude/settings.json")
        return 0
    if a.dry_run:
        print("  would write ~/.claude/settings.json")
        return 0
    if os.path.exists(path):
        backup(path, time.strftime("%Y%m%d-%H%M%S"))
    tmp = path + ".context-keeper.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(after, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)
    print(f"  ~ ~/.claude/settings.json  (backup in {BACKUPS.replace(HOME, '~')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
