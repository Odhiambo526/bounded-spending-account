# ERC-4337 Compatibility Checklist

This document specifies what must be verified for production deployment. Anvil simulation alone is insufficient; **bundler integration** is required for credibility.

---

## 1. Bundler Integration

### 1.1 Target

- **Network:** Base mainnet (or Base Sepolia for staging)
- **Bundler:** A public ERC-4337 bundler (e.g. Pimlico, Stackup, Biconomy, Alchemy)
- **EntryPoint:** Canonical `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)

### 1.2 Verification Steps

1. Deploy Paymaster, Factory, and a SpendingAccount on Base.
2. Fund the Paymaster's EntryPoint deposit.
3. Construct a UserOp with the account as sender.
4. Submit via the bundler's API (e.g. `eth_sendUserOperation`).
5. Confirm the UserOp is included and the transaction succeeds.

---

## 2. Execution Modes

### 2.1 Paymaster Enabled

| Check | Expected |
|-------|----------|
| UserOp has `paymasterAndData` set to our Paymaster | UserOp succeeds |
| Account has sufficient USDC for gas (with premium) | postOp succeeds, USDC transferred to Paymaster |
| Account has insufficient USDC | `validatePaymasterUserOp` reverts with `InsufficientUsdcBalance` |
| Gas cost exceeds `MAX_COST_CAP` (0.01 ether) | `validatePaymasterUserOp` reverts with `CostCapExceeded` |

### 2.2 Paymaster Disabled

| Check | Expected |
|-------|----------|
| UserOp has empty `paymasterAndData` | UserOp succeeds if account has sufficient EntryPoint deposit |
| Account has insufficient deposit | `validateUserOp` reverts or EntryPoint handles prefund |

---

## 3. Failure Modes (Must Fail Cleanly)

| Scenario | Failure Point | Expected Behavior |
|----------|---------------|-------------------|
| Limits exceeded (ETH or USDC) | `validateUserOp` (preflight) or `execute` | Revert with `DailyLimitExceeded` or `MonthlyLimitExceeded` |
| USDC insufficient for gas | `validatePaymasterUserOp` | Revert with `InsufficientUsdcBalance` |
| Gas cap exceeded | `validatePaymasterUserOp` | Revert with `CostCapExceeded` |
| Invalid signature | `validateUserOp` | Return `SIG_VALIDATION_FAILED` |
| Invalid callData (wrong selector) | `validateUserOp` (preflight) or `execute` | Revert with `InvalidTargetOrSelector` or `InvalidSelector` |

---

## 4. Test Matrix

| Paymaster | Limits | USDC Balance | Expected |
|-----------|--------|--------------|----------|
| Enabled | Within | Sufficient | Success |
| Enabled | Exceeded | Sufficient | Revert (preflight) |
| Enabled | Within | Insufficient | Revert (Paymaster validation) |
| Enabled | Within | Sufficient | Success (gas cap enforced) |
| Disabled | Within | N/A | Success (if deposit sufficient) |
| Disabled | Exceeded | N/A | Revert |

---

## 5. Credibility Statement

**Before claiming production readiness:**

- [ ] Tested against a public bundler on Base (or Base Sepolia)
- [ ] Paymaster-enabled path verified
- [ ] Paymaster-disabled path verified
- [ ] All failure modes confirmed to revert with expected errors
- [ ] No bundler-specific workarounds required

**Example:** *"Tested against [Bundler X] on Base Sepolia. Paymaster and non-Paymaster paths both succeed. Limit-exceeded and insufficient-USDC paths revert as expected."*

---

## 6. Out of Scope (MVP)

- Fuzzing
- Formal verification (e.g. Certora, Foundry invariants)
- Multi-chain deployment
- Other L2s (Arbitrum, etc.)
