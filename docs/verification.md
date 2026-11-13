# Verification

Environment: Foundry/Anvil 1.5.0-stable (1c57854462289b2e71ee7654cd6666217ed86ffd), Solidity 0.8.26, Cancun EVM.

## Test-first evidence

- The initial base-fee-only skeleton compiled. Five of eight tests failed on missing discount behavior and pool validation.
- The first CREATE2 test failed with HookAddressNotValid for an unmined address, then passed with salt mining.
- Completed suite: 30 passing tests, including three fuzz tests with 256 configured runs. Foundry may replay additional cached cases.

## Reproduction

```sh
forge fmt --check
forge build
forge test -vv
forge test --match-test testDemo -vv
python3 scripts/check-transactions.py
git diff --check
```

The Python script starts and stops a fresh local node. It asserts real PoolManager fee events and reservation events for two distinct transactions in one block. Each transaction executes swaps through different routers with fees [1000, 3000] at 20 gwei, and each reserves 2,000,000,000,000,000 wei. A later zero-basefee transaction uses [3000, 3000].

A sample run is stored in [transaction-check.json](transaction-check.json). Its addresses/hashes are ephemeral local-chain evidence, not public explorer links. The sample gas usage is for the entire two-swap demo transaction, not the hook's isolated overhead.

## Scope

Real local CREATE2 deployment and real local PoolManager swaps are covered. No public-chain deployment was performed. These are functional tests and a source review; they do not constitute a professional security audit, economic proof or market-data backtest.

## Independent source review

A fresh reviewer examined every tracked non-vendor file at c7a35afcbea8e94893d95c31b664d206ecfef56d and independently reran formatting, build, all 30 tests, whitespace checks and a fresh Anvil transaction check. No substantiated correctness findings or publication blockers were reported. This review did not judge profitability, global novelty, professional-audit readiness, public-chain addresses or GitHub/CI outcomes.
