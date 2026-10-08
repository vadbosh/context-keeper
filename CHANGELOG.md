# Changelog

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
