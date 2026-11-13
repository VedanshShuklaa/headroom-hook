# Headroom — Dynamic Fees quest design

Date: 2026-11-13.
Status: proposed; implementation has not started.
Research: [workspace RESEARCH.md](../../../../RESEARCH.md).

## Intent

Build the UHI Dynamic Fees quest in a new folder, with a public GitHub repository and a locally reproducible demonstration. Give the gas-price lesson a distinctive, testable extension: a single gas-related LP-fee discount allowance shared by all eligible swaps in one transaction through one hook instance.

The user requested a new folder, a good unique idea and a central research file. The mechanism and constants below are the builder's recommendation; they have not been represented as user-chosen settings.

## Mechanism

Headroom reduces the ordinary LP fee for an exact-input swap paid in native ETH or the configured canonical WETH. It allocates one ETH-denominated allowance per transaction, using block.basefee and a fixed reference gas quantity. All pools and callers interacting with this hook instance share the same allowance.

The project does not pay ETH back to the trader. LPs simply earn a reduced swap fee. The economic hypothesis is that lower swap fees during expensive network conditions may attract volume. This has not been calibrated or shown to improve LP returns.

## Fixed MVP choices

- Folder: /home/vedansh/Uniswap/dynamic-fees-hook.
- Repository name: headroom-hook under the existing authenticated GitHub user, if available.
- Solidity 0.8.26, Cancun EVM, Foundry, OpenZeppelin BaseHook, compatible pinned v4-core.
- Base LP fee: 3,000 millionths (0.30%).
- Fee floor: 500 millionths (0.05%).
- Reference gas: 100,000 units.
- Allowance basefee cap: 100 gwei.
- Allowance = 100,000 * min(block.basefee, 100 gwei), in wei.
- Configured WETH address is immutable and nonzero; it must be the target chain's canonical 18-decimal WETH. The hook cannot prove canonical identity.
- Pools must be dynamic fee pools and contain native ETH or the configured WETH. Reject unsupported pools during initialization.
- Only exact-input swaps whose input currency is native ETH or configured WETH are eligible. In a pool containing both, either direction is eligible.
- Exact-output and non-ETH-input swaps use the base fee and consume no allowance.
- Use no discretionary tip component. Increasing a transaction priority tip does not increase the allowance.

## Fee and reservation arithmetic

For eligible requested gross exact-input amount A > 0, remaining allowance R and denominator D = 1,000,000:

    reduction = min(2500, floor(R * D / A))
    fee = 3000 - reduction
    reservation = ceil(A * reduction / D)
    Rnext = R - reservation

R is bounded by 0.01 ETH due to the basefee cap. Use an upstream full-precision math helper for products/divisions and avoid unsafe signed negation of int256.min. Reservation must never exceed R. If the rate reduction rounds to zero, return base fee without consuming allowance.

Reserve against requested input, before returning the fee, without later reimbursement for a partial fill or zero executed fill. This is deliberately conservative and avoids pending-swap context/refund logic. Document this behavior prominently.

The promised invariant is about the sum of nominal reservations and the shared allowance. Do not claim exact counterfactual realized savings are bounded to the last wei: Uniswap fees use per-step arithmetic and the lower fee can alter execution.

## Hook integration

Use only the callback permissions actually needed: afterInitialize and beforeSwap.

- afterInitialize: check dynamic sentinel, supported currencies and set stored base LP fee.
- beforeSwap: select eligibility; initialize/read the transaction allowance; reserve a discount when available; return callback selector, zero BeforeSwapDelta and fee OR OVERRIDE_FEE_FLAG.
- All callbacks must retain BaseHook's PoolManager-only protection.
- No hook delta, ERC-6909 claim, custom token transfer, custody or allowance from users.
- No admin setter, upgrade proxy, router allowlist or oracle.
- PoolManager applies ordinary fees and any separately configured protocol fee.

A view quote should explain the eligible fee and reservation in the present transaction context. A standalone call starts with a fresh allowance; batch simulation must execute the actual sequence to model depletion.

## Transaction state

Use contract-local EIP-1153 transient storage with a separate initialized marker and remaining-wei slot. Zero allowance must not be mistaken for an uninitialized allowance. Use namespaced slots if assembly is needed for Solidity 0.8.26.

The budget is shared across pools, routers and sender values for this contract. Do not key it by caller, PoolId or tx.origin. EVM rollback handles reverted calls. It resets only when the transaction ends.

Different hook contracts cannot share it. Different transactions, even in the same block, get distinct allowances. Users bundled into one transaction share a first-used allowance; do not call it one allowance per person.

## Demonstration

At basefee 20 gwei, fresh allowance is 0.002 ETH:

| Eligible input | Applied LP fee | Nominal reservation |
| --- | ---: | ---: |
| 1 ETH | 0.10% | 0.002 ETH |
| 10 ETH | 0.28% | 0.002 ETH |
| 0.1 ETH | 0.05% | 0.00025 ETH |

A second eligible swap gets only what the first leaves. Once depleted, fee is 0.30%. A distinct transaction starts with a fresh allowance.

Use funded mock tokens and a real local PoolManager. Include a small settlement router capable of several swaps in one transaction. An oracle, wallet connection, frontend or public-chain funds are unnecessary.

## Success criteria

1. The hook builds against locked dependencies and deploys to a real permission-valid CREATE2 address.
2. Tests execute real swaps and read actual applied LP fees from PoolManager events.
3. Multiple swaps across multiple pools and caller paths cannot exceed the nominal allowance for one hook instance per transaction.
4. Separate transactions prove the reset, including transactions included in one block. vm.roll alone is insufficient evidence.
5. Reverted swaps/settlement roll state back.
6. Edge cases cover rounding, zero gas signal, capped gas signal, input extremes, partial fills, fee floor, unsupported trade modes and callback access.
7. Fee-rate and reservation fuzz tests validate bounds and monotonic behavior where applicable.
8. Formatting, build and relevant complete tests pass.
9. README explains the mechanism, example, reproducible commands, eligibility, router/bundling limits, LP tradeoff and lack of economic validation.
10. A new public GitHub repo is created, pushed and its visibility verified. Do not alter the first-hook repo.
11. Research and new implementation findings are appended to workspace RESEARCH.md.
12. No quest form, email declaration or lesson-review declaration is submitted on the user's behalf.

## Deliberate non-goals

No universal gas refund, guaranteed total execution-cost ceiling, bot detection, MEV protection, arbitrary-token oracle conversion, support for every trade mode, LP profitability guarantee, token rewards, vault, frontend or automated mainnet deployment.

The distinctive claim is a small composition of existing primitives. Literature searches cannot establish global novelty.

## Left to the builder

File organization, namespaced transient-slot identifiers, compatible dependency revisions, event names, test helper layout, CI details and the precise way to exercise real transaction boundaries are implementation choices. Keep the contract small and comments precise. Publishing follows the user's public-repository requirement; funded public-chain deployment is outside the request.
