## Tests the mandatory get v3 read-only command policy.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_command_policy.nim
## :License: AGPL-3.0
##
## This suite covers common inspection commands and bypass classes including
## redirection, in-place flags, package managers, interpreters, and remote IO.

{.experimental: "strictFuncs".}

import std/[unittest]

import command_policy

## Verifies allowed inspections and rejected mutations.
suite "mandatory read-only command policy":
  test "allows common local inspections":
    check checkReadOnlyCommand("pwd").allowed
    check checkReadOnlyCommand("git status --short").allowed
    check checkReadOnlyCommand("find . -maxdepth 2 -type f | head").allowed
    check checkReadOnlyCommand("curl -sS https://example.com").allowed
    check checkReadOnlyCommand("uname -a 2>/dev/null").allowed
    check checkReadOnlyCommand("command 2>&1 | head").allowed

  test "rejects destructive utility names":
    check not checkReadOnlyCommand("/bin/rm -rf ./data").allowed
    check not checkReadOnlyCommand("sudo chmod 777 file").allowed
    check not checkReadOnlyCommand("find . -delete").allowed

  test "rejects regular-file output redirection":
    check not checkReadOnlyCommand("printf value > result.txt").allowed
    check not checkReadOnlyCommand("date >> result.txt").allowed
    check checkReadOnlyCommand("printf 'a > b'").allowed

  test "rejects state-changing subcommands and flags":
    check not checkReadOnlyCommand("git checkout main").allowed
    check not checkReadOnlyCommand("docker run alpine").allowed
    check not checkReadOnlyCommand("kubectl apply -f app.yaml").allowed
    check not checkReadOnlyCommand("pip install package").allowed
    check not checkReadOnlyCommand("sed -i 's/a/b/' file").allowed

  test "rejects inline code and mutating network requests":
    check not checkReadOnlyCommand("python3 -c 'open(\"x\",\"w\")'").allowed
    check not checkReadOnlyCommand("node -e 'process.exit()'").allowed
    check not checkReadOnlyCommand("bash -c 'printf x > file'").allowed
    check not checkReadOnlyCommand("cmd /c dir").allowed
    check not checkReadOnlyCommand("curl -X POST https://example.com").allowed
    check not checkReadOnlyCommand("curl -XPOST https://example.com").allowed
    check not checkReadOnlyCommand("curl --data x=1 https://example.com").allowed
    check not checkReadOnlyCommand("curl --data=x https://example.com").allowed
    check not checkReadOnlyCommand("curl -o file https://example.com").allowed
    check not checkReadOnlyCommand("curl -O https://example.com/file").allowed
    check not checkReadOnlyCommand("wget https://example.com/file").allowed
    check checkReadOnlyCommand("curl -fsSL https://example.com").allowed
