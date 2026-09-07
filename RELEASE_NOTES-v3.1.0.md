# get v3.1.0 — Markdown output and read-only fixes

get 3.1.0 adds configurable Markdown rendering and fixes reproducible read-only policy bypasses and execution failures found during the whole-program review.

- Model answers render headings, lists, emphasis, links, quotes, code blocks, and tables in interactive terminals. `get set markdown true` is the default; use `false` or per-query `--no-markdown` for source text. Pipes and raw command output retain their original text. Rendering needs no external program.
- Ordinary answer code blocks in `auto` and `native` mode are examples. They no longer accidentally become tools, including when the request explicitly disables tool use. Bare v2 command fences remain available in explicit `legacy` mode.
- Fixes quote-escape and glob-option injection, Git working-tree blame filters, RPM macros, embedded nft/tmux commands, abbreviated ip mutations, and platform-specific null-device handling. Normal bounded readers remain supported.
- Fixes safe command rewrites during double-check review, rejects unclear approvals, and caches the command actually executed.
- Closes unused stdin, applies one deadline after stdout closes, and terminates remaining process-group descendants after timeout.
- Uses private atomic replacement for configuration and keys, retains complete multiline log entries, and requires an exact acknowledgment from `get isok`.

Existing configuration is retained. The new `markdown` field defaults to true when absent. Cache behavior identity changes so previous-policy entries are not reused under the new semantics.

Download the ZIP matching your platform, extract it, and run `python get_ready.py`. The Windows ZIP includes the required OpenSSL/zlib DLLs. Linux x64, Windows x64, and macOS arm64 assets include internal checksums and build/provider provenance; the release also provides outer ZIP checksums and an asset manifest.

The release validation record is in [VALIDATION-v3.1.0.md](https://github.com/Water-Run/get/blob/v3.1.0/VALIDATION-v3.1.0.md). The [review](https://github.com/Water-Run/get/blob/v3.1.0/CODE_REVIEW-v3.md) explains reproductions, fixes, and remaining medium-priority issues: simultaneous configuration/log updates are not transactional, and NO_PROXY port-specific matching is incomplete. Read-only semantics depend on trusted tools; OS filesystem sandbox coverage differs by platform. No new performance improvement claim is made in this release.
