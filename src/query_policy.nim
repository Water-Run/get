## One authorization contract for new, repaired, and cached query proposals.
## Executable adapters and isolated compute share this boundary.
import std/[os, strutils]
import command_policy
import config
import harness_types
import tool_registry
import git_query

type
  QueryBackend* = enum
    qbBuiltin, qbHostReader, qbIsolatedCompute, qbGitSnapshot
  QueryDecisionKind* = enum
    qdAllowed, qdInvalid, qdUnsupported, qdDenied
  AuthorizedQuery* = object
    invocation: ToolCall
    executionBackend: QueryBackend
    executionShell: string
  QueryDecision* = object
    kind*: QueryDecisionKind
    reason*: string
    plan*: AuthorizedQuery

func call*(plan: AuthorizedQuery): ToolCall = plan.invocation
func backend*(plan: AuthorizedQuery): QueryBackend = plan.executionBackend
func shell*(plan: AuthorizedQuery): string = plan.executionShell

when defined(getTest):
  func authorizeTestProbe*(invocation: ToolCall, shell: string): AuthorizedQuery =
    ## Only test executables use this for their in-process timing probe.
    AuthorizedQuery(invocation: invocation, executionBackend: qbHostReader,
      executionShell: shell)

func classifyFailure(reason: string): QueryDecisionKind =
  for marker in ["not in", "not supported", "unsupported", "unrecognised",
      "outside", "allowed only for version", "expansion", "requires"]:
    if marker in reason: return qdUnsupported
  result = qdDenied

proc authorizeQuery*(invocation: ToolCall, defaultShell: string,
    isolatedAvailable = false): QueryDecision =
  if not knownQueryTool(invocation.toolName) or invocation.command.len == 0:
    return QueryDecision(kind: qdInvalid, reason: "invalid or unknown query tool")
  let effectiveShell = if invocation.shell.len > 0: invocation.shell else: defaultShell
  if invocation.invocationKind == tikShell and not isSupportedShell(effectiveShell):
    return QueryDecision(kind: qdInvalid, reason: "unsupported shell executable")
  var approvedBackend = qbBuiltin
  case invocation.invocationKind
  of tikEnvironment, tikReadFile, tikSearchFiles:
    # These adapters cannot execute commands or modify host files.
    discard
  of tikShell, tikProcess:
    approvedBackend = qbHostReader
    let gitReader = gitQueryWords(invocation, effectiveShell).len > 0
    let decision =
      if invocation.invocationKind == tikProcess:
        checkReadOnlyArguments(invocation.executable, invocation.argv, effectiveShell)
      else:
        checkReadOnlyCommand(invocation.command, effectiveShell)
    if gitReader:
      approvedBackend = qbGitSnapshot
    elif not decision.allowed:
      if isolatedAvailable:
        approvedBackend = qbIsolatedCompute
      else:
        return QueryDecision(kind: classifyFailure(decision.reason), reason: decision.reason)
  if invocation.cwd.len > 0 and not dirExists(invocation.cwd):
    return QueryDecision(kind: qdInvalid, reason: "query working directory does not exist")
  result = QueryDecision(kind: qdAllowed, plan: AuthorizedQuery(
    invocation: invocation, executionBackend: approvedBackend,
    executionShell: effectiveShell))
