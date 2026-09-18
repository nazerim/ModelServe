#!/usr/bin/env python3
"""Load-stress a running server: alternating image + long-text turns.

Catches the failure mode we hit before, where the process survived plain text but
died on the first image once a GPU ran out of room. Prints per-cycle tok/s and a
FAILS tally; non-zero exit if anything failed.
Env: PORT (default 8000), CYCLES (default 4)
"""
import base64, json, os, struct, sys, time, urllib.request, zlib

B = "http://127.0.0.1:" + os.environ.get("PORT", "8000")
CYCLES = int(os.environ.get("CYCLES", "4"))

def chunk(t, d):
    return struct.pack(">I", len(t)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

def png(W, H, s):
    rows = bytearray()
    for y in range(H):
        rows += b"\x00"
        for x in range(W):
            rows += bytes(((x * 7 + s) % 256, (y * 5 + s) % 256, (x * y + s) % 256))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))

def post(p, t=600):
    r = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(p).encode(),
                               headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=t))

def probe(label):
    """Cheap liveness check that does NOT depend on generation."""
    try:
        return json.load(urllib.request.urlopen(B + "/health", timeout=5)).get("status")
    except Exception as e:
        print("  health probe (%s) failed: %s" % (label, str(e)[:60]))
        return None

fails = 0; tps = []; peak_free = []
for cyc in range(CYCLES):
    try:
        for s in (1, 2):
            b64 = base64.b64encode(png(512, 512, s + cyc * 3)).decode()
            post({"model": "qwen3.8-27b", "max_tokens": 40, "temperature": 0, "messages": [
                {"role": "user", "content": [
                    {"type": "text", "text": "Describe in five words."},
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}]})
        t = time.time()
        d = post({"model": "qwen3.8-27b", "max_tokens": 300, "temperature": 0, "messages": [
            {"role": "user", "content": "Write 250 words on streaming versus batch inference."}]})
        n = d["usage"]["completion_tokens"]; sp = n / (time.time() - t)
        tps.append(sp)
        free = os.popen("nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits").read().split()
        peak_free.append(min(int(x) for x in free))
        print("cycle %d ok  %.1f tok/s  min-free=%s MiB" % (cyc, sp, min(int(x) for x in free)))
    except Exception as e:
        fails += 1
        print("cycle %d FAILED: %s" % (cyc, str(e)[:70]))
        print("  health after failure: %s" % (probe("post-fail") or "DEAD"))
        break

print("FAILS=%d  mean %.1f tok/s over %d cycle(s)  lowest free seen=%s MiB"
      % (fails, (sum(tps) / len(tps)) if tps else 0, len(tps), min(peak_free) if peak_free else "?"))
sys.exit(1 if fails else 0)
