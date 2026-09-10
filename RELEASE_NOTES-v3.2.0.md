# get v3.2.0

Code and system inspections now finish with an answer based on the collected evidence. Read-only aggregation and environment queries are more permissive, and old model-ranking and Markdown-command machinery has been removed.

- Allow AWK arithmetic, variables, arrays, pure builtins and END aggregation. External programs, output files and input-source mutation remain blocked.
- Give POSIX inspection processes a private disk scratch directory, writable inside the native read-only sandbox and removed after execution. Large sorts can spill without modifying the host workspace.
- Allow environment-only env/set queries, GNOME settings inspection, Git file-name metadata queries without redundant diff flags, and direct revision/blob reads.
- Exclude nested build, dependency and virtual-environment directories when gathering code composition. Supply the configured model identifier as context.
- Always interpret observations in auto/loop/parallel. Reserve one tool-free final answer turn after the configured inspection budget, with bounded evidence output if completion fails. Explicit direct mode retains one call and raw output.
- Remove model-name strength rankings, warning lists, model-dependent colors and Qwen-name sampling overrides. Any nonempty identifier is passed through unchanged.
- Remove v2 fenced-command and HTML-marker execution. Code examples remain text in every mode. Existing legacy protocol settings migrate to json.
- Replace the repetitive monolithic validation matrix with focused provider-independent task replay. Keep native execution, protocol, security and persistence regression tests; cap local persistence workers at four.

Compatibility: max-rounds now counts inspection turns, with at most one additional tool-free answer turn. Use --harness direct when raw output or automatic command caching is required. Auto answers can be cached explicitly with --cache. The cache behavior identity changes so older entries cannot replay under the new semantics. Existing configuration and credentials remain usable.

This release retains mandatory command validation and platform write protection. It does not install software, change system settings, or turn code examples into execution requests.
