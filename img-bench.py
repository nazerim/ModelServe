#!/usr/bin/env python3
"""Time image requests against a running llama-server (mmproj GPU vs CPU).
Each solid-gradient PNG forces the vision tower to do real work; prompt_tokens
in the usage block tells us how many image tokens each request cost."""
import base64, json, os, struct, sys, time, urllib.request, zlib

B = "http://127.0.0.1:" + os.environ.get("PORT", "8000")
LABEL = sys.argv[1] if len(sys.argv) > 1 else "run"

def png(W, H, seed):
    def ch(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    rows = bytearray()
    for y in range(H):
        rows += b"\x00"
        for x in range(W):
            rows += bytes(((x * 7 + seed) % 256, (y * 5 + seed) % 256, (x * y + seed) % 256))
    return (b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
            + ch(b"IDAT", zlib.compress(bytes(rows), 6)) + ch(b"IEND", b""))

def ask(b64):
    p = {"model": "qwen3.8-27b", "max_tokens": 48, "temperature": 0, "seed": 42, "messages": [
        {"role": "user", "content": [
            {"type": "text", "text": "Describe this image in five words."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}]}
    r = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(p).encode(),
                              headers={"Content-Type": "application/json"})
    t = time.time()
    d = json.load(urllib.request.urlopen(r, timeout=600))
    return time.time() - t, d["usage"]["prompt_tokens"], (d["choices"][0]["message"].get("content") or "")[:40]

print("== image bench (%s) ==" % LABEL)
print("  %-10s %8s %9s %8s  answer" % ("size", "img_tok", "warm_s", "cold_s"))
for (w, h), seed in (((256, 256), 1), ((512, 512), 2), ((1024, 1024), 3)):
    b = png(w, h, seed)
    b64 = base64.b64encode(b).decode()
    try:
        c, tok, ans = ask(b64)          # cold (prefill of image tokens)
        warm, tok2, _ = ask(b64)        # same image again -> prefix cache
        print("  %10s %8d %9.2f %8.2f  %r" % ("%dx%d" % (w, h), tok, warm, c, ans))
    except Exception as e:
        print("  %10s FAILED: %s" % ("%dx%d" % (w, h), str(e)[:70]))
