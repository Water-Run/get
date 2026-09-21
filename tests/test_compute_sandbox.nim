## Exercises computation capabilities against synthetic host resources only.
import std/[json, os, strutils, tempfiles, unittest]
import compute_sandbox
import exec

dispatchComputeWorker()

when defined(linux):
  suite "isolated query computation":
    test "Python arithmetic and shell substitution run with bounded scratch":
      let value = executeIsolatedProcess("python3", @["-c",
        "import json,tempfile,os; p=tempfile.mktemp(); open(p,'w').write('scratch'); " &
        "print(json.dumps({'sum':sum(range(10)),'tmp':p,'value':open(p).read()}))"], 5, 4096)
      checkpoint value.output
      require value.exitCode == 0
      let data = parseJson(value.output)
      check data["sum"].getInt == 45
      check data["value"].getStr == "scratch"
      check not fileExists(data["tmp"].getStr)
      check not dirExists(parentDir(data["tmp"].getStr))
      let shell = executeIsolatedCommand("printf '%s\\n' \"$(uname -s)\"", "bash", 5, 1024)
      check shell.exitCode == 0
      check shell.output.strip == "Linux"

    test "host files and symlink targets remain unchanged":
      let root = createTempDir("get-v4-compute-", "")
      defer: removeDir(root)
      let marker = root / "host.txt"
      writeFile(marker, "preserved")
      let program = "import os,pathlib; p=" & $(%marker) & "; " &
        "link=os.environ['TMPDIR']+'/link'; os.symlink(p,link); " &
        "open(link,'w').write('changed')"
      let value = executeIsolatedProcess("python3", @["-c", program], 5, 4096, root)
      check value.exitCode != 0
      check readFile(marker) == "preserved"
      # The host's /tmp remains readable even when cwd is inside it.
      let read = executeIsolatedProcess("python3", @["-c",
        "print(open('host.txt').read())"], 5, 4096, root)
      check read.exitCode == 0
      check read.output.strip == "preserved"

    test "network and Unix control sockets cannot be opened":
      for family in ["AF_INET", "AF_UNIX"]:
        let value = executeIsolatedProcess("python3", @["-c",
          "import socket; socket.socket(socket." & family & ")"], 5, 4096)
        check value.exitCode != 0
        check "Operation not permitted" in value.output

    test "host process IDs are absent and resource ceilings are installed":
      let program = "import os,resource,json; print(json.dumps({'pid':os.getpid()," &
        "'host_visible':os.path.exists('/proc/" & $getCurrentProcessId() & "')," &
        "'memory':resource.getrlimit(resource.RLIMIT_AS)[1]," &
        "'processes':resource.getrlimit(resource.RLIMIT_NPROC)[1]}))"
      let value = executeIsolatedProcess("python3", @["-c", program], 5, 4096)
      checkpoint value.output
      require value.exitCode == 0
      let data = parseJson(value.output)
      check data["pid"].getInt == 1
      check not data["host_visible"].getBool
      check data["memory"].getInt == 128 * 1024 * 1024
      check data["processes"].getInt == 8

    test "computation deadline and output bounds still apply":
      let slow = executeIsolatedProcess("python3", @["-c", "import time; time.sleep(10)"], 1, 1024)
      check slow.timedOut
      let large = executeIsolatedProcess("python3", @["-c", "print('x'*8192)"], 5, 1024)
      check large.truncated
      check large.output.len <= 1024
