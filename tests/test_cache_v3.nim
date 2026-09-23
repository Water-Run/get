## Tests cache identity, lookup, and persistence.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: test_cache_v3.nim
## :License: AGPL-3.0
##
## This suite verifies that provider, protocol, and working-directory
## boundaries cannot reuse incompatible entries, that an answer outranks a
## plan, and that a damaged primary falls back to the last-good copy.

{.experimental: "strictFuncs".}

import std/[json, options, os, strutils, tempfiles, times, unittest]

import cache
import harness_types
import tool_registry
import utils

func key(query = "query", cwd = "/one", url = "https://one.test/v1",
    shell = "bash"): string =
  computeCacheKey(query, cwd, shell, "model", url, "native", none(string))

suite "cache identity":
  test "provider, query, and directory choices produce distinct keys":
    check key() == key()
    check key() != key(url = "https://two.test/v1")
    check key() != key(query = "Query")
    check key() != key(cwd = "/two")
    check key(query = "a\x1fb", shell = "c") != key(query = "a", shell = "b\x1fc")
    check key().len == 64

  test "the identity revision names this release's loop":
    check CACHE_SCHEMA_VERSION == 5
    check CACHE_IDENTITY_REVISION.startsWith("get-v5-")

suite "cache store":
  test "replacement, expiry, and capacity are deterministic":
    let current = epochTime().int64
    let hashA = repeat('a', 64)
    let hashB = repeat('b', 64)
    let hashC = repeat('c', 64)
    var store = CacheStore(entries: @[])
    addCacheEntry(store, CacheEntry(hash: hashA, cacheMode: cmResult,
      query: "a", output: "old", timestamp: current - 2), 2, 30)
    addCacheEntry(store, CacheEntry(hash: hashA, cacheMode: cmResult,
      query: "a", output: "new", timestamp: current - 1), 2, 30)
    addCacheEntry(store, CacheEntry(hash: hashB, cacheMode: cmResult,
      query: "b", output: "b", timestamp: current), 2, 30)
    addCacheEntry(store, CacheEntry(hash: hashC, cacheMode: cmResult,
      query: "c", output: "c", timestamp: current + 1), 2, 30)
    check store.entries.len == 2
    check store.entries[0].hash == hashB
    check store.entries[1].hash == hashC

    store.entries.add(CacheEntry(hash: hashA, cacheMode: cmResult,
      query: "expired", output: "expired", timestamp: current - 3 * 86_400))
    pruneCacheStore(store, 10, 1)
    check store.entries.len == 2

  test "an answer outranks a plan for the same key":
    let current = epochTime().int64
    let hash = repeat('d', 64)
    var store = CacheStore(entries: @[])
    addCacheEntry(store, CacheEntry(hash: hash, cacheMode: cmPlan,
      query: "q", plan: "[{}]", timestamp: current), 10, 30)
    check lookupCache(store, hash, 30).get.cacheMode == cmPlan
    addCacheEntry(store, CacheEntry(hash: hash, cacheMode: cmResult,
      query: "q", output: "answer", timestamp: current - 5), 10, 30)
    check store.entries.len == 2
    let hit = lookupCache(store, hash, 30)
    check hit.get.cacheMode == cmResult
    check hit.get.output == "answer"
    check lookupCache(store, repeat('e', 64), 30).isNone

  test "malformed entries are refused":
    var store = CacheStore(entries: @[])
    expect CacheError:
      addCacheEntry(store, CacheEntry(hash: "short", cacheMode: cmResult,
        query: "bad", output: "bad", timestamp: epochTime().int64), 10, 30)
    expect CacheError:
      addCacheEntry(store, CacheEntry(hash: repeat('f', 64), cacheMode: cmPlan,
        query: "bad", plan: "", timestamp: epochTime().int64), 10, 30)

  test "a plan round-trips the reads that answered a query":
    let observations = @[
      ToolObservation(toolName: "run_shell", command: "uname -a",
        argumentsJson: $(%*{"command": "uname -a"})),
      ToolObservation(toolName: "read_file",
        argumentsJson: $(%*{"path": "README.md", "limit": 20}))]
    let calls = decodeCachedQueryPlan(encodeCachedQueryPlan(observations))
    check calls.len == 2
    check calls[0].id == "cached-1"
    check calls[0].command == "uname -a"
    check calls[1].invocationKind == tikReadFile
    check calls[1].limit == 20
    expect ValueError:
      discard decodeCachedQueryPlan("[]")

  test "atomic snapshots recover from a damaged primary":
    let envName =
      when defined(windows): "APPDATA"
      else: "XDG_CONFIG_HOME"
    let existed = existsEnv(envName)
    let previous = getEnv(envName, "")
    let root = createTempDir("get_cache_v5_", "")
    putEnv(envName, root)
    try:
      let entry = CacheEntry(hash: repeat('f', 64), cacheMode: cmResult,
        query: "recover", output: "last-good", timestamp: epochTime().int64)
      saveCache(CacheStore(entries: @[entry]))
      let path = getCacheFilePath()
      check fileExists(path)
      check fileExists(path & ".bak")
      writeFile(path, "{damaged")
      let recovered = loadCache()
      check recovered.entries.len == 1
      check recovered.entries[0].output == "last-good"
      writeFile(path, "{\"entries\":{}}")
      check loadCache().entries.len == 1
      writeFile(path, "{\"entries\":[]}")
      check loadCache().entries.len == 1
      writeFile(path, "{\"schemaVersion\":4,\"hashAlgorithm\":\"sha256\",\"entries\":[]}")
      check loadCache().entries.len == 1
      writeFile(path, "{\"schemaVersion\":" & $CACHE_SCHEMA_VERSION & "," &
        "\"hashAlgorithm\":\"md5\",\"entries\":[]}")
      check loadCache().entries.len == 1
    finally:
      if existed:
        putEnv(envName, previous)
      else:
        delEnv(envName)
      removeDir(root)

  test "a leftover lock directory from an older version is replaced":
    let envName =
      when defined(windows): "APPDATA"
      else: "XDG_CONFIG_HOME"
    let existed = existsEnv(envName)
    let previous = getEnv(envName, "")
    let root = createTempDir("get_cache_lock_", "")
    putEnv(envName, root)
    try:
      createDir(getCacheFilePath() & ".lock")
      putCacheEntry(CacheEntry(hash: repeat('a', 64), cacheMode: cmResult,
        query: "q", output: "x", timestamp: epochTime().int64), 10, 30)
      check fileExists(getCacheFilePath() & ".lock")
      check loadCache().entries.len == 1
    finally:
      if existed:
        putEnv(envName, previous)
      else:
        delEnv(envName)
      removeDir(root)
