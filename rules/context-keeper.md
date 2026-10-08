# Compaction: what the summary must keep

When this conversation is compacted, the summary keeps, in this order:

1. the task in hand and its acceptance condition, in the user's words;
2. every decision the user made, with the option they rejected;
3. paths, commands, ids, versions and error strings exactly as written;
4. what is unfinished: the next step, open questions, unverified claims.

It drops what can be read again: file contents, command output, search
results. Right after compaction a `context-keeper snapshot` block lists the
changed files, git state and the last requests verbatim, read from the machine;
where it and the summary disagree, the snapshot wins.
