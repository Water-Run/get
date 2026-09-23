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

# Documentation style

User-facing docs (README.md, README-zh.md, get.1, THIRD_PARTY_NOTICES.md) are
written for people, not for agents. Keep them that way when editing:

- Write for the current version only. No changelogs, release attestations, or
  "since vX.Y" history. Git history is the log.
- Say what a user needs and stop. Cut edge-case enumeration, exhaustive
  parameter semantics, and implementation internals (locking, hashing, atomic
  replacement). If a detail only matters when something breaks, it doesn't
  belong in the README — man pages may carry a little more, still trimmed.
- Plain sentences a person would say. No spec-legalese walls, no nested
  qualifiers, no "every X is Y; Z may differ when..." hedging chains.
- Calm, factual tone. Prefer "doesn't" / "不会" over "never" / "绝不". Soften a
  behavioral absolute with "by design" / "设计上". Describe what the tool does;
  don't preach absolutes.
- Use GitHub Markdown deliberately: tables for reference data, `<details>`
  for long lists (the full config table), blockquote notes for caveats. The
  area under the title carries only the language switch link — no badge or
  nav-link rows. Keep README.md and README-zh.md structurally in sync.
- Machine-only instructions (build memory limits, CI matrices, test worker
  caps) live here in AGENTS.md, not in user docs.
