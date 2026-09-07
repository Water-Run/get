## Production-grade deterministic caching for the get v3 harness.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: cache.nim
## :License: AGPL-3.0
##
## Cache identity is provider- and policy-aware, persistence is atomic, and
## every read is size-bounded and schema-validated. Writers use a small
## cross-process lock so concurrent get invocations cannot lose updates.
## A last-good backup provides transparent recovery from a damaged primary.

{.experimental: "strictFuncs".}

import std/[algorithm, json, options, os, strformat, strutils, tables, times]

when not defined(windows):
  import std/monotimes

when defined(posix):
  import std/posix
elif defined(windows):
  import std/[widestrs, winlean]

import checksums/sha2

import style
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## On-disk cache schema. Older hashes are intentionally invalidated by SHA-256.
const CACHE_SCHEMA_VERSION* = 3

## Semantic identity of the built-in Harness, prompt, protocol, and mandatory
## read-only policy. Bump this when a behavior change could make a cached result
## or command incompatible even though the JSON schema itself remains v3.
const CACHE_IDENTITY_REVISION* = "get-v3-harness-policy-20260907"

## Hard input bound protecting startup from an unexpectedly large cache file.
const MAX_CACHE_FILE_BYTES* = 64 * 1024 * 1024

## Bounds for individual persisted values.
const MAX_CACHE_QUERY_CHARS* = 32_768
const MAX_CACHE_COMMAND_CHARS* = 32_768
const MAX_CACHE_OUTPUT_BYTES* = 4 * 1024 * 1024

## Cross-process writer lock behavior.
const CACHE_LOCK_WAIT_MS = 10_000
when not defined(windows):
  const CACHE_LOCK_POLL_MS = 10
  const CACHE_STALE_LOCK_SECONDS = 120

when defined(windows):
  ## ``winlean`` intentionally exposes only the small Win32 surface needed by
  ## Nim's runtime.  Cache persistence additionally needs a crash-safe named
  ## mutex so independent CLI processes cannot lose a read-modify-write.
  const WAIT_ABANDONED = 0x00000080'i32

  proc createMutexW(
    attributes: pointer,
    initialOwner: WINBOOL,
    name: WideCString
  ): Handle {.stdcall, dynlib: "kernel32", importc: "CreateMutexW".}

  proc releaseMutex(handle: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ReleaseMutex".}

## Timestamps farther into the future are treated as malformed.
const MAX_CACHE_CLOCK_SKEW_SECONDS = 86_400'i64

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Raised when a cache write cannot be completed safely.
type
  CacheError* = object of GetError

  CacheLock = object
    when defined(windows):
      handle: Handle
    else:
      path: string

## Whether a cache entry applies globally or to one working directory.
type
  CacheScope* = enum
    csGlobal  ## Valid regardless of working directory.
    csContext ## Valid only for the original context.

## Behavior when a cache entry is hit.
type
  CacheMode* = enum
    cmCommand ## Revalidate and re-execute the cached command.
    cmResult  ## Return the cached text without a provider request.

## A single validated cache entry.
type
  CacheEntry* = object
    hash*: string         ## SHA-256 global or context identity.
    scope*: CacheScope    ## Global or context scope.
    cacheMode*: CacheMode ## Command or final-result behavior.
    query*: string        ## Original user query text.
    command*: string      ## Generated shell command for cmCommand.
    output*: string       ## Final output for cmResult.
    isMarkdown*: bool     ## Model answer, rendered only at terminal display time.
    timestamp*: int64     ## Unix epoch seconds when created.

## In-memory representation of the v3 cache file.
type
  CacheStore* = object
    entries*: seq[CacheEntry] ## Validated, de-duplicated entries.

## Minimal cache state carried by the unified query dispatcher.
type
  CacheContext* = object
    useCache*: bool      ## Whether this invocation uses the cache.
    globalHash*: string  ## Identity without working directory.
    contextHash*: string ## Identity including working directory.

# ---------------------------------------------------------------------------
# Private helpers — identity and validation
# ---------------------------------------------------------------------------

## Returns a canonical SHA-256 hex digest.
func implSha256(value: string): string =
  var state = initSha_256()
  state.update(value)
  result = $state.digest()

func implScopeToStr(scope: CacheScope): string =
  case scope
  of csGlobal: result = "global"
  of csContext: result = "context"

func implModeToStr(mode: CacheMode): string =
  case mode
  of cmCommand: result = "command"
  of cmResult: result = "result"

func implParseScope(value: string): Option[CacheScope] =
  case toLowerAscii(value.strip())
  of "global": result = some(csGlobal)
  of "context": result = some(csContext)
  else: result = none(CacheScope)

func implParseMode(value: string): Option[CacheMode] =
  case toLowerAscii(value.strip())
  of "command": result = some(cmCommand)
  of "result": result = some(cmResult)
  else: result = none(CacheMode)

func implValidHash(value: string): bool =
  if value.len != 64:
    return false
  for character in value:
    if character notin {'0'..'9', 'a'..'f'}:
      return false
  result = true

func implFreshTimestamp(
  timestamp: int64,
  nowEpoch: int64,
  expiryDays: int
): bool =
  if timestamp <= 0 or
      timestamp > nowEpoch + MAX_CACHE_CLOCK_SKEW_SECONDS:
    return false
  if expiryDays <= 0:
    return true
  let maxAge =
    if expiryDays.int64 > high(int64) div 86_400'i64:
      high(int64)
    else:
      expiryDays.int64 * 86_400'i64
  result = nowEpoch - timestamp <= maxAge

func implValidEntry(entry: CacheEntry, nowEpoch: int64): bool =
  if not implValidHash(entry.hash) or
      entry.query.len == 0 or
      entry.query.len > MAX_CACHE_QUERY_CHARS or
      entry.command.len > MAX_CACHE_COMMAND_CHARS or
      entry.output.len > MAX_CACHE_OUTPUT_BYTES or
      entry.query.contains('\0') or
      entry.command.contains('\0') or
      entry.output.contains('\0') or
      not implFreshTimestamp(entry.timestamp, nowEpoch, 0):
    return false
  case entry.cacheMode
  of cmCommand:
    result = entry.command.strip().len > 0
  of cmResult:
    result = entry.output.len > 0

func implEntryKey(entry: CacheEntry): string =
  result = $entry.scope & ":" & entry.hash

func implCmpEntry(a, b: CacheEntry): int =
  result = cmp(a.timestamp, b.timestamp)
  if result == 0:
    result = cmp(implEntryKey(a), implEntryKey(b))

## Parses one entry and rejects malformed or oversized fields.
proc implParseEntry(
  node: JsonNode,
  defaultScope: CacheScope,
  nowEpoch: int64
): Option[CacheEntry] =
  if node.kind != JObject:
    return none(CacheEntry)
  try:
    let scope =
      if node{"scope"}.isNil:
        some(defaultScope)
      else:
        implParseScope(node{"scope"}.getStr(""))
    let mode = implParseMode(node{"cacheMode"}.getStr(""))
    if scope.isNone or mode.isNone:
      return none(CacheEntry)
    let entry = CacheEntry(
      hash: node{"hash"}.getStr(""),
      scope: scope.get,
      cacheMode: mode.get,
      query: node{"query"}.getStr(""),
      command: node{"command"}.getStr(""),
      output: node{"output"}.getStr(""),
      isMarkdown: node{"isMarkdown"}.getBool(false),
      timestamp: node{"timestamp"}.getBiggestInt(0).int64
    )
    if implValidEntry(entry, nowEpoch):
      result = some(entry)
    else:
      result = none(CacheEntry)
  except CatchableError:
    result = none(CacheEntry)

## De-duplicates identities and keeps the newest valid entry.
proc implNormalizeEntries(entries: seq[CacheEntry]): seq[CacheEntry] =
  var positions = initTable[string, int]()
  for entry in entries:
    let key = implEntryKey(entry)
    if positions.hasKey(key):
      let index = positions[key]
      if entry.timestamp >= result[index].timestamp:
        result[index] = entry
    else:
      positions[key] = result.len
      result.add(entry)
  result.sort(implCmpEntry)

# ---------------------------------------------------------------------------
# Public API — cache identity
# ---------------------------------------------------------------------------

## Computes a v3 global key across provider, strategy, protocol, and policy.
proc computeGlobalHashV3*(
  query: string,
  shell: string,
  model: string,
  providerUrl: string,
  harness: string,
  toolProtocol: string,
  systemPrompt: Option[string],
  commandPattern: Option[string]
): string =
  let customInstruction =
    if systemPrompt.isSome: systemPrompt.get
    else: ""
  let filterPattern =
    if commandPattern.isSome and commandPattern.get.len > 0:
      "custom:" & commandPattern.get
    else:
      "semantic-policy-only"
  result = implSha256($(%*[
    CACHE_IDENTITY_REVISION,
    query.strip(),
    shell,
    model,
    providerUrl,
    harness,
    toolProtocol,
    customInstruction,
    filterPattern,
    hostOS,
    hostCPU
  ]))

## Computes a v3 context key by adding the working directory.
proc computeContextHashV3*(
  query: string,
  cwd: string,
  shell: string,
  model: string,
  providerUrl: string,
  harness: string,
  toolProtocol: string,
  systemPrompt: Option[string],
  commandPattern: Option[string]
): string =
  let globalHash = computeGlobalHashV3(
    query,
    shell,
    model,
    providerUrl,
    harness,
    toolProtocol,
    systemPrompt,
    commandPattern
  )
  result = implSha256($(%*[
    "get-v3-context",
    globalHash,
    cwd
  ]))

# ---------------------------------------------------------------------------
# Private helpers — decoding and bounded reads
# ---------------------------------------------------------------------------

proc implDecodeCache(content: string): CacheStore =
  let node = parseJson(content)
  let nowEpoch = epochTime().int64
  var parsed: seq[CacheEntry] = @[]
  if node.kind == JArray:
    # v2 arrays are read only for graceful migration. Their 32-character
    # hashes fail v3 validation and therefore cannot collide with v3 entries.
    for item in node:
      let entry = implParseEntry(item, csContext, nowEpoch)
      if entry.isSome:
        parsed.add(entry.get)
  elif node.kind == JObject:
    let entriesNode = node{"entries"}
    if entriesNode.isNil or entriesNode.kind != JArray:
      raise newException(CacheError,
        "cache entries must be a JSON array")
    let schemaNode = node{"schemaVersion"}
    if schemaNode.isNil or schemaNode.kind != JInt or
        schemaNode.getInt() != CACHE_SCHEMA_VERSION:
      raise newException(CacheError,
        "cache schema version is unsupported")
    let algorithmNode = node{"hashAlgorithm"}
    if algorithmNode.isNil or algorithmNode.kind != JString or
        algorithmNode.getStr() != "sha256":
      raise newException(CacheError,
        "cache hash algorithm is unsupported")
    for item in entriesNode:
      let entry = implParseEntry(item, csContext, nowEpoch)
      if entry.isSome:
        parsed.add(entry.get)
  else:
    raise newException(CacheError,
      "cache root must be a JSON object")
  result = CacheStore(entries: implNormalizeEntries(parsed))

proc implReadFileBounded(path: string, maximumBytes: int): string =
  var file: File
  if not open(file, path, fmRead):
    raise newException(CacheError, "cannot open cache snapshot")
  try:
    var buffer: array[8192, char]
    while true:
      let count = file.readBuffer(addr buffer[0], buffer.len)
      if count <= 0:
        break
      if result.len > maximumBytes - count:
        raise newException(CacheError, "cache snapshot exceeds the hard limit")
      let previousLength = result.len
      result.setLen(previousLength + count)
      copyMem(addr result[previousLength], addr buffer[0], count)
  finally:
    file.close()

proc implTryLoadPath(path: string): Option[CacheStore] =
  if not fileExists(path):
    return none(CacheStore)
  try:
    let size = getFileSize(path)
    if size < 0 or size > MAX_CACHE_FILE_BYTES:
      return none(CacheStore)
    result = some(implDecodeCache(
      implReadFileBounded(path, MAX_CACHE_FILE_BYTES)))
  except CatchableError:
    result = none(CacheStore)

## Loads one cache snapshot without acquiring the writer mutex. Callers that
## do not already hold the mutex must use ``loadCache`` instead.
proc implLoadCacheUnlocked(path: string): CacheStore =
  let primary = implTryLoadPath(path)
  if primary.isSome:
    return primary.get
  let backup = implTryLoadPath(path & ".bak")
  if backup.isSome:
    return backup.get
  result = CacheStore(entries: @[])

# ---------------------------------------------------------------------------
# Private helpers — lock and atomic persistence
# ---------------------------------------------------------------------------

proc implAcquireCacheLock(path: string): CacheLock =
  when defined(windows):
    # Directory creation is not a reliable cross-process mutex on every
    # Windows-compatible runtime (notably Wine under heavy contention).  A
    # named kernel mutex is atomic, releases automatically after a crash, and
    # makes a successful cache write mean that its update was actually merged.
    let mutexName = "Local\\get-cache-v3-" &
      implSha256(toLowerAscii(path))
    let handle = createMutexW(nil, 0'i32, newWideCString(mutexName))
    if handle == 0:
      raise newException(CacheError,
        "cannot create the cache writer mutex")
    let waitResult = waitForSingleObject(handle, CACHE_LOCK_WAIT_MS.int32)
    if waitResult notin [WAIT_OBJECT_0, WAIT_ABANDONED]:
      discard closeHandle(handle)
      if waitResult == WAIT_TIMEOUT:
        raise newException(CacheError,
          "cache is busy; retry the operation")
      raise newException(CacheError,
        "cannot acquire the cache writer mutex")
    result = CacheLock(handle: handle)
  else:
    result.path = path & ".lock"
    let started = getMonoTime()
    while true:
      try:
        if not existsOrCreateDir(result.path):
          return
        try:
          let age = epochTime().int64 -
            getLastModificationTime(result.path).toUnix
          if age > CACHE_STALE_LOCK_SECONDS:
            removeDir(result.path)
            continue
        except OSError, IOError:
          discard
      except OSError, IOError:
        discard
      if (getMonoTime() - started).inMilliseconds >=
          CACHE_LOCK_WAIT_MS:
        raise newException(CacheError,
          "cache is busy; retry the operation")
      sleep(CACHE_LOCK_POLL_MS)

proc implReleaseCacheLock(lock: CacheLock) =
  when defined(windows):
    if lock.handle != 0:
      discard releaseMutex(lock.handle)
      discard closeHandle(lock.handle)
  else:
    try:
      removeDir(lock.path)
    except OSError, IOError:
      discard

## Loads the primary cache, transparently falling back to the last-good copy.
proc loadCache*(): CacheStore =
  let path = getCacheFilePath()
  when defined(windows):
    # Windows does not permit replacing a file while another process has it
    # open without delete sharing.  Readers therefore join the same short
    # critical section as atomic replacement; writers call the unlocked helper
    # below after they have already acquired this mutex.
    let lock = implAcquireCacheLock(path)
    try:
      result = implLoadCacheUnlocked(path)
    finally:
      implReleaseCacheLock(lock)
  else:
    result = implLoadCacheUnlocked(path)

proc implEncodeCache(store: CacheStore): string =
  var entries = implNormalizeEntries(store.entries)
  entries.sort(implCmpEntry)
  var entryArray = newJArray()
  for entry in entries:
    entryArray.add(%*{
      "hash": entry.hash,
      "scope": implScopeToStr(entry.scope),
      "cacheMode": implModeToStr(entry.cacheMode),
      "query": entry.query,
      "command": entry.command,
      "output": entry.output,
      "isMarkdown": entry.isMarkdown,
      "timestamp": entry.timestamp
    })
  let root = %*{
    "schemaVersion": CACHE_SCHEMA_VERSION,
    "hashAlgorithm": "sha256",
    "entries": entryArray
  }
  result = pretty(root, 2) & "\n"

proc implWriteFileDurable(path: string, content: string) =
  var file: File
  if not open(file, path, fmWrite):
    raise newException(CacheError,
      "cannot open temporary cache file")
  try:
    when defined(posix):
      # Restrict a newly created temporary before any cache data is written.
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    file.write(content)
    file.flushFile()
    when defined(posix):
      if posix.fsync(getFileHandle(file).cint) != 0:
        raise newException(CacheError,
          "cannot flush temporary cache file")
    elif defined(windows):
      # ``getFileHandle(File)`` is a Microsoft CRT descriptor, not a Win32
      # HANDLE. Convert it exactly as Nim's own Windows filesystem routines do
      # before asking the kernel to flush durable storage.
      let nativeHandle = get_osfhandle(getFileHandle(file).cint)
      if nativeHandle == INVALID_HANDLE_VALUE or
          flushFileBuffers(nativeHandle) == 0:
        raise newException(CacheError,
          "cannot flush temporary cache file")
  finally:
    file.close()

proc implSyncCacheDirectory(path: string) =
  when defined(posix):
    let directory = parentDir(path)
    let descriptor = posix.open(directory.cstring, O_RDONLY)
    if descriptor >= 0:
      discard posix.fsync(descriptor)
      discard posix.close(descriptor)

proc implSaveCacheUnlocked(store: CacheStore, path: string) =
  let payload = implEncodeCache(store)
  if payload.len > MAX_CACHE_FILE_BYTES:
    raise newException(CacheError,
      fmt"cache exceeds the {MAX_CACHE_FILE_BYTES}-byte hard limit")
  let processTag = $getCurrentProcessId()
  let tempPath = path & ".tmp." & processTag
  let backupTempPath = path & ".bak.tmp." & processTag
  try:
    implWriteFileDurable(tempPath, payload)
    implWriteFileDurable(backupTempPath, payload)
    moveFile(backupTempPath, path & ".bak")
    moveFile(tempPath, path)
    implSyncCacheDirectory(path)
  except CacheError:
    discard tryRemoveFile(tempPath)
    discard tryRemoveFile(backupTempPath)
    raise
  except CatchableError as error:
    discard tryRemoveFile(tempPath)
    discard tryRemoveFile(backupTempPath)
    raise newException(CacheError,
      "cannot persist cache: " & error.msg)

## Atomically persists a complete cache snapshot under the writer lock.
proc saveCache*(store: CacheStore) =
  let path = getCacheFilePath()
  let lock = implAcquireCacheLock(path)
  try:
    implSaveCacheUnlocked(store, path)
  finally:
    implReleaseCacheLock(lock)

# ---------------------------------------------------------------------------
# Public API — lookup and mutation
# ---------------------------------------------------------------------------

## Prunes invalid, expired, duplicate, and over-capacity entries in place.
proc pruneCacheStore*(
  store: var CacheStore,
  maxEntries: int,
  expiryDays: int
) =
  let nowEpoch = epochTime().int64
  var kept: seq[CacheEntry] = @[]
  for entry in store.entries:
    if implValidEntry(entry, nowEpoch) and
        implFreshTimestamp(entry.timestamp, nowEpoch, expiryDays):
      kept.add(entry)
  kept = implNormalizeEntries(kept)
  if maxEntries > 0 and kept.len > maxEntries:
    kept = kept[kept.len - maxEntries .. ^1]
  store.entries = kept

## Returns the newest non-expired match using context-result, global-result,
## context-command, then global-command priority.
proc lookupCache*(
  store: CacheStore,
  globalHash: string,
  contextHash: string,
  expiryDays: int
): Option[CacheEntry] =
  let nowEpoch = epochTime().int64
  var candidates: array[4, Option[CacheEntry]]
  for entry in store.entries:
    if not implFreshTimestamp(
        entry.timestamp, nowEpoch, expiryDays):
      continue
    var slot = -1
    if entry.scope == csContext and
        entry.hash == contextHash:
      slot = if entry.cacheMode == cmResult: 0 else: 2
    elif entry.scope == csGlobal and
        entry.hash == globalHash:
      slot = if entry.cacheMode == cmResult: 1 else: 3
    if slot >= 0 and
        (candidates[slot].isNone or
         entry.timestamp > candidates[slot].get.timestamp):
      candidates[slot] = some(entry)
  for candidate in candidates:
    if candidate.isSome:
      return candidate
  result = none(CacheEntry)

## Adds or replaces one identity and applies expiry and age-based caps.
proc addCacheEntry*(
  store: var CacheStore,
  entry: CacheEntry,
  maxEntries: int,
  expiryDays: int
) =
  let nowEpoch = epochTime().int64
  if not implValidEntry(entry, nowEpoch):
    raise newException(CacheError,
      "refusing to persist an invalid cache entry")
  var kept: seq[CacheEntry] = @[]
  for existing in store.entries:
    if existing.hash != entry.hash or
        existing.scope != entry.scope:
      kept.add(existing)
  kept.add(entry)
  store.entries = kept
  pruneCacheStore(store, maxEntries, expiryDays)

## Performs a lock-scoped read-modify-write so concurrent processes cannot
## overwrite one another's cache entries.
proc putCacheEntry*(
  entry: CacheEntry,
  maxEntries: int,
  expiryDays: int
) =
  let path = getCacheFilePath()
  let lock = implAcquireCacheLock(path)
  try:
    var store = implLoadCacheUnlocked(path)
    addCacheEntry(store, entry, maxEntries, expiryDays)
    implSaveCacheUnlocked(store, path)
  finally:
    implReleaseCacheLock(lock)

## Removes all identities whose normalized query matches the given text.
proc unsetCacheEntries*(
  store: var CacheStore,
  query: string
): int =
  let target = toLowerAscii(query.strip())
  var kept: seq[CacheEntry] = @[]
  for entry in store.entries:
    if toLowerAscii(entry.query.strip()) == target:
      result += 1
    else:
      kept.add(entry)
  store.entries = kept

# ---------------------------------------------------------------------------
# Public API — management commands
# ---------------------------------------------------------------------------

## Atomically removes every cache entry.
proc cleanCache*(): int =
  let path = getCacheFilePath()
  let lock = implAcquireCacheLock(path)
  try:
    let store = implLoadCacheUnlocked(path)
    result = store.entries.len
    implSaveCacheUnlocked(CacheStore(entries: @[]), path)
  finally:
    implReleaseCacheLock(lock)

## Atomically removes cache entries matching a query.
proc unsetCache*(query: string): int =
  let path = getCacheFilePath()
  let lock = implAcquireCacheLock(path)
  try:
    var store = implLoadCacheUnlocked(path)
    result = unsetCacheEntries(store, query)
    implSaveCacheUnlocked(store, path)
  finally:
    implReleaseCacheLock(lock)

## Prints live, expiry-aware cache statistics.
proc displayCacheInfo*(
  cacheEnabled: bool,
  expiryDays: int,
  maxEntries: int,
  sk: StyleKind = skSimp
) =
  var store = loadCache()
  pruneCacheStore(store, maxEntries, expiryDays)
  let path = getCacheFilePath()
  styleKeyValue(sk, "cache",
    if cacheEnabled: "enabled" else: "disabled")
  styleKeyValue(sk, "schema-version", $CACHE_SCHEMA_VERSION)
  styleKeyValue(sk, "entries", $store.entries.len)
  var globalCommands = 0
  var globalResults = 0
  var contextCommands = 0
  var contextResults = 0
  for entry in store.entries:
    case entry.scope
    of csGlobal:
      if entry.cacheMode == cmCommand:
        globalCommands += 1
      else:
        globalResults += 1
    of csContext:
      if entry.cacheMode == cmCommand:
        contextCommands += 1
      else:
        contextResults += 1
  styleKeyValue(sk, "global-command entries", $globalCommands)
  styleKeyValue(sk, "global-result entries", $globalResults)
  styleKeyValue(sk, "context-command entries", $contextCommands)
  styleKeyValue(sk, "context-result entries", $contextResults)
  styleKeyValue(sk, "max-entries", formatIntOrDisable(maxEntries))
  styleKeyValue(sk, "expiry",
    if expiryDays <= 0: "never" else: fmt"{expiryDays} days")
  styleKeyValue(sk, "file", path)
  if fileExists(path):
    let size = getFileSize(path)
    let sizeText =
      if size < 1024:
        fmt"{size} B"
      elif size < 1024 * 1024:
        fmt"{size div 1024} KB"
      else:
        fmt"{size div (1024 * 1024)} MB"
    styleKeyValue(sk, "file-size", sizeText)
  else:
    styleKeyValue(sk, "file-size", "0 B")
