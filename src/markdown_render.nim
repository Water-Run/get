## Small, dependency-free terminal renderer for model answers.
## Rendering never executes code, opens links, or emits terminal hyperlinks.
import std/[strutils, unicode]

const
  Reset = "\e[0m"
  Bold = "\e[1m"
  Italic = "\e[3m"
  Cyan = "\e[36m"
  Dim = "\e[2m"

func safeTerminalText*(text: string): string =
  ## Strip terminal control sequences supplied by the model or a cached answer.
  var i = 0
  while i < text.len:
    if text[i] == '\e':
      inc i
      if i >= text.len: break
      if text[i] == '[':
        inc i
        while i < text.len and text[i] notin {'@' .. '~'}: inc i
        if i < text.len: inc i
      elif text[i] in {']', 'P', 'X', '^', '_'}:
        inc i
        while i < text.len:
          if text[i] == '\a':
            inc i
            break
          if text[i] == '\e' and i + 1 < text.len and text[i + 1] == '\\':
            i += 2
            break
          inc i
      else:
        inc i
      continue
    let size = min(text.runeLenAt(i), text.len - i)
    if byte(text[i]) >= 0x80 and validateUtf8(text[i ..< i + size]) >= 0:
      result.add("�")
      inc i
      continue
    let rune = text.runeAt(i)
    if int(rune) in [9, 10] or
        (int(rune) >= 32 and int(rune) notin 127 .. 159):
      result.add(text[i ..< i + size])
    i += size

func decorate(text, ansi: string, color: bool): string =
  if color: ansi & text & Reset else: text

func inlineText(text: string, color: bool): string =
  var i = 0
  while i < text.len:
    if text[i] == '\\' and i + 1 < text.len and
        text[i + 1] in {'\\', '`', '*', '_', '[', ']', '(', ')', '#', '|'}:
      result.add(text[i + 1])
      i += 2
      continue
    if text[i] == '`':
      var length = 1
      while i + length < text.len and text[i + length] == '`': inc length
      let marker = repeat('`', length)
      let closing = text.find(marker, i + length)
      if closing >= 0:
        result.add(decorate(text[i + length ..< closing], Cyan, color))
        i = closing + length
        continue
    if text[i] in {'*', '_'}:
      let length =
        if i + 1 < text.len and text[i + 1] == text[i]: 2 else: 1
      let marker = repeat(text[i], length)
      let closing = text.find(marker, i + length)
      let inWord = text[i] == '_' and i > 0 and
        text[i - 1] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}
      if not inWord and closing > i + length and
          text[i + length] notin {' ', '\t'} and
          text[closing - 1] notin {' ', '\t'}:
        result.add(decorate(text[i + length ..< closing],
          if length == 2: Bold else: Italic, color))
        i = closing + length
        continue
    let imageLink = text[i] == '!' and i + 1 < text.len and text[i + 1] == '['
    if text[i] == '[' or imageLink:
      let start = i + (if imageLink: 2 else: 1)
      let middle = text.find("](", start)
      if middle >= 0:
        let closing = text.find(')', middle + 2)
        if closing >= 0:
          let label = text[start ..< middle]
          let target = text[middle + 2 ..< closing]
          result.add(decorate(label, Cyan, color))
          if target != label and target.len > 0:
            result.add(" (" & target & ")")
          i = closing + 1
          continue
    result.add(text[i])
    inc i

func cellWidth(text: string): int =
  for rune in text.runes:
    let value = int(rune)
    if value in 0x0300 .. 0x036f or value in 0xfe00 .. 0xfe0f or value == 0x200d:
      continue
    if value in 0x1100 .. 0x115f or value in 0x2e80 .. 0xa4cf or
        value in 0xac00 .. 0xd7a3 or value in 0xf900 .. 0xfaff or
        value in 0xfe10 .. 0xfe6f or value in 0xff01 .. 0xff60 or
        value in 0xffe0 .. 0xffe6 or value in 0x1f300 .. 0x1faff or
        value in 0x20000 .. 0x3fffd:
      result += 2
    else:
      inc result

func tableCells(line: string): seq[string] =
  var value = strutils.strip(line)
  if value.startsWith("|"): value = value[1 .. ^1]
  if value.endsWith("|") and not value.endsWith("\\|"): value.setLen(value.len - 1)
  var cell = ""
  var escaped = false
  var code = false
  for c in value:
    if c == '|' and not escaped and not code:
      result.add(strutils.strip(cell))
      cell = ""
    else:
      cell.add(c)
    if c == '`' and not escaped: code = not code
    if c == '\\' and not escaped: escaped = true
    else: escaped = false
  result.add(strutils.strip(cell))

func tableSeparator(line: string, columns: int): bool =
  if not line.contains('|') or columns < 2 or columns > 32: return false
  let cells = tableCells(line)
  if cells.len != columns: return false
  for cell in cells:
    let dashes = strutils.strip(cell, chars = {':'})
    if dashes.len < 3: return false
    for c in dashes:
      if c != '-': return false
  result = true

func fence(line: string): tuple[marker: char, length: int, rest: string] =
  let value = strutils.strip(line, leading = true, trailing = false)
  if line.len - value.len > 3 or value.len < 3 or value[0] notin {'`', '~'}:
    return
  result.marker = value[0]
  while result.length < value.len and value[result.length] == result.marker:
    inc result.length
  if result.length < 3: result.length = 0
  result.rest = strutils.strip(value[result.length .. ^1])

func renderMarkdown*(text: string, color: bool = true): string =
  ## Common headings, lists, quotes, fences, links, emphasis, and pipe tables.
  ## Unrecognized syntax stays readable; code contents retain their whitespace.
  let lines = safeTerminalText(text).split('\n')
  var output: seq[string] = @[]
  var codeMarker = '\0'
  var codeLength = 0
  var i = 0
  while i < lines.len:
    let line = lines[i]
    let currentFence = fence(line)
    if codeLength > 0:
      if currentFence.marker == codeMarker and
          currentFence.length >= codeLength and currentFence.rest.len == 0:
        codeLength = 0
      else:
        output.add("    " & line)
      inc i
      continue
    if currentFence.length >= 3:
      codeMarker = currentFence.marker
      codeLength = currentFence.length
      if currentFence.rest.len > 0:
        output.add(decorate(currentFence.rest, Dim, color))
      inc i
      continue
    let header = tableCells(line)
    if line.contains('|') and i + 1 < lines.len and
        tableSeparator(lines[i + 1], header.len):
      var rows = @[header]
      var j = i + 2
      while j < lines.len and lines[j].contains('|') and rows.len < 1000:
        let cells = tableCells(lines[j])
        if cells.len != header.len: break
        rows.add(cells)
        inc j
      var widths = newSeq[int](header.len)
      for row in rows:
        for column, cell in row:
          widths[column] = max(widths[column], cellWidth(inlineText(cell, false)))
      for rowIndex, row in rows:
        var rendered: seq[string] = @[]
        for column, cell in row:
          let plain = inlineText(cell, false)
          let value = if rowIndex == 0: decorate(plain, Bold, color)
                      else: inlineText(cell, color)
          rendered.add(value & repeat(' ', widths[column] - cellWidth(plain)))
        output.add(rendered.join(" │ "))
        if rowIndex == 0:
          var rules: seq[string] = @[]
          for width in widths: rules.add(repeat("─", width))
          output.add(rules.join("─┼─"))
      i = j
      continue
    let value = strutils.strip(line, leading = true, trailing = false)
    let indent = line[0 ..< line.len - value.len]
    var heading = 0
    while heading < value.len and value[heading] == '#': inc heading
    if heading in 1 .. 6 and heading < value.len and value[heading] == ' ':
      output.add(decorate(inlineText(strutils.strip(value[heading + 1 .. ^1]),
        false), Bold & Cyan, color))
    elif value in ["---", "***", "___"]:
      output.add(decorate("────────────────────────", Dim, color))
    elif value.startsWith("> "):
      output.add(indent & decorate("│ ", Dim, color) & inlineText(value[2 .. ^1], color))
    elif value.len >= 2 and value[0] in {'-', '*', '+'} and value[1] == ' ':
      output.add(indent & "• " & inlineText(value[2 .. ^1], color))
    elif indent.len >= 4 or line.startsWith("\t"):
      output.add(line)
    else:
      output.add(inlineText(line, color))
    inc i
  result = output.join("\n")
