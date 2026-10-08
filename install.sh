#!/usr/bin/env bash
# install.sh — wire context-keeper into Claude Code.
#
#   ./install.sh                  install or update
#   ./install.sh --dry-run        print what would change, change nothing
#   ./install.sh --window N       auto-compact window in tokens (default 400000);
#                                 a value already in settings.json is kept
#   ./install.sh --bin-dir D      put the command in D instead of ~/.local/bin
#   ./install.sh --uninstall      take the hooks and the rule out, keep the
#                                 snapshots and autoCompactWindow
#
# Writes ~/.local/bin/context-keeper, ~/.claude/rules/context-keeper.md and two
# hooks in ~/.claude/settings.json. A file about to change is copied first to
# ~/.local/state/context-keeper-backups, three copies kept, never beside it.
# Idempotent: a re-run changes nothing. Nothing outside $HOME is touched.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CONTEXT_KEEPER_BIN_DIR:-$HOME/.local/bin}"
BACKUP_DIR="${CONTEXT_KEEPER_BACKUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/context-keeper-backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
WINDOW=400000
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --window)    WINDOW="${2:?--window needs a number}"; shift ;;
        --bin-dir)   BIN_DIR="${2:?--bin-dir needs a directory}"; shift ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$WINDOW" in
    ''|*[!0-9]*) echo "--window must be a plain number of tokens, e.g. 400000" >&2; exit 2 ;;
esac
if [ "$WINDOW" -lt 100000 ] || [ "$WINDOW" -gt 1000000 ]; then
    echo "--window must be between 100000 and 1000000 (Claude Code accepts that range)" >&2
    exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

tilde() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# Same backup rule as the settings patcher: path below $HOME, / turned into _.
backup_file() {
    local dst="$1" name old n=0
    name="${dst#"$HOME"/}"
    name="${name//\//_}"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    cp -p "$dst" "$BACKUP_DIR/$name.bak.$STAMP"
    printf '%s\n' "$BACKUP_DIR/$name".bak.* | sort -r | while IFS= read -r old; do
        n=$((n + 1))
        if [ "$n" -gt 3 ]; then rm -f "$old"; fi
    done
    return 0
}

install_file() {
    local src="$1" dst="$2" mode="$3"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  = $(tilde "$dst")"; return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  would write $(tilde "$dst")"; return 0
    fi
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then backup_file "$dst"; echo "  ~ $(tilde "$dst")"; else echo "  + $(tilde "$dst")"; fi
    cp "$src" "$dst"
    chmod "$mode" "$dst"
}

remove_file() {
    local dst="$1"
    [ -f "$dst" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then echo "  would remove $(tilde "$dst")"; return 0; fi
    backup_file "$dst"
    rm -f "$dst"
    echo "  - $(tilde "$dst")"
}

flags=()
[ "$DRY_RUN" -eq 1 ] && flags+=(--dry-run)

if [ "$UNINSTALL" -eq 1 ]; then
    echo "── context-keeper: uninstall ──"
    python3 "$SRC/lib/patch_settings.py" --bin "$BIN_DIR/context-keeper" --remove "${flags[@]+"${flags[@]}"}"
    remove_file "$HOME/.claude/rules/context-keeper.md"
    remove_file "$BIN_DIR/context-keeper"
    echo "  snapshots and autoCompactWindow were left in place"
    exit 0
fi

echo "── context-keeper ──"
install_file "$SRC/bin/context-keeper" "$BIN_DIR/context-keeper" 755
if [ -d "$HOME/.claude" ]; then
    install_file "$SRC/rules/context-keeper.md" "$HOME/.claude/rules/context-keeper.md" 644
fi
python3 "$SRC/lib/patch_settings.py" --bin "$BIN_DIR/context-keeper" --window "$WINDOW" "${flags[@]+"${flags[@]}"}"

if [ "$DRY_RUN" -eq 0 ]; then
    # The snapshot must come out of a fake session and the restore must print it.
    t="$(mktemp -d)"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"probe request"}}' > "$t/tr.jsonl"
    probe="$(printf '{"session_id":"install-probe","transcript_path":"%s","cwd":"%s","trigger":"manual"}' "$t/tr.jsonl" "$t")"
    printf '%s' "$probe" | CONTEXT_KEEPER_DIR="$t/state" "$BIN_DIR/context-keeper" snapshot
    if printf '%s' "$probe" | CONTEXT_KEEPER_DIR="$t/state" "$BIN_DIR/context-keeper" restore | grep -q 'probe request'; then
        echo "  ok — a snapshot is written before compaction and handed back after it"
    else
        echo "  the self-check failed: no snapshot came back" >&2
        rm -rf -- "${t:?}"; exit 1
    fi
    rm -rf -- "${t:?}"
    echo "  Restart Claude Code: hooks are read at start-up."
fi
