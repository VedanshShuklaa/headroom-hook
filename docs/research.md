# Headroom research and decisions

Research date: 2026-11-13. The workspace's central RESEARCH.md contains the cumulative first-hook and quest research; this file keeps the project-specific conclusions portable with the public repository.

## Sources checked

- [Atrium course outline](https://atrium.academy/uniswap/course): the Dynamic Fees module includes gas-price and directional fee designs. The enrolled Gas Price Fee lesson itself was not accessed.
- [Uniswap dynamic fees](https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees): a dynamic pool can accept per-swap beforeSwap LP-fee overrides. Gas, time, volume and direction strategies already exist.
- [Uniswap core](https://github.com/Uniswap/v4-core), checked through Context7 and pinned local source: dynamic sentinel 0x800000, override flag 0x400000; SwapParams uses negative exact input and positive exact output.
- [OpenZeppelin fee hooks](https://docs.openzeppelin.com/uniswap-hooks/fee): established dynamic/override fee primitives.
- [Uniswap Labs public hooks](https://github.com/Uniswap/v4-hooks-public): existing directional and decaying fees.
- [Detoxer](https://github.com/web3yurii/detoxer): UHI prior art for priority-fee-based hooks. Its protection claims were not audited here.
- [PulseFee](https://github.com/BitCitrus/Pulse-v4-hook): volume-distribution LP fees and a separate gas-ratio hook-fee component.
- [Alphix](https://github.com/alphixfi/alphix-core): established EMA, bounds and cooldown approaches.
- [EIP-1559](https://eips.ethereum.org/EIPS/eip-1559): block base fee is distinct from transaction priority tips. Headroom's budget uses the former.
- [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153): contract-local transient storage is shared across call frames, reverts with calls and clears at transaction end.
- [Foundry Anvil RPC methods](https://github.com/foundry-rs/book/blob/master/src/pages/anvil/rpc-methods.mdx), checked through Context7: anvil_setNextBlockBaseFeePerGas sets the next basefee; evm_setAutomine and evm_mine allow distinct transactions to share a manually mined block.

## Alternatives

| Candidate | Decision |
| --- | --- |
| Gas-price fee tiers | Too close to the basic lesson exercise |
| Priority-tip pricing | Existing direct UHI prior art; discretionary tips are not proof of MEV |
| Gas spike plus time-decaying premium | Too close to the previous Afterglow hook |
| Relative gas EMA / hysteresis | Valid alternative, but sampling adds complexity and differentiation is weak |
| Gas plus directional rebalancing | A local price anchor is not fair value; overshoot/manipulation complicate the scope |
| Per-swap gas discount | Routing can request the same allowance repeatedly |
| Shared transaction allowance | Chosen: distinctive composability property and a compact, testable implementation |

## Decisions and consequences

- ETH/WETH exact input keeps budget and input in the same unit, avoiding a token-price oracle. Other modes get the base fee.
- One allowance belongs to a hook instance and transaction, not a pool, router, sender or person.
- Use a separate initialized marker so an exhausted allowance cannot be renewed.
- Round reservations up and reserve against requested input. Partial/zero fills can waste allowance; reversions restore it.
- Promise a bound on nominal reservations, not exact realized savings against a hypothetical different swap.
- A 0.30% base, 0.05% floor, 100000 reference gas and 100 gwei cap are demonstration parameters, not optimized economic values.
- LPs pay for the discount through lower fees. The project does not establish improved LP revenue.
- No global originality, anti-MEV or all-in-cost guarantee is claimed.

## Implementation findings

- Solidity 0.8.26 supports assembly tload/tstore, so no compiler upgrade or proxy is needed.
- The basefee must be capped before multiplication. FullMath handles amount/fee arithmetic.
- int256.min requires a safe unsigned magnitude conversion.
- Foundry 1.5 reserves test names beginning with testFail and restricts vm.fee to uint64; fixtures were corrected accordingly.
- The initial Anvil check used an incomplete RPC method name. Documentation confirmed anvil_setNextBlockBaseFeePerGas; the corrected check passed.
- A block-number change within one test cannot prove a transaction reset. Separate same-block Anvil receipts directly exercise the intended boundary.
- See [verification](verification.md) for reproducible evidence; the original research did not establish profitability or production safety.
