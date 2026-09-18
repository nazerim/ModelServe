#!/usr/bin/env python3
"""Which quant gets us to ~200K on THIS box. Calibrated to measurements, not theory.

Baseline config (operator decision: images are infrequent -> projector on CPU):
  -sm layer --tensor-split 19,6  -ngl 99  -ctk q8_0 -ctv q8_0  --no-mmproj-offload

Two measured anchors of the SAME config at two context sizes give the real slope:
  CTX 81920 -> 15080 + 7353 = 22433 MiB   (mm-bench step 3, 50.3 tok/s class)
  CTX 114688 -> 15881 + 7761 = 23642 MiB  (47.2 tok/s, ctx-test)
and the pass/fail pair brackets capacity:
  114688 PASS, 122880 FAIL  -> capacity sits between those two demands.
"""
MIB, GIB = 1024.0, 1024.0 ** 1

A_TOK, A_MiB = 81_920, 22_433
B_TOK, B_MiB = 114_688, 23_642
FAIL_TOK = 122_880

RATE_KiB = (B_MiB - A_MiB) * MIB / (B_TOK - A_TOK)          # KiB per token, q8_0
FIXED_GiB = (A_MiB - RATE_KiB * A_TOK / MIB) / MIB          # main weights + buffers
CUR_MAIN = 16.35
BUFS_GiB = FIXED_GiB - CUR_MAIN
CAP_LO = B_MiB / MIB                                        # proven to fit
CAP_HI = (FIXED_GiB * MIB + RATE_KiB * FAIL_TOK / MIB) / MIB  # proven NOT to fit

QUANTS = [("Q6_K_XL", 23.56), ("Q5_K_XL", 19.44), ("Q5_K_M", 18.41),
          ("Q4_K_XL  *current*", 16.35), ("Q4_K_M", 15.33), ("Q4_K_S", 14.30),
          ("IQ4_XS", 13.27), ("Q3_K_XL", 12.24), ("IQ3_S", 11.21),
          ("IQ3_XXS", 10.18), ("Q2_K_XL", 9.15), ("IQ2_S", 7.80)]
NATIVE = 262_144

def max_ctx(main_gib, cap_giB=None, rate=RATE_KiB):
    cap = cap_giB if cap_giB else CAP_LO
    kv_gib = cap - BUFS_GiB - main_gib
    if kv_gib <= 0: return 0
    return int(min(NATIVE, kv_gib * MIB * MIB / rate))

def main():
    print("calibrated: q8_0 KV = %.1f KiB/token  (pure theory says 36.1 -> measured overhead %.2fx)"
          % (RATE_KiB, RATE_KiB / (17 * 4 * 256 * 2 * (34 / 32.0) / MIB)))
    print("            fixed cost %.2f GiB = main weights %.2f + compute/MTP/DeltaNet-state %.2f"
          % (FIXED_GiB, CUR_MAIN, BUFS_GiB))
    print("            capacity bracketed to %.2f - %.2f GiB by 114688 PASS / 122880 FAIL\n"
          % (CAP_LO, CAP_HI))

    print("=== largest context per quant (q8_0 KV, projector on CPU) ===")
    print("  %-18s %6s | %-12s | %-12s | %s"
          % ("quant", "GiB", "conservative", "optimistic", "at 200K needs"))
    for name, sz in QUANTS:
        lo, hi = max_ctx(sz, CAP_LO), max_ctx(sz, CAP_HI)
        kv200 = RATE_KiB * 200_000 / MIB / MIB
        verdict = "fits (%.1f spare)" % (CAP_LO - BUFS_GiB - sz - kv200) if sz + BUFS_GiB + kv200 <= CAP_LO \
                  else "NO (%.1f over)" % (sz + BUFS_GiB + kv200 - CAP_LO)
        print("  %-18s %6.2f | %9s | %9s | %s"
              % (name, sz, format(lo, ","), format(hi, ","), verdict))

    print("\n=== what 200K / 256K costs in KV (q8_0) ===")
    for t in (114_688, 150_000, 200_000, 262_144):
        print("  %9s tokens -> KV %5.2f GiB -> main weights must be <= %.2f GiB"
              % (format(t, ","), RATE_KiB * t / MIB / MIB, CAP_LO - BUFS_GiB - RATE_KiB * t / MIB / MIB))
    print("\nNOTE q4_0 KV does NOT scale down predictably here: theory says ~20 KiB/token and")
    print("     the model then predicts 192K fits on Q4_K_XL, but it measured FAIL. Stay on q8_0.")
main()
