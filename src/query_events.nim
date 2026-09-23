## One event receiver for process lines and optional machine-readable diagnostics.
import std/[json]
import config, harness_types, style

## The status word a process line shows for an observation.
func statusLabel*(status: ObservationStatus): string =
  case status
  of osCompleted, osTruncated: result = "ok"
  of osNoMatch: result = "no match"
  of osFinding: result = "finding"
  of osReused: result = "reused"
  of osDenied: result = "denied"
  of osUnsupported, osUnavailable: result = "unsupported"
  of osTimedOut: result = "timeout"

proc queryEventSink*(cfg: Config, sk: StyleKind): HarnessEventSink =
  result = proc(event: HarnessEvent) =
    if cfg.diagnostics:
      stderr.writeLine($( %*{"get_event": $event.kind, "turn": event.turn,
        "call_id": event.callId, "tool": event.tool, "message": event.message,
        "elapsed_ms": event.elapsedMs}))
    if not cfg.hideProcess and event.kind == hekToolCompleted:
      styleProcessLine(sk, event.tool, event.target, statusLabel(event.status),
        event.elapsedMs)

proc querySummary*(metrics: RunMetrics, partial: bool, exitCode: int): string =
  $(%*{"model_turns": metrics.modelTurns, "model_requests": metrics.modelRequests,
    "tool_proposals": metrics.toolProposals, "tool_starts": metrics.toolCalls,
    "tool_rejections": metrics.toolRejections, "tool_reuses": metrics.toolReuses,
    "tokens": metrics.inputOutputTokens, "elapsed_ms": metrics.elapsedMs,
    "partial": partial, "exit_code": exitCode})
