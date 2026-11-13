#!/usr/bin/env python3
"""Run a fresh local Anvil chain and prove Headroom's transaction boundaries.

Python standard library only. Uses Anvil's unlocked development account, no real
RPC, private key, wallet or funds. The spawned node is stopped on completion.
"""
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def tool(name):
    found = shutil.which(name)
    fallback = Path.home() / ".foundry" / "bin" / name
    if found:
        return found
    if fallback.is_file():
        return str(fallback)
    raise RuntimeError(f"Install Foundry: missing {name}")


def command(*args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args[0]}\n{result.stdout[-6000:]}\n{result.stderr[-3000:]}")
    return result.stdout.strip()


def main():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"

    def rpc(method, params=None):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
        request = urllib.request.Request(url, body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.load(response)
        if "error" in payload:
            raise RuntimeError(f"{method}: {payload['error']}")
        return payload["result"]

    with tempfile.TemporaryDirectory(prefix="headroom-anvil-") as directory:
        log_path = Path(directory) / "anvil.log"
        with log_path.open("w") as log:
            node = subprocess.Popen(
                [tool("anvil"), "--host", "127.0.0.1", "--port", str(port),
                 "--chain-id", "31337", "--base-fee", "20000000000", "--silent"],
                stdout=log, stderr=subprocess.STDOUT,
            )
            try:
                for attempt in range(100):
                    if node.poll() is not None:
                        raise RuntimeError(log_path.read_text())
                    try:
                        rpc("eth_chainId")
                        break
                    except (OSError, ValueError):
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Local Anvil startup timed out")

                account = rpc("eth_accounts")[0]
                deployed = command(
                    tool("forge"), "script", "script/LocalDemo.s.sol:LocalDemo",
                    "--rpc-url", url, "--sender", account, "--unlocked", "--broadcast",
                    "--non-interactive", "-vv",
                )
                market_match = re.search(r"Demo market:\s*(0x[0-9a-fA-F]{40})", deployed)
                manager_match = re.search(r"PoolManager:\s*(0x[0-9a-fA-F]{40})", deployed)
                hook_match = re.search(r"Headroom hook:\s*(0x[0-9a-fA-F]{40})", deployed)
                if not all((market_match, manager_match, hook_match)):
                    raise RuntimeError(f"Deployment addresses missing:\n{deployed[-6000:]}")
                market = market_match.group(1)
                manager = manager_match.group(1).lower()
                hook = hook_match.group(1).lower()
                batch_data = command(tool("cast"), "calldata", "batch()")
                swap_topic = command(tool("cast"), "keccak",
                    "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)").lower()
                reserve_topic = command(tool("cast"), "keccak",
                    "DiscountReserved(bytes32,uint24,uint256,uint256,uint256)").lower()

                # These are two distinct transactions, deliberately included in ONE block.
                rpc("evm_setAutomine", [False])
                rpc("anvil_setNextBlockBaseFeePerGas", [hex(20_000_000_000)])
                nonce = int(rpc("eth_getTransactionCount", [account, "pending"]), 16)
                hashes = []
                for offset in range(2):
                    hashes.append(rpc("eth_sendTransaction", [{
                        "from": account, "to": market, "data": batch_data,
                        "nonce": hex(nonce + offset), "gas": hex(3_000_000),
                        "maxFeePerGas": hex(50_000_000_000),
                        "maxPriorityFeePerGas": hex(1_000_000_000),
                    }]))
                rpc("evm_mine")
                receipts = [rpc("eth_getTransactionReceipt", [tx]) for tx in hashes]
                assert all(receipts), "transactions not mined"
                assert hashes[0] != hashes[1], "must exercise separate transactions"
                assert receipts[0]["blockNumber"] == receipts[1]["blockNumber"], "must share one block"
                block = rpc("eth_getBlockByNumber", [receipts[0]["blockNumber"], False])
                assert int(block["baseFeePerGas"], 16) == 20_000_000_000

                summary = []
                for tx, receipt in zip(hashes, receipts):
                    assert int(receipt["status"], 16) == 1, f"reverted demo transaction {tx}"
                    swaps = [event for event in receipt["logs"]
                             if event["address"].lower() == manager
                             and event["topics"][0].lower() == swap_topic]
                    fees = [int(event["data"][-64:], 16) for event in swaps]
                    assert fees == [1000, 3000], f"expected fresh then exhausted allowance; got {fees}"
                    reservations = [event for event in receipt["logs"]
                                    if event["address"].lower() == hook
                                    and event["topics"][0].lower() == reserve_topic]
                    reserved = sum(int(event["data"][2 + 128:2 + 192], 16) for event in reservations)
                    assert reserved == 2_000_000_000_000_000, f"wrong nominal reservations: {reserved}"
                    summary.append({"transaction": tx, "block": int(receipt["blockNumber"], 16),
                                    "swap_fees_millionths": fees, "reserved_wei": reserved,
                                    "gas_used": int(receipt["gasUsed"], 16)})

                # Also exercise zero basefee on an actual transaction.
                rpc("anvil_setNextBlockBaseFeePerGas", ["0x0"])
                zero_hash = rpc("eth_sendTransaction", [{
                    "from": account, "to": market, "data": batch_data,
                    "gas": hex(3_000_000), "maxFeePerGas": hex(50_000_000_000),
                    "maxPriorityFeePerGas": hex(1_000_000_000),
                }])
                rpc("evm_mine")
                zero_receipt = rpc("eth_getTransactionReceipt", [zero_hash])
                assert int(zero_receipt["status"], 16) == 1
                zero_fees = [int(event["data"][-64:], 16) for event in zero_receipt["logs"]
                             if event["address"].lower() == manager
                             and event["topics"][0].lower() == swap_topic]
                assert zero_fees == [3000, 3000], f"zero basefee should not discount: {zero_fees}"

                print(json.dumps({"result": "PASS", "chain_id": 31337,
                                  "hook": hook, "same_block_transactions": summary,
                                  "zero_basefee_fees_millionths": zero_fees}, indent=2))
            finally:
                node.terminate()
                try:
                    node.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    node.kill()
                    node.wait()


if __name__ == "__main__":
    main()
