## Tests bounded shell execution for get v3.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_exec_bounded.nim
## :License: AGPL-3.0
##
## This suite verifies normal output capture, byte caps, and process deadlines.
## It uses only read-only shell operations and runs independently of an API key.

{.experimental: "strictFuncs".}

import std/[envvars, os, strutils, unittest]

import exec
import command_policy

## Verifies bounded process execution and metadata.
suite "bounded command execution":
  test "uses startup-hook-free shell arguments":
    check shellArgsForTest("bash", "pwd") ==
      @["--noprofile", "--norc", "-c", "pwd"]
    check shellArgsForTest("fish", "pwd") ==
      @["--no-config", "-c", "pwd"]
    check shellArgsForTest("zsh", "pwd") == @["-f", "-c", "pwd"]
    check shellArgsForTest("cmd", "ver") ==
      @["/D", "/Q", "/V:OFF", "/C", "ver"]
    check shellArgsForTest("powershell", "Get-Location")[0 .. 1] ==
      @["-NoProfile", "-NonInteractive"]
    let powerShellCommand =
      shellArgsForTest("powershell", "Get-Location")[3]
    check "$PSHOME" in powerShellCommand
    check "SystemDirectory" in powerShellCommand
    check "Documents" notin powerShellCommand

  test "sanitizes executable child environment":
    let blockedNames = [
      "BASH_ENV", "SHELLOPTS", "PS4", "LD_LIBRARY_PATH",
      "RIPGREP_CONFIG_PATH", "TAR_OPTIONS", "TAPE", "JAVA_TOOL_OPTIONS",
      "OPENSSL_CONF", "GIT_TRACE", "PSMODULEPATH", "KUBECONFIG",
      "KUBE_EXTERNAL_DIFF", "DOCKER_CONFIG", "CORECLR_ENABLE_PROFILING",
      "MAKEFILES", "PIP_CONFIG_FILE", "NPM_CONFIG_SCRIPT_SHELL",
      "CARGO_HOME", "RUSTUP_HOME", "NIM_CONFIG_DIR", "NIMBLE_DIR",
      "GOFLAGS", "HOMEBREW_CACHE", "IFS", "UNZIPOPT", "PS_PERSONALITY",
      "DEVELOPER_DIR", "SWIFT_EXEC", "XCODE_XCCONFIG_FILE",
      "BASH_FUNC_uname%%", "GCONV_PATH", "GLIBC_TUNABLES",
      "GIO_EXTRA_MODULES", "GTK_MODULES", "QT_PLUGIN_PATH",
      "OCL_ICD_VENDORS", "LIBGL_DRIVERS_PATH", "VK_ICD_FILENAMES",
      "CUDA_INJECTION64_PATH", "LUA_INIT", "LUA_INIT_5_4",
      "SYSTEMD_GENERATOR_PATH", "SYSTEMD_ENVIRONMENT_GENERATOR_PATH"
    ]
    var previous: seq[tuple[name: string, existed: bool, value: string]] = @[]
    for name in blockedNames:
      previous.add((name, existsEnv(name), getEnv(name, "")))
      putEnv(name, "/tmp/untrusted-get-hook")
    try:
      for name in blockedNames:
        check childEnvironmentValueForTest(name) == ""
      check childEnvironmentValueForTest("PAGER") == "cat"
      check childEnvironmentValueForTest("GIT_OPTIONAL_LOCKS") == "0"
      check childEnvironmentValueForTest("GIT_NO_LAZY_FETCH") == "1"
      check childEnvironmentValueForTest("GIT_CONFIG_COUNT") == "3"
      check childEnvironmentValueForTest("GIT_CONFIG_KEY_0") ==
        "core.fsmonitor"
      check childEnvironmentValueForTest("GIT_CONFIG_KEY_2") ==
        "log.showSignature"
      check childEnvironmentValueForTest("GOENV") == "off"
      check childEnvironmentValueForTest("GOTOOLCHAIN") == "local"
      check childEnvironmentValueForTest(
        "NoDefaultCurrentDirectoryInExePath") == "1"
      when defined(posix):
        let pathExisted = existsEnv("PATH")
        let oldPath = getEnv("PATH", "")
        putEnv("PATH", ".::relative:/usr/bin:/tmp/tools:" & getCurrentDir())
        try:
          let childPath = childEnvironmentValueForTest("PATH").split(PathSep)
          check childPath.len > 0
          check childPath[0] == "/usr/bin"
          check "/tmp/tools" notin childPath
          check getCurrentDir() notin childPath
          check "." notin childPath
          check "relative" notin childPath
        finally:
          if pathExisted:
            putEnv("PATH", oldPath)
          else:
            delEnv("PATH")
        let homeExisted = existsEnv("HOME")
        let oldHome = getEnv("HOME", "")
        putEnv("HOME", "relative --output /tmp/marker")
        try:
          check childEnvironmentValueForTest("HOME") == "/"
          check childEnvironmentValueForTest("PWD") == getCurrentDir()
        finally:
          if homeExisted:
            putEnv("HOME", oldHome)
          else:
            delEnv("HOME")
    finally:
      for item in previous:
        if item.existed:
          putEnv(item.name, item.value)
        else:
          delEnv(item.name)

  when defined(posix):
    test "does not resolve the shell or reader from an untrusted PATH":
      let root = getTempDir() /
        ("get-v3-path-shadow-" & $getCurrentProcessId())
      createDir(root)
      let fakeShell = root / "bash"
      let fakeReader = root / "uname"
      let marker = root / "executed"
      writeFile(fakeShell,
        "#!/bin/sh\nprintf shell > '" & marker & "'\n")
      writeFile(fakeReader,
        "#!/bin/sh\nprintf reader > '" & marker & "'\n")
      for executable in [fakeShell, fakeReader]:
        setFilePermissions(executable, {
          fpUserRead, fpUserWrite, fpUserExec
        })
      let previousPath = getEnv("PATH", "")
      putEnv("PATH", root & $PathSep & previousPath)
      try:
        let value = executeCommandBounded(
          "uname -s", "bash", 2, 1024)
        check value.exitCode == 0
        check value.output.strip() notin ["shell", "reader"]
        check not fileExists(marker)
      finally:
        putEnv("PATH", previousPath)
        if fileExists(marker):
          removeFile(marker)
        if fileExists(fakeShell):
          removeFile(fakeShell)
        if fileExists(fakeReader):
          removeFile(fakeReader)
        if dirExists(root):
          removeDir(root)

    test "does not execute a BASH_ENV startup payload":
      let root = getTempDir() /
        ("get-v3-bash-env-" & $getCurrentProcessId())
      createDir(root)
      let startup = root / "startup.sh"
      let marker = root / "executed"
      if fileExists(marker):
        removeFile(marker)
      writeFile(startup, "printf injected > '" & marker & "'\n")
      let previous = getEnv("BASH_ENV", "")
      putEnv("BASH_ENV", startup)
      try:
        let value = executeCommandBounded(
          "printf 'ready'", "bash", 2, 1024)
        check value.output == "ready"
        check value.exitCode == 0
        check not fileExists(marker)
      finally:
        if previous.len > 0:
          putEnv("BASH_ENV", previous)
        else:
          delEnv("BASH_ENV")
        if fileExists(startup):
          removeFile(startup)
        if fileExists(marker):
          removeFile(marker)
        if dirExists(root):
          removeDir(root)

    test "does not import an exported Bash function over a reader name":
      let root = getTempDir() /
        ("get-v3-bash-function-" & $getCurrentProcessId())
      createDir(root)
      let marker = root / "executed"
      let variable = "BASH_FUNC_uname%%"
      let existed = existsEnv(variable)
      let previous = getEnv(variable, "")
      putEnv(variable,
        "() { printf injected > '" & marker & "'; }")
      try:
        let value = executeCommandBounded(
          "uname -s", "bash", 2, 1024)
        check value.exitCode == 0
        check value.output.strip().len > 0
        check not fileExists(marker)
      finally:
        if existed:
          putEnv(variable, previous)
        else:
          delEnv(variable)
        if fileExists(marker):
          removeFile(marker)
        if dirExists(root):
          removeDir(root)

    test "git no-ext-diff suppresses repository-defined helpers":
      let root = getTempDir() /
        ("get-v3-git-diff-" & $getCurrentProcessId())
      createDir(root)
      let content = root / "probe.txt"
      let attributes = root / ".gitattributes"
      let helper = root / "external-diff.sh"
      let marker = root / "executed"
      writeFile(content, "before\n")
      writeFile(attributes, "probe.txt diff=untrusted\n")
      writeFile(helper,
        "#!/bin/sh\nprintf executed > '" & marker & "'\ncat \"$2\"\n")
      setFilePermissions(helper, {
        fpUserRead, fpUserWrite, fpUserExec
      })
      try:
        for command in [
          "git -C '" & root & "' init -q",
          "git -C '" & root & "' config user.name probe",
          "git -C '" & root & "' config user.email probe@example.invalid",
          "git -C '" & root & "' config diff.untrusted.command '" & helper & "'",
          "git -C '" & root & "' add probe.txt .gitattributes external-diff.sh",
          "git -C '" & root & "' commit -qm baseline"
        ]:
          let setup = executeCommandBounded(command, "bash", 5, 16_384)
          check setup.exitCode == 0
        writeFile(content, "after\n")
        let value = executeCommandBounded(
          "git -C '" & root & "' diff --no-ext-diff",
          "bash", 5, 16_384)
        check value.exitCode == 0
        check not fileExists(marker)
      finally:
        if dirExists(root):
          removeDir(root)

    test "safe git queries cannot invoke repository filter helpers":
      let root = getTempDir() /
        ("get-v3-git-filters-" & $getCurrentProcessId())
      createDir(root)
      let content = root / "probe.txt"
      let attributes = root / ".gitattributes"
      let cleanHelper = root / "clean-filter.sh"
      let textHelper = root / "textconv-filter.sh"
      let fsmonitorHelper = root / "fsmonitor-hook.sh"
      let cleanMarker = root / "clean-executed"
      let textMarker = root / "textconv-executed"
      let fsmonitorMarker = root / "fsmonitor-executed"
      writeFile(content, "before\n")
      writeFile(attributes,
        "probe.txt filter=untrusted diff=untrusted\n")
      writeFile(cleanHelper,
        "#!/bin/sh\nprintf executed > '" & cleanMarker & "'\ncat\n")
      writeFile(textHelper,
        "#!/bin/sh\nprintf executed > '" & textMarker & "'\ncat \"$1\"\n")
      writeFile(fsmonitorHelper,
        "#!/bin/sh\nprintf executed > '" & fsmonitorMarker & "'\nprintf '\\n'\n")
      for helper in [cleanHelper, textHelper, fsmonitorHelper]:
        setFilePermissions(helper, {
          fpUserRead, fpUserWrite, fpUserExec
        })
      try:
        for command in [
          "git -C '" & root & "' init -q",
          "git -C '" & root & "' config user.name probe",
          "git -C '" & root & "' config user.email probe@example.invalid",
          "git -C '" & root & "' config filter.untrusted.clean '" &
            cleanHelper & "'",
          "git -C '" & root & "' config diff.untrusted.textconv '" &
            textHelper & "'",
          "git -C '" & root & "' config core.fsmonitor '" &
            fsmonitorHelper & "'",
          "git -C '" & root & "' add probe.txt .gitattributes",
          "git -C '" & root & "' commit -qm baseline"
        ]:
          let setup = executeCommandBounded(command, "bash", 5, 16_384)
          check setup.exitCode == 0
        writeFile(content, "after!\n")
        let stage = executeCommandBounded(
          "git -C '" & root & "' add probe.txt", "bash", 5, 16_384)
        check stage.exitCode == 0
        if fileExists(cleanMarker):
          removeFile(cleanMarker)
        if fileExists(textMarker):
          removeFile(textMarker)
        if fileExists(fsmonitorMarker):
          removeFile(fsmonitorMarker)

        let command = "git -C '" & root &
          "' diff --cached --no-ext-diff --no-textconv"
        check checkReadOnlyCommand(command, "bash").allowed
        let value = executeCommandBounded(command, "bash", 5, 16_384)
        check value.exitCode == 0
        check value.output.contains("after!")
        check not fileExists(cleanMarker)
        check not fileExists(textMarker)
        check not fileExists(fsmonitorMarker)
        writeFile(content, "worktree!\n")
        let metadataCommand = "git -C '" & root &
          "' diff-files --name-only --no-ext-diff --no-textconv"
        check checkReadOnlyCommand(metadataCommand, "bash").allowed
        let metadata = executeCommandBounded(
          metadataCommand, "bash", 5, 16_384)
        check metadata.exitCode == 0
        check metadata.output.contains("probe.txt")
        check not fileExists(cleanMarker)
        check not fileExists(textMarker)
        check not fileExists(fsmonitorMarker)
        check not checkReadOnlyCommand(
          "git status --short", "bash").allowed
        check not checkReadOnlyCommand(
          "git diff --no-ext-diff --no-textconv", "bash").allowed
      finally:
        if dirExists(root):
          removeDir(root)

    test "captures normal command output":
      let value = executeCommandBounded(
        "printf 'ready'", "bash", 2, 1024)
      check value.output == "ready"
      check value.exitCode == 0
      check not value.timedOut
      check not value.truncated

    test "native read-only sandbox preserves reads and blocks file writes":
      let readValue = executeCommandBounded(
        "printf 'sandbox-ready'", "bash", 2, 1024,
        readOnlySandbox = true)
      check readValue.output == "sandbox-ready"
      check readValue.exitCode == 0

      if readOnlySandboxAvailableForTest():
        let root = getTempDir() /
          ("get-v3-readonly-sandbox-" & $getCurrentProcessId())
        createDir(root)
        let marker = root / "unexpected-write"
        try:
          let writeValue = executeCommandBounded(
            "touch '" & marker & "'", "bash", 2, 4096,
            readOnlySandbox = true)
          check writeValue.exitCode != 0
          check not fileExists(marker)
          check writeValue.output.toLowerAscii().contains("read-only") or
            writeValue.output.toLowerAscii().contains("operation not permitted")
          let nullValue = executeCommandBounded(
            "printf ignored >/dev/null", "bash", 2, 1024,
            readOnlySandbox = true)
          check nullValue.exitCode == 0
        finally:
          if fileExists(marker):
            removeFile(marker)
          if dirExists(root):
            removeDir(root)

    when defined(macosx):
      test "macOS launchctl compatibility preserves the service table":
        let value = executeCommandBounded(
          "launchctl list | head -n 5", "zsh", 3, 16_384,
          readOnlySandbox = true)
        check value.exitCode == 0
        check value.output.contains("PID")
        check value.output.contains("Label")

    test "caps captured output":
      let value = executeCommandBounded(
        "printf '1234567890'", "bash", 2, 5)
      check value.output == "12345"
      check value.truncated
      check not value.timedOut

    test "stops a silent process at its deadline":
      let value = executeCommandBounded(
        "sleep 2", "bash", 1, 1024)
      check value.timedOut
      check value.elapsedMs >= 900
      check value.elapsedMs < 1800
      check value.exitCode != 0

    test "stdin readers receive EOF without consuming the deadline":
      let value = executeCommandBounded("cat", "bash", 2, 1024)
      check value.exitCode == 0
      check value.output == ""
      check not value.timedOut
      check value.elapsedMs < 1000

    test "closing output early retains the configured deadline":
      let value = executeCommandBounded(
        "exec 1>&- 2>&-; sleep 10", "bash", 2, 1024)
      check value.timedOut
      check value.elapsedMs >= 1900
      check value.elapsedMs < 2800

    test "deadline kills descendants even after their shell exits on TERM":
      let root = getTempDir() / ("get-v3-descendant-" & $getCurrentProcessId())
      createDir(root)
      let marker = root / "survived"
      defer: removeDir(root)
      let value = executeCommandBounded(
        "sh -c 'trap \"\" TERM; sleep 2; touch \"" & marker &
          "\"' & wait", "bash", 1, 1024)
      check value.timedOut
      sleep(1300)
      check not fileExists(marker)

    when defined(linux):
      test "native sandbox preserves the command deadline":
        if readOnlySandboxAvailableForTest():
          let value = executeCommandBounded(
            "sleep 10", "bash", 1, 1024,
            readOnlySandbox = true)
          check value.timedOut
          check value.elapsedMs >= 900
          check value.elapsedMs < 1800
          check value.exitCode != 0

    test "keeps output produced before the deadline":
      let value = executeCommandBounded(
        "printf 'started'; sleep 2", "bash", 1, 1024)
      check value.output == "started"
      check value.timedOut
      check value.elapsedMs >= 900
      check value.elapsedMs < 1800
      check value.exitCode != 0
  else:
    test "captures normal command output":
      let value = executeCommandBounded(
        "echo ready", "cmd", 2, 1024)
      check value.output.strip() == "ready"
      check value.exitCode == 0

    test "caps captured output":
      let value = executeCommandBounded(
        "echo 1234567890", "cmd", 2, 5)
      check value.output == "12345"
      check value.truncated
      check not value.timedOut

    test "stops a silent process at its deadline":
      let value = executeCommandBounded(
        "ping -n 3 127.0.0.1 >NUL", "cmd", 1, 1024)
      check value.timedOut
      check value.elapsedMs >= 900
      check value.elapsedMs < 2_000
      check value.exitCode != 0
