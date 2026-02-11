> **⚠️ WARNING: These contracts are not safe for production use.** They have not been audited and may contain critical bugs or vulnerabilities. Use only for development, testing, or educational purposes. Do not deploy with real funds.

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
