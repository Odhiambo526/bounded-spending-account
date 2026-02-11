# Smart Allowance MVP

A minimal, auditable ERC-4337 spending wallet with hard onchain limits for ETH and USDC. Target: Base L2.

## Components

- **SpendingAccount.sol** – ERC-4337 smart account; enforces daily/monthly ETH and USDC limits
- **LimitPolicy.sol** – Library for rolling 24h/30d windows and limit checks
- **SpendingPaymaster.sol** – Paymaster that accepts USDC for gas with a 5% premium
- **SpendingAccountFactory.sol** – Factory for deploying SpendingAccount via Create2

## Limits

- Rolling 24h and 30d windows (not calendar-based)
- ETH: `msg.value` per call
- USDC: `transfer` / `transferFrom` amounts
- Only ETH and USDC spending allowed; other tokens rejected

## Security (Audit Fixes)

- **Free Spend fix:** Gas cost (when using Paymaster) is included in `validateUserOp` limit check *before* gas is paid. Prevents draining USDC via repeated failed transactions.
- **Strict selectors:** Only `IERC20.transfer` allowed on USDC (no `transferFrom`; reduces UX confusion and attack surface).
- **Configurable USDC_PER_ETH:** Set at deployment. Manual/operator-updated. No oracle.
- **Emergency withdraw:** `requestEmergencyWithdraw()` + `emergencyWithdraw()` with 48h timelock; only `vaultOwner`.
- **Window semantics:** Rolling windows re-anchor on first tx after expiry. Documented in LimitPolicy.

## Milestones

- **[INVARIANTS.md](./INVARIANTS.md)** – Explicit formal guarantees (accounting completeness, no bypass, vault isolation, batch atomicity).
- **Adversarial tests** – `SpendingAccountAdversarialTest` (bypass, grief, drain scenarios).
- **[COMPATIBILITY.md](./COMPATIBILITY.md)** – ERC-4337 bundler compatibility checklist.

## USDC Address (Base)

```
0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

## Setup

```bash
npm install
forge build
forge test
```

Dependencies (already in `lib/`): account-abstraction, forge-std. OpenZeppelin via npm.

## Deploy

```bash
forge script script/Deploy.s.sol --broadcast --rpc-url <RPC_URL> --private-key <PK>
```

Env vars (optional):

- `VAULT_OWNER` – EOA owner
- `USDC_PER_ETH` – ETH/USDC rate (6 decimals). Default 2000e6. Operator-updated, no oracle.
- `DAILY_ETH_LIMIT`, `MONTHLY_ETH_LIMIT`
- `DAILY_USDC_LIMIT`, `MONTHLY_USDC_LIMIT`

## Dependencies

- account-abstraction (ERC-4337)
- forge-std
- OpenZeppelin Contracts 5.1
