# get v3.2.0 validation

The canonical source commit is `3defeab1785c71c7ebdae5750bdd5e3297ead4eb`.
[Native candidate run 34459041437](https://github.com/Water-Run/get/actions/runs/34459041437)
passed on Linux x64, Windows x64 and macOS arm64 with Nim 2.2.10.

| Native target | Nim unit tests passed | CLI tests passed | CLI skips |
| --- | ---: | ---: | --- |
| Linux x64 | 153 | 41 | None |
| Windows x64 | 139 | 39 | Two POSIX-only terminal/process tests |
| macOS arm64 | 152 | 41 | None |

Each target ran all 15 native Nim test files, built its release binary, and
passed HTTPS runtime and installer smoke checks. Platform-specific Nim tests
are selected at compilation. Policy tests include the safe/attack corpus and
generated negative variants; their individual inputs are not counted as
separate unit tests in the table.

Focused Linux checks also covered fish and bash CLI behavior, AWK aggregation
and forbidden side effects, sandbox scratch cleanup, external sort spill,
native/JSON protocol handling, observation budgets and final-answer fallback.
Full native platform suites ran in CI; local compilation used one reduced-priority
worker after checking memory availability and pressure.

The exact canonical Linux binary passed all nine real-provider replay cases
using the configured `deepseek-flash` identifier and fish shell. The identifier
is recorded as supplied by the provider configuration; no capability ranking
or backend-version inference is made from its spelling.

- Exact language counts in a fixture with nested generated/dependency trees.
- Code lookup with a verified source token and condition.
- Exact Python source-line counts, independently known from the fixture.
- Environment inspection with an independently known value.
- No-match handling with a zero result.
- One-tool inspection budget followed by an evidence-based final answer.
- A code example returned as text without tool execution.
- System memory inspection compared with the host's actual `MemTotal`.
- The original language-composition query in a real multi-language repository.

Each scenario ran once in the successful replay, without semantic retries.
The eight fixtures verify task-specific results; the real-repository replay
requires successful inspection and an answer naming at least three observed
languages. Its file counts were also checked independently. The earlier
candidate exposed an all-or-none tool-batch budget bug; the fix was included
before rebuilding and repeating the full replay. Tool discovery and serial
source-file reading were then broadened, and the environment prompt was
clarified to distinguish shell expansion from environment inspection.

An earlier replay of the final binary passed 7/9 cases. Its budget question
called a comparison literal a constant definition; the final question names
the requested literal precisely. One real-project response also ended in
bounded evidence fallback. After clarifying the fixture, the complete suite
passed 9/9 in one invocation. The public record includes the earlier outcome;
these focused results do not claim that every model response will succeed.

Linux payload SHA-256:

```text
757b984d66252a014cedfec71527c7d7788f6936c1b20a05ee2a7f8b6adf8fce
```

[provider validation record](https://github.com/Water-Run/get/blob/v3.2.0/provider-validation-v3.2.0.json) records the
nine passing cases, zero failures and zero skips. Provider testing used
temporary configuration roots; hashes confirm that the live configuration,
credentials and installed binary were preserved. Private source contents,
provider responses and credentials are excluded from the public attestation.

Release assembly requires all three native gates to pass again and requires
the Linux payload to match this digest. Packaged `BUILDINFO.json` and the
appended native attestation identify that assembly run and all payloads.
The public asset manifest records archive integrity, architecture and byte
identity checks, plus isolated Linux fresh-install and upgrade verification.

Historical model matrices and performance numbers are not v3.2.0 evidence.
This release makes no new performance claim.
