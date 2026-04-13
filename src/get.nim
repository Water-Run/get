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
## It depends on the config and utils modules for all infrastructure
## operations and will depend on llm, prompt, and exec once query
## functionality is implemented.

{.experimental: "strictFuncs".}

import std/[os, strformat, strutils]

import config
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Help text displayed by `get help`.
const HELP_TEXT* = """usage: get <command> [<args>]

   "query"              get information using natural language
   set <option> [val]   set configuration (omit val to reset)
   config [--reset]     display or reset configuration
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
  let value = if args.len > 1: args[1 .. ^1].join(" ") else: ""
  setConfigOption(optName, value)

## Handles `get config` and `get config --reset`.
##
## :param args: Arguments after "config" (may be empty or ["--reset"]).
proc implHandleConfig(args: seq[string]) =
  if args.len > 0 and args[0] == "--reset":
    resetConfig()
    echo "configuration reset."
  else:
    displayConfig()

## Handles `get get` and its sub-flags.
##
## :param args: Arguments after "get" (may be empty or a single flag).
proc implHandleGet(args: seq[string]) =
  if args.len == 0:
    echo fmt"{APP_NAME} version {APP_VERSION}"
    echo APP_INTRO
    echo APP_LICENSE
    echo APP_GITHUB
    return
  case args[0]
  of "--intro":
    echo APP_INTRO
  of "--version":
    echo fmt"{APP_NAME} version {APP_VERSION}"
  of "--license":
    echo APP_LICENSE
  of "--github":
    echo APP_GITHUB
  else:
    raise newException(GetError,
      fmt"unknown option '{args[0]}' for 'get get'")

## Handles `get isok`.
##
## :returns: Exits with code 1 when configuration is incomplete.
proc implHandleIsOk() =
  let ready = checkReady()
  if not ready:
    quit(1)

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
    echo fmt"{APP_VERSION}"
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