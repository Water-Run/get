## Response caching with deferred decision for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-19
## :File: cache.nim
## :License: AGPL-3.0
##
## This module implements a disk-backed cache with a deferred
## decision mechanism.  Queries are cached only when repeated:
## the first execution merely records the query in a "seen" set;
## the second execution triggers an LLM call that chooses one of
## five caching strategies:
##
##   NOCACHE         — do not cache anything.
##   GLOBAL_COMMAND  — cache the command globally; re-execute
##                     on hit.
##   GLOBAL_RESULT   — cache the output globally; return
##                     directly on hit.
##   CONTEXT_COMMAND — cache the command for this context;
##                     re-execute on hit.
##   CONTEXT_RESULT  — cache the output for this context;
##                     return directly on hit.
##
## Global entries ignore the working directory; context entries
## include it in their hash key.  On lookup the four possible
## hit types are checked in priority order: context result,
## global result, context command, global command.

{.experimental: "strictFuncs".}

import std/[algorithm, json, options, os, strformat,
            strutils, times]

import checksums/md5

import style
import utils

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Whether a cache entry applies globally or only within a
## specific working-directory context.
type
  CacheScope* = enum
    csGlobal  ## Valid regardless of working directory.
    csContext ## Valid only for the original context.

## Behaviour when a cache entry is hit.
type
  CacheMode* = enum
    cmCommand ## Re-execute the cached command.
    cmResult  ## Return the cached output directly.

## The five possible outcomes of the LLM cache-worthiness
## check.
type
  CacheDecision* = enum
    cdNoCache        ## Do not cache anything.
    cdGlobalCommand  ## Cache command globally.
    cdGlobalResult   ## Cache result globally.
    cdContextCommand ## Cache command for this context.
    cdContextResult  ## Cache result for this context.

## A single cached entry.
type
  CacheEntry* = object
    hash*: string         ## Global or context hash key.
    scope*: CacheScope    ## Global or context scope.
    cacheMode*: CacheMode ## Behaviour on hit.
    query*: string        ## Original user query text.
    command*: string      ## Generated shell command.
    output*: string       ## Final output (cmResult only).
    timestamp*: int64     ## Unix epoch seconds when created.

## Records that a query has been executed at least once.
type
  SeenEntry* = object
    queryHash*: string ## MD5 of the query text.
    timestamp*: int64  ## Unix epoch seconds.
    count*: int        ## Number of observed executions.

## Records that a query has been evaluated by the cache
## decision LLM and explicitly classified as NOCACHE, so that
## subsequent executions can skip the decision call entirely.
type
  NoCacheEntry* = object
    queryHash*: string ## MD5 of the query text.
    timestamp*: int64  ## Unix epoch seconds.

## In-memory representation of the cache file.
type
  CacheStore* = object
    entries*: seq[CacheEntry]    ## Cached results.
    seen*: seq[SeenEntry]        ## Seen-query tracker.
    nocache*: seq[NoCacheEntry]  ## NOCACHE decisions.

## Groups the cache-related state that the main dispatcher
## passes into the instance and agent flow functions.
type
  CacheContext* = object
    useCache*: bool      ## Cache pipeline active.
    wasSeen*: bool       ## Query was previously seen.
    queryHash*: string   ## Hash of query text only.
    globalHash*: string  ## Hash without cwd.
    contextHash*: string ## Hash including cwd.

# ---------------------------------------------------------------------------
# Private helpers — string conversion
# ---------------------------------------------------------------------------

## Converts a CacheScope to its JSON string.
##
## :param scope: The scope value.
## :returns: "global" or "context".
func implScopeToStr(scope: CacheScope): string =
  case scope
  of csGlobal:  result = "global"
  of csContext: result = "context"

## Parses a string into a CacheScope.
##
## :param s: The string to parse.
## :returns: The corresponding CacheScope.
func implStrToScope(s: string): CacheScope =
  if toLowerAscii(s) == "global":
    result = csGlobal
  else:
    result = csContext

## Converts a CacheMode to its JSON string.
##
## :param mode: The cache mode value.
## :returns: "command" or "result".
func implModeToStr(mode: CacheMode): string =
  case mode
  of cmCommand: result = "command"
  of cmResult:  result = "result"

## Parses a string into a CacheMode.
##
## :param s: The string to parse.
## :returns: The corresponding CacheMode.
func implStrToMode(s: string): CacheMode =
  if toLowerAscii(s) == "command":
    result = cmCommand
  else:
    result = cmResult

## Compares two cache entries by timestamp (ascending).
##
## :param a: First entry.
## :param b: Second entry.
## :returns: Negative if a is older, positive if newer.
func implCmpTimestamp(
  a, b: CacheEntry
): int =
  result = cmp(a.timestamp, b.timestamp)

# ---------------------------------------------------------------------------
# Public API — hash computation
# ---------------------------------------------------------------------------

## Computes an MD5 hex hash from the query text alone.  Used
## as the key for the "seen" tracker.
##
## :param query: The user's natural-language query.
## :returns: A 32-character lowercase hex string.
##
## .. code-block:: nim
##   runnableExamples:
##     let h = computeQueryHash("test")
##     assert h.len == 32
proc computeQueryHash*(query: string): string =
  result = $toMD5(toLowerAscii(query.strip()))

## Computes a global hash that includes every context field
## except the working directory.  Used as the key for global
## cache entries (GLOBAL_COMMAND, GLOBAL_RESULT).
##
## :param query: The user's natural-language query.
## :param shell: Configured shell name.
## :param model: LLM model identifier.
## :param instance: Whether instance mode is active.
## :param systemPrompt: Custom system prompt, if any.
## :param commandPattern: Command-pattern regex, if any.
## :returns: A 32-character lowercase hex string.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let h = computeGlobalHash("test", "bash",
##       "gpt", false, none(string), none(string))
##     assert h.len == 32
proc computeGlobalHash*(
  query: string,
  shell: string,
  model: string,
  instance: bool,
  systemPrompt: Option[string],
  commandPattern: Option[string]
): string =
  let sysPmt =
    if systemPrompt.isSome: systemPrompt.get
    else: ""
  let cmdPat =
    if commandPattern.isSome: commandPattern.get
    else: ""
  let parts = @[
    toLowerAscii(query.strip()),
    shell, model, $instance,
    sysPmt, cmdPat, hostOS, hostCPU]
  result = $toMD5(parts.join("|"))

## Computes a context hash that includes the working directory
## and all other context fields.  Used as the key for context
## cache entries (CONTEXT_COMMAND, CONTEXT_RESULT).
##
## :param query: The user's natural-language query.
## :param cwd: Current working directory.
## :param shell: Configured shell name.
## :param model: LLM model identifier.
## :param instance: Whether instance mode is active.
## :param systemPrompt: Custom system prompt, if any.
## :param commandPattern: Command-pattern regex, if any.
## :returns: A 32-character lowercase hex string.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let h = computeContextHash("test", "/tmp",
##       "bash", "gpt", false,
##       none(string), none(string))
##     assert h.len == 32
proc computeContextHash*(
  query: string,
  cwd: string,
  shell: string,
  model: string,
  instance: bool,
  systemPrompt: Option[string],
  commandPattern: Option[string]
): string =
  let sysPmt =
    if systemPrompt.isSome: systemPrompt.get
    else: ""
  let cmdPat =
    if commandPattern.isSome: commandPattern.get
    else: ""
  let parts = @[
    toLowerAscii(query.strip()),
    cwd, shell, model, $instance,
    sysPmt, cmdPat, hostOS, hostCPU]
  result = $toMD5(parts.join("|"))

# ---------------------------------------------------------------------------
# Public API — persistence
# ---------------------------------------------------------------------------

## Loads the cache store from disk.  Returns an empty store
## when the file does not exist or cannot be parsed.  Old-
## format files (top-level JSON Array) are migrated
## transparently: entries are assigned csContext scope and
## cmResult mode; seen and nocache are left empty.  The new
## object format includes "entries", "seen", and "nocache"
## arrays.
##
## :returns: The loaded cache store.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc loadCache*(): CacheStore =
  let path = getCacheFilePath()
  if not fileExists(path):
    return CacheStore(
      entries: @[], seen: @[], nocache: @[])
  try:
    let content = readFile(path)
    let node = parseJson(content)
    # Backward compatibility: old format is a JSON Array.
    if node.kind == JArray:
      var entries: seq[CacheEntry] = @[]
      for item in node:
        let entry = CacheEntry(
          hash: item{"hash"}.getStr(""),
          scope: csContext,
          cacheMode: implStrToMode(
            item{"cacheMode"}.getStr("result")),
          query: item{"query"}.getStr(""),
          command: item{"command"}.getStr(""),
          output: item{"output"}.getStr(""),
          timestamp:
            item{"timestamp"}.getBiggestInt(
              0).int64)
        if entry.hash.len > 0:
          entries.add(entry)
      return CacheStore(
        entries: entries, seen: @[], nocache: @[])
    if node.kind != JObject:
      return CacheStore(
        entries: @[], seen: @[], nocache: @[])
    # New format: { "entries": [...], "seen": [...],
    #               "nocache": [...] }
    var entries: seq[CacheEntry] = @[]
    let eNode = node{"entries"}
    if not eNode.isNil and eNode.kind == JArray:
      for item in eNode:
        let entry = CacheEntry(
          hash: item{"hash"}.getStr(""),
          scope: implStrToScope(
            item{"scope"}.getStr("context")),
          cacheMode: implStrToMode(
            item{"cacheMode"}.getStr("result")),
          query: item{"query"}.getStr(""),
          command: item{"command"}.getStr(""),
          output: item{"output"}.getStr(""),
          timestamp:
            item{"timestamp"}.getBiggestInt(
              0).int64)
        if entry.hash.len > 0:
          entries.add(entry)
    var seen: seq[SeenEntry] = @[]
    let sNode = node{"seen"}
    if not sNode.isNil and sNode.kind == JArray:
      for item in sNode:
        let se = SeenEntry(
          queryHash:
            item{"queryHash"}.getStr(""),
          timestamp:
            item{"timestamp"}.getBiggestInt(
              0).int64,
          count: item{"count"}.getInt(1))
        if se.queryHash.len > 0:
          seen.add(se)
    var nocache: seq[NoCacheEntry] = @[]
    let nNode = node{"nocache"}
    if not nNode.isNil and nNode.kind == JArray:
      for item in nNode:
        let ne = NoCacheEntry(
          queryHash:
            item{"queryHash"}.getStr(""),
          timestamp:
            item{"timestamp"}.getBiggestInt(
              0).int64)
        if ne.queryHash.len > 0:
          nocache.add(ne)
    result = CacheStore(
      entries: entries,
      seen: seen,
      nocache: nocache)
  except JsonParsingError, IOError:
    result = CacheStore(
      entries: @[], seen: @[], nocache: @[])

## Writes the cache store to disk as a JSON object with
## "entries", "seen", and "nocache" arrays.
##
## :param store: The cache store to persist.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc saveCache*(store: CacheStore) =
  let path = getCacheFilePath()
  var eArr = newJArray()
  for e in store.entries:
    eArr.add(%*{
      "hash":      e.hash,
      "scope":     implScopeToStr(e.scope),
      "cacheMode": implModeToStr(e.cacheMode),
      "query":     e.query,
      "command":   e.command,
      "output":    e.output,
      "timestamp": e.timestamp})
  var sArr = newJArray()
  for s in store.seen:
    sArr.add(%*{
      "queryHash": s.queryHash,
      "timestamp": s.timestamp,
      "count": s.count})
  var nArr = newJArray()
  for n in store.nocache:
    nArr.add(%*{
      "queryHash": n.queryHash,
      "timestamp": n.timestamp})
  let root = %*{
    "entries": eArr,
    "seen":    sArr,
    "nocache": nArr}
  try:
    writeFile(path, pretty(root, 2) & "\n")
  except IOError:
    discard

# ---------------------------------------------------------------------------
# Public API — seen tracking
# ---------------------------------------------------------------------------

## Returns how many times a query has been seen within the
## active expiry window.
##
## :param store: The loaded cache store.
## :param queryHash: The query-text hash to inspect.
## :param expiryDays: Maximum age in days (0 = never expire).
## :returns: Execution count for this query (0 if not seen).
##
## .. code-block:: nim
##   runnableExamples:
##     let store = CacheStore(entries: @[], seen: @[],
##                            nocache: @[])
##     assert getSeenCount(store, "abc", 30) == 0
proc getSeenCount*(
  store: CacheStore,
  queryHash: string,
  expiryDays: int
): int =
  let now = epochTime().int64
  for s in store.seen:
    if s.queryHash == queryHash:
      let safeCount = max(s.count, 1)
      if expiryDays <= 0:
        return safeCount
      let maxAge = expiryDays.int64 * 86400'i64
      if (now - s.timestamp) <= maxAge:
        return safeCount
      return 0
  result = 0

## Checks whether a query has been seen before (i.e. executed
## at least once within the expiry window).
##
## :param store: The loaded cache store.
## :param queryHash: The query-text hash to check.
## :param expiryDays: Maximum age in days (0 = never expire).
## :returns: true when the query has been seen.
##
## .. code-block:: nim
##   runnableExamples:
##     let store = CacheStore(entries: @[], seen: @[],
##                            nocache: @[])
##     assert not isSeen(store, "abc", 30)
proc isSeen*(
  store: CacheStore,
  queryHash: string,
  expiryDays: int
): bool =
  result = getSeenCount(
    store, queryHash, expiryDays) > 0

## Records a query as seen.  Replaces an existing entry for
## the same hash and enforces the maximum entry cap on the
## seen list.
##
## :param store: The cache store to mutate.
## :param queryHash: The query-text hash to record.
## :param maxEntries: Maximum seen entries (0 = unlimited).
## :param expiryDays: Expiry in days (0 = no purge).
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc markSeen*(
  store: var CacheStore,
  queryHash: string,
  maxEntries: int,
  expiryDays: int
) =
  let now = epochTime().int64
  let maxAge =
    if expiryDays > 0:
      expiryDays.int64 * 86400'i64
    else:
      0'i64

  var kept: seq[SeenEntry] = @[]
  var nextCount = 1

  for s in store.seen:
    let isExpired =
      expiryDays > 0 and
      ((now - s.timestamp) > maxAge)
    if isExpired:
      continue
    if s.queryHash == queryHash:
      nextCount = max(s.count, 1) + 1
      continue
    kept.add(s)

  kept.add(SeenEntry(
    queryHash: queryHash,
    timestamp: now,
    count: nextCount))

  if maxEntries > 0 and kept.len > maxEntries:
    kept = kept[kept.len - maxEntries .. ^1]

  store.seen = kept

## Checks whether a query has been explicitly decided as
## NOCACHE by a prior cache-decision LLM call.  A hit on this
## predicate allows callers to skip the decision step.
##
## :param store: The loaded cache store.
## :param queryHash: The query-text hash to check.
## :param expiryDays: Maximum age in days (0 = never expire).
## :returns: true when the query has a live NOCACHE decision.
##
## .. code-block:: nim
##   runnableExamples:
##     let store = CacheStore(entries: @[], seen: @[],
##                            nocache: @[])
##     assert not isNoCacheDecided(store, "abc", 30)
proc isNoCacheDecided*(
  store: CacheStore,
  queryHash: string,
  expiryDays: int
): bool =
  let now = epochTime().int64
  for n in store.nocache:
    if n.queryHash == queryHash:
      if expiryDays <= 0:
        return true
      let maxAge = expiryDays.int64 * 86400'i64
      if (now - n.timestamp) <= maxAge:
        return true
      else:
        return false
  result = false

## Records a query as explicitly decided to be not cached.
## Replaces any existing entry for the same hash, enforces the
## expiry window, and caps the list at maxEntries.
##
## :param store: The cache store to mutate.
## :param queryHash: The query-text hash to record.
## :param maxEntries: Maximum nocache entries (0 = unlimited).
## :param expiryDays: Expiry in days (0 = no purge).
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc markNoCacheDecided*(
  store: var CacheStore,
  queryHash: string,
  maxEntries: int,
  expiryDays: int
) =
  let now = epochTime().int64
  var kept: seq[NoCacheEntry] = @[]
  for n in store.nocache:
    if n.queryHash != queryHash:
      kept.add(n)
  kept.add(NoCacheEntry(
    queryHash: queryHash, timestamp: now))
  if expiryDays > 0:
    let maxAge = expiryDays.int64 * 86400'i64
    var fresh: seq[NoCacheEntry] = @[]
    for n in kept:
      if (now - n.timestamp) <= maxAge:
        fresh.add(n)
    kept = fresh
  if maxEntries > 0 and kept.len > maxEntries:
    kept = kept[kept.len - maxEntries .. ^1]
  store.nocache = kept

# ---------------------------------------------------------------------------
# Private helpers — seen/nocache removal
# ---------------------------------------------------------------------------

## Removes all seen entries matching a query hash.
##
## :param store: The cache store to mutate.
## :param queryHash: The hash to remove.
proc implRemoveSeen(
  store: var CacheStore,
  queryHash: string
) =
  var kept: seq[SeenEntry] = @[]
  for s in store.seen:
    if s.queryHash != queryHash:
      kept.add(s)
  store.seen = kept

## Removes all nocache-decision entries matching a query hash.
##
## :param store: The cache store to mutate.
## :param queryHash: The hash to remove.
proc implRemoveNoCache(
  store: var CacheStore,
  queryHash: string
) =
  var kept: seq[NoCacheEntry] = @[]
  for n in store.nocache:
    if n.queryHash != queryHash:
      kept.add(n)
  store.nocache = kept

# ---------------------------------------------------------------------------
# Public API — lookup
# ---------------------------------------------------------------------------

## Looks up a cache hit using priority order:
##   1. contextHash + cmResult  (most precise, fastest)
##   2. globalHash  + cmResult
##   3. contextHash + cmCommand (precise, re-execute)
##   4. globalHash  + cmCommand
##
## Returns the first non-expired match.
##
## :param store: The loaded cache store.
## :param globalHash: Hash without cwd.
## :param contextHash: Hash including cwd.
## :param expiryDays: Maximum age in days (0 = no expiry).
## :returns: The matching entry, or none.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let store = CacheStore(entries: @[], seen: @[])
##     assert lookupCache(store, "a", "b", 30).isNone
proc lookupCache*(
  store: CacheStore,
  globalHash: string,
  contextHash: string,
  expiryDays: int
): Option[CacheEntry] =
  let now = epochTime().int64
  var ctxResult:  Option[CacheEntry] = none(CacheEntry)
  var glbResult:  Option[CacheEntry] = none(CacheEntry)
  var ctxCommand: Option[CacheEntry] = none(CacheEntry)
  var glbCommand: Option[CacheEntry] = none(CacheEntry)
  for e in store.entries:
    if expiryDays > 0:
      let maxAge = expiryDays.int64 * 86400'i64
      if (now - e.timestamp) > maxAge:
        continue
    if e.scope == csContext and
        e.hash == contextHash:
      if e.cacheMode == cmResult and
          ctxResult.isNone:
        ctxResult = some(e)
      elif e.cacheMode == cmCommand and
          ctxCommand.isNone:
        ctxCommand = some(e)
    elif e.scope == csGlobal and
        e.hash == globalHash:
      if e.cacheMode == cmResult and
          glbResult.isNone:
        glbResult = some(e)
      elif e.cacheMode == cmCommand and
          glbCommand.isNone:
        glbCommand = some(e)
  if ctxResult.isSome:  return ctxResult
  if glbResult.isSome:  return glbResult
  if ctxCommand.isSome: return ctxCommand
  if glbCommand.isSome: return glbCommand
  result = none(CacheEntry)

# ---------------------------------------------------------------------------
# Public API — mutation
# ---------------------------------------------------------------------------

## Adds or replaces a cache entry and enforces the maximum
## entry cap and expiry on the entries list.
##
## :param store: The cache store to mutate.
## :param entry: The new cache entry to insert.
## :param maxEntries: Maximum entries (0 = unlimited).
## :param expiryDays: Expiry in days (0 = no purge).
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc addCacheEntry*(
  store: var CacheStore,
  entry: CacheEntry,
  maxEntries: int,
  expiryDays: int
) =
  var kept: seq[CacheEntry] = @[]
  for e in store.entries:
    if e.hash != entry.hash or
        e.scope != entry.scope:
      kept.add(e)
  kept.add(entry)
  if expiryDays > 0:
    let now = epochTime().int64
    let maxAge = expiryDays.int64 * 86400'i64
    var fresh: seq[CacheEntry] = @[]
    for e in kept:
      if (now - e.timestamp) <= maxAge:
        fresh.add(e)
    kept = fresh
  if maxEntries > 0 and kept.len > maxEntries:
    kept.sort(implCmpTimestamp)
    kept = kept[kept.len - maxEntries .. ^1]
  store.entries = kept

## Removes all cache entries whose query matches the given
## text (case-insensitive) and also removes the corresponding
## seen entry.
##
## :param store: The cache store to mutate.
## :param query: The query text to match against.
## :returns: The number of cache entries removed.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc unsetCacheEntries*(
  store: var CacheStore,
  query: string
): int =
  let target = toLowerAscii(query.strip())
  var kept: seq[CacheEntry] = @[]
  var removed = 0
  for e in store.entries:
    if toLowerAscii(e.query.strip()) == target:
      removed += 1
    else:
      kept.add(e)
  store.entries = kept
  let qh = computeQueryHash(query)
  implRemoveSeen(store, qh)
  implRemoveNoCache(store, qh)
  result = removed

# ---------------------------------------------------------------------------
# Public API — management commands
# ---------------------------------------------------------------------------

## Removes all entries and seen records from the cache file.
##
## :returns: The number of cache entries removed.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc cleanCache*(): int =
  var store = loadCache()
  result = store.entries.len
  store.entries = @[]
  store.seen = @[]
  store.nocache = @[]
  saveCache(store)

## Removes cache entries matching a query and persists.
##
## :param query: The query text to match.
## :returns: The number of entries removed.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc unsetCache*(query: string): int =
  var store = loadCache()
  result = unsetCacheEntries(store, query)
  saveCache(store)

## Prints a summary of the cache state including per-scope
## and per-mode entry counts and seen tracker statistics.
##
## :param cacheEnabled: Whether cache is enabled.
## :param expiryDays: Configured expiry in days.
## :param maxEntries: Configured max entry count.
## :param sk: The active output style.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc displayCacheInfo*(
  cacheEnabled: bool,
  expiryDays: int,
  maxEntries: int,
  sk: StyleKind = skSimp
) =
  let store = loadCache()
  let path = getCacheFilePath()
  let status =
    if cacheEnabled: "enabled" else: "disabled"
  styleKeyValue(sk, "cache", status)
  styleKeyValue(sk, "entries",
    $store.entries.len)
  var gcCount = 0
  var grCount = 0
  var ccCount = 0
  var crCount = 0
  for e in store.entries:
    case e.scope
    of csGlobal:
      case e.cacheMode
      of cmCommand: gcCount += 1
      of cmResult:  grCount += 1
    of csContext:
      case e.cacheMode
      of cmCommand: ccCount += 1
      of cmResult:  crCount += 1
  styleKeyValue(sk, "global-command entries",
    $gcCount)
  styleKeyValue(sk, "global-result entries",
    $grCount)
  styleKeyValue(sk, "context-command entries",
    $ccCount)
  styleKeyValue(sk, "context-result entries",
    $crCount)
  styleKeyValue(sk, "seen entries",
    $store.seen.len)
  styleKeyValue(sk, "nocache decisions",
    $store.nocache.len)
  styleKeyValue(sk, "max entries",
    formatIntOrDisable(maxEntries))
  let expiryStr =
    if expiryDays <= 0: "never"
    else: fmt"{expiryDays} days"
  styleKeyValue(sk, "expiry", expiryStr)
  styleKeyValue(sk, "file", path)
  if fileExists(path):
    let size = getFileSize(path)
    let sizeStr =
      if size < 1024:
        fmt"{size} B"
      elif size < 1024 * 1024:
        fmt"{size div 1024} KB"
      else:
        fmt"{size div (1024 * 1024)} MB"
    styleKeyValue(sk, "file size", sizeStr)
  else:
    styleKeyValue(sk, "file size", "0 B")
