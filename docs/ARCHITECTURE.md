# Smart Allowance Architecture

## Flow Diagram

```mermaid
flowchart LR
    subgraph User[" "]
        VO[Vault Owner<br/><small>Holds Main Funds</small>]
    end

    subgraph Account[" "]
        SA[SpendingAccount<br/><small>Bounded Wallet with Limits</small>]
    end

    subgraph ERC4337[" "]
        EP[EntryPoint<br/><small>Validation & Execution</small>]
    end

    subgraph Gas[" "]
        PM[Paymaster<br/><small>Pays Gas, Collects USDC</small>]
    end

    VO -->|creates| SA
    SA -->|1. Validate limits| EP
    SA -->|2. Execute call| EP
    EP -->|3. Success| PM
    PM -->|postOp: USDC| PM
```

## Component Roles

| Component | Role |
|-----------|------|
| **Vault Owner** | EOA that holds main funds; signs UserOperations |
| **SpendingAccount** | Smart account with hard ETH/USDC limits; limits enforced before execution |
| **EntryPoint** | ERC-4337 hub; validates and executes UserOps |
| **Paymaster** | Pays gas in ETH; collects USDC from SpendingAccount (5% premium) |

## Transaction Flow

1. **Vault Owner** signs a UserOperation (execute or executeBatch).
2. **Bundler** submits the UserOp to the **EntryPoint**.
3. **EntryPoint** calls `validateUserOp` on SpendingAccount → limits checked (ETH + USDC spend + gas cost).
4. **EntryPoint** executes the call on SpendingAccount.
5. **PostOp**: Paymaster calls `payForGasInUsdc` on SpendingAccount → USDC transferred to Paymaster.
6. Paymaster is reimbursed for gas; SpendingAccount’s USDC limit is updated.

Limits are enforced **before** execution and gas payment—no bypass possible.
