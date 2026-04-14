# Package

version       = "1.0.0"
author        = "Water-Run"
description   = "get -- get anything from your computer"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
bin           = @["get"]


# Dependencies

requires "nim >= 2.2.8"
requires "checksums >= 0.1.0"
requires "regex >= 0.25.0"


# Tasks

task test, "Run all tests":
  exec "nimble c -r --path:src test.nim"