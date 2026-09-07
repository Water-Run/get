import std/[strutils, unittest]
import markdown_render

suite "terminal Markdown answers":
  test "renders common structure while preserving code and URLs":
    let source = "# 中文标题\n\n- **重点**和 `code`\n> 引用\n" &
      "1. 第一项\n\n[文档](https://example.com/docs)\n\n" &
      "```sh\n  printf '**literal**'\n```"
    let plain = renderMarkdown(source, false)
    check plain == "中文标题\n\n• 重点和 code\n│ 引用\n" &
      "1. 第一项\n\n文档 (https://example.com/docs)\n\n" &
      "sh\n      printf '**literal**'"
    let colored = renderMarkdown(source)
    check colored.contains("\e[1m\e[36m中文标题\e[0m")
    check colored.contains("printf '**literal**'")

  test "aligns Chinese table cells and leaves escaped pipes as data":
    let table = "| 名称 | Value |\n| --- | --- |\n| 内存 | **16** |\n| a\\|b | x |"
    let plain = renderMarkdown(table, false)
    check plain == "名称 │ Value\n─────┼──────\n内存 │ 16   \na|b  │ x    "

  test "code fences must match and indented code stays literal":
    check renderMarkdown("````text\n```\n*literal*\n````", false) ==
      "text\n    ```\n    *literal*"
    check renderMarkdown("    **literal**\n~~~\n  code\n~~~", false) ==
      "    **literal**\n      code"
    check renderMarkdown("unclosed *markup and snake_case", false) ==
      "unclosed *markup and snake_case"

  test "model controls cannot clear the terminal or set the clipboard":
    let source = "# Safe\e[2J\n\e]52;c;payload\a**text**\r\b\0"
    check renderMarkdown(source, false) == "Safe\ntext"
    check safeTerminalText("a\ePpayload\e\\b") == "ab"
    check safeTerminalText("truncated: \xc3") == "truncated: �"
