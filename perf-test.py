#!/usr/bin/env python3
"""Performance test: prompt processing + generation throughput, with medians.

Deliberately distinct prompts (no repeated text) so the KV prefix cache cannot flatter
the numbers, a sampler thread so VRAM margin is reported alongside speed, and medians
because single-shot llama.cpp timings swing with power and clock states.

Env: PORT, ROUNDS_PP, ROUNDS_TG, PP_TOKENS (approx words), GEN_TOKENS
"""
import json, os, random, statistics, subprocess, threading, time, urllib.request

PORT = os.environ.get("PORT", "8000")
B = f"http://127.0.0.1:{PORT}/v1/chat/completions"
KEY = os.environ.get("OMLX_API_KEY", "")
MODEL = os.environ.get("MODEL", "qwen3.8-27b")
R_PP = int(os.environ.get("ROUNDS_PP", "3"))
R_TG = int(os.environ.get("ROUNDS_TG", "6"))
WORDS = int(os.environ.get("PP_TOKENS", "20000"))
GTOK = int(os.environ.get("GEN_TOKENS", "300"))

VOCAB = ("context memory bandwidth attention cache quant layer token gpu tensor stream kernel "
         "weight gradient batch inference latency transformer head router shard decode prefetch "
         "pipeline register shader alloc buffer logits rotary norm expert dense sparse").split()


def filler(seed):
    rng = random.Random(seed)
    return " ".join(rng.choice(VOCAB) for _ in range(WORDS))


def post(msgs, max_tokens, temperature=0):
    p = {"model": MODEL, "max_tokens": max_tokens, "temperature": temperature, "messages": msgs}
    h = {"Content-Type": "application/json"}
    if KEY:
        h["Authorization"] = "Bearer " + KEY
    r = urllib.request.Request(B, data=json.dumps(p).encode(), headers=h)
    t = time.time()
    d = json.load(urllib.request.urlopen(r, timeout=900))
    return d, time.time() - t


stop = threading.Event()
lows = [None, None]


def sampler():
    while not stop.is_set():
        try:
            out = subprocess.run(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True, timeout=10).stdout.split()
            for i, v in enumerate(out[:2]):
                v = int(v)
                if lows[i] is None or v < lows[i]:
                    lows[i] = v
        except Exception:
            pass
        time.sleep(0.4)


def stats(v):
    return f"median {statistics.median(v):.0f}  min {min(v):.0f}  max {max(v):.0f}"


th = threading.Thread(target=sampler, daemon=True)
th.start()
try:
    pp = []
    for i in range(R_PP):
        d, dt = post([{"role": "user", "content": filler(100 + i) + "\n\nAnswer with exactly: ok"}], 8)
        n = d["usage"]["prompt_tokens"]
        rate = n / max(dt - 0.4, 0.1)          # subtract the ~0.4s of generating 8 tokens
        pp.append(rate)
        print(f"  pp round {i}: {n:,} tok in {dt:.1f}s = {rate:.0f} tok/s")

    tg = []
    for i in range(R_TG):
        q = ("Explain in detail how paged KV caches work, point " + str(i) + ", at least 200 words.")
        d, dt = post([{"role": "user", "content": q}], GTOK)
        n = d["usage"]["completion_tokens"]
        rate = n / dt
        tg.append(rate)
        print(f"  tg round {i}: {n} tok in {dt:.1f}s = {rate:.1f} tok/s")
finally:
    stop.set()
    th.join(timeout=3)

print(f"\nPROMPT PROCESSING : {stats(pp)} tok/s   ({R_PP} distinct ~{WORDS}-word prompts)")
print(f"GENERATION        : {stats(tg)} tok/s   ({R_TG} runs of {GTOK} tok)")
print(f"WORST FREE        : {[lows[1], lows[0]]} MiB  [5070Ti, 3080]")
try:
    log = open("server.log", errors="replace").read()
    accs = [float(x) for x in __import__("re").findall(r"draft acceptance = ([0-9.]+)", log)]
    if accs:
        print(f"MTP ACCEPTANCE    : median {statistics.median(accs):.2f} over {len(accs)} samples")
except Exception:
    pass
