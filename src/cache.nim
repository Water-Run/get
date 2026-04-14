## Response caching for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: cache.nim
## :License: AGPL-3.0
##
## This module implements a disk-backed cache that maps
## (query + context) hashes to previously generated commands and
## their final output.  When the cache is enabled and a hash match
## is found, the tool can return the cached result immediately
## without making any LLM API calls or executing commands.
##
## Cache entries expire after a configurable number of days (0 =
## never expire) and the store is capped at a configurable maximum
## number of entries (0 = unlimited).

{.experimental: "strictFuncs".}

import std/[algorithm, json, options, os, strformat,
            strutils, times]

import checksums/md5

import style
import utils

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## A single cached result mapping a context hash to the generated
## command and final displayed output.
type
  CacheEntry* = object
    hash*: string       ## MD5 hex digest of the context.
    query*: string      ## Original user query text.
    command*: string     ## Generated shell command (may be empty).
    output*: string     ## Final displayed output.
    timestamp*: int64   ## Unix epoch seconds when entry was created.

## In-memory representation of the entire cache file.
type
  CacheStore* = object
    entries*: seq[CacheEntry]  ## All cached entries.

# ---------------------------------------------------------------------------
# Private helpers — sorting
# ---------------------------------------------------------------------------

## Compares two cache entries by timestamp (ascending).
##
## :param a: First entry.
## :param b: Second entry.
## :returns: Negative if a is older, positive if newer, 0 if equal.
func implCmpTimestamp(a, b: CacheEntry): int =
  result = cmp(a.timestamp, b.timestamp)

# ---------------------------------------------------------------------------
# Public API — hash computation
# ---------------------------------------------------------------------------

## Computes a deterministic MD5 hex hash from the query and all
## context parameters that influence command generation.
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
##     let h1 = computeCacheHash("test", "/tmp", "bash",
##       "gpt", false, none(string), none(string))
##     let h2 = computeCacheHash("test", "/tmp", "bash",
##       "gpt", false, none(string), none(string))
##     assert h1 == h2
##     assert h1.len == 32
proc computeCacheHash*(
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
    cwd,
    shell,
    model,
    $instance,
    sysPmt,
    cmdPat,
    hostOS,
    hostCPU
  ]
  result = $toMD5(parts.join("|"))

# ---------------------------------------------------------------------------
# Public API — persistence
# ---------------------------------------------------------------------------

## Loads the cache store from disk.  Returns an empty store when the
## file does not exist or cannot be parsed.
##
## :returns: The current cache store.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — requires filesystem.
##     discard
proc loadCache*(): CacheStore =
  let path = getCacheFilePath()
  if not fileExists(path):
    return CacheStore(entries: @[])
  try:
    let content = readFile(path)
    let node = parseJson(content)
    if node.kind != JArray:
      return CacheStore(entries: @[])
    var entries: seq[CacheEntry] = @[]
    for item in node:
      let entry = CacheEntry(
        hash:
          item{"hash"}.getStr(""),
        query:
          item{"query"}.getStr(""),
        command:
          item{"command"}.getStr(""),
        output:
          item{"output"}.getStr(""),
        timestamp:
          item{"timestamp"}.getBiggestInt(0).int64
      )
      if entry.hash.len > 0:
        entries.add(entry)
    result = CacheStore(entries: entries)
  except JsonParsingError, IOError:
    result = CacheStore(entries: @[])

## Writes the cache store to disk as a JSON array.
##
## :param store: The cache store to persist.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — requires filesystem.
##     discard
proc saveCache*(store: CacheStore) =
  let path = getCacheFilePath()
  var arr = newJArray()
  for e in store.entries:
    arr.add(%*{
      "hash":      e.hash,
      "query":     e.query,
      "command":   e.command,
      "output":    e.output,
      "timestamp": e.timestamp
    })
  try:
    writeFile(path, pretty(arr, 2) & "\n")
  except IOError:
    discard

# ---------------------------------------------------------------------------
# Public API — lookup
# ---------------------------------------------------------------------------

## Looks up a hash in the cache store.  Returns the matching entry
## only if it has not expired.  When expiryDays is 0 (disabled)
## entries never expire.
##
## :param store: The loaded cache store.
## :param hash: The context hash to search for.
## :param expiryDays: Maximum age in days (0 = never expire).
## :returns: The matching entry, or none if not found or expired.
##
## .. code-block:: nim
##   runnableExamples:
##     let store = CacheStore(entries: @[])
##     import std/options
##     assert lookupCache(store, "abc", 30).isNone
proc lookupCache*(
  store: CacheStore,
  hash: string,
  expiryDays: int
): Option[CacheEntry] =
  let now = epochTime().int64
  for e in store.entries:
    if e.hash == hash:
      if expiryDays <= 0:
        # Expiry disabled — entry never expires.
        return some(e)
      let maxAge = expiryDays.int64 * 86400'i64
      if (now - e.timestamp) <= maxAge:
        return some(e)
      else:
        return none(CacheEntry)
  return none(CacheEntry)

# ---------------------------------------------------------------------------
# Public API — mutation
# ---------------------------------------------------------------------------

## Adds or replaces a cache entry and enforces the maximum entry
## cap.  When maxEntries is 0 (disabled) no cap is enforced.
## When expiryDays is 0 (disabled) no entries are purged by age.
##
## :param store: The cache store to mutate (var).
## :param entry: The new cache entry to insert.
## :param maxEntries: Maximum entries to retain (0 = unlimited).
## :param expiryDays: Expiry period in days (0 = no purge).
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — mutates state.
##     discard
proc addCacheEntry*(
  store: var CacheStore,
  entry: CacheEntry,
  maxEntries: int,
  expiryDays: int
) =
  # Remove any existing entry with the same hash.
  var kept: seq[CacheEntry] = @[]
  for e in store.entries:
    if e.hash != entry.hash:
      kept.add(e)
  kept.add(entry)

  # Purge expired entries (only when expiry is enabled).
  if expiryDays > 0:
    let now = epochTime().int64
    let maxAge = expiryDays.int64 * 86400'i64
    var fresh: seq[CacheEntry] = @[]
    for e in kept:
      if (now - e.timestamp) <= maxAge:
        fresh.add(e)
    kept = fresh

  # Enforce cap by removing oldest entries.
  if maxEntries > 0 and kept.len > maxEntries:
    kept.sort(implCmpTimestamp)
    kept = kept[kept.len - maxEntries .. ^1]

  store.entries = kept

## Removes all cache entries whose query matches the given text
## (case-insensitive, trimmed comparison).
##
## :param store: The cache store to mutate (var).
## :param query: The query text to match against.
## :returns: The number of entries removed.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — mutates state.
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
  result = removed

# ---------------------------------------------------------------------------
# Public API — management commands
# ---------------------------------------------------------------------------

## Removes all entries from the cache file.
##
## :returns: The number of entries that were removed.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — modifies filesystem.
##     discard
proc cleanCache*(): int =
  var store = loadCache()
  result = store.entries.len
  store.entries = @[]
  saveCache(store)

## Removes cache entries matching a query and persists the result.
##
## :param query: The query text to match (case-insensitive).
## :returns: The number of entries removed.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — modifies filesystem.
##     discard
proc unsetCache*(query: string): int =
  var store = loadCache()
  result = unsetCacheEntries(store, query)
  saveCache(store)

## Prints a summary of the cache state using the active output
## style.
##
## :param cacheEnabled: Whether cache is enabled.
## :param expiryDays: Configured expiry in days (0 = never).
## :param maxEntries: Configured max entry count (0 = unlimited).
## :param sk: The active output style.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — produces console output.
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
