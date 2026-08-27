# Incident Report — Chatbot 524 Error

**Date:** 2026-08-10
**Reported by:** Yalini Natarajan
**Duration:** ~04:30 to ~04:35 UTC (~5 min, from detection to full resolution)
**Severity:** High — chatbot fully unavailable to end users

## Summary

The chatbot returned **HTTP 524 (origin timeout)**. The LLM (vLLM) itself was healthy throughout — the outage was caused by the **gateway service** (the API layer in front of vLLM) freezing completely, plus an unrelated **MySQL crash** from earlier the same day that had gone unnoticed.

## Root Cause

1. **`/workspace` is a network-mounted filesystem** (RunPod's MooseFS storage, not local disk).
2. At **04:30:11**, that network mount hit a transient I/O error (`[Errno 5] Input/output error`) while the gateway tried to write a log line.
3. The gateway runs as a **single worker** (`--workers 1`). The blocked write froze its entire event loop — the process went into kernel **D-state ("disk sleep")**, waiting on the FUSE mount to answer a request that never came back. A process in this state cannot be killed, even with `SIGKILL`, until the underlying I/O resolves.
4. Because the gateway stopped responding to *everything*, including its own `/health` endpoint, requests from the chatbot piled up until the proxy gave up — **524**.
5. Separately, **MariaDB had already crashed** at ~01:00 (core dump, mid-write to the `api_keys` table) — likely the same storage flakiness — and never restarted, since it has no auto-restart configured. This wasn't the direct cause of the 524, but left the platform running in a degraded, unlogged state for ~3.5 hours before the outage.

## Resolution

1. Diagnosed vLLM as healthy (ruled out the LLM itself).
2. Restarted MariaDB — clean InnoDB crash recovery.
3. The stuck gateway process's blocking I/O eventually resolved on its own; process exited, freeing port 7778.
4. Re-ran `start_all.sh` to bring the gateway back up.
5. Verified all five services healthy: vLLM, gateway, OCR, embed, MySQL.

## Recommendations

- **Run the gateway with multiple workers** (e.g. `--workers 2+`) so one stuck request can't freeze the whole service.
- **Add auto-restart for MySQL and the gateway** (systemd, or a watchdog loop like the one already protecting OCR) so crashes/hangs self-heal instead of sitting broken for hours.
- **Add a health-check alert** (uptime monitor hitting `/health` every 1–2 min) so outages are caught in minutes, not discovered via a user-facing 524.
- **Move MySQL's datadir consideration**: crashes coinciding with network-storage I/O errors suggest the underlying MooseFS mount had a hiccup this window — if this recurs, worth flagging to RunPod support as a storage-layer issue.
