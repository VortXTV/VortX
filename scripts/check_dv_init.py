#!/usr/bin/env python3
"""Offline verifier for the VortX DV remux HLS artifacts (b172 audit tooling).

Usage:
  python3 check_dv_init.py init.mp4            # verify the init segment's DV carriage
  python3 check_dv_init.py master.m3u8         # lint the master playlist DV signaling

Init segment checks (ftyp+moov produced by VortXMKVRemuxStream / served as /init.mp4):
  1. ftyp compatible brands include 'dby1' (movenc adds it only when DOVI side data exists).
  2. stsd sample entry fourcc (hvc1 / dvh1 / hev1 / dvhe).
  3. hvcC present with non-empty VPS/SPS/PPS arrays (empty hvcC = AVPlayer "Cannot Open").
  4. dvvC/dvcC present; decode profile, level, rpu/el/bl flags, bl_signal_compatibility_id.
  5. dec3 present (E-AC3) and whether the Atmos JOC extension byte is set.

Master playlist checks:
  A. Two variants, same URI.
  B. DV variant first with CODECS + SUPPLEMENTAL-CODECS (dvh1.08.xx/db1p|db4h) + VIDEO-RANGE.
  C. Lifeboat variant has NO VIDEO-RANGE and NO SUPPLEMENTAL-CODECS.
  D. FRAME-RATE present on both (authoring spec rule 9.15 MUST).
Exit code 0 = all hard checks pass, 1 = a hard check failed.
"""
import struct, sys, re

def walk_boxes(buf, start, end, depth=0, path=""):
    pos = start
    while pos + 8 <= end:
        size = struct.unpack(">I", buf[pos:pos+4])[0]
        four = buf[pos+4:pos+8].decode("ascii", "replace")
        hdr = 8
        if size == 1:
            size = struct.unpack(">Q", buf[pos+8:pos+16])[0]; hdr = 16
        if size < hdr or pos + size > end:
            yield (path + "/" + four, pos, hdr, min(end, pos + max(size, hdr)))
            return
        yield (path + "/" + four, pos, hdr, pos + size)
        if four in ("moov", "trak", "mdia", "minf", "stbl", "stsd", "mvex"):
            inner = pos + hdr + (8 if four == "stsd" else 0)
            yield from walk_boxes(buf, inner, pos + size, depth+1, path + "/" + four)
        if four in ("hvc1", "dvh1", "hev1", "dvhe"):
            # VisualSampleEntry: 8 hdr + 78 fixed bytes, then child boxes
            yield from walk_boxes(buf, pos + hdr + 78, pos + size, depth+1, path + "/" + four)
        pos += size

def check_init(path):
    buf = open(path, "rb").read()
    boxes = list(walk_boxes(buf, 0, len(buf)))
    names = {p.split("/")[-1] for p, *_ in boxes}
    ok = True

    ftyp = next(((p, s, h, e) for p, s, h, e in boxes if p.endswith("/ftyp")), None)
    if ftyp:
        _, s, h, e = ftyp
        brands = [buf[i:i+4].decode("ascii", "replace") for i in range(s+h+8, e, 4)]
        has_dby1 = "dby1" in brands
        print(f"ftyp brands: {brands}  dby1={'YES' if has_dby1 else 'MISSING'}")
        if not has_dby1:
            print("  !! movenc adds dby1 only when AV_PKT_DATA_DOVI_CONF side data exists ->")
            print("     no dby1 almost certainly means NO dvvC/dvcC either (in-band-only source gap).")
    else:
        print("!! no ftyp box"); ok = False

    entry = next((p.split("/")[-1] for p, *_ in boxes
                  if p.split("/")[-1] in ("hvc1", "dvh1", "hev1", "dvhe")), None)
    print(f"sample entry: {entry or 'NOT FOUND'}")
    if entry is None: ok = False

    hvcc = next(((s, h, e) for p, s, h, e in boxes if p.endswith("/hvcC")), None)
    if hvcc:
        s, h, e = hvcc
        payload = buf[s+h:e]
        n = len(payload)
        counts = {32: 0, 33: 0, 34: 0}
        if n >= 23 and payload[0] == 1:
            num_arrays = payload[22]; p2 = 23
            for _ in range(num_arrays):
                if p2 + 3 > n: break
                t = payload[p2] & 0x3F
                cnt = (payload[p2+1] << 8) | payload[p2+2]; p2 += 3
                for _ in range(cnt):
                    if p2 + 2 > n: break
                    ln = (payload[p2] << 8) | payload[p2+1]; p2 += 2 + ln
                    if t in counts: counts[t] += 1
        print(f"hvcC: {n}B vps={counts[32]} sps={counts[33]} pps={counts[34]}")
        if n <= 8 or not all(counts.values()):
            print("  !! empty/deficient hvcC -> AVPlayer 'Cannot Open' on an hvc1/dvh1 entry"); ok = False
    else:
        print("!! no hvcC box"); ok = False

    dovi = next(((p, s, h, e) for p, s, h, e in boxes
                 if p.split("/")[-1] in ("dvvC", "dvcC", "dvwC")), None)
    if dovi:
        p, s, h, e = dovi
        d = buf[s+h:e]  # 24-byte DOVIDecoderConfigurationRecord
        if len(d) >= 5:
            profile = (d[2] >> 1) & 0x7F
            level = ((d[2] & 1) << 5) | ((d[3] >> 3) & 0x1F)
            rpu = (d[3] >> 2) & 1; el = (d[3] >> 1) & 1; bl = d[3] & 1
            compat = (d[4] >> 4) & 0x0F
            print(f"{p.split('/')[-1]}: profile={profile} level={level} rpu={rpu} el={el} bl={bl} blCompatId={compat}")
            if p.endswith("dvvC") and profile <= 7:
                print("  !! dvvC fourcc but profile <= 7 (should be dvcC)"); ok = False
            if el != 0:
                print("  !! el_present=1 in a single-layer output"); ok = False
            if profile == 8 and compat not in (1, 2, 4, 6):
                print("  !! unexpected bl compatibility id for profile 8")
        else:
            print("!! DOVI config box too short"); ok = False
    else:
        print("!! NO dvvC/dvcC box in the init segment -> AVPlayer will NOT engage Dolby Vision (plays HDR10)")
        ok = False

    dec3 = next(((s, h, e) for p, s, h, e in boxes if p.endswith("/dec3")), None)
    if dec3:
        s, h, e = dec3
        payload = buf[s+h:e]
        has_ext = len(payload) >= 2 and (payload[-2] & 0x01) == 1
        print(f"dec3: {len(payload)}B atmosJOCext={'YES complexity=' + str(payload[-1]) if has_ext else 'absent'}")
    return ok

def check_master(path):
    text = open(path).read()
    infs = re.findall(r"#EXT-X-STREAM-INF:([^\n]+)\n([^\n]+)", text)
    ok = True
    print(f"{len(infs)} variants")
    if len(infs) != 2:
        print("!! expected exactly 2 variants (DV + lifeboat)"); ok = False
    uris = {u for _, u in infs}
    if len(uris) != 1:
        print(f"!! variants point at different URIs: {uris}"); ok = False
    for i, (attrs, uri) in enumerate(infs):
        has_range = "VIDEO-RANGE=" in attrs
        has_supp = "SUPPLEMENTAL-CODECS=" in attrs
        has_fr = "FRAME-RATE=" in attrs
        label = "DV variant " if i == 0 else "lifeboat  "
        print(f"{label}: RANGE={'Y' if has_range else 'n'} SUPPLEMENTAL={'Y' if has_supp else 'n'} FRAME-RATE={'Y' if has_fr else 'n'}  {attrs}")
        if i == 0 and not has_range:
            print("  !! DV variant missing VIDEO-RANGE (spec: brand + VIDEO-RANGE are cross-checks)"); ok = False
        if i == 1 and (has_range or has_supp):
            print("  !! lifeboat must stay range-unlabeled (the -1002 fix)"); ok = False
        if not has_fr:
            print("  .. FRAME-RATE missing (authoring rule 9.15 MUST; add in b172)")
    m = re.search(r'SUPPLEMENTAL-CODECS="([^"]+)"', text)
    if m and not re.match(r"dvh1\.0[58]\.\d{2}/(db1p|db4h)", m.group(1)):
        print(f"!! malformed SUPPLEMENTAL-CODECS: {m.group(1)}"); ok = False
    return ok

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    p = sys.argv[1]
    good = check_master(p) if p.endswith(".m3u8") else check_init(p)
    sys.exit(0 if good else 1)
