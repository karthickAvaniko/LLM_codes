#!/usr/bin/env python3
"""
Avaniko AI — Invoice / document -> JSON extractor.

Calls POST /v1/extract, the same accurate document pipeline the chatbot UI
uses (native PDF text + OCR fallback, page-aware, deterministic). Do NOT
switch this to /v1/chat/completions with an inline base64 image — that path
gives inconsistent output call-to-call.

Usage: python3 invoice_to_json.py
  (it will ask for the file path and where to save the JSON)
"""

import json
import os
import sys
from pathlib import Path

import requests

# ── Configuration ──────────────────────────────────────────
# Set AVANIKO_API_KEY in your environment rather than hardcoding it here —
# this file is committed to git, and a hardcoded key here would leak it.
API_KEY  = os.environ.get("AVANIKO_API_KEY", "")
BASE_URL = os.environ.get("AVANIKO_BASE_URL", "https://s2f1q59mb9tg9r-7778.proxy.runpod.net")

if not API_KEY:
    sys.exit("Set AVANIKO_API_KEY in your environment before running this script.")

# ── Extraction prompt ──────────────────────────────────────
# No fixed field list here on purpose — this stays dynamic: let the model
# structure the output to fit whatever the document actually contains,
# rather than forcing every invoice into one predetermined shape. If YOU
# want a guaranteed structure for a specific document/vendor, paste a JSON
# Schema when the script asks for one below — that's a per-run, per-document
# choice, not a shape baked into this script.
PROMPT = """You are a document data extraction engine. Extract every single piece of visible data from this invoice/document — no omissions, no hallucinations, no assumptions.

RULES:
1. Only extract what is explicitly visible. Never guess or invent a value.
2. Return a single valid JSON object (not a bare array). No markdown, no explanation, no text outside the JSON.
3. Every number must be numeric (not a string). Strip currency symbols.
4. If a field is not present in the document, omit it or use null — never invent a placeholder.
5. Structure the JSON to fit what THIS document actually contains — group vendor/seller info together, line items as an array, totals together, etc. Use field names that describe what they hold.
"""


def extract(file_path: str, output_schema: str, consistency: int, canonicalize: bool) -> dict:
    data = {"question": PROMPT}
    if output_schema.strip():
        data["output_schema"] = output_schema.strip()
    if consistency > 1:
        data["consistency"] = str(consistency)
    if canonicalize:
        data["canonicalize"] = "true"
    with open(file_path, "rb") as f:
        resp = requests.post(
            f"{BASE_URL}/v1/extract",
            headers={"Authorization": f"Bearer {API_KEY}"},
            files={"files": (Path(file_path).name, f)},
            data=data,
            timeout=180,
        )
    resp.raise_for_status()
    return resp.json()


def ask_yn(prompt: str, default: bool = False) -> bool:
    d = "y" if default else "n"
    ans = input(f"{prompt} (y/n) [{d}]: ").strip().lower()
    return {"y": True, "n": False}.get(ans, default)


def main():
    file_path = input("Invoice/document file path (pdf/png/jpg): ").strip().strip('"')
    if not file_path or not Path(file_path).exists():
        print(f"File not found: {file_path!r}")
        sys.exit(1)

    default_save = str(Path(file_path).with_name(Path(file_path).stem + "_output.json"))
    save_path = input(f"Save output JSON to [{default_save}]: ").strip().strip('"')
    if not save_path:
        save_path = default_save

    output_schema = input(
        "Paste a JSON Schema to enforce for THIS document (optional — blank = fully "
        "dynamic, model decides the shape):\n> ").strip()
    if output_schema:
        try:
            json.loads(output_schema)
        except json.JSONDecodeError as e:
            print(f"That's not valid JSON ({e}) — continuing without a schema.")
            output_schema = ""
    consistency  = input("Self-consistency samples, 1-5 (more = slower, more reliable) [1]: ").strip()
    consistency  = int(consistency) if consistency.isdigit() else 1
    canonicalize = ask_yn("Canonicalize field names? (maps vendor_info/totals/etc. to standard names)")

    print(f"\nExtracting {file_path} ... (can take 5-60s depending on options above)")
    result = extract(file_path, output_schema, consistency, canonicalize)

    file_result = result.get("results", [{}])[0]
    if file_result.get("error"):
        print(f"ERROR: {file_result['error']}")
        sys.exit(1)

    answer = file_result.get("answer", "")
    try:
        parsed = json.loads(answer)
    except json.JSONDecodeError:
        parsed = answer  # model didn't return pure JSON — save the raw text instead

    with open(save_path, "w", encoding="utf-8") as f:
        if isinstance(parsed, str):
            f.write(parsed)
        else:
            json.dump(parsed, f, indent=2, ensure_ascii=False)

    print(f"\nSaved to: {save_path}")
    print(f"strategy: {file_result.get('strategy')}")
    validation = file_result.get("validation", {})
    print(f"validation ok: {validation.get('ok')} | corrected: {validation.get('corrected')}")
    if validation.get("issues"):
        for issue in validation["issues"]:
            print(f"  [{issue.get('severity')}] {issue.get('type')}: {issue.get('detail')}")
    if file_result.get("field_renames"):
        print(f"field renames: {file_result['field_renames']}")
    print()
    print(json.dumps(parsed, indent=2, ensure_ascii=False) if not isinstance(parsed, str) else parsed)


if __name__ == "__main__":
    main()
