## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to the
## appropriate subcommand handler, and manages top-level error reporting.
## It depends on config and utils for infrastructure, on llm for API
## communication, and on prompt for prompt templates.

{.experimental: "strictFuncs".}

import std/[os, strformat, strutils, options]

import config
import llm
import prompt
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Help text displayed by `get help`.
const HELP_TEXT* = """usage: get <command> [<args>]

   "query"              get information using natural language
   set <option> [val]   set configuration (omit val to reset)
   config [--reset|--<option>]
                        display, reset, or query configuration
   get [--intro|--version|--license|--github]
   version              display version
   isok                 check configuration readiness
   help                 display this help message"""

# ---------------------------------------------------------------------------
# Private helpers — subcommand handlers
# ---------------------------------------------------------------------------

## Handles `get set <option> [value...]`.
##
## :param args: Arguments after "set", i.e. option name followed by
##              zero or more value tokens.
proc implHandleSet(args: seq[string]) =
  if args.len == 0:
    raise newException(GetError, "missing option name")
  let optName = args[0]
  let value =
    if args.len > 1: args[1 .. ^1].join(" ") else: ""
  setConfigOption(optName, value)

## Handles `get config`, `get config --reset`, and
## `get config --<option>`.  Displays a single option value when a
## --<option> flag is given (key excluded for security).
##
## :param args: Arguments after "config" (may be empty,
##              ["--reset"], or ["--<option>"]).
proc implHandleConfig(args: seq[string]) =
  if args.len == 0:
    displayConfig()
    return
  if args[0] == "--reset":
    resetConfig()
    echo "configuration reset."
    return
  if args[0].startsWith("--"):
    let optName = args[0][2 .. ^1]
    let cfg = loadConfig()
    case optName
    of "url":
      echo cfg.url
    of "model":
      echo cfg.model
    of "manual-confirm":
      echo cfg.manualConfirm
    of "double-check":
      echo cfg.doubleCheck
    of "instance":
      echo cfg.instance
    of "timeout":
      echo cfg.timeout
    of "max-token":
      echo cfg.maxToken
    of "command-pattern":
      echo(
        if cfg.commandPattern.isSome:
          cfg.commandPattern.get else: "")
    of "system-prompt":
      echo(
        if cfg.systemPrompt.isSome:
          cfg.systemPrompt.get else: "")
    of "shell":
      echo cfg.shell
    of "log":
      echo cfg.log
    of "hide-process":
      echo cfg.hideProcess
    else:
      raise newException(GetError,
        fmt"unknown config option '{optName}'")
    return
  raise newException(GetError,
    fmt"unknown argument '{args[0]}' for 'config'")

## Handles `get get` and its sub-flags.
## With no flags, prints all fields with labelled prefixes.
##
## :param args: Arguments after "get" (may be empty or a single flag).
proc implHandleGet(args: seq[string]) =
  if args.len == 0:
    echo fmt"version: {APP_VERSION}"
    echo fmt"intro: {APP_INTRO}"
    echo fmt"license: {APP_LICENSE}"
    echo fmt"github: {APP_GITHUB}"
    return
  case args[0]
  of "--intro":
    echo APP_INTRO
  of "--version":
    echo APP_VERSION
  of "--license":
    echo APP_LICENSE
  of "--github":
    echo APP_GITHUB
  else:
    raise newException(GetError,
      fmt"unknown option '{args[0]}' for 'get get'")

## Handles `get isok`.  First verifies that key, url, and model are
## configured, then sends a lightweight probe request to the LLM and
## prints the raw reply.  Exits with code 1 when configuration is
## incomplete or the API call fails.
proc implHandleIsOk() =
  let cfgReady = checkReady()
  if not cfgReady:
    quit(1)
  let cfg = loadConfig()
  let key = loadKey()
  if key.isNone:
    # checkReady should have caught this, but guard anyway.
    raise newException(GetError,
      "API key is not configured")
  let req = LlmRequest(
    model: cfg.model,
    systemPrompt: ISOK_SYSTEM_PROMPT,
    userPrompt: ISOK_USER_PROMPT,
    maxTokens: ISOK_MAX_TOKENS
  )
  let resp = sendLlmRequest(
    req,
    cfg.url,
    key.get,
    timeoutSec = cfg.timeout,
    hideProcess = cfg.hideProcess
  )
  echo resp.content

## Top-level CLI dispatcher.  Called from the main block.
proc implMain() =
  let args = commandLineParams()
  if args.len == 0:
    echo HELP_TEXT
    quit(0)
  case args[0]
  of "set":
    implHandleSet(args[1 .. ^1])
  of "config":
    implHandleConfig(args[1 .. ^1])
  of "get":
    implHandleGet(args[1 .. ^1])
  of "version":
    echo APP_VERSION
  of "isok":
    implHandleIsOk()
  of "help", "--help", "-h":
    echo HELP_TEXT
  else:
    # Everything else is treated as a query.
    # Query functionality is not yet implemented.
    stderr.writeLine("error: query not yet implemented")
    quit(1)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

when isMainModule:
  try:
    implMain()
  except GetError as e:
    stderr.writeLine(fmt"error: {e.msg}")
    quit(1)
  except CatchableError as e:
    stderr.writeLine(fmt"error: {e.msg}")
    quit(1)