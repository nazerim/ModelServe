#!/usr/bin/env python3
"""Real-photo vision check against a running server: identification + a detail
question, with cold/warm latency. Uses testimg/*.jpg (see get-testimg.sh).

Env: PORT (8000), IMGDIR, TOKENS (max_tokens; this model thinks first, so small
budgets come back with empty content).
"""
import base64, glob, json, os, time, urllib.request

B = "http://127.0.0.1:" + os.environ.get("PORT", "8000")
HERE = os.path.dirname(os.path.abspath(__file__))
IMGDIR = os.environ.get("IMGDIR", os.path.join(HERE, "testimg"))
TOKENS = int(os.environ.get("TOKENS", "600"))  # 400 was too small: this model thinks first

# score against species synonyms: the model answers with a BREED ("Husky", "Siamese"),
# which is a correct answer but would not match a naive substring check on "dog"/"cat".
EXPECT = {
    "cat": {"cat", "kitten", "feline", "siamese", "tabby", "persian", "maine"},
    "dog": {"dog", "puppy", "canine", "husky", "shepherd", "malinois", "german",
            "labrador", "retriever", "bulldog", "poodle", "malamute", "samoyed"},
}

def ask(path, text, t=600):
    raw = open(path, "rb").read()
    mime = "image/png" if raw[:4] == b"\x89PNG" else "image/jpeg"
    b64 = base64.b64encode(raw).decode()
    p = {"model": "qwen3.8-27b", "max_tokens": TOKENS, "temperature": 0, "messages": [
        {"role": "user", "content": [
            {"type": "text", "text": text},
            {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (mime, b64)}}]}]}
    r = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(p).encode(),
                               headers={"Content-Type": "application/json"})
    st = time.time()
    d = json.load(urllib.request.urlopen(r, timeout=t))
    m = d["choices"][0]["message"]
    return d, time.time() - st, (m.get("content") or ""), (m.get("reasoning_content") or "")

print("== real-photo vision (mmproj on CPU unless MM=gpu was used at boot) ==")
ok = 0; n = 0
for path in sorted(glob.glob(os.path.join(IMGDIR, "*.jpg")) + glob.glob(os.path.join(IMGDIR, "*.png"))):
    key = os.path.splitext(os.path.basename(path))[0].lower()
    want = EXPECT.get(key)
    size = os.path.getsize(path)
    try:
        d, cold, content, reason = ask(path, "What animal is in this photo? Answer in ONE word.")
    except Exception as e:
        print("  %-8s FAILED: %s" % (key, str(e)[:80])); n += 1; continue
    got = (content or "").strip()
    if not got:
        got = "(empty content; reasoning said: %s...)" % (reason or "")[:40]
    got_l = (content or "").lower()
    hit = bool(want) and any(w in got_l for w in want)
    ok += hit; n += 1
    pt = d["usage"]["prompt_tokens"]
    print("  %-8s %6.0f KiB  img_prompt=%d tok  %.1fs cold  -> %r %s"
          % (key, size / 1024, pt, cold, got[:34], "OK" if hit else "WRONG"))
    # a detail question on the same image (prefix-cached, so mostly decode+gen)
    try:
        d2, warm, c2, r2 = ask(path, "Describe the colour/markings of the animal in one short sentence.")
        print("  %-8s detail %.1fs -> %r" % ("", warm, (c2 or ("(reasoning: " + r2[:40] + ")"))[:90]))
    except Exception as e:
        print("  %-8s detail FAILED: %s" % ("", str(e)[:60]))
print("%d/%d identified correctly" % (ok, n))
