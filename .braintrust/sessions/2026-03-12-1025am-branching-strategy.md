# Branching Strategy & Change Risk Assessment

## Query
Should we destroy the debug branch and start fresh from master for P0/P1 changes? How disruptive is each change? What's the correct CMIO fix pattern?

## Gemini
Model unavailable (empty output)

## Codex
Detailed risk ratings and a key architectural recommendation for the CMIO fix:

### Risk Ratings
- P0-A (delegate queue): **Low-risk** - matches Apple's intended model, only risk is data races if state vars accessed from multiple queues without confinement
- P0-B (session queue): **Low-risk** - canonical pattern, risk is migration ordering bugs if session state partly remains on main
- P1-A (listener cleanup): **Low-risk** - externally invisible, just bookkeeping
- P1-B (coreaudiod restart): **High-risk** - system-wide blast radius, can interrupt calls/music, must be heavily gated and opt-in

### CMIO Fix Pattern (key insight)
Don't use a semaphore wait. Use a state machine:
1. On sessionQueue, detach delegate immediately
2. Hand teardown to a separate teardownQueue
3. Do NOT start new session immediately
4. Start new session only when teardown reports completion back to sessionQueue
5. If teardown doesn't complete within timeout, escalate (don't open new session on same device)

"Better to have a bounded 'mic unavailable while teardown resolves' window than a silently broken warm session."

## Claude (Opus subagent)
Read the actual git diff between master and debug-logging, then provided:

### Branch Strategy: Start Fresh from Master
- Debug branch does two things at once (instrumentation + structural changes)
- P0 queue changes will fundamentally rewrite the same code debug branch modified
- Layering on top means resolving conflicts in code about to be replaced
- Create `session-queue-overhaul` from master, reimplement properly

### Risk Ratings
- P0 delegate queue: **Low risk** - highest value change, watch for shared state access between sample queue and heartbeat timer
- P0 session queue: **Medium risk** - right fix, but changes operation ordering relative to KVO/notifications/listeners. Need to audit every `self.session` access
- P1 listener cleanup: **Low risk** - need to store block references for RemovePropertyListenerBlock
- P1 coreaudiod restart: **Medium risk** - require 3 consecutive failures + 60s minimum + env-var killswitch

### CMIO Fix: Do Not Port As-Is
The current fix trades a deadlock for a race condition. With proper session queue architecture, both problems disappear:
```swift
sessionQueue.async {
    // teardown old (synchronous on this queue, not main)
    old.removeOutput(...)
    old.removeInput(...)
    old.stopRunning()
    // setup new (guaranteed old is done)
    let s = AVCaptureSession()
    s.addInput(...)
    s.startRunning()
}
```
Deadlock avoided because session queue is not main. Race avoided because teardown and setup are serialized.

### Recommended Sequence
1. Create `session-queue-overhaul` from master
2. Add sessionQueue + sampleQueue
3. Port silent-sample detection (always-on, not behind #if false)
4. Add listener cleanup
5. Add coreaudiod restart (gated)
6. Soak 48-72 hours
7. Merge to master

## Synthesis

### Consensus (all models agree)
1. **Start fresh from master** - don't layer on debug branch
2. **P0 delegate queue change is low risk and highest value**
3. **The current CMIO fix must not go to master as-is** - it trades deadlock for zero-sample race
4. **coreaudiod restart is the highest-risk change** and needs heavy guardrails
5. **Dedicated session queue solves both the deadlock AND the zero-sample race** naturally through serialization

### Key Divergence
- Claude rates P0-B (session queue) as medium risk; Codex rates it low risk
- Claude recommends 48-72 hour soak; Codex doesn't specify duration
- Both agree on the pattern but Codex explicitly recommends a separate teardownQueue for isolating hung teardowns, while Claude puts everything on one sessionQueue

### Recommendation
Use Codex's two-queue pattern (sessionQueue for lifecycle decisions, teardownQueue for potentially-hung teardowns) with Claude's soak testing timeline. The two-queue approach is more resilient because a hung stopRunning() on sessionQueue would block all future session operations.
