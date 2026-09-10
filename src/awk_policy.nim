## Lexical capability checks for inline AWK data processing.
## Variables, arithmetic, aggregation and pure builtins are allowed. Input-list
## mutation, external functions, program loading, pipes and output files are not.

func safeAwkProgram*(program: string): bool =
  if program.len == 0 or program.len > 8192:
    return false
  const PureCalls = ["length", "substr", "index", "split", "patsplit",
    "match", "sub", "gsub", "gensub", "tolower", "toupper", "sprintf",
    "int", "sqrt", "log", "exp", "sin", "cos", "atan2", "rand", "srand",
    "systime", "strftime", "mktime", "and", "or", "xor", "compl",
    "lshift", "rshift", "isarray", "typeof"]
  var index = 0
  var parens = 0
  var printDepth = -1
  var expectsOperand = true
  while index < program.len:
    let character = program[index]
    if character in {' ', '\t', '\r', '\n'}:
      # AWK can continue expressions across a newline after operators.
      # Keep print redirection checks active until an explicit statement/block
      # boundary, rather than treating whitespace as a new capability scope.
      index += 1
      continue
    if character == '#':
      while index < program.len and program[index] != '\n':
        index += 1
      continue
    if character == '"' or (character == '/' and expectsOperand):
      let delimiter = character
      var inClass = false
      var closed = false
      index += 1
      while index < program.len:
        let current = program[index]
        if current == '\\':
          index += 2
          continue
        if delimiter == '/' and current == '[':
          inClass = true
        elif delimiter == '/' and current == ']':
          inClass = false
        elif current == delimiter and not inClass:
          closed = true
          index += 1
          break
        elif current in {'\n', '\r'}:
          return false
        index += 1
      if not closed:
        return false
      expectsOperand = false
      continue
    if character in {'A' .. 'Z', 'a' .. 'z', '_'}:
      let start = index
      while index < program.len and
          program[index] in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
        index += 1
      let word = program[start ..< index]
      if word in ["system", "getline", "close", "fflush", "function",
          "func", "ARGV", "ARGC", "ENVIRON", "PROCINFO", "FUNCTAB",
          "SYMTAB", "LINT", "BINMODE"]:
        return false
      var next = index
      while next < program.len and program[next] in {' ', '\t', '\r', '\n'}:
        next += 1
      if next < program.len and program[next] == '(' and
          word notin PureCalls and word notin ["if", "while", "for",
            "print", "printf", "exit"]:
        return false
      if word in ["print", "printf"]:
        printDepth = parens
      expectsOperand = word in ["print", "printf", "if", "while", "for",
        "in", "else", "do", "exit", "BEGIN", "END"]
      continue
    case character
    of '@', '\\', '`', '\0':
      return false
    of '|':
      if index + 1 >= program.len or program[index + 1] != '|':
        return false
      index += 1
      expectsOperand = true
    of '>':
      if printDepth >= 0 and parens <= printDepth:
        return false
      if index + 1 < program.len and program[index + 1] == '>':
        return false
      expectsOperand = true
    of '(':
      parens += 1
      expectsOperand = true
    of ')':
      parens -= 1
      if parens < 0:
        return false
      expectsOperand = false
    of ';', '{', '}':
      printDepth = -1
      expectsOperand = true
    of '0' .. '9', '.', ']':
      expectsOperand = false
    of '+', '-':
      if index + 1 < program.len and program[index + 1] == character:
        index += 1 # Postfix ++/-- still ends an operand; it cannot start a regex.
      else:
        expectsOperand = true
    of '*', '/', '%', '^', '=', '!', '~', '<', '?', ':', ',', '[', '$', '&':
      expectsOperand = true
    else:
      return false
    index += 1
  result = parens == 0
