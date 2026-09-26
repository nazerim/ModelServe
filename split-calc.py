#!/usr/bin/env python3
"""One-off: simulate llama.cpp's -sm layer device assignment for this model and price each
candidate --tensor-split in MiB per device.

Rule read out of src/llama-model.cpp (base commit 911f6cdc, which the patched build is on):
    n_layer_all = block_count            (= 65 here: blocks 0..64)
    act_gpu_layers = min(ngl, n_layer_all + 1)   -> 66 with -ngl 99   <-- the "66"
    i_gpu_start    = max(n_layer_all + 1 - ngl, 0) -> 0 with -ngl 99
    splits  = normalize(tensor_split)
    device(il) = upper_bound(splits, (il - i_gpu_start)/act_gpu_layers)
    il = 0..64 are the blocks;  il = 65 is the OUTPUT layer (lm_head / output.weight)
    token_embd is always CPU ("very little benefit to offloading the input layer").
-ts is therefore a LAYER-COUNT fraction, not a byte fraction: with 66 units, "-ts K,66-K"
lands exactly K units on CUDA0.
"""
import os, re, struct, sys, collections

PATH = sys.argv[1] if len(sys.argv) > 1 else "/home/naz/.models/Qwen3.8-27B-UD-Q3_K_XL.gguf"
CTX = int(os.environ.get("CTX", "229376"))
CANDIDATES = os.environ.get("SPLITS", "17,8 18,7 45,21 46,20 47,19 48,18 49,17").split()
KV = os.environ.get("KV", "q8_0")          # -ctk/-ctv
KVD = os.environ.get("KVD", os.environ.get("KV", "q8_0"))   # -ctkd/-ctvd (draft)
PIN_BLK64_TO_CUDA0 = os.environ.get("PIN", "1") != "0"
GDN_STATE_MiB_PER_BLOCK = 448.0 / 48   # measured fixed part of one cache entry / GDN blocks
# Cross-device activation buffer: measured, not guessed. On CUDA1 (the card that owns the last
# layers and the output tensor) the footprint grows by n_embd*2 bytes PER TOKEN on top of KV:
#   q3 measured slope on the 3080 = 84 MiB per 4,096 tokens; KV alone predicts 5 layers x 8.7 = 43.5
#   the missing 40.5 MiB = 4,096 x 5,120 x 2 B exactly; and the absolute boot-time residual on the
#   3080 (2.6 GiB) equals 229,376 x 10 KiB. CUDA0's residual is only ~160 MiB, consistent with this
#   buffer living on the LAST device. Treat it as a calibrated term, not an explained one.

BPE = {"f16": 2.0, "q8_0": 34.0 / 32, "q4_0": 18.0 / 32}

# ---- parse GGUF (metadata + exact tensor bytes via offset gaps) ------------
f = open(PATH, "rb")
assert f.read(4) == b"GGUF"
f.read(4)
n_ten = struct.unpack("<Q", f.read(8))[0]
n_kv = struct.unpack("<Q", f.read(8))[0]

def rstr():
    L = struct.unpack("<Q", f.read(8))[0]
    return f.read(L)

def rval(t):
    SCAL = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?",
            10: "<Q", 11: "<q", 12: "<d"}
    SZ = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
    if t == 8:
        return rstr()
    if t == 9:
        et = struct.unpack("<I", f.read(4))[0]
        n = struct.unpack("<Q", f.read(8))[0]
        out = []
        for i in range(n):
            if et == 8:
                v = rstr()
            elif et in SZ:
                v = struct.unpack(SCAL[et], f.read(SZ[et]))[0]
            else:
                v = None
                f.read(0)
            if i < 6:
                out.append(v)
        return out
    return struct.unpack(SCAL[t], f.read(struct.calcsize(SCAL[t])))[0]

meta = {}
for _ in range(n_kv):
    k = rstr().decode("utf8", "replace")
    meta[k] = rval(struct.unpack("<I", f.read(4))[0])

tinfo = []
for _ in range(n_ten):
    nm = rstr().decode("utf8", "replace")
    nd = struct.unpack("<I", f.read(4))[0]
    dims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nd)]
    dt = struct.unpack("<I", f.read(4))[0]
    off = struct.unpack("<Q", f.read(8))[0]
    tinfo.append((nm, dims, dt, off))

align = meta.get("general.alignment", 32)
import os
fsize = os.path.getsize(PATH)
data_start = (f.tell() + align - 1) // align * align
by_off = sorted(tinfo, key=lambda t: t[3])
size = {}
for i, (nm, dims, dt, off) in enumerate(by_off):
    nxt = by_off[i + 1][3] if i + 1 < len(by_off) else fsize - data_start
    size[nm] = nxt - off

arch = meta["general.architecture"]
arch = arch.decode() if isinstance(arch, bytes) else str(arch)
EMB = int(meta.get(arch + ".embedding_length", 0))
ACT_BYTES_PER_TOKEN = EMB * 2
n_layer = int(meta[arch + ".block_count"])
n_kv_heads = int(meta[arch + ".attention.head_count_kv"])
head_dim = int(meta[arch + ".attention.key_length"])
interval = int(meta.get(arch + ".full_attention_interval", 0))

per_block = collections.defaultdict(int)
for nm, v in size.items():
    m = re.match(r"blk\.(\d+)\.", nm)
    if m:
        per_block[int(m.group(1))] += v
attn_q = {int(m.group(1)) for nm in size if (m := re.match(r"blk\.(\d+)\.attn_q\.weight", nm))}
kv_blocks = sorted(attn_q)
gdn_blocks = [b for b in range(n_layer) if b not in attn_q]

mb = 1048576.0
print("arch=%s block_count=%d  units_in_split=%d  n_kv_heads=%d head_dim=%d  full_attn_interval=%d"
      % (arch, n_layer, n_layer + 1, n_kv_heads, head_dim, interval))
print("KV-bearing blocks (has attn_q): %d -> %s" % (len(kv_blocks), kv_blocks))
print("block weights: total %.0f MiB | GDN avg %.1f | full-attn avg %.1f | blk.64(MTP) %.1f | output.weight %.1f | token_embd %.1f (CPU)"
      % (sum(per_block.values()) / mb,
         sum(per_block[b] for b in gdn_blocks if b != n_layer - 1) / max(len(gdn_blocks) - (1 if n_layer - 1 in gdn_blocks else 0), 1) / mb,
         sum(per_block[b] for b in kv_blocks) / len(kv_blocks) / mb,
         per_block.get(n_layer - 1, 0) / mb, size["output.weight"] / mb, size["token_embd.weight"] / mb))

kv_tok_layer = 2 * n_kv_heads * head_dim * BPE[KV]          # bytes/token/layer
kvd_tok = 2 * n_kv_heads * head_dim * BPE[KVD]              # draft: 1 layer


def device_of(il, splits_norm, n_units):
    """llama.cpp: upper_bound(splits, il/n_units); ties go to the LATER device."""
    x = float(il) / n_units
    for i, s in enumerate(splits_norm):
        if x < s - 1e-9:
            return i
    return len(splits_norm) - 1


def price(ts):
    parts = [float(x) for x in ts.split(",")]
    tot = sum(parts)
    norm = []
    run = 0.0
    for p in parts:
        run += p
        norm.append(run / tot)
    n_units = n_layer + 1     # blocks 0..64 + output layer
    dev = [0, 1]
    w = [0.0, 0.0]
    kv = [0.0, 0.0]
    st = [0.0, 0.0]
    act = [0.0, 0.0]
    detail = [[], []]
    d64 = 0
    for il in range(n_units):
        d = device_of(il, norm, n_units)
        if il < n_layer:
            b = il
            if PIN_BLK64_TO_CUDA0 and b == n_layer - 1:
                d = 0
            if b == n_layer - 1:
                d64 = d          # where the MTP block ACTUALLY lands, after the pin
            w[d] += per_block[b]
            if b in attn_q:
                kv[d] += CTX * kv_tok_layer
            else:
                st[d] += GDN_STATE_MiB_PER_BLOCK * mb
            detail[d].append(b)
        else:
            w[d] += size["output.weight"]
            detail[d].append("out")
            act[1] += CTX * ACT_BYTES_PER_TOKEN     # measured on the card owning the tail/output
    # Draft-context KV goes to CUDA0. It is NOT tied to whichever device owns blk.64 - falsified on
    # 2026-09-26 by q4s as-shipped (17,8, no pin, f16 draft): it BOOTED and measured a 9,322 MiB
    # footprint on the 3080. "draft follows blk.64" predicted 9,689 before any compute buffer, i.e.
    # impossible; "draft on CUDA0" predicted 9,081 + ~240 of buffers. config.ps1 agrees from the
    # other side: with the pin set and an f16 draft it OOMed in sched_reserve on CUDA0. So the pin
    # moves the MTP WEIGHTS (335 MiB) and the draft KV was on CUDA0 all along.
    kv[0] += CTX * kvd_tok
    return norm, w, kv, st, detail, act


print("\nper-device MiB  (weights + KV@%d %s + GDN state + calibrated act buffer)" % (CTX, KV))
print("%-14s %-6s %9s %9s %9s | %9s %9s %9s | %s" % (
    "--tensor-split", "frac0", "C0 wt", "C0 kv+st", "C0 tot", "C1 wt", "C1 kv+st", "C1 tot", "CUDA1 holds"))
for ts in CANDIDATES:
    norm, w, kv, st, det, act = price(ts)
    t0 = (w[0] + kv[0] + st[0] + act[0]) / mb
    t1 = (w[1] + kv[1] + st[1] + act[1]) / mb
    blks = det[1]
    nb = len([x for x in blks if x != "out"])
    print("%-14s %-6.4f %9.0f %9.0f %9.0f | %9.0f %9.0f %9.0f | %d blocks %s%s" % (
        ts, norm[0], w[0] / mb, (kv[0] + st[0]) / mb, t0,
        w[1] / mb, (kv[1] + st[1] + act[1]) / mb, t1, nb,
        "%d..%d" % (blks[0], blks[nb - 1]) if nb > 1 else blks[0],
        " +out" if "out" in blks else ""))

print("\nreference: free VRAM at boot (win logs) CUDA0 15037 MiB / CUDA1 9095 MiB;"
      "\n           live now: 3080 111 MiB free, 5070 Ti ~733 MiB free (desktop swings ~700 MiB).")
