# Robinhood Chain v4 pools — BandHook launch kit

Uniswap v4 dynamic-fee pools on Robinhood Chain (chain id 4663), market-made by
`BandHook`: hook-owned core band + wide backstop, oracle-guarded permissionless
recentering, divergence-driven dynamic fee. Pools: **ETH/HOLLAR, HDX/HOLLAR,
ETH/HDX** (native ETH).

Design + evidence: garden note `wiki/note-robinhood-pools-proposal`.

## Layout

- `src/BandHook.sol` — the hook (owner-funded, open to third-party LPs)
- `src/sources/` — `ChainlinkSource` (single feed + invert + decimals), `RatioSource` (fallback)
- `script/00–03` — deploy hook (CREATE2 salt-mined to flags `0x1080`), setup pool, fund, hand off ownership
- `test/` — 18 unit tests (ERC20 + native pools) and 2 fork tests against the live PoolManager

## Prerequisites

Fill `.env` from `.env.example`. Blanks that must exist first:

- bridged HOLLAR + HDX addresses (and confirmed decimals),
- HDX/USD + HDX/ETH ManagedOracles (wormhole-direct receiver stack, `whm` repo),
- owner multisig on Robinhood Chain.

## Run order

```sh
forge test                                   # 20 green, incl. fork tests (uses the "robinhood" rpc alias)

forge script script/00_DeployBandHook.s.sol --rpc-url robinhood --broadcast   # once
# per pool (three env files):
set -a; source .env.eth-hollar; set +a
forge script script/01_SetupPool.s.sol --rpc-url robinhood --broadcast       # source + configure + initialize at oracle price
forge script script/02_Fund.s.sol --rpc-url robinhood --broadcast            # POOL_ID + FUND_AMOUNT0/1
# after all pools:
forge script script/03_HandOff.s.sol --rpc-url robinhood --broadcast         # multisig then calls acceptOwnership()
```

Post-launch: run the recenter keeper (permissionless `recenter(poolId)`; ~350k
gas, guards make it safe to call blindly) and wire alerts for feed staleness,
guard tripped > N hours, and inventory skew.

**Not audited.** The hook custodies the LP capital — cap the pilot size until
the audit lands.
