#!/usr/bin/env bash
# tests/test_keeper.sh — the snapshot, the restore and the installer.
#
#   bash tests/test_keeper.sh
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CK="$SRC/bin/context-keeper"
pass=0
fail=0
ok () { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no () { fail=$((fail + 1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }
check () {                      # check <name> <command…>: passes when it exits 0
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else no "$name" "command failed: $*"; fi
}

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf -- "${tmp:?}"' EXIT
unset XDG_STATE_HOME CONTEXT_KEEPER_BACKUP_DIR CONTEXT_KEEPER_BIN_DIR
export CONTEXT_KEEPER_DIR="$tmp/state"

# A repository with one commit and one uncommitted change, edited in the session.
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
GIT_AUTHOR_DATE=2025-12-31T00:00:00Z GIT_COMMITTER_DATE=2025-12-31T00:00:00Z \
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "first commit of the fixture"
printf 'x\n' > "$repo/changed.txt"

tr="$tmp/transcript.jsonl"
{
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"first request of the session"}}'
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/changed.txt"}}]}}\n' "$repo"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/new.md"}}]}}\n' "$repo"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/changed.txt"}}]}}\n' "$repo"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"a tool result, not a request"}]}}'
    printf '%s\n' '{"type":"user","isMeta":true,"message":{"role":"user","content":"injected meta text"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"/compact"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"second request, keep paths like /opt/x exact"}]}}'
    printf '%s\n' 'not json at all'
} > "$tr"
hook="$(printf '{"session_id":"s-1","transcript_path":"%s","cwd":"%s","trigger":"manual"}' "$tr" "$repo")"

# ── snapshot ────────────────────────────────────────────────────────────────
printf '%s' "$hook" | "$CK" snapshot
snap="$CONTEXT_KEEPER_DIR/s-1.md"
check "snapshot: the file is written" test -s "$snap"
mode_f="$(stat -c %a "$snap" 2>/dev/null || stat -f %Lp "$snap")"
mode_d="$(stat -c %a "$CONTEXT_KEEPER_DIR" 2>/dev/null || stat -f %Lp "$CONTEXT_KEEPER_DIR")"
if [ "$mode_f" = 600 ] && [ "$mode_d" = 700 ]; then ok "snapshot: file 600, directory 700"
else no "snapshot: file 600, directory 700" "file $mode_f, directory $mode_d"; fi
check "snapshot: both changed files are listed" grep -q "$repo/new.md" "$snap"
n="$(grep -c "^- $repo/changed.txt$" "$snap")"
last="$(grep '^- /' "$snap" | tail -1)"
if [ "$n" -eq 1 ] && [ "$last" = "- $repo/changed.txt" ]; then ok "snapshot: a file edited twice is listed once, newest last"
else no "snapshot: a file edited twice is listed once, newest last" "count $n, last [$last]"; fi
check "snapshot: the git state of the repository" grep -q "first commit of the fixture" "$snap"
check "snapshot: the uncommitted change" grep -q "changed.txt" "$snap"
check "snapshot: the typed requests, verbatim" grep -q "second request, keep paths like /opt/x exact" "$snap"
if grep -q -e "a tool result" -e "injected meta" -e "<command-name>" -e "^> /compact$" "$snap"; then
    no "snapshot: tool results, meta text and commands are not requests" "one of them is in it"
else ok "snapshot: tool results, meta text and commands are not requests"; fi

# ── restore ─────────────────────────────────────────────────────────────────
# field <name>: systemMessage or additionalContext of the hook JSON on stdin.
field () {
    python3 -c 'import json, sys
d = json.load(sys.stdin)
print(d.get("systemMessage", "") if sys.argv[1] == "message"
      else d.get("hookSpecificOutput", {}).get("additionalContext", ""))' "$1"
}
out="$(printf '%s' "$hook" | "$CK" restore)"
if [ "$(printf '%s' "$out" | field context)" = "$(cat "$snap")" ]; then ok "restore: hands the snapshot of the session to the model"
else no "restore: hands the snapshot of the session to the model" "context differs"; fi
case "$(printf '%s' "$out" | field message)" in
    "context-keeper: snapshot restored"*) ok "restore: tells the user it restored the snapshot" ;;
    *) no "restore: tells the user it restored the snapshot" "message [$(printf '%s' "$out" | field message)]" ;; esac
out="$(printf '%s' '{"session_id":"other"}' | "$CK" restore)"; rc=$?
if [ -z "$(printf '%s' "$out" | field context)" ] && [ "$rc" -eq 0 ]; then ok "restore: another session gets no context, exit 0"
else no "restore: another session gets no context, exit 0" "rc $rc"; fi

# ── resume ──────────────────────────────────────────────────────────────────
# A session left a while ago: one commit was made in the repository since.
printf '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"left here"}}\n' > "$tmp/tr5.jsonl"
printf '{"type":"assistant","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/changed.txt"}}]}}\n' "$repo" >> "$tmp/tr5.jsonl"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "made while the session was away"
before="$(find "$CONTEXT_KEEPER_DIR" -type f | wc -l)"
out="$(printf '{"session_id":"s-5","transcript_path":"%s","cwd":"%s"}' "$tmp/tr5.jsonl" "$repo" | "$CK" resume)"
ctx="$(printf '%s' "$out" | field context)"; msg="$(printf '%s' "$out" | field message)"
case "$ctx" in *"state on return"*"Last activity in it: 2026-01-01 00:00:01 UTC"*"made while the session was away"*)
    ok "resume: the time away and the commits made since go to the model" ;;
    *) no "resume: the time away and the commits made since go to the model" "got [$ctx]" ;; esac
case "$msg" in "context-keeper: away "*"d "*"state of 1 repositories read now, 1 new commits")
    ok "resume: tells the user what it read ($msg)" ;;
    *) no "resume: tells the user what it read" "message [$msg]" ;; esac
case "$ctx" in *"first commit of the fixture"*) no "resume: commits from before the last activity are left out" "an old commit is listed" ;;
    *) ok "resume: commits from before the last activity are left out" ;; esac
if [ "$(find "$CONTEXT_KEEPER_DIR" -type f | wc -l)" -eq "$before" ]; then ok "resume: writes nothing to disk"
else no "resume: writes nothing to disk" "a file appeared"; fi
printf 'garbage' | "$CK" resume > /dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "resume: garbage on stdin exits 0"; else no "resume: garbage on stdin exits 0" "rc $rc"; fi
# Seven repositories edited one after another: the cap of six drops the one
# touched first, never the newest. Found live: the newest one was cut.
: > "$tmp/tr6.jsonl"
for i in 1 2 3 4 5 6 7; do
    git -C "$tmp" init -q "many-$i"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/many-%s/f"}}]}}\n' "$tmp" "$i" >> "$tmp/tr6.jsonl"
done
ctx="$(printf '{"session_id":"s-6","transcript_path":"%s","cwd":"%s"}' "$tmp/tr6.jsonl" "$tmp" | "$CK" resume | field context)"
case "$ctx" in *"many-7"*) case "$ctx" in *"many-1\`"*) no "resume: the cap keeps the newest repositories" "many-1 kept" ;;
    *) ok "resume: the cap keeps the newest repositories" ;; esac ;;
    *) no "resume: the cap keeps the newest repositories" "many-7 dropped" ;; esac

# ── a repository from the transcript runs none of its own code ──────────────
# An unpacked archive can carry a .git/config whose core.fsmonitor names a
# program; plain `git status` runs it. Snapshot and resume must not.
evil="$tmp/evil"
git -C "$tmp" init -q evil
printf '#!/bin/sh\ntouch "%s/fsmonitor-ran"\n' "$tmp" > "$tmp/fsmon.sh"; chmod +x "$tmp/fsmon.sh"
git -C "$evil" config core.fsmonitor "$tmp/fsmon.sh"
git -C "$evil" status --short > /dev/null 2>&1
if [ -e "$tmp/fsmonitor-ran" ]; then rm -f -- "$tmp/fsmonitor-ran"; armed=1; else armed=0; fi
printf '{"type":"assistant","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/f"}}]}}\n' "$evil" > "$tmp/tr-evil.jsonl"
for cmd in snapshot resume; do
    printf '{"session_id":"s-evil","transcript_path":"%s","cwd":"%s","trigger":"manual"}' "$tmp/tr-evil.jsonl" "$evil" | "$CK" "$cmd" > /dev/null 2>&1
done
if [ "$armed" -eq 1 ] && [ ! -e "$tmp/fsmonitor-ran" ]; then ok "snapshot, resume: the repository's core.fsmonitor is not run"
else no "snapshot, resume: the repository's core.fsmonitor is not run" "fixture armed=$armed, marker $( [ -e "$tmp/fsmonitor-ran" ] && echo present || echo absent)"; fi

# ── auto-compaction is the user's call ──────────────────────────────────────
out="$(printf '{"session_id":"s-7","transcript_path":"%s","cwd":"%s","trigger":"auto"}' "$tr" "$repo" | "$CK" snapshot)"; rc=$?
dec="$(printf '%s' "$out" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("decision", ""))')"
if [ "$rc" -eq 0 ] && [ "$dec" = block ] && [ ! -e "$CONTEXT_KEEPER_DIR/s-7.md" ]; then
    ok "snapshot: compaction the user did not ask for is blocked, nothing written"
else no "snapshot: compaction the user did not ask for is blocked, nothing written" "rc $rc, decision [$dec]"; fi
# Claude Code shows nothing a PreCompact hook prints, so the announcement comes
# from the next UserPromptSubmit, once.
auto7 () { printf '{"session_id":"s-7","transcript_path":"%s","cwd":"%s","trigger":"%s"}' "$tr" "$repo" "$1" | "$CK" snapshot; }
notice7 () { printf '{"session_id":"s-7"}' | "$CK" notice; }
n1="$(notice7)"; n2="$(notice7)"
case "$(printf '%s' "$n1" | field message)" in *"run /compact"*)
    if [ -z "$n2" ]; then ok "notice: the next prompt tells the user once to run /compact"
    else no "notice: the next prompt tells the user once to run /compact" "said it twice"; fi ;;
    *) no "notice: the next prompt tells the user once to run /compact" "got [$n1]" ;; esac
case "$(printf '%s' "$n1" | field context)" in *"Say so to the user"*) ok "notice: the model is asked to mention it in its reply" ;;
    *) no "notice: the model is asked to mention it in its reply" "no context" ;; esac
auto7 auto > /dev/null
if [ -z "$(notice7)" ]; then ok "notice: later blocks in the session stay silent"
else no "notice: later blocks in the session stay silent" "announced again"; fi
auto7 manual > /dev/null; auto7 auto > /dev/null
case "$(notice7 | field message)" in *"run /compact"*) ok "notice: after the user compacts, the next block is announced again" ;;
    *) no "notice: after the user compacts, the next block is announced again" "silent" ;; esac
# The status line keeps saying it, in raspberry, until the user compacts.
sl7 () { printf '{"session_id":"s-7"}' | "$CK" statusline; }
s1="$(sl7)"; notice7 > /dev/null; s2="$(sl7)"; auto7 manual > /dev/null; s3="$(sl7)"
if [[ "$s1" == $'\033[38;5;198m'*"auto-compact blocked"* ]] && [ "$s2" = "$s1" ] && [ -z "$s3" ] &&
   [ -z "$(printf '{"session_id":"never-blocked"}' | "$CK" statusline)" ]; then
    ok "statusline: raspberry while blocked, after notice too; gone after /compact and for others"
else no "statusline: raspberry while blocked, after notice too; gone after /compact and for others" "[$s1] [$s2] [$s3]"; fi
auto7 auto > /dev/null
if [ -z "$(printf '{"session_id":"never-blocked"}' | "$CK" notice)" ]; then ok "notice: a session never blocked hears nothing"
else no "notice: a session never blocked hears nothing" "it printed"; fi
out="$(printf '{"session_id":"s-8","transcript_path":"%s","cwd":"%s","trigger":"auto"}' "$tr" "$repo" | "$CK" snapshot --allow-auto)"
if [ -z "$out" ] && [ -s "$CONTEXT_KEEPER_DIR/s-8.md" ]; then ok "snapshot --allow-auto: automatic compaction goes on, with a snapshot"
else no "snapshot --allow-auto: automatic compaction goes on, with a snapshot" "out [$out]"; fi

# ── never fails a hook ──────────────────────────────────────────────────────
printf 'garbage' | "$CK" snapshot; rc=$?
if [ "$rc" -eq 0 ]; then ok "snapshot: garbage on stdin exits 0"; else no "snapshot: garbage on stdin exits 0" "rc $rc"; fi
printf '%s' '{"session_id":"s-2","transcript_path":"/nonexistent"}' | "$CK" snapshot; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$CONTEXT_KEEPER_DIR/s-2.md" ]; then ok "snapshot: a missing transcript still exits 0 and writes the rest"
else no "snapshot: a missing transcript still exits 0 and writes the rest" "rc $rc"; fi
printf '%s' '{"session_id":"../../escape"}' | "$CK" snapshot
if [ ! -e "$tmp/escape.md" ] && [ "$(find "$CONTEXT_KEEPER_DIR" -maxdepth 1 -name "*escape.md" | wc -l)" -eq 1 ]; then
    ok "snapshot: a session id cannot leave the state directory"
else no "snapshot: a session id cannot leave the state directory" "written outside"; fi

# ── secrets are masked when secrets-redact is installed ─────────────────────
if command -v secrets-redact >/dev/null 2>&1; then
    pw="$(printf %s%s Q7XKPZRM 4HDV2a9c)"
    printf '{"type":"user","message":{"role":"user","content":"password: %s"}}\n' "$pw" > "$tmp/tr2.jsonl"
    printf '{"session_id":"s-3","transcript_path":"%s","cwd":"%s"}' "$tmp/tr2.jsonl" "$tmp" | "$CK" snapshot
    if ! grep -qF "$pw" "$CONTEXT_KEEPER_DIR/s-3.md" && grep -q 'REDACTED' "$CONTEXT_KEEPER_DIR/s-3.md"; then
        ok "snapshot: a password in a request is masked"
    else no "snapshot: a password in a request is masked" "the value is in the snapshot"; fi
else
    echo "  skip  secrets-redact not installed: masking not checked"
fi

# ── size and pruning ────────────────────────────────────────────────────────
big="$(head -c 3000 /dev/zero | tr '\0' 'a')"
: > "$tmp/tr3.jsonl"
for i in $(seq 1 40); do
    printf '{"type":"user","message":{"role":"user","content":"%s %s"}}\n' "$i" "$big" >> "$tmp/tr3.jsonl"
done
printf '{"session_id":"s-4","transcript_path":"%s","cwd":"%s"}' "$tmp/tr3.jsonl" "$tmp" | "$CK" snapshot
size="$(wc -c < "$CONTEXT_KEEPER_DIR/s-4.md")"
if [ "$size" -le 24100 ]; then ok "snapshot: capped near 24000 bytes ($size)"; else no "snapshot: capped near 24000 bytes" "$size bytes"; fi
for i in $(seq 1 25); do printf '{"session_id":"p-%s"}' "$i" | "$CK" snapshot; done
count="$(find "$CONTEXT_KEEPER_DIR" -name '*.md' | wc -l)"
if [ "$count" -le 20 ]; then ok "snapshot: twenty snapshots are kept ($count)"; else no "snapshot: twenty snapshots are kept" "$count left"; fi

# ── the installer ───────────────────────────────────────────────────────────
home="$tmp/home"
mkdir -p "$home/.claude"
cat > "$home/.claude/settings.json" <<'JSON'
{
  "model": "kept-by-the-user",
  "hooks": {
    "PreCompact": [{"matcher": "", "hooks": [{"type": "command", "command": "echo foreign"}]}]
  }
}
JSON
inst () { HOME="$home" CONTEXT_KEEPER_BIN_DIR="$home/bin" bash "$SRC/install.sh" "$@"; }
if inst > "$tmp/i1.out" 2>&1; then ok "install: a run over a fresh home finishes"
else no "install: a run over a fresh home finishes" "$(tail -3 "$tmp/i1.out")"; fi
state () {
    python3 - "$home/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
h = d.get("hooks", {})
cmds = lambda k: [x["command"] for b in h.get(k, []) for x in b["hooks"]]
pre = cmds("PreCompact"); start = [b for b in h.get("SessionStart", [])]
ours_start = [b["matcher"] for b in start for x in b["hooks"]
              if x["command"].endswith(("context-keeper restore", "context-keeper resume"))]
notice = sum(c.endswith("context-keeper notice") for c in cmds("UserPromptSubmit"))
print(f"pre={sum(c.endswith('context-keeper snapshot') for c in pre)} foreign={'echo foreign' in pre} "
      f"start={len(ours_start)}:{','.join(ours_start)} notice={notice} "
      f"window={d.get('autoCompactWindow')} model={d.get('model')}")
PY
}
s1="$(state)"
if [ "$s1" = "pre=1 foreign=True start=2:compact,resume notice=1 window=400000 model=kept-by-the-user" ]; then
    ok "install: hooks, window, and the user's own entries ($s1)"
else no "install: hooks, window, and the user's own entries" "got [$s1]"; fi
check "install: the rule lands" test -s "$home/.claude/rules/context-keeper.md"
inst > "$tmp/i2.out" 2>&1
s2="$(state)"
if [ "$s2" = "$s1" ] && grep -q '= ~/.claude/settings.json' "$tmp/i2.out"; then ok "install: a second run changes nothing"
else no "install: a second run changes nothing" "got [$s2]"; fi
beside="$(find "$home/.claude" -maxdepth 1 -name '*.bak.*' | wc -l)"
backed="$(find "$home/.local/state/context-keeper-backups" -name '.claude_settings.json.bak.*' 2>/dev/null | wc -l)"
if [ "$beside" -eq 0 ] && [ "$backed" -ge 1 ]; then ok "install: the backup is in the state directory, not beside settings.json"
else no "install: the backup is in the state directory, not beside settings.json" "$beside beside, $backed backed up"; fi
python3 - "$home/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["autoCompactWindow"] = 600000
json.dump(d, open(p, "w"), indent=2)
PY
inst --window 300000 > /dev/null 2>&1
case "$(state)" in *window=600000*) ok "install: a window the user set is kept" ;;
    *) no "install: a window the user set is kept" "got [$(state)]" ;; esac
if inst --window 50000 > /dev/null 2>&1; then no "install: a window outside 100000..1000000 is refused" "accepted"
else ok "install: a window outside 100000..1000000 is refused"; fi
precmd () { rg -o '"[^"]*context-keeper snapshot[^"]*"' "$home/.claude/settings.json" 2>/dev/null ||
            grep -o '"[^"]*context-keeper snapshot[^"]*"' "$home/.claude/settings.json"; }
inst --allow-auto > /dev/null 2>&1
a1="$(precmd)"
inst > /dev/null 2>&1
a2="$(precmd)"
if [ "$a1" = "\"$home/bin/context-keeper snapshot --allow-auto\"" ] && [ "$a2" = "\"$home/bin/context-keeper snapshot\"" ]; then
    case "$(inst --allow-auto >/dev/null 2>&1; state)" in *notice=0*) ok "install: --allow-auto switches automatic compaction on, a plain re-run off" ;;
        *) no "install: --allow-auto drops the notice hook" "got [$(state)]" ;; esac; inst > /dev/null 2>&1
else no "install: --allow-auto switches automatic compaction on, a plain re-run off" "[$a1] then [$a2]"; fi
inst --uninstall > /dev/null 2>&1
s3="$(state)"
if [ "$s3" = "pre=0 foreign=True start=0: notice=0 window=600000 model=kept-by-the-user" ] &&
   [ ! -e "$home/.claude/rules/context-keeper.md" ] && [ ! -e "$home/bin/context-keeper" ]; then
    ok "uninstall: ours go, the user's hook and window stay"
else no "uninstall: ours go, the user's hook and window stay" "got [$s3]"; fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
