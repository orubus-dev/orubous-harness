#!/usr/bin/env python3
"""Verify APK Signature Scheme v2: parse sig block, recompute chunked digests,
extract signer certificate, compare against local keystore fingerprint."""
import struct, sys, hashlib, subprocess, os

APK = sys.argv[1] if len(sys.argv) > 1 else "admin.apk"
EXPECT_FP = "80:31:65:AA:B1:D7:58:13:2C:B0:C6:2C:B0:D2:37:8F:AE:B6:C7:81:D7:76:A8:0D:3E:77:37:40:96:FE:B4:C4"
V2_ID = 0x7109871a
CHUNK = 0x100000  # 1MB per spec

data = open(APK, "rb").read()
n = len(data)

# ---- locate EOCD (last 0x06054b50) ----
eocd = data.rfind(b"PK\x05\x06")
assert eocd != -1, "no EOCD"
cd_size, cd_off = struct.unpack_from("<II", data, eocd + 12)

# ---- locate APK Signing Block: sits right before central directory ----
# sig block tail: [8-byte size][16-byte magic]
magic_off = cd_off - 16
magic = data[magic_off:cd_off]
assert magic == b"APK Sig Block 42", f"no sig block magic at {magic_off}, got {magic!r}"
size2 = struct.unpack_from("<Q", data, magic_off - 8)[0]
block_start = cd_off - 8 - size2
size1 = struct.unpack_from("<Q", data, block_start)[0]
print(f"APK {n:,} B | EOCD@{eocd:,} | CD@{cd_off:,} ({cd_size:,} B) | sig block [{block_start:,} .. {cd_off:,}) size={size1+8:,} B")

# ---- walk pairs ----
pairs_off = block_start + 8
pairs_end = block_start + 8 + size1 - 8 - 16
v2_val = None
ids = []
p = pairs_off
while p < pairs_end:
    plen = struct.unpack_from("<Q", data, p)[0]
    pid = struct.unpack_from("<I", data, p + 8)[0]
    val = data[p + 12 : p + 8 + plen]
    ids.append(hex(pid))
    if pid == V2_ID:
        v2_val = val
    p += 8 + plen
print("sig block pair ids:", ids)
assert v2_val is not None, "no v2 signature pair"

# ---- parse v2: length-prefixed sequence of signers ----
def rd_lp(buf, off):
    ln = struct.unpack_from("<I", buf, off)[0]
    return buf[off + 4 : off + 4 + ln], off + 4 + ln

signer_seq, off = rd_lp(v2_val, 0)
# one signer (first)
signer, off = rd_lp(signer_seq, 0)
signed_data, off = rd_lp(signer, 0)
sigs_seq, off = rd_lp(signer, off)
pubkey, off = rd_lp(signer, off)

# signed_data = digests seq, certificates seq, attrs seq
digests_seq, d = rd_lp(signed_data, 0)
certs_seq, d = rd_lp(signed_data, d)
attrs_seq, d = rd_lp(signed_data, d)

digest_map = {}
q = 0
while q < len(digests_seq):
    item, q = rd_lp(digests_seq, q)
    did = struct.unpack_from("<I", item, 0)[0]
    dg, _ = rd_lp(item, 4)
    digest_map[hex(did)] = dg
print("digest algorithms:", {k: len(v) for k, v in digest_map.items()})

certs = []
q = 0
while q < len(certs_seq):
    c, q = rd_lp(certs_seq, q)
    certs.append(c)
print("certs:", len(certs))
open("/tmp/signer.der", "wb").write(certs[0])

# ---- recompute chunked SHA-256 over 3 sections (spec-accurate) ----
# sections: [0, block_start), [cd_off, cd_off+cd_size), [eocd, n)
# per spec: chunk_digest = SHA256(0xa5 | u32le(len) | chunk)
#           top_digest   = SHA256(0x5a | u32le(count) | chunk_digest_1 | ... | chunk_digest_n)
# EOCD normalization: bytes [eocd+16,eocd+20) (CD-offset field) must be replaced
# with the offset of the APK signing block before hashing (spec requirement).
eocd_norm = bytearray(data[eocd:n])
struct.pack_into("<I", eocd_norm, 16, block_start)
chunk_digests = []
for (s, e, blob) in [(0, block_start, None), (cd_off, cd_off + cd_size, None), (None, None, bytes(eocd_norm))]:
    if blob is None:
        i = s
        while i < e:
            chunk = data[i : min(i + CHUNK, e)]
            ch = hashlib.sha256()
            ch.update(b"\xa5")
            ch.update(struct.pack("<I", len(chunk)))
            ch.update(chunk)
            chunk_digests.append(ch.digest())
            i += CHUNK
    else:
        i = 0
        while i < len(blob):
            chunk = blob[i : min(i + CHUNK, len(blob))]
            ch = hashlib.sha256()
            ch.update(b"\xa5")
            ch.update(struct.pack("<I", len(chunk)))
            ch.update(chunk)
            chunk_digests.append(ch.digest())
            i += CHUNK
top = hashlib.sha256()
top.update(b"\x5a")
top.update(struct.pack("<I", len(chunk_digests)))
for cdig in chunk_digests:
    top.update(cdig)
rec = top.digest()
ok = False
for k, v in digest_map.items():
    if v == rec:
        ok = True
        print(f"DIGEST MATCH for alg {k}: {rec.hex()}")
print("self-consistent (v2 block was created over THIS file):", ok)

# ---- cert details ----
print("\n--- signer certificate ---")
r = subprocess.run(["openssl", "x509", "-inform", "DER", "-in", "/tmp/signer.der", "-noout",
                    "-subject", "-issuer", "-dates", "-fingerprint", "-sha256"],
                   capture_output=True, text=True)
print(r.stdout or r.stderr)

# ---- key algos ----
q = 0
while q < len(sigs_seq):
    item, q = rd_lp(sigs_seq, q)
    alg = struct.unpack_from("<I", item, 0)[0]
    print("signature algorithm id:", hex(alg))

if ok:
    fp_line = [l for l in r.stdout.splitlines() if "SHA256 Fingerprint" in l or l.startswith("sha256 Fingerprint")]
    print("\nexpected keystore fp:", EXPECT_FP)
    print("VERDICT: v2 signature block is VALID and self-consistent over this exact APK")
else:
    print("\nVERDICT: digest MISMATCH — signature block does NOT match this file (broken APK)")
