"""Focused tests for the Priority-2 change: skip _needs_web() for
auto-classified non-chat tasks (extraction/coding/reasoning/classification).

Uses stdlib unittest + unittest.mock only (no pytest/third-party deps were
added). Importing `main` performs one real, read-only MySQL SELECT via
_load_keys() at module import time (existing module-level behavior, not
something this test suite changes) — the background loops
(_persist_loop/_vllm_keepalive_loop) are only started by FastAPI's
"startup" event, which a plain import never triggers, so no lingering
threads are created. No real LLM or web calls are made anywhere here;
_needs_web, _web_context, _detect_task, _resolve_images, and the outbound
vLLM call (_vllm_post) are all mocked.

Run with:  /workspace/gateway/venv/bin/python -m unittest test_needs_web_skip -v
"""
import asyncio
import re
import types
import unittest
from unittest.mock import AsyncMock, patch

import main


# ---------------------------------------------------------------------------
# 1-7: pure unit tests for the extracted decision helper
# ---------------------------------------------------------------------------
class ShouldSkipWebCheckTests(unittest.TestCase):
    def test_extraction_auto_classified_skips(self):
        self.assertTrue(main._should_skip_web_check("auto", True, "extraction"))

    def test_coding_auto_classified_skips(self):
        self.assertTrue(main._should_skip_web_check("auto", True, "coding"))

    def test_reasoning_auto_classified_skips(self):
        self.assertTrue(main._should_skip_web_check("auto", True, "reasoning"))

    def test_classification_auto_classified_skips(self):
        self.assertTrue(main._should_skip_web_check("auto", True, "classification"))

    def test_chat_auto_classified_does_not_skip(self):
        self.assertFalse(main._should_skip_web_check("auto", True, "chat"))

    def test_unknown_ambiguous_task_does_not_skip(self):
        # a task string outside the known preset set must never trigger a skip
        self.assertFalse(main._should_skip_web_check("auto", True, "some_future_task"))
        self.assertFalse(main._should_skip_web_check("auto", True, ""))

    def test_explicit_task_not_auto_classified_does_not_skip(self):
        # client explicitly sent task="extraction" — _detect_task() never ran
        self.assertFalse(main._should_skip_web_check("auto", False, "extraction"))

    def test_image_resolved_shortcut_not_auto_classified_does_not_skip(self):
        # img_resolved path also sets task="extraction" without classifying —
        # same guard as the explicit-task case above
        self.assertFalse(main._should_skip_web_check("auto", False, "extraction"))

    def test_explicit_web_search_true_force_never_skips(self):
        self.assertFalse(main._should_skip_web_check(True, True, "extraction"))

    def test_explicit_web_search_false_never_skips_flag_itself(self):
        # ws=False already short-circuits to no-web upstream of this helper;
        # the helper itself must still report "no skip" for a non-"auto" ws
        self.assertFalse(main._should_skip_web_check(False, True, "extraction"))


# ---------------------------------------------------------------------------
# Lightweight Request/Response test doubles (no Starlette/httpx I/O)
# ---------------------------------------------------------------------------
class FakeRequest:
    def __init__(self, body: dict, key_hash=None):
        self._body = body
        self.headers = {}
        self.client = types.SimpleNamespace(host="127.0.0.1")
        self.state = types.SimpleNamespace(key_hash=key_hash)

    async def json(self):
        return self._body


class FakeVllmResponse:
    """Stands in for the httpx.Response that _vllm_post() would return."""
    def __init__(self, content: str = "ok"):
        self.status_code = 200
        self._data = {
            "model": "qwen3.6-35b",
            "choices": [{"message": {"content": content}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1},
        }

    def json(self):
        return self._data


def run_async(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------------------
# 8-9: does skipping actually prevent the extra calls, and does the main
# completion still execute correctly — exercised through the real
# chat_completions() route function, not a re-derivation of the logic.
# ---------------------------------------------------------------------------
class ChatCompletionsSkipIntegrationTests(unittest.TestCase):
    def _patches(self, *, resolve_images_return=(None, False), detect_task_return="chat"):
        """Returns the common set of patches every scenario needs. Callers
        further configure/override individual mocks before invoking the
        route. messages passed through resolve_images_return[0] default to
        echoing the input when None."""
        return [
            patch("main._log_async"),                      # never touch real log files
            patch("main._record_tokens"),                   # never touch real key stats
            patch("main._resolve_images", new_callable=AsyncMock),
            patch("main._detect_task", new_callable=AsyncMock),
            patch("main._needs_web", new_callable=AsyncMock, return_value=False),
            patch("main._web_context", new_callable=AsyncMock, return_value=None),
            patch("main._vllm_post", new_callable=AsyncMock,
                  return_value=FakeVllmResponse()),
        ]

    def _run_scenario(self, body, *, resolve_images_images=False, detect_task="chat"):
        patches = self._patches()
        mocks = [p.start() for p in patches]
        (_log_async_m, _record_tokens_m, resolve_images_m, detect_task_m,
         needs_web_m, web_context_m, vllm_post_m) = mocks
        try:
            resolve_images_m.return_value = (body.get("messages", []), resolve_images_images)
            detect_task_m.return_value = detect_task
            req = FakeRequest(body)
            resp = run_async(main.chat_completions(req))
            return resp, needs_web_m, web_context_m, vllm_post_m, detect_task_m
        finally:
            for p in patches:
                p.stop()

    def test_auto_extraction_skips_needs_web_and_web_context(self):
        body = {"messages": [{"role": "user", "content": "extract the invoice total"}],
                "stream": False}
        resp, needs_web_m, web_context_m, vllm_post_m, detect_task_m = self._run_scenario(
            body, detect_task="extraction")
        self.assertEqual(resp.status_code, 200)
        needs_web_m.assert_not_called()
        web_context_m.assert_not_called()
        vllm_post_m.assert_called_once()   # main answer-generation call still executes

    def test_auto_coding_skips_needs_web(self):
        body = {"messages": [{"role": "user", "content": "fix this python function"}],
                "stream": False}
        resp, needs_web_m, web_context_m, vllm_post_m, _ = self._run_scenario(
            body, detect_task="coding")
        self.assertEqual(resp.status_code, 200)
        needs_web_m.assert_not_called()
        web_context_m.assert_not_called()
        vllm_post_m.assert_called_once()

    def test_auto_chat_still_checks_needs_web(self):
        body = {"messages": [{"role": "user", "content": "how's it going?"}],
                "stream": False}
        resp, needs_web_m, web_context_m, vllm_post_m, _ = self._run_scenario(
            body, detect_task="chat")
        self.assertEqual(resp.status_code, 200)
        needs_web_m.assert_called_once()   # normal chat behavior preserved
        web_context_m.assert_not_called()  # _needs_web mocked to return False here
        vllm_post_m.assert_called_once()

    def test_explicit_task_extraction_still_checks_needs_web(self):
        # client explicitly set task="extraction" — _detect_task() must not
        # even be invoked, and the skip must NOT apply (existing behavior
        # preserved for explicit task values).
        body = {"messages": [{"role": "user", "content": "pull fields from this text"}],
                "task": "extraction", "stream": False}
        resp, needs_web_m, web_context_m, vllm_post_m, detect_task_m = self._run_scenario(
            body, detect_task="extraction")  # would only be used if (wrongly) invoked
        self.assertEqual(resp.status_code, 200)
        detect_task_m.assert_not_called()
        needs_web_m.assert_called_once()
        vllm_post_m.assert_called_once()

    def test_image_resolved_extraction_still_checks_needs_web(self):
        # img_resolved=True forces task="extraction" via the shortcut path,
        # not the classifier — existing behavior (still checks) preserved.
        body = {"messages": [{"role": "user", "content": [
            {"type": "text", "text": "what's on this invoice?"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,Zm9v"}},
        ]}], "stream": False}
        resp, needs_web_m, web_context_m, vllm_post_m, detect_task_m = self._run_scenario(
            body, resolve_images_images=True, detect_task="extraction")
        self.assertEqual(resp.status_code, 200)
        detect_task_m.assert_not_called()   # img_resolved skips the classifier call too
        needs_web_m.assert_called_once()
        vllm_post_m.assert_called_once()


class FakeStreamResponse:
    """Stands in for the httpx streaming Response the real event_stream()
    reads via aiter_bytes()."""
    def __init__(self, chunks, status_code=200):
        self._chunks = chunks
        self.status_code = status_code

    async def aiter_bytes(self):
        for c in self._chunks:
            yield c

    async def aread(self):
        return b"".join(self._chunks)


class FakeStreamCtx:
    def __init__(self, resp):
        self._resp = resp

    async def __aenter__(self):
        return self._resp

    async def __aexit__(self, *exc):
        return False


class FakeStreamingHttpxClient:
    """Replaces httpx.AsyncClient for the streaming branch only — no real
    socket/network activity. One SSE-style chunk + [DONE], matching the
    shape event_stream() actually parses."""
    _CHUNK = (
        b'data: {"id":"x","model":"' + main.MODEL.encode() +
        b'","choices":[{"delta":{"content":"hi"}}]}\n\n'
        b'data: [DONE]\n\n'
    )

    def __init__(self, *a, **kw):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    def stream(self, method, url, json=None):
        return FakeStreamCtx(FakeStreamResponse([self._CHUNK]))


async def _drain(streaming_response):
    chunks = []
    async for c in streaming_response.body_iterator:
        chunks.append(c if isinstance(c, (bytes, bytearray)) else c.encode())
    return b"".join(chunks)


# ---------------------------------------------------------------------------
# Streaming branch: same pre-computed _should_skip_web_check() decision
# applies before the stream/non-stream fork, but the branch itself (SSE
# parsing, model-name relabeling, response shape) was previously untested
# end-to-end. httpx is faked here — no real socket is opened.
# ---------------------------------------------------------------------------
class ChatCompletionsStreamingTests(unittest.TestCase):
    def _run_stream_scenario(self, body, *, detect_task="chat"):
        patches = [
            patch("main._log_async"),
            patch("main._record_tokens"),
            patch("main._resolve_images", new_callable=AsyncMock, return_value=(body.get("messages", []), False)),
            patch("main._detect_task", new_callable=AsyncMock, return_value=detect_task),
            patch("main._needs_web", new_callable=AsyncMock, return_value=False),
            patch("main._web_context", new_callable=AsyncMock, return_value=None),
            patch("main.httpx.AsyncClient", new=FakeStreamingHttpxClient),
        ]
        mocks = [p.start() for p in patches]
        (_log_async_m, _record_tokens_m, resolve_images_m, detect_task_m,
         needs_web_m, web_context_m, _httpx_client_m) = mocks
        try:
            req = FakeRequest(body)
            resp = run_async(main.chat_completions(req))
            # chat_completions() returns synchronously even for stream=True —
            # the generator body only runs once we drain it.
            from starlette.responses import StreamingResponse
            self.assertIsInstance(resp, StreamingResponse)
            self.assertEqual(resp.media_type, "text/event-stream")
            body_bytes = run_async(_drain(resp))
            return resp, body_bytes, needs_web_m, web_context_m, detect_task_m
        finally:
            for p in patches:
                p.stop()

    def test_streaming_auto_extraction_skips_needs_web_and_preserves_format(self):
        body = {"messages": [{"role": "user", "content": "extract totals from this"}],
                "stream": True}
        resp, body_bytes, needs_web_m, web_context_m, _ = self._run_stream_scenario(
            body, detect_task="extraction")
        needs_web_m.assert_not_called()
        web_context_m.assert_not_called()
        # response format preserved: SSE framing intact, internal model name
        # relabeled to the public name exactly as the unmodified code does
        self.assertIn(b"data: ", body_bytes)
        self.assertIn(b"data: [DONE]", body_bytes)
        self.assertNotIn(main.MODEL.encode(), body_bytes)
        self.assertIn(main.PUBLIC_MODEL.encode(), body_bytes)

    def test_streaming_auto_coding_skips_needs_web(self):
        body = {"messages": [{"role": "user", "content": "refactor this function"}],
                "stream": True}
        resp, body_bytes, needs_web_m, web_context_m, _ = self._run_stream_scenario(
            body, detect_task="coding")
        needs_web_m.assert_not_called()
        web_context_m.assert_not_called()
        self.assertIn(b"data: [DONE]", body_bytes)

    def test_streaming_auto_chat_still_checks_needs_web(self):
        body = {"messages": [{"role": "user", "content": "how are you?"}],
                "stream": True}
        resp, body_bytes, needs_web_m, web_context_m, _ = self._run_stream_scenario(
            body, detect_task="chat")
        needs_web_m.assert_called_once()
        self.assertIn(b"data: [DONE]", body_bytes)

    def test_streaming_explicit_web_search_true_forces_check(self):
        body = {"messages": [{"role": "user", "content": "extract totals"}],
                "task": "extraction", "web_search": True, "stream": True}
        resp, body_bytes, needs_web_m, web_context_m, detect_task_m = self._run_stream_scenario(
            body, detect_task="extraction")
        detect_task_m.assert_not_called()  # explicit task — classifier never runs
        # ws is True → _needs_web short-circuited, but _web_context must
        # still run (force semantics preserved even for a skip-eligible task)
        needs_web_m.assert_not_called()
        web_context_m.assert_called_once()
        self.assertIn(b"data: [DONE]", body_bytes)

    def test_streaming_explicit_web_search_false_skips_check(self):
        body = {"messages": [{"role": "user", "content": "how's the weather"}],
                "web_search": False, "stream": True}
        resp, body_bytes, needs_web_m, web_context_m, _ = self._run_stream_scenario(
            body, detect_task="chat")
        needs_web_m.assert_not_called()
        web_context_m.assert_not_called()
        self.assertIn(b"data: [DONE]", body_bytes)


_REQ_ID_RE = re.compile(r"req_id=([0-9a-f]{12})\b")


# ---------------------------------------------------------------------------
# WEB_DECISION structured log: correlation id + safe diagnostic fields only.
# ---------------------------------------------------------------------------
class WebDecisionLoggingTests(unittest.TestCase):
    def _run_and_capture(self, body, *, detect_task="chat", resolve_images_images=False):
        patches = [
            patch("main._log_async"),
            patch("main._record_tokens"),
            patch("main._resolve_images", new_callable=AsyncMock,
                  return_value=(body.get("messages", []), resolve_images_images)),
            patch("main._detect_task", new_callable=AsyncMock, return_value=detect_task),
            patch("main._needs_web", new_callable=AsyncMock, return_value=False),
            patch("main._web_context", new_callable=AsyncMock, return_value=None),
            patch("main._vllm_post", new_callable=AsyncMock, return_value=FakeVllmResponse()),
        ]
        mocks = [p.start() for p in patches]
        try:
            req = FakeRequest(body)
            with self.assertLogs(main.log, level="INFO") as cm:
                resp = run_async(main.chat_completions(req))
            return resp, cm.output
        finally:
            for p in patches:
                p.stop()

    def _web_decision_line(self, output):
        lines = [l for l in output if "WEB_DECISION" in l]
        self.assertEqual(len(lines), 1, f"expected exactly one WEB_DECISION line, got: {output}")
        return lines[0]

    def test_skipped_logged_for_auto_classified_extraction(self):
        body = {"messages": [{"role": "user", "content": "extract the totals"}], "stream": False}
        _, output = self._run_and_capture(body, detect_task="extraction")
        line = self._web_decision_line(output)
        self.assertIn("task=extraction", line)
        self.assertIn("web_search=auto", line)
        self.assertIn("web_check=skipped", line)

    def test_executed_logged_for_normal_chat(self):
        body = {"messages": [{"role": "user", "content": "how are you?"}], "stream": False}
        _, output = self._run_and_capture(body, detect_task="chat")
        line = self._web_decision_line(output)
        self.assertIn("task=chat", line)
        self.assertIn("web_search=auto", line)
        self.assertIn("web_check=executed", line)

    def test_forced_logged_for_explicit_web_search_true(self):
        body = {"messages": [{"role": "user", "content": "extract totals"}],
                "task": "extraction", "web_search": True, "stream": False}
        _, output = self._run_and_capture(body, detect_task="extraction")
        line = self._web_decision_line(output)
        self.assertIn("web_search=forced", line)
        self.assertIn("web_check=n/a", line)

    def test_disabled_logged_for_explicit_web_search_false(self):
        body = {"messages": [{"role": "user", "content": "how's the weather"}],
                "web_search": False, "stream": False}
        _, output = self._run_and_capture(body, detect_task="chat")
        line = self._web_decision_line(output)
        self.assertIn("web_search=disabled", line)
        self.assertIn("web_check=n/a", line)

    def test_explicit_task_value_logs_executed_not_skipped(self):
        # explicit task="extraction" — not auto-classified, so the skip must
        # not apply, and the log must reflect that (web_check=executed).
        body = {"messages": [{"role": "user", "content": "pull fields from this"}],
                "task": "extraction", "stream": False}
        _, output = self._run_and_capture(body, detect_task="extraction")
        line = self._web_decision_line(output)
        self.assertIn("task=extraction", line)
        self.assertIn("web_check=executed", line)

    def test_image_resolved_logs_executed_not_skipped(self):
        body = {"messages": [{"role": "user", "content": [
            {"type": "text", "text": "what's on this invoice?"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,Zm9v"}},
        ]}], "stream": False}
        _, output = self._run_and_capture(body, resolve_images_images=True, detect_task="extraction")
        line = self._web_decision_line(output)
        self.assertIn("task=extraction", line)
        self.assertIn("web_check=executed", line)

    def test_req_id_present_well_formed_and_unique_per_request(self):
        body1 = {"messages": [{"role": "user", "content": "extract totals"}], "stream": False}
        body2 = {"messages": [{"role": "user", "content": "extract other totals"}], "stream": False}
        _, output1 = self._run_and_capture(body1, detect_task="extraction")
        _, output2 = self._run_and_capture(body2, detect_task="extraction")
        m1 = _REQ_ID_RE.search(self._web_decision_line(output1))
        m2 = _REQ_ID_RE.search(self._web_decision_line(output2))
        self.assertIsNotNone(m1)
        self.assertIsNotNone(m2)
        self.assertNotEqual(m1.group(1), m2.group(1))

    def test_no_prompt_content_or_secrets_in_log_output(self):
        secret_phrase = "SSN-123-45-6789-do-not-log-this"
        body = {"messages": [{"role": "user", "content": f"please extract {secret_phrase}"}],
                "stream": False}
        _, output = self._run_and_capture(body, detect_task="extraction")
        joined = "\n".join(output)
        self.assertNotIn(secret_phrase, joined)
        self.assertNotIn("Authorization", joined)
        self.assertNotIn("Bearer ", joined)

    def test_streaming_path_also_logs_web_decision(self):
        # the decision happens before the stream/non-stream fork — confirm
        # the log fires identically for stream=True.
        patches = [
            patch("main._log_async"),
            patch("main._record_tokens"),
            patch("main._resolve_images", new_callable=AsyncMock, return_value=([], False)),
            patch("main._detect_task", new_callable=AsyncMock, return_value="coding"),
            patch("main._needs_web", new_callable=AsyncMock, return_value=False),
            patch("main._web_context", new_callable=AsyncMock, return_value=None),
            patch("main.httpx.AsyncClient", new=FakeStreamingHttpxClient),
        ]
        mocks = [p.start() for p in patches]
        try:
            body = {"messages": [{"role": "user", "content": "refactor this"}], "stream": True}
            req = FakeRequest(body)
            with self.assertLogs(main.log, level="INFO") as cm:
                resp = run_async(main.chat_completions(req))
                run_async(_drain(resp))
            line = self._web_decision_line(cm.output)
            self.assertIn("task=coding", line)
            self.assertIn("web_check=skipped", line)
        finally:
            for p in patches:
                p.stop()


if __name__ == "__main__":
    unittest.main()
