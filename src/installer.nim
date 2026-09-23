## Self-update and uninstall.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: installer.nim
## :License: AGPL-3.0
##
## ``get update`` reads the latest GitHub release of this repository, downloads
## the package for this platform into a temporary directory, and installs it
## only when both the release checksum and the package's own SHA256SUMS match.
## With Python it hands over to the package's ``get_ready.py --update``;
## without Python it copies the documented files itself. No model is called.
##
## ``get uninstall`` removes what the installer placed: the program, the man
## page, the Windows runtime DLLs, and the PATH entry. Configuration, key,
## log, and cache stay unless ``--purge`` is given.

{.experimental: "strictFuncs".}

import std/[httpclient, json, os, osproc, strformat, strutils, tables, tempfiles, uri]

import checksums/sha2

import llm
import style
import tls_context
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const RELEASE_API_URL = "https://api.github.com/repos/Water-Run/get/releases/latest"

## Release assets must come from this repository's download path.
const RELEASE_DOWNLOAD_PREFIX = "https://github.com/Water-Run/get/releases/download/"

## Hosts GitHub redirects release downloads to.
const DOWNLOAD_REDIRECT_HOSTS = ["objects.githubusercontent.com",
  "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"]

const MAX_API_BYTES = 4 * 1024 * 1024
const MAX_PACKAGE_BYTES = 256 * 1024 * 1024
const MAX_REDIRECTS = 5
const HTTP_TIMEOUT_MS = 60_000

const RC_MARK_BEGIN = "# >>> get installer >>>"
const RC_MARK_END = "# <<< get installer <<<"

when defined(windows):
  const WINDOWS_RUNTIME_FILES = ["libcrypto-3.dll", "libssl-3.dll", "zlib1.dll"]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  InstallError* = object of GetError

  ## Where the installer puts things on this platform.
  InstallPaths = object
    binary: string
    man: string      ## Empty on Windows.
    dir: string      ## Directory added to PATH.

# ---------------------------------------------------------------------------
# Private helpers — platform
# ---------------------------------------------------------------------------

func implPlatformTag(): string =
  when defined(windows): "windows-x64"
  elif defined(macosx): "macos-arm64"
  else: "linux-x64"

func implPayloadName(): string =
  when defined(windows): "get-windows-x64.exe"
  elif defined(macosx): "get-macos-arm64"
  else: "get-linux-x64"

proc implInstallPaths(): InstallPaths =
  when defined(windows):
    var local = getEnv("LOCALAPPDATA")
    if local.len == 0: local = getHomeDir() / "AppData" / "Local"
    let dir = local / "Programs" / "get"
    result = InstallPaths(binary: dir / "get.exe", man: "", dir: dir)
  else:
    let home = getHomeDir()
    result = InstallPaths(binary: home / ".local" / "bin" / "get",
      man: home / ".local" / "share" / "man" / "man1" / "get.1",
      dir: home / ".local" / "bin")

proc implFindPython(): string =
  for name in ["python3", "python", "py"]:
    let found = findExe(name)
    if found.len > 0:
      return found

func implStripV(tag: string): string =
  if tag.len > 0 and tag[0] in {'v', 'V'}: tag[1 .. ^1] else: tag

proc implSha256File(path: string): string =
  var state = initSha_256()
  var file = open(path, fmRead)
  defer: file.close()
  var buffer = newString(1 shl 16)
  while true:
    let count = file.readBuffer(addr buffer[0], buffer.len)
    if count <= 0: break
    state.update(buffer.toOpenArray(0, count - 1))
  result = toLowerAscii($state.digest())

## Parses ``<sha256>  <name>`` lines.
func implParseSums(text: string): Table[string, string] =
  for line in text.splitLines():
    let parts = line.strip().splitWhitespace(maxsplit = 1)
    if parts.len == 2:
      result[parts[1].strip(chars = {'*', ' '})] = toLowerAscii(parts[0])

# ---------------------------------------------------------------------------
# Private helpers — download
# ---------------------------------------------------------------------------

func implAllowedHost(url: string): bool =
  let host = toLowerAscii(parseUri(url).hostname)
  result = parseUri(url).scheme == "https" and
    (host in ["api.github.com", "github.com"] or host in DOWNLOAD_REDIRECT_HOSTS)

## Fetches ``url`` over verified TLS, following GitHub's redirects only to
## GitHub hosts. Each hop gets a context verified for its own hostname.
proc implFetch(url: string, maxBytes: int, preferSystemProxy: bool,
    accept = "application/octet-stream"): string =
  var current = url
  for hop in 0 .. MAX_REDIRECTS:
    if not implAllowedHost(current):
      raise newException(InstallError, "refusing to download from " & current)
    let proxy = detectProxyUrl(current, preferSystemProxy)
    let client =
      if proxy.len > 0:
        newHttpClient(maxRedirects = 0, timeout = HTTP_TIMEOUT_MS,
          sslContext = newTransportSslContext(current), proxy = newProxy(proxy))
      else:
        newHttpClient(maxRedirects = 0, timeout = HTTP_TIMEOUT_MS,
          sslContext = newTransportSslContext(current))
    defer: client.close()
    client.headers = newHttpHeaders({"User-Agent": APP_NAME & "/" & APP_VERSION,
      "Accept": accept})
    let response = client.get(current)
    let code = response.code.int
    if code in [301, 302, 303, 307, 308]:
      current = $combine(parseUri(current), parseUri(response.headers.getOrDefault("location")))
      continue
    if code != 200:
      raise newException(InstallError, fmt"HTTP {code} from {parseUri(current).hostname}")
    let declared = response.contentLength()
    if declared > maxBytes:
      raise newException(InstallError, "download is larger than expected")
    result = response.body
    if result.len > maxBytes:
      raise newException(InstallError, "download is larger than expected")
    return
  raise newException(InstallError, "too many redirects")

# ---------------------------------------------------------------------------
# Private helpers — archive
# ---------------------------------------------------------------------------

func implU16(data: string, at: int): int =
  int(uint8(data[at])) or (int(uint8(data[at + 1])) shl 8)

func implU32(data: string, at: int): int =
  implU16(data, at) or (implU16(data, at + 2) shl 16)

## Lists the entry names of a ZIP archive from its central directory, and
## rejects any entry that could land outside ``root/`` or is a symlink.
func implCheckedZipEntries(data: string, root: string): seq[string] =
  const EOCD = "PK\x05\x06"
  const CENTRAL = "PK\x01\x02"
  let eocd = data.rfind(EOCD)
  if eocd < 0 or eocd + 22 > data.len:
    raise newException(InstallError, "package is not a ZIP archive")
  let count = implU16(data, eocd + 10)
  var cursor = implU32(data, eocd + 16)
  for index in 0 ..< count:
    if cursor < 0 or cursor + 46 > data.len or data[cursor ..< cursor + 4] != CENTRAL:
      raise newException(InstallError, "package ZIP directory is damaged")
    let nameLen = implU16(data, cursor + 28)
    let extraLen = implU16(data, cursor + 30)
    let commentLen = implU16(data, cursor + 32)
    let external = implU32(data, cursor + 38)
    if cursor + 46 + nameLen > data.len:
      raise newException(InstallError, "package ZIP directory is damaged")
    let name = data[cursor + 46 ..< cursor + 46 + nameLen]
    let unixMode = (external shr 16) and 0o170000
    if unixMode == 0o120000:
      raise newException(InstallError, "package contains a symbolic link: " & name)
    let inside = name[min(root.len + 1, name.len) .. ^1]
    if not name.startsWith(root & "/") or '\\' in name or ':' in name or
        '\0' in name or ".." in name.split('/') or '/' in inside.strip(chars = {'/'}):
      raise newException(InstallError, "package entry is outside its directory: " & name)
    if inside.len > 0:
      result.add(inside)
    cursor += 46 + nameLen + extraLen + commentLen

proc implRun(command: string, args: seq[string]): int =
  let process = startProcess(command, args = args,
    options = {poUsePath, poParentStreams})
  defer: process.close()
  result = process.waitForExit()

## Extracts with Python when present, otherwise with unzip or bsdtar.
proc implExtract(archive, destination, python: string) =
  var code = -1
  if python.len > 0:
    code = implRun(python, @["-c",
      "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])",
      archive, destination])
  elif findExe("unzip").len > 0:
    code = implRun("unzip", @["-q", archive, "-d", destination])
  else:
    for tool in ["bsdtar", "tar"]:
      if findExe(tool).len > 0:
        code = implRun(tool, @["-xf", archive, "-C", destination])
        if code == 0: break
  if code != 0:
    raise newException(InstallError,
      "could not unpack the package; install Python or unzip and try again")

# ---------------------------------------------------------------------------
# Private helpers — copy install
# ---------------------------------------------------------------------------

## Replaces ``target`` by renaming a finished copy over it, so a running
## program keeps its old file until it exits.
proc implReplaceFile(source, target: string, executable: bool) =
  createDir(target.parentDir)
  let staging = target & ".new"
  copyFile(source, staging)
  if executable:
    setFilePermissions(staging, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  moveFile(staging, target)

func implPsQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

## Runs a PowerShell script detached so it can finish after this process.
proc implSpawnPowerShell(script: string) =
  let path = getTempDir() / ("get-" & $getCurrentProcessId() & ".ps1")
  writeFile(path, script & "\r\nRemove-Item -LiteralPath " & implPsQuote(path) &
    " -ErrorAction SilentlyContinue\r\n")
  let process = startProcess("powershell.exe", args = @["-NoProfile",
    "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", path],
    options = {poUsePath, poDaemon})
  process.close()

proc implCopyInstall(package: string, paths: InstallPaths) =
  when defined(windows):
    var script = "Wait-Process -Id " & $getCurrentProcessId() &
      " -ErrorAction SilentlyContinue\r\n"
    script.add("New-Item -ItemType Directory -Force -Path " &
      implPsQuote(paths.dir) & " | Out-Null\r\n")
    script.add("Copy-Item -Force -LiteralPath " &
      implPsQuote(package / implPayloadName()) & " -Destination " &
      implPsQuote(paths.binary) & "\r\n")
    for name in WINDOWS_RUNTIME_FILES:
      script.add("Copy-Item -Force -LiteralPath " & implPsQuote(package / name) &
        " -Destination " & implPsQuote(paths.dir / name) & "\r\n")
    implSpawnPowerShell(script)
  else:
    implReplaceFile(package / implPayloadName(), paths.binary, executable = true)
    if fileExists(package / "get.1"):
      implReplaceFile(package / "get.1", paths.man, executable = false)
    when defined(macosx):
      discard execCmdEx("xattr -d com.apple.quarantine " & quoteShell(paths.binary))

# ---------------------------------------------------------------------------
# Private helpers — uninstall
# ---------------------------------------------------------------------------

## Removes the installer's marked block from a shell startup file.
proc implRemoveRcBlock(path: string): bool =
  if not fileExists(path):
    return false
  let content = readFile(path)
  let begin = content.find(RC_MARK_BEGIN)
  if begin < 0:
    return false
  let finish = content.find(RC_MARK_END, begin)
  if finish < 0:
    return false
  var before = content[0 ..< begin]
  var after = content[finish + RC_MARK_END.len .. ^1]
  if after.startsWith("\n"): after = after[1 .. ^1]
  if before.endsWith("\n\n"): before.setLen(before.len - 1)
  writeFile(path, before & after)
  result = true

proc implRemoveIfEmpty(dir: string): bool =
  if not dirExists(dir):
    return false
  for entry in walkDir(dir):
    return false
  removeDir(dir)
  result = true

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Updates get to the latest release. Returns the process exit code.
##
## :param sk: Output style.
## :param preferSystemProxy: Whether the Windows system proxy wins.
## :raises: InstallError: If the release cannot be verified or installed.
proc updateGet*(sk: StyleKind, preferSystemProxy: bool): int =
  styleProgress(sk, "checking the latest release")
  let release = parseJson(implFetch(RELEASE_API_URL, MAX_API_BYTES,
    preferSystemProxy, accept = "application/vnd.github+json"))
  let version = implStripV(release{"tag_name"}.getStr(""))
  if version.len == 0:
    raise newException(InstallError, "the latest release has no version tag")
  if version == APP_VERSION:
    styleSuccess(sk, fmt"get {APP_VERSION} is already the latest release")
    return 0
  let stem = fmt"get-v{version}-{implPlatformTag()}"
  let archiveName = stem & ".zip"
  let sumsName = fmt"SHA256SUMS-v{version}.txt"
  var archiveUrl, sumsUrl: string
  for asset in release{"assets"}.getElems():
    let name = asset{"name"}.getStr("")
    let url = asset{"browser_download_url"}.getStr("")
    if not url.startsWith(RELEASE_DOWNLOAD_PREFIX):
      continue
    if name == archiveName: archiveUrl = url
    elif name == sumsName: sumsUrl = url
  if archiveUrl.len == 0 or sumsUrl.len == 0:
    raise newException(InstallError,
      fmt"release {version} has no {archiveName} with {sumsName}")

  styleProgress(sk, fmt"downloading {archiveName}")
  let sums = implParseSums(implFetch(sumsUrl, MAX_API_BYTES, preferSystemProxy))
  let archive = implFetch(archiveUrl, MAX_PACKAGE_BYTES, preferSystemProxy)
  var state = initSha_256()
  state.update(archive)
  if sums.getOrDefault(archiveName) != toLowerAscii($state.digest()):
    raise newException(InstallError,
      archiveName & " does not match the release checksum; nothing was installed")
  let entries = implCheckedZipEntries(archive, stem)

  let work = createTempDir("get-update-", "")
  let python = implFindPython()
  let package = work / stem
  let archivePath = work / archiveName
  writeFile(archivePath, archive)
  implExtract(archivePath, work, python)
  let inner = implParseSums(readFile(package / "SHA256SUMS"))
  for name in entries:
    if name == "SHA256SUMS": continue
    if not inner.hasKey(name) or implSha256File(package / name) != inner[name]:
      raise newException(InstallError,
        name & " does not match the package SHA256SUMS; nothing was installed")
  if not inner.hasKey(implPayloadName()):
    raise newException(InstallError, "the package has no program for this system")

  let paths = implInstallPaths()
  styleProgress(sk, fmt"installing get {version}")
  if python.len > 0:
    var args = @[package / "get_ready.py", "--update"]
    when defined(windows):
      # get.exe cannot be replaced while it runs; the installer waits for us.
      args.add(@["--wait-pid", $getCurrentProcessId()])
      let process = startProcess(python, args = args,
        options = {poParentStreams})
      process.close()
      return 0
    else:
      result = implRun(python, args)
  else:
    implCopyInstall(package, paths)
    result = 0
  when not defined(windows):
    removeDir(work)
    if result == 0:
      styleSuccess(sk, fmt"updated to get {version}")

## Removes the installed program and its PATH entry. With ``purge`` the
## configuration, key, log, and cache go too.
##
## :param sk: Output style.
## :param purge: Also remove settings and data.
proc uninstallGet*(sk: StyleKind, purge: bool) =
  let paths = implInstallPaths()
  let dataDir = getConfigDir() / APP_NAME
  when defined(windows):
    var script = "$p = [Environment]::GetEnvironmentVariable('Path', 'User')\r\n" &
      "if ($p) { $parts = $p -split ';' | Where-Object { $_ -and $_ -ne " &
      implPsQuote(paths.dir) & " }\r\n" &
      "  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User') }\r\n"
    script.add("Wait-Process -Id " & $getCurrentProcessId() &
      " -ErrorAction SilentlyContinue\r\n")
    script.add("Remove-Item -Recurse -Force -LiteralPath " & implPsQuote(paths.dir) &
      " -ErrorAction SilentlyContinue\r\n")
    if purge:
      script.add("Remove-Item -Recurse -Force -LiteralPath " & implPsQuote(dataDir) &
        " -ErrorAction SilentlyContinue\r\n")
    implSpawnPowerShell(script)
    styleSuccess(sk, "removing " & paths.dir & " after get exits")
  else:
    for path in [paths.binary, paths.man]:
      if fileExists(path):
        removeFile(path)
        styleSuccess(sk, "removed " & path)
    let home = getHomeDir()
    let configHome = getEnv("XDG_CONFIG_HOME", home / ".config")
    for rc in [home / ".profile", home / ".bashrc", home / ".zshrc",
        configHome / "fish" / "config.fish"]:
      if implRemoveRcBlock(rc):
        styleSuccess(sk, "removed PATH entry from " & rc)
    # Directories older installers created; kept if anything is inside.
    discard implRemoveIfEmpty(home / ".local" / "share" / "get")
    when defined(macosx):
      discard implRemoveIfEmpty(home / "Library" / "Application Support" / "get")
    if purge and dirExists(dataDir):
      removeDir(dataDir)
      styleSuccess(sk, "removed " & dataDir)
  if not purge:
    styleProgress(sk, "settings, key, log, and cache kept in " & dataDir &
      "; `get uninstall --purge` removes them")

when defined(getTest):
  func checkedZipEntriesForTest*(data, root: string): seq[string] =
    implCheckedZipEntries(data, root)
  proc removeRcBlockForTest*(path: string): bool = implRemoveRcBlock(path)
  func parseSumsForTest*(text: string): Table[string, string] = implParseSums(text)
  func allowedHostForTest*(url: string): bool = implAllowedHost(url)
