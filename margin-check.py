#!/usr/bin/env python3
"""Margin under load, not at idle.

The 212,992 default was chosen on a post-boot reading (~508 MiB free) and then the
host driver lost both cards with no OOM in our log - so an idle reading is not a safety
argument. This samples nvidia-smi continuously while a large prompt is prefilled and the
answer generated, and reports the LOWEST free memory actually seen on each GPU.

Env: PORT (8000), WORDS (filler word count), ROUNDS

KNOWN LIMITATION: the per-round "s wall" figure includes the 400 generated tokens, so it is
NOT prompt-processing throughput and must not be compared against another run's pp number.
Authoritative pp comes from the server log:
    grep "prompt eval time" server.log
which at 3080=150W / 5070Ti=250W, q3 @196,608, split 17.4,7.7 reported 1,258 tok/s on a
20,058-token prompt, and 49.0-49.9 tok/s for generation (20.0-20.4 ms/token).
"""
import json, os, subprocess, threading, time, urllib.request

PORT = os.environ.get("PORT", "8000")
B = f"http://127.0.0.1:{PORT}"
WORDS = int(os.environ.get("WORDS", "30000"))
KEY = os.environ.get("OMLX_API_KEY", "")
NAMES = subprocess.run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                       capture_output=True, text=True).stdout.split("\n")
seen_prompts = []
stop = threading.Event()
lows = [None, None]


def sampler():
    while not stop.is_set():
        try:
            out = subprocess.run(["nvidia-smi", "--query-gpu=memory.free",
                                  "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True, timeout=10).stdout.split()
            for i, v in enumerate(out[:2]):
                v = int(v)
                if lows[i] is None or v < lows[i]:
                    lows[i] = v
        except Exception:
            pass
        time.sleep(0.4)


def idle_free():
    out = subprocess.run(["nvidia-smi", "--query-gpu=memory.free",
                          "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout.split()
    return [int(x) for x in out[:2]]


def chat(content, max_tokens=400):
    p = {"model": "qwen3.8-27b", "max_tokens": max_tokens, "temperature": 0,
         "messages": [{"role": "user", "content": content}]}
    h = {"Content-Type": "application/json"}
    if KEY:
        h["Authorization"] = "Bearer " + KEY
    r = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(p).encode(), headers=h)
    t = time.time()
    d = json.load(urllib.request.urlopen(r, timeout=900))
    return d["usage"], time.time() - t


print("== margin under load (min free sampled while working) ==")
print("  idle free:", idle_free(), "MiB  [0]=3080 [1]=5070Ti")

th = threading.Thread(target=sampler, daemon=True)
th.start()
try:
    for r in range(int(os.environ.get("ROUNDS", "2"))):
        import random
        w = ("context memory bandwidth attention kv cache quant layer token gpu tensor stream "
             "kernel weight gradient batch inference latency transformer head router shard "
             f"nonce{r}").split()
        rng = random.Random(1000 + r)
        filler = " ".join(rng.choice(w) for _ in range(WORDS))
        u, dt = chat(filler + "\n\nIn three sentences, summarise the trade-offs.")
        seen_prompts.append(u["prompt_tokens"])
        print(f"  round {r}: pp={u['prompt_tokens']:,} tok, {dt:.1f}s wall, min-free={lows}")
    # a burst of concurrent-ish long generations, which is closer to agent behaviour
    for r in range(3):
        u, dt = chat("Write 400 words on paged KV caches and prefix reuse, in detail.")
        print(f"  gen {r}: {u['completion_tokens']} tok in {dt:.1f}s")
finally:
    stop.set()
    th.join(timeout=3)

after = idle_free()
print("  min free DURING load:", lows, "MiB")
print("  free AFTER teardown  :", after, "MiB")
worst = min(x for x in lows if x is not None)
print(f"\nWORST-CASE FREE = {worst} MiB  ->  "
      + ("SAFE (>=400)" if worst >= 400 else "MARGINAL (<400, consider dropping ctx)" if worst >= 240
         else "UNSAFE (<240, this box has aborted here)"))
