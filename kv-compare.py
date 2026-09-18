#!/usr/bin/env python3
"""Compare two kv-probe.py dumps: retrieval accuracy, greedy drift, logit divergence.
Usage: kv-compare.py ref.json test.json"""
import json, math, statistics, sys

def load(p): return json.load(open(p))

def top_dist(entries):
    """{token_string: prob} from a truncated top-k logprob list, renormalised."""
    d = {e["tok"]: math.exp(e["logprob"]) for e in entries}
    s = sum(d.values())
    return {k: v / s for k, v in d.items()} if s > 0 else d

def kl(p, q, eps=1e-9):
    ks = set(p) | set(q)
    return sum((p.get(k, 0.0)) * math.log((p.get(k, 0.0) + eps) / (q.get(k, 0.0) + eps)) for k in ks)

def jsd(p, q, eps=1e-9):
    ks = set(p) | set(q)
    m = {k: (p.get(k, 0.0) + q.get(k, 0.0)) / 2 for k in ks}
    return 0.5 * kl(p, m, eps) + 0.5 * kl(q, m, eps)

def score_retrieval(res):
    # search content AND reasoning - the model often states facts while thinking
    txt = (res["retrieval"].get("text", "") + " " + res["retrieval"].get("reasoning", "")).lower()
    return [v.lower() in txt for _, v in res["needles"]]

def compare_block(ref, test, name):
    if name not in ref or name not in test: return
    a = ref[name].get("logprobs") or []
    b = test[name].get("logprobs") or []
    n = min(len(a), len(b))
    if n == 0:
        print("  %s: no logprobs returned" % name); return
    K1, K2, J = [], [], []; same = 0; first_div = None
    for i in range(n):
        da, db = top_dist(a[i]), top_dist(b[i])
        K1.append(kl(da, db)); K2.append(kl(db, da)); J.append(jsd(da, db))
        ta = a[i][0]["tok"] if a[i] else None
        tb = b[i][0]["tok"] if b[i] else None
        if ta == tb: same += 1
        elif first_div is None: first_div = i
    print("  %-12s positions=%d  greedy-argmax-identical=%.1f%%  first divergence=%s"
          % (name, n, 100.0 * same / n, first_div if first_div is not None else "none"))
    med = lambda v: statistics.median(v)
    big = sum(1 for x in J if x > 0.01)
    print("  %-12s median KL(ref||test)=%.5f  KL(test||ref)=%.5f  median JSD=%.5f"
          % ("", med(K1), med(K2), med(J)))
    print("  %-12s mean  JSD=%.5f  positions with JSD>0.01: %d/%d (outlier-driven means are misleading)"
          % ("", sum(J) / n, big, n))

ref, test = load(sys.argv[1]), load(sys.argv[2])
print("=== KV quality comparison: %s (ref) vs %s ===" % (ref["label"], test["label"]))
for r in (ref, test):
    s = score_retrieval(r)
    print("  %-6s long-context retrieval %d/%d correct  |  %d tok in %.1fs  |  prompt=%s tok"
          % (r["label"], sum(s), len(s), r["gen"]["usage"]["completion_tokens"], r["gen"]["secs"],
             r["retrieval"]["usage"]["prompt_tokens"]))
    print("         answers: %r" % r["retrieval"]["text"][:150].replace("\n", " | "))
print()
for blk in ("gen", "retrieval"):
    compare_block(ref, test, blk)
