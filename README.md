> **⚠️ WARNING: The contracts have not been audited and may contain bugs or vulnerabilities.**

Most crypto wallets give **one key full control over all funds**, so if that key is stolen or a mistake is made, **everything can be lost at once**, which makes people afraid to use crypto for everyday spending.

![Smart Allowance Architecture](docs/architecture.png)
This code solves that by creating a **separate spending wallet with hard, on-chain daily and monthly limits**, so even if the spending wallet is compromised, **the maximum possible loss is strictly capped** and the main vault remains safe.
It also enforces these limits **before execution and gas payment**, ensuring no transaction can bypass the protections or silently drain funds.

## Setup

```bash
npm install
forge build
forge test
```

Dependencies (already in `lib/`): account-abstraction, forge-std. OpenZeppelin via npm.

