// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/core/Helpers.sol";
import "account-abstraction/core/UserOperationLib.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SpendingAccount.sol";

/**
 * @title SpendingPaymaster
 * @notice ERC-4337 Paymaster: accepts USDC from SpendingAccount, pays gas in ETH.
 * @dev Fixed +5% premium. Hard per-tx cost cap. No oracles.
 */
contract SpendingPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;

    /// @notice Base mainnet USDC. Must match SpendingAccount.
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Premium: 5% on gas cost
    uint256 private constant PREMIUM_BPS = 500; // 5%

    /// @notice ETH/USDC rate (6 decimals). Set at deployment. Manual/operator-updated. No oracle.
    uint256 public immutable usdcPerEth;

    /// @notice Max cost per tx (ETH wei). Hard cap.
    uint256 public constant MAX_COST_CAP = 0.01 ether;

    error CostCapExceeded(uint256 maxCost, uint256 cap);
    error InsufficientUsdcBalance(address account, uint256 required);

    constructor(IEntryPoint _entryPoint, uint256 _usdcPerEth) BasePaymaster(_entryPoint) {
        usdcPerEth = _usdcPerEth;
    }

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) internal view override returns (bytes memory context, uint256 validationData) {
        if (maxCost > MAX_COST_CAP) {
            revert CostCapExceeded(maxCost, MAX_COST_CAP);
        }
        uint256 costWithPremium = maxCost + (maxCost * PREMIUM_BPS / 10000);
        uint256 costInUsdc = costWithPremium * usdcPerEth / 1e18;
        address account = userOp.sender;
        uint256 balance = IERC20(USDC).balanceOf(account);
        if (balance < costInUsdc) {
            revert InsufficientUsdcBalance(account, costInUsdc);
        }
        context = abi.encode(account);
        return (context, SIG_VALIDATION_SUCCESS);
    }

    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        (mode, actualUserOpFeePerGas);
        address account = abi.decode(context, (address));
        uint256 costWithPremium = actualGasCost + (actualGasCost * PREMIUM_BPS / 10000);
        uint256 costInUsdc = costWithPremium * usdcPerEth / 1e18;
        SpendingAccount(payable(account)).payForGasInUsdc(costInUsdc);
    }
}
