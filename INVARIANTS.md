# SpendingAccount Invariants

These invariants are the formal guarantees that make the compromise of a SpendingAccount **non-catastrophic**. They must hold for all execution paths.

---

## Invariant 1: Accounting Completeness

**Total ETH + USDC spend recorded ≥ actual value transferred + gas paid**

- Every ETH transfer (`msg.value`) is counted in `dailyEthSpent` and `monthlyEthSpent` before the call executes.
- Every USDC transfer is counted in `dailyUsdcSpent` and `monthlyUsdcSpent` before the call executes.
- Gas paid in USDC (via `payForGasInUsdc`) is counted in `dailyUsdcSpent` and `monthlyUsdcSpent` before the transfer executes.
- There is no execution path that transfers ETH or USDC without first updating spend counters.
- **Proof sketch:** `execute` and `executeBatch` call `_validateAndRecordSpend` (or equivalent) before `_doCall`. `payForGasInUsdc` calls `_applyUsdcSpend` before the USDC transfer. All three update counters before any external transfer.

---

## Invariant 2: No Bypass Path

**No execution path allows ETH or USDC transfer without passing limit checks**

- `execute` and `executeBatch` validate limits via `_applySpendAndUpdate` before any call.
- `validateUserOp` validates limits (including projected gas cost) via `_validatePreflightLimits` before the EntryPoint pays gas.
- `payForGasInUsdc` validates limits via `_applyUsdcSpend` before the USDC transfer.
- Only allowed operations: ETH sends (any target, `value > 0`) and USDC `transfer` (target = USDC). All other paths revert.
- **Proof sketch:** EntryPoint is the only caller of `execute` and `executeBatch`. Paymaster is the only caller of `payForGasInUsdc`. All entry points enforce limits before transferring value.

---

## Invariant 3: Vault Isolation

**Compromise of SpendingAccount cannot affect vaultOwner funds**

- The vault (EOA) is not implemented in this contract. Funds in the vault are outside the SpendingAccount.
- The SpendingAccount holds only what is sent to it (ETH) or transferred to it (USDC).
- The `vaultOwner` is immutable; no key rotation in this MVP.
- The SpendingAccount cannot pull from the vault. The vault can only push to the SpendingAccount (or approve USDC).
- **Proof sketch:** No `delegatecall`. No upgrade. No admin backdoors. No `transferFrom` without prior approval. Loss is bounded by (1) what the account holds and (2) the spending limits.

---

## Invariant 4: Batch Atomicity

**Batch execution is atomic with respect to spend accounting**

- For `executeBatch`, total ETH and total USDC are computed and validated against limits **once** before any call executes.
- If any call in the batch reverts, the entire batch reverts. No partial spend is recorded.
- Counters are updated in a single `_applySpendAndUpdate` before the loop of `_doCall`.
- **Proof sketch:** `_applySpendAndUpdate(totalEth, totalUsdc)` runs first. If it succeeds, counters are updated. Then calls execute sequentially. If a call reverts, the transaction reverts; state changes (including counter updates) are rolled back. So either all succeed or none do.

---

## Violation Conditions (What Would Break These)

| Invariant | Violation would require |
|-----------|-------------------------|
| 1 | A transfer that does not go through `_applySpendAndUpdate` or `_applyUsdcSpend` |
| 2 | A call path that transfers ETH/USDC without hitting limit checks |
| 3 | A way for the SpendingAccount to pull from the vault or an upgrade path |
| 4 | Partial counter update with some calls succeeding and some failing |

---

## Relation to "Non-Catastrophic Compromise"

- **Invariant 1 + 2:** Limits are real. You cannot spend more than allowed.
- **Invariant 3:** Attacker gains only what the SpendingAccount holds and what limits allow.
- **Invariant 4:** No inconsistent state from partial batch execution.

Together, these guarantee: *compromise of the SpendingAccount key cannot drain the vault or exceed the configured limits.*
