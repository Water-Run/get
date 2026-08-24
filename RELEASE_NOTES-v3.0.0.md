# get v3.0.0 — fast, modern, production-ready

Version 3.0 is the largest runtime update in `get` so far. It replaces the
separate instance/agent paths with one provider-independent Harness, removes
avoidable model calls and polling delays, and hardens execution, transport,
cache persistence, and Windows support.

## Highlights

- One typed `Model → Action → Policy → Tool → Observation` runtime.
- Four strategies over the same core: `auto`, `direct`, `loop`, and
  `parallel`.
- Native function tools, strict structured-JSON fallback, and isolated v2
  Markdown compatibility parsing.
- One model call for routine work; cache hits require zero provider calls.
- Reused HTTP connections, immediate completion wakeups, bounded retries,
  response-size limits, redirect protection, and robust provider parsing.
- Real bounded parallel execution with deterministic result ordering.
- Mandatory read-only policy, command deadlines, output caps, and
  cross-platform process-tree cancellation.
- Cache schema v3 with SHA-256 context identities, cross-process locking,
  durable atomic snapshots, deterministic eviction, and backup recovery.
- Native Windows hardening: DPAPI-protected API keys, PowerShell/cmd support,
  native CI, and bundled OpenSSL 3.5.7 LTS runtime libraries.

## Install

The release archive contains Linux x86_64, Windows x86_64, and macOS arm64
binaries in one flat package:

```bash
python get_ready.py
get version
```

Keep all files together while running the installer. Windows requires the two
bundled OpenSSL DLLs; the installer copies them beside `get.exe`.

Before installation, compare the archive with `get-v3.0.0.zip.sha256`. The
archive also contains `SHA256SUMS` for every payload file.

## Upgrade notes

- Existing v2 configuration is migrated to schema v3.
- `instance=true` becomes `harness=direct`; otherwise `auto` is the default.
- Cache schema v3 intentionally does not reuse incompatible v2 entries.
- The mandatory read-only command policy cannot be disabled.
- Windows builds use Nim `refc` while Linux and macOS retain ORC.
- Windows now requires the bundled `libcrypto-3.dll`, `libssl-3.dll`, and
  `zlib1.dll`; v2 OpenSSL 1.1 DLLs are not used.

## Compatibility

- Linux x86_64
- Windows 10/11 x86_64
- macOS Apple Silicon (arm64)

The binaries are currently distributed without platform code signing. Windows
SmartScreen or macOS Gatekeeper may therefore display an unrecognized
publisher warning.

Full documentation is in `README.md` and `README-zh.md`.
