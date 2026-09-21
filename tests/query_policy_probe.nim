## Emits decisions without executing commands; usable against versioned sources.
import std/[json, os]
import command_policy

let cases = parseFile(paramStr(1))
var results = newJArray()
for item in cases:
  let decision = checkReadOnlyCommand(item["command"].getStr,
    item["shell"].getStr)
  results.add(%*{"id": item["id"].getStr, "allowed": decision.allowed,
    "reason": decision.reason})
echo $results
