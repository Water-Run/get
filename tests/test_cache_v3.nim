## Tests deterministic cache identity for the get v3 harness.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_cache_v3.nim
## :License: AGPL-3.0
##
## This suite verifies that provider, protocol, policy, and working-directory
## boundaries cannot reuse semantically incompatible v3 cache entries.

{.experimental: "strictFuncs".}

import std/[options, os, strutils, tempfiles, times, unittest]

import cache
import utils

## Verifies versioned cache hashes across provider and context boundaries.
suite "v3 cache identity":
  test "provider and policy choices produce distinct global keys":
    let base = computeGlobalHashV3(
      "query", "bash", "model", "https://one.test/v1",
      "auto", "native", none(string), none(string))
    let otherProvider = computeGlobalHashV3(
      "query", "bash", "model", "https://two.test/v1",
      "auto", "native", none(string), none(string))
    let clearedPattern = computeGlobalHashV3(
      "query", "bash", "model", "https://one.test/v1",
      "auto", "native", none(string), some(""))
    let caseVariant = computeGlobalHashV3(
      "Query", "bash", "model", "https://one.test/v1",
      "auto", "native", none(string), none(string))
    let delimiterLeft = computeGlobalHashV3(
      "a\x1fb", "c", "model", "https://one.test/v1",
      "auto", "native", none(string), none(string))
    let delimiterRight = computeGlobalHashV3(
      "a", "b\x1fc", "model", "https://one.test/v1",
      "auto", "native", none(string), none(string))
    check base != otherProvider
    check base != clearedPattern
    check base != caseVariant
    check delimiterLeft != delimiterRight
    check base.len == 64

  test "working directories produce distinct context keys":
    let first = computeContextHashV3(
      "query", "/one", "bash", "model", "https://one.test/v1",
      "auto", "native", none(string), none(string))
    let second = computeContextHashV3(
      "query", "/two", "bash", "model", "https://one.test/v1",
      "auto", "native", none(string), none(string))
    check first != second
    check first.len == 64

  test "replacement, expiry, and capacity are deterministic":
    let current = epochTime().int64
    let hashA = repeat('a', 64)
    let hashB = repeat('b', 64)
    let hashC = repeat('c', 64)
    var store = CacheStore(entries: @[])
    addCacheEntry(store, CacheEntry(
      hash: hashA, scope: csContext, cacheMode: cmResult,
      query: "a", command: "", output: "old", timestamp: current - 2),
      2, 30)
    addCacheEntry(store, CacheEntry(
      hash: hashA, scope: csContext, cacheMode: cmResult,
      query: "a", command: "", output: "new", timestamp: current - 1),
      2, 30)
    addCacheEntry(store, CacheEntry(
      hash: hashB, scope: csContext, cacheMode: cmResult,
      query: "b", command: "", output: "b", timestamp: current),
      2, 30)
    addCacheEntry(store, CacheEntry(
      hash: hashC, scope: csContext, cacheMode: cmResult,
      query: "c", command: "", output: "c", timestamp: current + 1),
      2, 30)
    check store.entries.len == 2
    check store.entries[0].hash == hashB
    check store.entries[1].hash == hashC

    store.entries.add(CacheEntry(
      hash: hashA, scope: csContext, cacheMode: cmResult,
      query: "expired", command: "", output: "expired",
      timestamp: current - 3 * 86_400))
    pruneCacheStore(store, 10, 1)
    check store.entries.len == 2

  test "lookup respects precision and rejects malformed entries":
    let current = epochTime().int64
    let globalHash = repeat('d', 64)
    let contextHash = repeat('e', 64)
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: globalHash, scope: csGlobal, cacheMode: cmCommand,
        query: "q", command: "printf global", output: "",
        timestamp: current),
      CacheEntry(
        hash: contextHash, scope: csContext, cacheMode: cmResult,
        query: "q", command: "", output: "context",
        timestamp: current)
    ])
    let hit = lookupCache(store, globalHash, contextHash, 30)
    check hit.isSome
    check hit.get.output == "context"

    expect CacheError:
      addCacheEntry(store, CacheEntry(
        hash: "short", scope: csContext, cacheMode: cmResult,
        query: "bad", command: "", output: "bad",
        timestamp: current), 10, 30)

  test "atomic snapshots recover from a damaged primary":
    let envName =
      when defined(windows): "APPDATA"
      else: "XDG_CONFIG_HOME"
    let existed = existsEnv(envName)
    let previous = getEnv(envName, "")
    let root = createTempDir("get_cache_v3_", "")
    putEnv(envName, root)
    try:
      let entry = CacheEntry(
        hash: repeat('f', 64),
        scope: csContext,
        cacheMode: cmResult,
        query: "recover",
        command: "",
        output: "last-good",
        timestamp: epochTime().int64)
      saveCache(CacheStore(entries: @[entry]))
      let path = getCacheFilePath()
      check fileExists(path)
      check fileExists(path & ".bak")
      writeFile(path, "{damaged")
      let recovered = loadCache()
      check recovered.entries.len == 1
      check recovered.entries[0].output == "last-good"
      writeFile(path, "{\"entries\":{}}")
      let structuralRecovery = loadCache()
      check structuralRecovery.entries.len == 1
      writeFile(path, "{\"entries\":[]}")
      let schemaRecovery = loadCache()
      check schemaRecovery.entries.len == 1
      writeFile(path, "{\"schemaVersion\":3," &
        "\"hashAlgorithm\":\"md5\",\"entries\":[]}")
      let algorithmRecovery = loadCache()
      check algorithmRecovery.entries.len == 1
    finally:
      if existed:
        putEnv(envName, previous)
      else:
        delEnv(envName)
      removeDir(root)
