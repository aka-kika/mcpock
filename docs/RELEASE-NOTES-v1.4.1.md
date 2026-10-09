# MCPBAR v1.4.1

**2026-09-12** — hotfix for v1.4.0, which could pin the app at 100% CPU.

macOS 26+, Apple Silicon. Notarized, stapled, Developer ID-signed DMG.

---

## Fix

**App stuck at 100% CPU after "Refresh now".** The v1.4.0 single-flight wait
(`while let existing = probeTask { await existing.value }`) never yielded once the
awaited cycle had finished: awaiting a completed task returns without suspending,
and the finished task was still in `probeTask` because only its original caller
cleared it, after its own continuation got a turn — which the spinning loop never
gave it. Whoever wakes first now clears the finished task, and the loop yields.
Regression test races fifty rounds of overlapping refreshes against a deadline.

Everything else is v1.4.0 (see `docs/RELEASE-NOTES-v1.4.0.md`).
