## Environment inspection and child-process credential hygiene.
import std/[envvars, json, strutils]

func sensitiveEnvironmentName*(name: string): bool =
  let upper = name.toUpperAscii
  for marker in ["PASSWORD", "PASSWD", "TOKEN", "SECRET", "API_KEY",
      "APIKEY", "PRIVATE_KEY", "CREDENTIAL", "AUTHORIZATION", "ACCESS_KEY"]:
    if marker in upper: return true

proc environmentObservation*(names: seq[string]): string =
  var values = newJObject()
  for name in names:
    values[name] =
      if not existsEnv(name): newJNull()
      elif sensitiveEnvironmentName(name): %"[redacted]"
      else: %getEnv(name)
  result = $(%*{"source": "host environment", "values": values})

proc redactEnvironmentSecrets*(text: string): string =
  result = text
  for name, value in envPairs():
    if value.len >= 6 and sensitiveEnvironmentName(name):
      result = result.replace(value, "[redacted]")
