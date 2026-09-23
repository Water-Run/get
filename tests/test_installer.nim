## Tests the pieces of `get update` and `get uninstall` that need no network.
import std/[os, osproc, strutils, tables, tempfiles, unittest]
import installer

proc zipOf(files: openArray[(string, string)]): string =
  ## Builds a ZIP with Python so the test does not depend on a zip library.
  let work = createTempDir("get-zip-", "")
  defer: removeDir(work)
  var script = "import zipfile\nz = zipfile.ZipFile('" & (work / "t.zip") & "', 'w')\n"
  for (name, body) in files:
    script.add("z.writestr(" & repr(name) & ", " & repr(body) & ")\n")
  script.add("z.close()\n")
  writeFile(work / "make.py", script)
  doAssert execCmd("python3 " & quoteShell(work / "make.py")) == 0
  readFile(work / "t.zip")

suite "update package checks":
  test "entries stay flat inside the package directory":
    let good = zipOf([("get-v5.0.0-linux-x64/get-linux-x64", "bin"),
      ("get-v5.0.0-linux-x64/SHA256SUMS", "x")])
    check checkedZipEntriesForTest(good, "get-v5.0.0-linux-x64") ==
      @["get-linux-x64", "SHA256SUMS"]
    for bad in ["get-v5.0.0-linux-x64/../evil", "/etc/passwd",
        "other/get-linux-x64", "get-v5.0.0-linux-x64/sub/deep",
        "get-v5.0.0-linux-x64\\evil"]:
      expect InstallError:
        discard checkedZipEntriesForTest(zipOf([(bad, "x")]), "get-v5.0.0-linux-x64")
    expect InstallError:
      discard checkedZipEntriesForTest("not a zip", "get-v5.0.0-linux-x64")

  test "checksum lists parse with either separator":
    let sums = parseSumsForTest("ABC  get-linux-x64\ndef *get.1\n\n")
    check sums["get-linux-x64"] == "abc"
    check sums["get.1"] == "def"

  test "downloads only come from GitHub over HTTPS":
    check allowedHostForTest("https://api.github.com/repos/Water-Run/get/releases/latest")
    check allowedHostForTest("https://objects.githubusercontent.com/x")
    check not allowedHostForTest("http://github.com/Water-Run/get")
    check not allowedHostForTest("https://evil.example/get.zip")

suite "uninstall":
  test "only the installer's PATH block is removed":
    let work = createTempDir("get-rc-", "")
    defer: removeDir(work)
    let rc = work / ".bashrc"
    writeFile(rc, "alias ll='ls -l'\n\n# >>> get installer >>>\n" &
      "export PATH=\"x:$PATH\"\n# <<< get installer <<<\nexport EDITOR=vi\n")
    check removeRcBlockForTest(rc)
    let content = readFile(rc)
    check "get installer" notin content
    check "alias ll" in content
    check "EDITOR=vi" in content
    check not removeRcBlockForTest(rc)
    check not removeRcBlockForTest(work / "missing")
