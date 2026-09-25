#!/bin/bash
# Single-attempt vLLM launch. `exec`s into the server so the caller's `$!`/
# `wait` tracks the real vLLM process PID directly, with no wrapper shell in
# between. Used by both start_all.sh (one-shot, pod boot) and
# vllm_watchdog.sh (auto-restart loop). Keep /workspace and ~/LLM_codes
# copies identical.
set -u

# "12.0f" (family-conditional PTX) needs CUDA >=12.9 to even compile and
# isn't what this GPU's toolchain resolves anyway — plain "12.0" (this
# card's real compute capability, RTX PRO 6000 Blackwell = sm_120) is what
# actually builds. Needs CUDA toolkit 12.9+ on PATH (13.0 installed at
# /usr/local/cuda) — CUDA 12.6/12.8 both failed this model's FlashInfer/
# Triton kernel builds outright (nvcc/"SM 12.x requires CUDA >= 12.9").
export FLASHINFER_CUDA_ARCH_LIST="12.0"
export VLLM_USE_DEEP_GEMM=0
# MoE shared experts are enqueued on an auxiliary CUDA stream and rejoined via
# cuda events (shared_experts.py maybe_forward_async/wait). That path faulted
# on 2026-09-21 09:02:29 with "CUDA error: an illegal memory access was
# encountered" inside wait() -> EngineDeadError, which aborts EngineCore
# outright (std::terminate) and cannot be recovered without a full restart.
# It only engages for batches <= VLLM_SHARED_EXPERTS_STREAM_TOKEN_THRESHOLD
# (256), i.e. ordinary decode traffic, which is why it hit in production.
# Forcing the single-stream NO_OVERLAP path removes the race; it costs a
# little decode overlap and nothing else. (A second, different kernel —
# the GDN attention path — hit the same "illegal memory access" symptom on
# 2026-09-22 and is NOT covered by this flag; see vllm_watchdog.sh, which
# exists because this class of crash cannot be fully eliminated, only
# recovered from quickly.)
export VLLM_DISABLE_SHARED_EXPERTS_STREAM=1
export PATH=/usr/local/cuda/bin:$PATH

exec /workspace/venv/bin/python -m vllm.entrypoints.openai.api_server \
  --model /workspace/models/Qwen3.6-35B-A3B-FP8 \
  --served-model-name qwen3.6-35b \
  --host 127.0.0.1 --port 7777 \
  --dtype auto \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.85 \
  --max-num-seqs 32 \
  --max-num-batched-tokens 32768 \
  --trust-remote-code \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3 \
  --kv-cache-dtype fp8_e4m3
