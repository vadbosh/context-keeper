# Changelog

## 0.2.1 — 2026-10-08

### Fixed

- **The cap of six repositories dropped the newest one.** Repositories were
  listed in the order they were first touched, so in a session that touched
  seven, the one edited last was the one cut. The working directory's
  repository comes first, then the others newest first, in both the snapshot
  and the resume block.

## 0.2.0 — 2026-10-08

### Added

- **A resumed session learns what happened while it was away.** A SessionStart
  hook with matcher `resume` runs `context-keeper resume`. It hands the model
  the time of the last activity, how long ago it was, and for each repository
  touched the branch line, the uncommitted changes and the commits made since.
  It reads the transcript and the repositories, so a session that was never
  compacted gets it too. It writes nothing to disk.
- **Both hooks tell the user what they did,** in one line: `snapshot
  restored — N lines`, or `away 2d 3h; state of 3 repositories read now, 2 new
  commits`.

### Fixed

- **An unstaged change looked staged in the snapshot.** The output of `git
  status --short` lost the leading space of its first line, so ` M file` came
  out as `M file`.

## 0.1.1 — 2026-10-08

### Fixed

- **A typed `/compact` is no longer one of the last six requests.** The
  transcript records it as plain text, so it took a place in the snapshot
  that a real request should have.

## 0.1.0 — 2026-10-08

### Added

- **Claude Code keeps its exact state across compaction.** A PreCompact hook
  runs `context-keeper snapshot`, which writes the facts a summary loses to
  `~/.local/state/context-keeper/<session>.md`: the changed files, the git
  state of each repository touched, the newest kb state note, the open
  findings and the last six typed requests verbatim. A SessionStart hook with
  matcher `compact` runs `context-keeper restore` and hands the snapshot back
  right after compaction. The snapshot passes through secrets-redact when it
  is installed; the directory is mode 700 and each file 600.
- **Compaction starts at 400000 tokens.** install.sh sets `autoCompactWindow`
  unless the user already set it; `--window` takes another value in the range
  Claude Code accepts, 100000 to 1000000.
- **A rule tells the summary what to keep:** the task and its acceptance
  condition, the decisions with the options rejected, exact paths, commands
  and ids, and what is unfinished.
- **install.sh** is idempotent, keeps the user's own hooks and window, backs up
  a file about to change into `~/.local/state/context-keeper-backups` (three
  copies, never beside it), ends with a self-check, and takes everything of
  its own out with `--uninstall`. tests/test_keeper.sh has 24 cases.
