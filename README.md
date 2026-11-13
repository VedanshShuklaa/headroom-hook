# Headroom

**Network gas rises. Your swap fee gets some breathing room.**

Headroom is a Uniswap v4 dynamic LP-fee hook for the UHI Dynamic Fees quest. It lowers the LP fee on eligible ETH/WETH swaps using a bounded gas-related allowance.

The twist: **one allowance per transaction, shared across every pool and caller using this hook instance.** Splitting a trade into more swaps cannot create additional allowances within that transaction.

## Try it

Requires [Foundry](https://getfoundry.sh/) with Cancun support; tested with v1.5.0. The transaction check also requires Python 3 (standard library only).

```sh
git clone --recurse-submodules https://github.com/VedanshShuklaa/headroom-hook.git
cd headroom-hook
forge build
forge test -vv
forge fmt --check
```

If already cloned, run `git submodule update --init --recursive` first. Solidity 0.8.26 and compatible Git-submodule revisions are pinned; the first build may download the compiler.

Quick demo:

```sh
forge test --match-test testDemo -vv
```

At 20 gwei basefee, the demo prints:

```text
Starting allowance (wei):                  2000000000000000
First 0.1 ETH swap fee (millionths):        500
Remaining allowance (wei):                 1750000000000000
Next 1 ETH swap fee (millionths):          1250
After exhaustion (millionths):            3000
```

### Prove the transaction boundary

```sh
python3 scripts/check-transactions.py
```

This starts a fresh local Anvil node, deploys a real PoolManager and a permission-valid hook, funds a mock-token pool, and sends **two distinct transactions into the same block**. Each transaction makes two real swaps through different routers.

Expected LP fees in each transaction:

```text
First swap:  1000  (0.10%; spends the fresh 0.002 ETH allowance)
Second swap: 3000  (0.30%; allowance exhausted)
```

The script checks transaction hashes, receipt block numbers, actual PoolManager Swap events and nominal reservation events. It also checks zero basefee: both fees are 3000. The node is stopped afterward. No wallet, public RPC, private key or real funds are needed.

The fixtures use mock WETH, mock assets and upstream test routers. They are local test infrastructure; the production contract is [HeadroomHook.sol](src/HeadroomHook.sol).

## The rule

| Setting | Value |
| --- | ---: |
| Base LP fee | 0.30% |
| Minimum LP fee | 0.05% |
| Reference gas units | 100,000 |
| Basefee used for the allowance | Capped at 100 gwei |
| Largest initial nominal allowance | 0.01 ETH |

Eligible trades are **exact-input swaps paid in native ETH or the immutable, configured canonical WETH**. Other token inputs and all exact-output swaps use the base fee without spending allowance. Both currency positions are supported. Pools must contain ETH/WETH and be created with the dynamic-fee sentinel.

For eligible gross requested input `A` in ETH wei and remaining allowance `R`:

```text
initial allowance = 100,000 × min(block.basefee, 100 gwei)

fee reduction     = min(2500, floor(R × 1,000,000 / A))
LP fee            = 3000 − fee reduction
reservation       = ceil(A × fee reduction / 1,000,000)
remaining         = R − reservation
```

Fees use millionths: 3000 = 0.30%, 1000 = 0.10%, 500 = 0.05%.

At 20 gwei, a fresh transaction starts with 0.002 ETH of nominal allowance:

| Requested eligible input | LP fee | Nominal reservation |
| --- | ---: | ---: |
| 0.1 ETH | 0.05% | 0.00025 ETH |
| 1 ETH | 0.10% | 0.002 ETH |
| 10 ETH | 0.28% | 0.002 ETH |

Each row assumes a fresh transaction. These are LP-fee examples, excluding gas, price impact, protocol fees and execution rounding.

## How it works

- `afterInitialize` validates the hook address, dynamic fee and supported currencies; sets the stored LP fee to 3000.
- `beforeSwap` computes the eligible fee, reserves allowance and returns the fee with `OVERRIDE_FEE_FLAG`.
- Two namespaced EIP-1153 transient slots hold the initialized marker and remaining allowance. They persist across callers, pools and unlocks, then reset at transaction end.
- Zero remaining allowance has its own initialized marker, so it cannot be mistaken for an unused allowance.
- The hook returns zero custom-accounting delta and collects no hook fee. Standard Uniswap LP/protocol fee accounting applies.
- The hook uses `block.basefee`; paying a larger priority tip does not increase the allowance.

Reservations round **up** against requested input. Partial fills and successful swaps with zero executed amounts still consume the nominal reservation. A reverted call or reverted settlement rolls its reservation back.

The public `quote(PoolKey, SwapParams)` returns the next LP fee, its nominal reservation and the allowance that would remain, without consuming it. `remainingAllowance()` reports the current transaction's remaining allowance. A standalone call starts fresh; simulate a complete batch for batch-aware quoting. The stored PoolManager fee alone does not reflect the per-swap discount.

## What is bounded

The sum of **nominal reservations** cannot exceed one initial allowance per hook instance per transaction. The floor also bounds the fee reduction.

This is not an ETH refund, a guaranteed all-in cost ceiling or an exact counterfactual bound on realized savings. Pool execution, partial fills, tick crossings and fee rounding affect the actual result.

## Tests

The suite covers:

- Actual LP fees from PoolManager Swap events, fee-floor depletion and size-aware quotes.
- Native ETH and WETH in either input position.
- Exact-output and unsupported-input fallback; static/unsupported pool rejection.
- Cross-pool, cross-router and cross-payer allowance sharing.
- No reset on a block change within the same transaction.
- Full and partial reservation rollback after failed settlement.
- Conservative partial/empty fill behavior.
- Zero/capped basefee, priority-tip independence and signed extreme input.
- Fractional-wei rounding, fuzzed budget bounds, repeated trades and fee monotonicity.
- Real CREATE2 deployment with valid callback permissions.
- Separate same-block transactions in the Anvil acceptance check.

See [verification](docs/verification.md), [research](docs/research.md) and [design](docs/superpowers/specs/2026-11-13-headroom-design.md). CI runs formatting, build, tests and the Anvil check.

## Deployment

The included `DeployHeadroom` script deploys only the hook. Use the official [Uniswap deployment reference](https://developers.uniswap.org/docs/protocols/v4/deployments) for the target chain's PoolManager and verify its canonical 18-decimal WETH address.

Set `POOL_MANAGER`, `WETH` and `RPC_URL` in your environment. The chain must support Cancun and Foundry's canonical CREATE2 deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

Simulate:

```sh
forge script script/DeployHeadroom.s.sol:DeployHeadroom --rpc-url "$RPC_URL"
```

To deliberately deploy using a configured Foundry keystore:

```sh
forge script script/DeployHeadroom.s.sol:DeployHeadroom \
  --rpc-url "$RPC_URL" --account deployer --broadcast
```

Then create a pool with sorted currencies, `fee = 0x800000` and the deployed hook address. The script validates deployed code at the manager, WETH and CREATE2 deployer addresses, mines a salt for the callback bits, and rejects an already-used predicted address. WETH canonical identity remains the deployer's responsibility.

Only local Anvil deployments are included in the verification record.

## Limits and tradeoffs

- **LPs fund the discount** through lower LP fees. Additional volume may or may not compensate them; no profitability improvement is established.
- The reference gas quantity is a policy constant, not measured transaction gas.
- **A bundled transaction shares one allowance.** A router decides which eligible trade uses it first; it is not an allowance per user.
- Separate transactions and separate hook deployments have independent allowances. Multi-transaction splitting is outside the guarantee.
- Eligibility is intentionally limited to ETH/WETH exact input so no token-price oracle is needed.
- Conservative reservations can waste allowance on partial or zero fills.
- Priority tips and L2 data charges are excluded. Basefee behavior differs by chain.
- Normal slippage controls and hook-aware quoting remain necessary.
- No bot detection, MEV protection, custody, owner controls, keeper or separate rebate token is provided.
- Parameters are educational choices. This code has not had a professional security audit or economic validation.

Gas-responsive fees and transaction-scoped accounting are existing primitives. Headroom's contribution is their small, testable combination; no global novelty claim is made.

## License and attribution

Headroom source is MIT licensed. Uniswap v4 core, OpenZeppelin hooks, Foundry helpers and mock-token code retain their own licenses. In particular, this repository does not relicense v4-core.

Built using [Uniswap v4](https://github.com/Uniswap/v4-core), [OpenZeppelin Uniswap Hooks](https://github.com/OpenZeppelin/uniswap-hooks), [EIP-1559](https://eips.ethereum.org/EIPS/eip-1559) and [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153).
