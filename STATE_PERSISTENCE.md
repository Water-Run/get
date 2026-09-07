# Configuration and log concurrency

This follow-up addresses the configuration/log concurrency issue recorded in
[the v3 review](CODE_REVIEW-v3.md). Concurrent `get set` operations now lock the
entire read, validation, and write sequence, so changing different options does
not discard another process's update. Key writes, full config saves, and reset
use the same settings lock. Invalid settings release their lock without saving.

Logs serialize append, retention, and cleaning. Bounded retention writes a
private replacement containing only the retained entries. Historical multiline
entries are scanned incrementally; counting and cleaning do not load the entire
file, and trimming keeps only the requested tail plus the current entry.

Locks use POSIX `flock` or Windows `LockFileEx`, with a five-second monotonic
wait budget for lock contention. The OS releases ownership when a process exits, including after a
crash. Persistent, empty `.settings.lock` and `get.log.lock` sidecars are retained
so an unlink/recreate race cannot create two independent locks. POSIX lock files
are private, regular files and cannot follow a symbolic link. Windows readers
also take the settings lock to prevent replacement racing an open reader.

These are cooperating-process locks. They serialize writers using this version;
older binaries and external editors do not participate. A full config save or
reset intentionally replaces all settings. Two-file reset is not a crash-atomic
database transaction, and power-loss durability is not claimed. Unlimited logs
still grow on disk when `log-max-entries=0`; retained memory depends on the
configured entry count and the largest historical entry.

The bounded worker regressions cover concurrent setters, reset, whole log
entries with/without retention, serialized cleaning, lock deadlines, owner
termination, and symbolic-link rejection. Local work follows [AGENTS.md](AGENTS.md)
to limit pressure on the shared desktop.

API behavior was checked against the [flock manual](https://man7.org/linux/man-pages/man2/flock.2.html)
and [Microsoft LockFileEx documentation](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex).
