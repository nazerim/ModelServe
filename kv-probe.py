#!/usr/bin/env python3
"""Probe a running llama-server and dump greedy output + top-k logprob dists.

Used to compare KV cache quantisations (q8_0 vs q4_0) on:
  A) long-context retrieval (needles buried at 3 depths in ~60K tokens)
  B) greedy token drift + logit divergence vs the reference run
Usage: kv-probe.py OUT.json [LABEL]
"""
import json, os, random, sys, time, urllib.request

B = "http://127.0.0.1:" + os.environ.get("PORT", "8000")
out_path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else "run"

WORDS = ("context memory bandwidth attention kv cache quant layer token gpu tensor "
         "stream kernel weight gradient batch inference latency transformer head").split()

def post(payload, t=900):
    req = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=t))

def needle_facts():
    rnd = random.Random(1234)
    return [
        ("the secret passcode", "cobalt-%04d-lantern" % rnd.randrange(1000, 9999)),
        ("the lab cat's name",  rnd.choice(["Fermi", "Noether", "Hopper", "Shirley"])),
        ("the bridge load rating", "%d.%d tonnes" % (rnd.randrange(7, 40), rnd.randrange(0, 10))),
    ]

def build_context(n_tokens, facts):
    """Filler text with needles at 25% / 55% / 85% depth."""
    rnd = random.Random(99)
    para = []
    for _ in range(n_tokens):
        para.append(rnd.choice(WORDS))
    body = " ".join(para)
    marks = [int(n_tokens * f) for f in (0.25, 0.55, 0.85)]
    chunks = []
    prev = 0
    for (name, val), m in zip(facts, marks):
        chunks.append(body[prev:m])
        chunks.append(" IMPORTANT FACT: %s is %s." % (name, val))
        prev = m
    chunks.append(body[prev:])
    return "".join(chunks), facts

def main():
    facts = needle_facts()
    ctx, facts = build_context(int(os.environ.get("NWORDS", "60000")), facts)
    res = {"label": label, "needles": [[n, v] for n, v in facts], "approx_ctx_tokens": len(ctx.split())}

    # ---- A) retrieval over the long context ----
    prompt = ctx + ("\n\nAnswer from the facts above, one per line, nothing else:\n"
                    "1) secret passcode:  2) lab cat name:  3) bridge load rating:")
    t = time.time()
    d = post({"model": "qwen3.8-27b", "messages": [{"role": "user", "content": prompt}],
              "max_tokens": 500, "temperature": 0, "seed": 42,
              "logprobs": True, "top_logprobs": 10})
    m = d["choices"][0]["message"]
    # this model "thinks" first: the facts may only appear in reasoning_content
    res["retrieval"] = {"secs": round(time.time() - t, 1),
                        "text": (m.get("content") or "").strip(),
                        "reasoning": (m.get("reasoning_content") or "").strip(),
                        "usage": d.get("usage")}
    lp = (d["choices"][0].get("logprobs") or {}).get("content") or []
    res["retrieval"]["logprobs"] = [[{"tok": e["token"], "logprob": e["logprob"]}
                                     for e in (item.get("top_logprobs") or [])] for item in lp]

    # ---- B) pure generation trace (short, deterministic) ----
    t = time.time()
    d = post({"model": "qwen3.8-27b",
              "messages": [{"role": "user", "content": "Explain in detail why KV cache quantisation hurts long-context recall more than short-context chat. Be technical."}],
              "max_tokens": 250, "temperature": 0, "seed": 42,
              "logprobs": True, "top_logprobs": 10})
    res["gen"] = {"secs": round(time.time() - t, 1),
                  "text": (d["choices"][0]["message"].get("content") or "").strip(),
                  "usage": d.get("usage")}
    lp = (d["choices"][0].get("logprobs") or {}).get("content") or []
    res["gen"]["logprobs"] = [[{"tok": e["token"], "logprob": e["logprob"]}
                               for e in (item.get("top_logprobs") or [])] for item in lp]
    res["gen"]["greedy"] = [item["token"] for item in lp]

    json.dump(res, open(out_path, "w"))
    print("%s: wrote %s" % (label, out_path))

main()
