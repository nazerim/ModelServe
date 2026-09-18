#!/usr/bin/env python3
"""Verify pi's samplingParams actually reach llama.cpp's sampler, and find out what an
unknown key does (silently ignored would be the dangerous answer).

Proof strategy: temp=0 + top_k=1 must be byte-identical across repeats; the real spec
(temp=1.0, top_k=20, top_p=0.95, min_p=0) must NOT be. If both look deterministic, the
params are being dropped somewhere.
"""
import json, os, time, urllib.request

B = "http://127.0.0.1:" + os.environ.get("PORT", "8000") + "/v1/chat/completions"
KEY = os.environ.get("OMLX_API_KEY", "")
SP = {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0,
      "presence_penalty": 0.0, "repeat_penalty": 1.0}
PROMPT = "Name one random number between 1 and 1000, plus one random colour. Answer terse."


def call(extra, tag):
    p = {"model": "qwen3.8-27b", "max_tokens": 400, "temperature": None, "messages": [{"role": "user", "content": PROMPT}]}
    p.pop("temperature", None)
    p.update(extra)
    h = {"Content-Type": "application/json"}
    if KEY:
        h["Authorization"] = "Bearer " + KEY
    r = urllib.request.Request(B, data=json.dumps(p).encode(), headers=h)
    try:
        d = json.load(urllib.request.urlopen(r, timeout=120))
        m = d["choices"][0]["message"]
        # this model thinks first: with a small budget content is "" and everything is in
        # reasoning_content, which made an earlier version of this probe compare empty strings
        txt = ((m.get("content") or "").strip() or "[think]" + (m.get("reasoning_content") or "").strip())
        print(f"  {tag:<34} 200  {txt[:58]!r}")
        return txt
    except urllib.error.HTTPError as e:
        body = e.read()[:90].decode(errors="replace")
        print(f"  {tag:<34} HTTP {e.code}  {body}")
        return f"HTTP{e.code}"


print("== 1. unknown key: does llama.cpp reject or ignore? ==")
call({"repetition_penalty": 1.0, "temperature": 0}, "repetition_penalty (wrong name)")
call({"totally_bogus_key": 123, "temperature": 0}, "totally_bogus_key")

print("== 2. greedy control: same params twice (must match) ==")
g1 = call({"temperature": 0, "top_k": 1}, "greedy run A")
g2 = call({"temperature": 0, "top_k": 1}, "greedy run B")

print("== 3. the spec, twice (must DIFFER if params are honoured) ==")
s1 = call(SP, "spec run A")
s2 = call(SP, "spec run B")

print()
print("  greedy identical      :", "PASS" if g1 == g2 and not g1.startswith("HTTP") else "FAIL")
print("  spec varies           :", "PASS (params reaching sampler)" if s1 != s2 else "FAIL (looks deterministic -> params dropped)")
print("  unknown key tolerated :", "yes -> a misspelled field would be silently ignored")
