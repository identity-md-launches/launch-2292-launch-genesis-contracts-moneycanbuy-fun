#!/usr/bin/env python3
"""Snapshot of identity.md NFT holders for the NftGate of $YOLO (no registration: a snapshot taken shortly before
the token launch). Read-only: it reads `ownerOf` of every NFT at one block and writes a json with the
holders, the batches for `NftGate.record(address[],uint256[])` (calldata included) and the hash the gate will show
after the last batch (`snapshotHash`). It sends nothing: the project wallet (the gate's writer) sends the batches and
then `seal(block)` itself.

  python3 snapshot.py --rpc <archive RPC> --block <number|latest> --out snapshot.json
      [--nft 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D] [--ids 0-1999] [--batch 200] [--extra wallets.json]

Mainnet: the NFT is LaunchPlan.NFT (0x0000eC93…ec1D, 2,000 NFTs, ids 0-1999); use an archive RPC for a past block.
`--ids a-b` scans ids a..b (default: 0..totalSupply()-1, or 0-1999 without totalSupply). A burned or missing id is
skipped and listed. `--extra` adds wallets by hand ([{"wallet": "0x..", "nfts": n}], e.g. test wallets on a testnet);
a wallet both read and added gets the sum. Holders that are contracts are flagged (`contract: true`): a contract in
the list buys like any wallet, through a router that pays it directly.
"""
import argparse
import json
import sys
import time
import urllib.request

# ---- keccak-256 (Ethereum's, not NIST SHA3), pure Python
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ (((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63)) & _M) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                r = _ROT[x][y]
                b[y][(2 * x + 3 * y) % 5] = ((a[x][y] << r) | (a[x][y] >> (64 - r))) & _M if r else a[x][y]
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    p = bytearray(data) + b"\x01" + b"\x00" * ((rate - (len(data) + 1) % rate) % rate)
    p[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(p), rate):
        blk = p[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            a[x][y] ^= int.from_bytes(blk[8 * i:8 * i + 8], "little")
        a = _f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"


# ---- JSON-RPC
class Rpc:
    def __init__(self, url):
        self.url = url
        self.n = 0

    def batch(self, calls):
        body = []
        for m, p in calls:
            self.n += 1
            body.append({"jsonrpc": "2.0", "id": self.n, "method": m, "params": p})
        for attempt in range(5):
            try:
                req = urllib.request.Request(self.url, json.dumps(body).encode(),
                                             {"Content-Type": "application/json", "User-Agent": "snapshot/1"})
                res = json.load(urllib.request.urlopen(req, timeout=60))
                if isinstance(res, dict):
                    raise RuntimeError(res)
                res.sort(key=lambda r: r["id"])
                return res
            except Exception as e:  # noqa: BLE001 (public RPCs drop batches now and then)
                if attempt == 4:
                    raise
                print(f"rpc retry {attempt + 1}: {e}", file=sys.stderr)
                time.sleep(2 * (attempt + 1))

    def one(self, m, p):
        r = self.batch([(m, p)])[0]
        if "error" in r:
            raise RuntimeError(r["error"])
        return r["result"]


def word(x: int) -> bytes:
    return x.to_bytes(32, "big")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--block", default="latest")
    ap.add_argument("--nft", default="0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D")
    ap.add_argument("--ids", default="")
    ap.add_argument("--batch", type=int, default=200)
    ap.add_argument("--rpc-batch", type=int, default=20, help="calls per JSON-RPC batch (free RPCs cap it)")
    ap.add_argument("--extra", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rpc = Rpc(a.rpc)
    chain = int(rpc.one("eth_chainId", []), 16)
    blk = rpc.one("eth_getBlockByNumber", [a.block if a.block == "latest" else hex(int(a.block)), False])
    number = int(blk["number"], 16)
    tag = hex(number)
    if a.ids:
        lo, hi = (int(x) for x in a.ids.split("-"))
    else:
        r = rpc.batch([("eth_call", [{"to": a.nft, "data": "0x18160ddd"}, tag])])[0]
        hi = int(r["result"], 16) - 1 if "result" in r and r["result"] not in ("0x", None) else 1999
        lo = 0
    owners, missing = {}, []
    ids = list(range(lo, hi + 1))
    for off in range(0, len(ids), a.rpc_batch):
        chunk = ids[off:off + a.rpc_batch]
        res = rpc.batch([("eth_call", [{"to": a.nft, "data": "0x6352211e" + word(i).hex()}, tag]) for i in chunk])
        for i, r in zip(chunk, res):
            if "error" in r or not r.get("result") or len(r["result"]) < 66:
                missing.append(i)
                continue
            w = "0x" + r["result"][-40:]
            if int(w, 16) == 0:
                missing.append(i)
                continue
            owners.setdefault(w.lower(), []).append(i)
    count = {w: len(v) for w, v in owners.items()}
    added = []
    if a.extra:
        for e in json.load(open(a.extra)):
            w = e["wallet"].lower()
            count[w] = count.get(w, 0) + int(e["nfts"])
            added.append({"wallet": e["wallet"], "nfts": int(e["nfts"])})
    wallets = sorted(count)
    codes = []
    for off in range(0, len(wallets), a.rpc_batch):
        codes += rpc.batch([("eth_getCode", [w, tag]) for w in wallets[off:off + a.rpc_batch]])
    holders = []
    for w, c in zip(wallets, codes):
        code = c.get("result") or "0x"
        # an EOA with an EIP-7702 delegation carries 0xef0100 + address: still a wallet with its own key
        delegated = code.lower().startswith("0xef0100") and len(code) == 48
        holders.append({"wallet": w, "nfts": count[w], "ids": owners.get(w, []),
                        "contract": code not in ("0x", "0x0") and not delegated, "eip7702": delegated})
    # the gate's running hash: h = keccak256(abi.encode(h, account, nfts)), in the order written
    h = b"\x00" * 32
    batches = []
    for off in range(0, len(holders), a.batch):
        part = holders[off:off + a.batch]
        for x in part:
            h = keccak256(h + word(int(x["wallet"], 16)) + word(x["nfts"]))
        n = len(part)
        # record(address[],uint256[]): selector, two offsets, two arrays
        sel = keccak256(b"record(address[],uint256[])")[:4]
        body = word(64) + word(64 + 32 * (n + 1)) + word(n) + b"".join(word(int(x["wallet"], 16)) for x in part)
        body += word(n) + b"".join(word(x["nfts"]) for x in part)
        batches.append({"accounts": [x["wallet"] for x in part], "nfts": [x["nfts"] for x in part],
                        "calldata": "0x" + (sel + body).hex(), "hashAfter": "0x" + h.hex()})
    out = {
        "chainId": chain, "nft": a.nft, "block": number, "blockTimestamp": int(blk["timestamp"], 16),
        "idsScanned": [lo, hi], "idsMissing": missing, "added": added,
        "wallets": len(holders), "totalNfts": sum(x["nfts"] for x in holders),
        "contracts": sum(1 for x in holders if x["contract"]),
        "contractNfts": sum(x["nfts"] for x in holders if x["contract"]),
        "eip7702Wallets": sum(1 for x in holders if x["eip7702"]),
        "snapshotHash": "0x" + h.hex(), "sealCalldata": "0x" + (keccak256(b"seal(uint256)")[:4] + word(number)).hex(),
        "holders": holders, "batches": batches,
    }
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"chain {chain} block {number}: {out['wallets']} wallets, {out['totalNfts']} NFTs "
          f"({out['contracts']} contracts with {out['contractNfts']} NFTs, {out['eip7702Wallets']} EIP-7702 wallets), {len(batches)} batches, hash {out['snapshotHash']}")


if __name__ == "__main__":
    main()
