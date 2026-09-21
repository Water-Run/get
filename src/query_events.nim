## One event receiver for terminal progress and optional machine-readable diagnostics.
import std/[json]
import config, harness_types, style

proc queryEventSink*(cfg: Config, sk: StyleKind): HarnessEventSink =
  result = proc(event: HarnessEvent) =
    if cfg.diagnostics:
      stderr.writeLine($( %*{"get_event": $event.kind, "turn": event.turn,
        "call_id": event.callId, "message": event.message,
        "elapsed_ms": event.elapsedMs}))
    if not cfg.hideProcess:
      case event.kind
      of hekToolAuthorized: styleCommand(sk, "query", event.message)
      of hekBatchStarted: styleProgress(sk, event.message)
      else: discard

proc querySummary*(metrics: RunMetrics, partial: bool, exitCode: int): string =
  $(%*{"model_turns": metrics.modelTurns, "model_requests": metrics.modelRequests,
    "tool_proposals": metrics.toolProposals, "tool_starts": metrics.toolCalls,
    "tool_rejections": metrics.toolRejections, "tool_reuses": metrics.toolReuses,
    "recovery_turns": metrics.recoveryTurns, "tokens": metrics.inputOutputTokens,
    "elapsed_ms": metrics.elapsedMs, "partial": partial, "exit_code": exitCode})
