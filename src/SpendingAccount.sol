// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable reason-string */

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "account-abstraction/interfaces/IAccount.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "account-abstraction/interfaces/PackedUserOperation.sol";
import "account-abstraction/core/Helpers.sol";
import "account-abstraction/core/UserOperationLib.sol";
import "account-abstraction/utils/Exec.sol";
import "./LimitPolicy.sol";

/**
 * @title SpendingAccount
 * @notice ERC-4337 Smart Account with hard onchain spending limits (ETH + USDC only).
 * @dev Single vaultOwner (EOA). No upgradeability. No delegatecall. Reentrancy-safe.
 *      Gas cost (when using Paymaster) is factored into limits in validateUserOp to prevent "Free Spend" drain.
 *      Reentrancy: USDC is hardcoded (no ERC777 hooks). No callback paths. Safe by design.
 */
contract SpendingAccount is IAccount {
    using UserOperationLib for PackedUserOperation;

    /// @notice Base mainnet USDC (native Circle-issued). Hardcoded for Base only.
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Must match SpendingPaymaster. Set at deployment. Operator-updated (no oracle).
    uint256 public immutable usdcPerEth;
    uint256 private constant PREMIUM_BPS = 500; // 5%

    /// @notice Minimum paymasterAndData length for paymaster (addr + validationGas + postOpGas)
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;

    IEntryPoint public immutable entryPointContract;
    address public immutable vaultOwner;
    address public immutable paymasterAddress;

    uint256 public immutable dailyEthLimit;
    uint256 public immutable monthlyEthLimit;
    uint256 public immutable dailyUsdcLimit;
    uint256 public immutable monthlyUsdcLimit;

    uint256 public dailyEthSpent;
    uint256 public monthlyEthSpent;
    uint256 public dailyUsdcSpent;
    uint256 public monthlyUsdcSpent;
    uint256 public lastDailyResetTimestamp;
    uint256 public lastMonthlyResetTimestamp;

    uint256 public emergencyWithdrawRequestTime;
    uint256 private constant WITHDRAW_TIMELOCK = 48 hours;

    /// @notice Panic Cooldown: timestamp of last large spend (>50% of daily limit). Blocks further txs for 1 hour.
    uint256 public lastLargeSpendTime;
    uint256 private constant COOLDOWN_PERIOD = 1 hours;
    uint256 private constant PANIC_THRESHOLD_BPS = 5000; // 50%

    error NotFromEntryPoint();
    error NotFromPaymaster();
    error NotVaultOwner();
    error InvalidTargetOrSelector();
    error InvalidSelector();
    error WithdrawTimelockNotMet();
    error NoWithdrawRequested();
    error InsufficientGasForUsdcTransfer(uint256 gasLeft, uint256 minRequired);
    error LargeSpendCooldownActive();

    event EthSpent(uint256 amount);
    event UsdcSpent(uint256 amount);
    event EmergencyWithdrawRequested();
    event EmergencyWithdrawExecuted(address to, uint256 ethAmount, uint256 usdcAmount);

    constructor(
        IEntryPoint _entryPoint,
        address _vaultOwner,
        address _paymaster,
        uint256 _usdcPerEth,
        uint256 _dailyEthLimit,
        uint256 _monthlyEthLimit,
        uint256 _dailyUsdcLimit,
        uint256 _monthlyUsdcLimit
    ) {
        entryPointContract = _entryPoint;
        vaultOwner = _vaultOwner;
        paymasterAddress = _paymaster;
        usdcPerEth = _usdcPerEth;
        dailyEthLimit = _dailyEthLimit;
        monthlyEthLimit = _monthlyEthLimit;
        dailyUsdcLimit = _dailyUsdcLimit;
        monthlyUsdcLimit = _monthlyUsdcLimit;
        lastDailyResetTimestamp = block.timestamp;
        lastMonthlyResetTimestamp = block.timestamp;
    }

    receive() external payable {}

    /// @inheritdoc IAccount
    /// @dev Preflight: validates (execute spend + gas cost) against limits BEFORE gas is paid. Prevents "Free Spend" drain.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        if (msg.sender != address(entryPointContract)) revert NotFromEntryPoint();
        validationData = _validateSignature(userOp, userOpHash);
        (uint256 ethSpend, uint256 usdcSpend) = _parseSpendAmountsFromCallData(userOp.callData);
        uint256 usdcGasCost = _getUsdcGasCostIfPaymaster(userOp);
        _validatePreflightLimits(ethSpend, usdcSpend + usdcGasCost);
        _payPrefund(missingAccountFunds);
    }

    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view returns (uint256) {
        address recovered = ECDSA.recover(userOpHash, userOp.signature);
        if (recovered != vaultOwner) return SIG_VALIDATION_FAILED;
        return SIG_VALIDATION_SUCCESS;
    }

    /// @notice Projected gas cost in USDC if this UserOp uses our Paymaster. Returns 0 otherwise.
    function _getUsdcGasCostIfPaymaster(PackedUserOperation calldata userOp) internal view returns (uint256) {
        if (userOp.paymasterAndData.length < PAYMASTER_DATA_OFFSET) return 0;
        address pm = address(bytes20(userOp.paymasterAndData[:20]));
        if (pm != paymasterAddress) return 0;
        uint256 verificationGasLimit = userOp.unpackVerificationGasLimit();
        uint256 callGasLimit = userOp.unpackCallGasLimit();
        uint256 validationGasLimit = uint128(bytes16(userOp.paymasterAndData[20:36]));
        uint256 postOpGasLimit = uint128(bytes16(userOp.paymasterAndData[36:52]));
        uint256 requiredGas = userOp.preVerificationGas + verificationGasLimit + callGasLimit
            + validationGasLimit + postOpGasLimit;
        uint256 maxCostEth = requiredGas * userOp.gasPrice();
        uint256 costWithPremium = maxCostEth + (maxCostEth * PREMIUM_BPS / 10000);
        return costWithPremium * usdcPerEth / 1e18;
    }

    /// @notice Parse callData (execute or executeBatch) and return total ETH + USDC spend. View only.
    function _parseSpendAmountsFromCallData(bytes calldata callData) internal pure returns (uint256 ethSpend, uint256 usdcSpend) {
        if (callData.length < 4) return (0, 0);
        bytes4 selector = bytes4(callData[:4]);
        if (selector == this.execute.selector) {
            (address target, uint256 value, bytes memory data) = abi.decode(callData[4:], (address, uint256, bytes));
            (uint256 e, uint256 u) = _parseSpendAmounts(target, value, data);
            return (e, u);
        }
        if (selector == this.executeBatch.selector) {
            Call[] memory calls = abi.decode(callData[4:], (Call[]));
            for (uint256 i = 0; i < calls.length; i++) {
                (uint256 e, uint256 u) = _parseSpendAmounts(calls[i].target, calls[i].value, calls[i].data);
                ethSpend += e;
                usdcSpend += u;
            }
            return (ethSpend, usdcSpend);
        }
        revert InvalidTargetOrSelector();
    }

    /// @notice Validate limits without updating state. Used in validateUserOp preflight.
    /// @dev Panic Cooldown: if spend >50% of daily limit, enforces 1h cooldown before any further tx.
    function _validatePreflightLimits(uint256 ethSpend, uint256 usdcSpend) internal {
        uint256 nowTs = block.timestamp;
        (, , uint256 dailyEth, uint256 monthlyEth) = LimitPolicy.maybeResetWindows(
            lastDailyResetTimestamp, lastMonthlyResetTimestamp, dailyEthSpent, monthlyEthSpent, nowTs
        );
        (, , uint256 dailyUsdc, uint256 monthlyUsdc) = LimitPolicy.maybeResetWindows(
            lastDailyResetTimestamp, lastMonthlyResetTimestamp, dailyUsdcSpent, monthlyUsdcSpent, nowTs
        );
        if (ethSpend > 0) {
            LimitPolicy.validateEthSpend(dailyEth, monthlyEth, dailyEthLimit, monthlyEthLimit, ethSpend);
        }
        if (usdcSpend > 0) {
            LimitPolicy.validateUsdcSpend(dailyUsdc, monthlyUsdc, dailyUsdcLimit, monthlyUsdcLimit, usdcSpend);
        }

        _checkAndUpdatePanicCooldown(ethSpend, usdcSpend);
    }

    /// @notice Convert ETH amount to USDC-equivalent value using operator-set rate.
    function _getUsdValue(uint256 ethAmount) internal view returns (uint256) {
        return ethAmount * usdcPerEth / 1e18;
    }

    /// @notice Panic Cooldown: if spend >50% of daily limit, enforce 1h cooldown before *any* further tx.
    function _checkAndUpdatePanicCooldown(uint256 ethAmount, uint256 usdcAmount) internal {
        if (lastLargeSpendTime != 0 && block.timestamp < lastLargeSpendTime + COOLDOWN_PERIOD) {
            revert LargeSpendCooldownActive();
        }
        uint256 totalUsdValue = _getUsdValue(ethAmount) + usdcAmount;
        if (totalUsdValue > (dailyUsdcLimit * PANIC_THRESHOLD_BPS) / 10000) {
            lastLargeSpendTime = block.timestamp;
        }
    }

    /// @dev Sends missing prefund to EntryPoint (msg.sender). EntryPoint expects this for gas.
    ///      Only called when account pays its own gas (no paymaster). No arbitrary ETH drain.
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds}("");
            (success);
        }
    }

    /// @notice Execute a single call. Only ETH and USDC spending allowed.
    /// @param target Target contract.
    /// @param value ETH to send.
    /// @param data Calldata.
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external {
        if (msg.sender != address(entryPointContract)) revert NotFromEntryPoint();
        _validateAndRecordSpend(target, value, data);
        _doCall(target, value, data);
    }

    /// @notice Execute a batch of calls. Each call must be valid; total spend checked per-type.
    /// @dev Batch execution is all-or-nothing. Spend counters updated once before any call.
    ///      If any call reverts, the entire batch reverts; no partial spend is recorded.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function executeBatch(Call[] calldata calls) external {
        if (msg.sender != address(entryPointContract)) revert NotFromEntryPoint();
        uint256 totalEth = 0;
        uint256 totalUsdc = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            (uint256 ethAmount, uint256 usdcAmount) = _parseSpendAmounts(
                calls[i].target,
                calls[i].value,
                bytes(calls[i].data)
            );
            totalEth += ethAmount;
            totalUsdc += usdcAmount;
        }
        _checkAndUpdatePanicCooldown(totalEth, totalUsdc);
        _applySpendAndUpdate(totalEth, totalUsdc);
        for (uint256 i = 0; i < calls.length; i++) {
            Call calldata c = calls[i];
            _doCall(c.target, c.value, c.data);
        }
    }

    /// @notice Minimum gas for USDC transfer. EIP-150 forwards 63/64 to sub-call; transfer needs ~50–80k.
    uint256 private constant MIN_GAS_FOR_USDC_TRANSFER = 60_000;

    /// @notice Pay for gas in USDC. Callable only by the configured paymaster.
    function payForGasInUsdc(uint256 amount) external {
        if (msg.sender != paymasterAddress) revert NotFromPaymaster();
        if (gasleft() < MIN_GAS_FOR_USDC_TRANSFER) {
            revert InsufficientGasForUsdcTransfer(gasleft(), MIN_GAS_FOR_USDC_TRANSFER);
        }
        _applyUsdcSpend(amount);
        bool ok = Exec.call(
            USDC,
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, paymasterAddress, amount),
            gasleft()
        );
        if (!ok) Exec.revertWithReturnData();
    }

    function _validateAndRecordSpend(
        address target,
        uint256 value,
        bytes calldata data
    ) internal {
        (uint256 ethAmount, uint256 usdcAmount) = _parseSpendAmounts(target, value, bytes(data));
        _checkAndUpdatePanicCooldown(ethAmount, usdcAmount);
        _applySpendAndUpdate(ethAmount, usdcAmount);
    }

    /// @notice Strict selector: only transfer(address,uint256). No transferFrom (reduces UX confusion).
    function _parseSpendAmounts(
        address target,
        uint256 value,
        bytes memory data
    ) internal pure returns (uint256 ethAmount, uint256 usdcAmount) {
        if (value > 0) ethAmount = value;
        if (target == USDC) {
            if (value > 0) revert InvalidTargetOrSelector(); // ETH to USDC would be burned
            if (data.length < 4) revert InvalidSelector();
            bytes4 selector;
            assembly {
                selector := shr(224, mload(add(data, 0x24)))
            }
            if (selector == IERC20.transfer.selector) {
                if (data.length < 68) revert InvalidSelector();
                (, uint256 amount) = abi.decode(_slice(data, 4), (address, uint256));
                usdcAmount = amount;
            } else {
                revert InvalidSelector();
            }
        } else if (value == 0) {
            revert InvalidTargetOrSelector();
        }
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        bytes memory result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    function _applySpendAndUpdate(uint256 ethAmount, uint256 usdcAmount) internal {
        uint256 nowTs = block.timestamp;
        (
            uint256 newDailyReset,
            uint256 newMonthlyReset,
            uint256 dailyEth,
            uint256 monthlyEth
        ) = LimitPolicy.maybeResetWindows(
            lastDailyResetTimestamp,
            lastMonthlyResetTimestamp,
            dailyEthSpent,
            monthlyEthSpent,
            nowTs
        );

        (
            ,
            ,
            uint256 dailyUsdc,
            uint256 monthlyUsdc
        ) = LimitPolicy.maybeResetWindows(
            newDailyReset,
            newMonthlyReset,
            dailyUsdcSpent,
            monthlyUsdcSpent,
            nowTs
        );

        if (ethAmount > 0) {
            LimitPolicy.validateEthSpend(
                dailyEth,
                monthlyEth,
                dailyEthLimit,
                monthlyEthLimit,
                ethAmount
            );
            dailyEthSpent = dailyEth + ethAmount;
            monthlyEthSpent = monthlyEth + ethAmount;
            emit EthSpent(ethAmount);
        }
        if (usdcAmount > 0) {
            LimitPolicy.validateUsdcSpend(
                dailyUsdc,
                monthlyUsdc,
                dailyUsdcLimit,
                monthlyUsdcLimit,
                usdcAmount
            );
            dailyUsdcSpent = dailyUsdc + usdcAmount;
            monthlyUsdcSpent = monthlyUsdc + usdcAmount;
            emit UsdcSpent(usdcAmount);
        }

        lastDailyResetTimestamp = newDailyReset;
        lastMonthlyResetTimestamp = newMonthlyReset;
    }

    function _applyUsdcSpend(uint256 amount) internal {
        uint256 nowTs = block.timestamp;
        (
            uint256 newDailyReset,
            uint256 newMonthlyReset,
            ,
        ) = LimitPolicy.maybeResetWindows(
            lastDailyResetTimestamp,
            lastMonthlyResetTimestamp,
            dailyEthSpent,
            monthlyUsdcSpent,
            nowTs
        );

        (
            ,
            ,
            uint256 dailyUsdc,
            uint256 monthlyUsdc
        ) = LimitPolicy.maybeResetWindows(
            newDailyReset,
            newMonthlyReset,
            dailyUsdcSpent,
            monthlyUsdcSpent,
            nowTs
        );

        LimitPolicy.validateUsdcSpend(
            dailyUsdc,
            monthlyUsdc,
            dailyUsdcLimit,
            monthlyUsdcLimit,
            amount
        );
        dailyUsdcSpent = dailyUsdc + amount;
        monthlyUsdcSpent = monthlyUsdc + amount;
        lastDailyResetTimestamp = newDailyReset;
        lastMonthlyResetTimestamp = newMonthlyReset;
        emit UsdcSpent(amount);
    }

    function _doCall(address target, uint256 value, bytes calldata data) internal {
        bool ok = Exec.call(target, value, data, gasleft());
        if (!ok) Exec.revertWithReturnData();
    }

    function getDeposit() external view returns (uint256) {
        return entryPointContract.balanceOf(address(this));
    }

    function addDeposit() external payable {
        entryPointContract.depositTo{value: msg.value}(address(this));
    }

    /// @notice Request emergency withdraw. Only vaultOwner. Starts 48h timelock.
    function requestEmergencyWithdraw() external {
        if (msg.sender != vaultOwner) revert NotVaultOwner();
        emergencyWithdrawRequestTime = block.timestamp;
        emit EmergencyWithdrawRequested();
    }

    /// @notice Execute emergency withdraw after 48h. Only vaultOwner. Sends all ETH and USDC to recipient.
    /// @param recipient Address to receive the funds.
    function emergencyWithdraw(address payable recipient) external {
        if (msg.sender != vaultOwner) revert NotVaultOwner();
        if (emergencyWithdrawRequestTime == 0) revert NoWithdrawRequested();
        if (block.timestamp < emergencyWithdrawRequestTime + WITHDRAW_TIMELOCK) {
            revert WithdrawTimelockNotMet();
        }
        emergencyWithdrawRequestTime = 0;

        uint256 ethAmount = address(this).balance;
        if (ethAmount > 0) {
            (bool ok,) = recipient.call{value: ethAmount}("");
            if (!ok) revert();
        }

        uint256 usdcAmount = 0;
        if (USDC.code.length > 0) {
            usdcAmount = IERC20(USDC).balanceOf(address(this));
            if (usdcAmount > 0) {
                bool ok = IERC20(USDC).transfer(recipient, usdcAmount);
                if (!ok) revert();
            }
        }

        emit EmergencyWithdrawExecuted(recipient, ethAmount, usdcAmount);
    }
}
