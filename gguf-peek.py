#!/usr/bin/env python3
"""Peek at candidate GGUFs WITHOUT downloading them: a ranged GET of the first
~13 MB covers the header + KV metadata + tensor-info block, which is enough to
answer "does this quant still ship the MTP (nextn) tensors?" and to read the KV
geometry. Usage: gguf-peek.py <repo> <file> [...]"""
import json, os, struct, subprocess, sys, urllib.request

REPO = sys.argv[1]
HEAD_BYTES = 13_000_000

def fetch(path):
    url = "https://huggingface.co/%s/resolve/main/%s" % (REPO, path)
    tmp = "/tmp/peek.bin"
    req = urllib.request.Request(url, headers={"Range": "bytes=0-%d" % (HEAD_BYTES - 1)})
    try:
        with urllib.request.urlopen(req, timeout=180) as r, open(tmp, "wb") as o:
            body = r.read()
            # the ranged response carries the true object size in Content-Range:
            # "bytes 0-N/TOTAL". x-linked-size is not always present.
            cr = r.headers.get("content-range") or ""
            total = int(cr.rsplit("/", 1)[-1]) if "/" in cr else r.headers.get("x-linked-size")
            o.write(body)
        return tmp, int(total) if total else None
    except Exception as e:
        print("  FETCH FAILED %s: %s" % (path, str(e)[:90])); return None, None

def strat(f):
    L = struct.unpack("<Q", f.read(8))[0]
    if L > 200_000_000: raise ValueError("bad str len %d @%d" % (L, f.tell()))
    return f.read(L).decode("utf-8", "replace")

def val(f, t):
    if t == 8: return strat(f)
    if t == 9:
        et = struct.unpack("<I", f.read(4))[0]; n = struct.unpack("<Q", f.read(8))[0]
        r = None
        for i in range(n):
            v = val(f, et)
            if i == 0: r = v
        return "<%d items>" % n
    fmt = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?",
           10: "<Q", 11: "<q", 12: "<d"}[t]
    return struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]

for path in sys.argv[2:]:
    local, fsize = fetch(path)
    if not local: continue
    f = open(local, "rb")
    if f.read(4) != b"GGUF":
        print("  %s: not GGUF (likely an LFS pointer redirect issue)" % path); continue
    ver = struct.unpack("<I", f.read(4))[0]
    nten = struct.unpack("<Q", f.read(8))[0]; nkv = struct.unpack("<Q", f.read(8))[0]
    md = {}
    try:
        for _ in range(nkv):
            k = strat(f); t = struct.unpack("<I", f.read(4))[0]; md[k] = val(f, t)
    except Exception as e:
        print("  %s: metadata parse stopped early (%s)" % (path, str(e)[:60]))
    arch = md.get("general.architecture", "?")
    print("== %s" % path)
    print("   size %s | arch %s | blocks %s | file_type %s | nextn_layers %s"
          % ("%.2f GiB" % (fsize / 2**30) if fsize else "?", arch,
             md.get("%s.block_count" % arch, "?"), md.get("general.file_type", "?"),
             md.get("%s.nextn_predict_layers" % arch, md.get("%s.nextn_predict" % arch, "ABSENT"))))
    # scan the tensor-info block for nextn / KV names
    names = []
    try:
        got = 0
        while True:
            nm = strat(f)
            nd = struct.unpack("<I", f.read(4))[0]
            dims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nd)]
            ty = struct.unpack("<I", f.read(4))[0]
            struct.unpack("<Q", f.read(8))[0]
            names.append((nm, dims, ty)); got += 1
    except Exception:
        pass
    nxt = [n for n, _, _ in names if "nextn" in n]
    kvb = sorted({int(n.split(".")[1]) for n, _, _ in names if n.startswith("blk.") and n.endswith("attn_k.weight")})
    print("   scanned %d/%d tensors from the range read | nextn tensors: %s | KV blocks: %d %s"
          % (len(names), nten, ("YES: " + ", ".join(sorted({n.split(".")[1] for n in nxt}))) if nxt
             else ("not in scanned range" if len(names) < nten else "** NONE **"),
             len(kvb), (str(kvb[:3]) + "...") if kvb else ""))
    print("   ctx native %s | heads_kv %s | head_dim %s"
          % (md.get("%s.context_length" % arch, "?"), md.get("%s.attention.head_count_kv" % arch, "?"),
             md.get("%s.attention.key_length" % arch, md.get("%s.attention.v_head_dim" % arch, "?"))))
