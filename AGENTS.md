# Development on the shared desktop

The user reported a GNOME/Wayland freeze associated with high memory pressure,
nearly exhausted swap, and an AppIndicator extension reload. Treat this as a
development constraint; a larger swap file is not a reason to increase load.

- Routine project work must not reload, enable, or disable desktop extensions,
  restart GNOME Shell, or close/manage the user's terminal windows.
- Run one local compilation at a time with Nim `--parallelBuild:1` and reduced
  priority (`nice -n 10` on Linux). Before starting, inspect `MemAvailable` and
  `/proc/pressure/memory`; defer compilation to CI if available memory is below
  6 GiB or the memory `full avg10` stall percentage is at least 2.
- Use focused local tests. Keep persistence test workers bounded to four small
  processes; run full native platform suites and heavier matrices in CI.
- Put development executables in `.ci/` and select them explicitly for tests.
  Preserve the user's configuration, credentials, and active installed binary
  during development. Test settings and keys in temporary configuration roots.
- When another session is changing the same checkout, use an isolated worktree
  and stage only the files owned by the current task.
