## Bounded, non-recursive wildcard matching for filename and ignore patterns.
## Matching is over UTF-8 bytes; literal Unicode names retain exact identity.
func queryGlobMatches*(text, pattern: string): bool =
  if pattern.len > 1024 or text.len > 32768: return false
  var state = newSeq[bool](text.len + 1)
  state[0] = true
  var cursor = 0
  while cursor < pattern.len:
    var next = newSeq[bool](text.len + 1)
    let character = pattern[cursor]
    if character == '*':
      var recursive = false
      while cursor + 1 < pattern.len and pattern[cursor + 1] == '*':
        recursive = true
        inc cursor
      let directories = recursive and cursor + 1 < pattern.len and pattern[cursor + 1] == '/'
      if directories: inc cursor
      next[0] = state[0]
      var reachable = state[0]
      for index in 1 .. text.len:
        if directories:
          next[index] = state[index] or (reachable and text[index - 1] == '/')
          reachable = reachable or state[index]
        else:
          next[index] = state[index] or
            (next[index - 1] and (recursive or text[index - 1] != '/'))
    elif character == '?':
      for index in 1 .. text.len:
        next[index] = state[index - 1] and text[index - 1] != '/'
    elif character == '[':
      var stop = cursor + 1
      while stop < pattern.len and pattern[stop] != ']': inc stop
      if stop >= pattern.len:
        for index in 1 .. text.len:
          next[index] = state[index - 1] and text[index - 1] == '['
      else:
        var start = cursor + 1
        let invert = start < stop and pattern[start] in {'!', '^'}
        if invert: inc start
        var accepted: set[char]
        while start < stop:
          if start + 2 < stop and pattern[start + 1] == '-':
            for c in pattern[start] .. pattern[start + 2]: accepted.incl(c)
            start += 3
          else:
            accepted.incl(pattern[start])
            inc start
        for index in 1 .. text.len:
          next[index] = state[index - 1] and text[index - 1] != '/' and
            ((text[index - 1] in accepted) != invert)
        cursor = stop
    else:
      var literal = character
      if character == '\\' and cursor + 1 < pattern.len:
        inc cursor
        literal = pattern[cursor]
      for index in 1 .. text.len:
        next[index] = state[index - 1] and text[index - 1] == literal
    state = move(next)
    inc cursor
  result = state[text.len]
