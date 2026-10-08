# context-keeper

**Keep the exact state of a Claude Code session across compaction.**

Русская версия: [README.RU.md](README.RU.md).

A long session costs more on every turn, because the whole context is read
again each time. Compacting earlier makes each turn cheaper, but a summary
loses detail. It forgets which files changed, what is committed and what is
not, the exact words of the last requests and what is still open.

context-keeper takes those facts from the machine instead of from the summary.
Just before compaction it writes them to a snapshot file. Right after
compaction it hands the snapshot back to the model. The summary then only has
to carry the reasoning.

## What it installs

| Piece | Where | What it does |
|---|---|---|
| `context-keeper` | `~/.local/bin` | the command the three hooks run |
| PreCompact hook | `~/.claude/settings.json` | `context-keeper snapshot` writes the snapshot |
| SessionStart hook, matcher `compact` | `~/.claude/settings.json` | `context-keeper restore` hands it back to the model |
| SessionStart hook, matcher `resume` | `~/.claude/settings.json` | `context-keeper resume` reads the state now when a session is picked up again |
| `autoCompactWindow: 400000` | `~/.claude/settings.json` | compaction starts at 400k tokens instead of near the full window |
| rule | `~/.claude/rules/context-keeper.md` | tells the summary what to keep: the task, the decisions, exact paths and ids, what is unfinished |

A value of `autoCompactWindow` that is already set is kept.

## What a snapshot holds

- the files changed in the session, newest last;
- for every git repository touched: the branch line, uncommitted changes and
  the last five commits;
- the newest `kind: state` note of a `kb/` in those repositories;
- the open findings of the session, when the `findings` command exists;
- the last six requests the user typed, verbatim.

Snapshots live in `~/.local/state/context-keeper`, one per session, the newest
20 kept. The directory is mode 700 and each file 600: a snapshot holds the
user's own words. When `secrets-redact` (from env2hell) is installed, the
snapshot passes through it before it is written.

Both SessionStart hooks also print one line for the user, such as
`context-keeper: snapshot restored — 120 lines, 6740 bytes`.

## Coming back to a session

The conversation cannot know what happened while nobody was in it. When a
session is resumed (`claude --resume`, `claude --continue`), `context-keeper
resume` reads the state at that moment and hands it to the model:

- the time of the last activity in the session and how long ago it was;
- for every git repository touched: the branch line, uncommitted changes and
  the commits made since the last activity;
- a repository that is clean and has no new commits takes one line.

It works the same whether the session was ever compacted or not: it reads the
transcript and the repositories, not a snapshot. The user sees one line, such
as `context-keeper: away 2d 3h; state of 3 repositories read now, 2 new
commits`. Nothing is written to disk.

## Disk use

The disk use is bounded and needs no care. At most 20 snapshots of at most
24000 bytes each are kept, and 3 copies of each file the installer changed.
`~/.local/state/context-keeper` and `~/.local/state/context-keeper-backups`
can both be deleted at any time. A snapshot is needed only from
the moment compaction starts until the session starts again: after that it is
part of the session transcript.

## Install

```bash
./install.sh                 # install or update
./install.sh --dry-run       # print what would change
./install.sh --window 300000 # another compaction window, 100000 to 1000000
./install.sh --uninstall     # take the hooks, the rule and the command out
```

Restart Claude Code after installing: hooks are read at start-up. A file about
to change is copied first to `~/.local/state/context-keeper-backups`, and the
three newest copies of each are kept. The installer ends with a self-check: it
writes a snapshot of a fake session and reads it back.

To read a snapshot by hand:

```bash
context-keeper show            # the newest
context-keeper show <session>  # one session
```

## What it does not do

- **It cannot choose what the summary says.** A PreCompact hook in Claude Code
  can only allow or block compaction. Guidance for the summary comes from the
  rule, which is the same for every session.
- **It does not summarise part of a conversation.** `/rewind` with
  *Summarize up to here* does that, and it is interactive only.
- **Codex and Opencode are not wired yet.** Codex has
  `model_auto_compact_token_limit` and `compact_prompt`, and Opencode has the
  plugin hook `experimental.session.compacting`. Both are planned once their
  hooks are checked on a live install.

## Tests

```bash
bash tests/test_keeper.sh
```

## License

MIT, see [LICENSE](LICENSE).
