// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/SpendingAccount.sol";
import "../src/SpendingAccountFactory.sol";
import "../src/SpendingPaymaster.sol";
import "../src/LimitPolicy.sol";
import "account-abstraction/core/EntryPoint.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";

/**
 * @title SpendingAccountAdversarialTest
 * @notice Adversarial tests: "We tested this as an attacker, not as a happy-path user."
 * @dev Tests bypass attempts, grief vectors, and drain scenarios.
 */
contract SpendingAccountAdversarialTest is Test {
    EntryPoint entryPoint;
    SpendingPaymaster paymaster;
    SpendingAccountFactory factory;
    SpendingAccount account;

    address vaultOwner;
    address attacker;
    uint256 constant DAILY_ETH = 1 ether;
    uint256 constant MONTHLY_ETH = 10 ether;
    uint256 constant DAILY_USDC = 1000e6;
    uint256 constant MONTHLY_USDC = 10000e6;
    uint256 constant USDC_PER_ETH = 2000e6;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function setUp() public {
        vaultOwner = makeAddr("vaultOwner");
        attacker = makeAddr("attacker");
        entryPoint = new EntryPoint();
        paymaster = new SpendingPaymaster(IEntryPoint(address(entryPoint)), USDC_PER_ETH);
        factory = new SpendingAccountFactory(IEntryPoint(address(entryPoint)), address(paymaster), USDC_PER_ETH);

        vm.deal(address(paymaster), 10 ether);
        paymaster.deposit{value: 5 ether}();

        account = factory.createAccount(
            vaultOwner,
            DAILY_ETH,
            MONTHLY_ETH,
            DAILY_USDC,
            MONTHLY_USDC,
            bytes32(uint256(1))
        );
        vm.deal(address(account), 5 ether);
    }

    // ========== BYPASS LIMITS ==========

    /// @notice Attacker tries to bypass limits via executeBatch ordering (e.g. first call under limit, second exceeds)
    function test_Adversarial_BatchOrderingCannotBypassLimits() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(LimitPolicy.DailyLimitExceeded.selector, 1.5 ether, DAILY_ETH)
        );
        SpendingAccount.Call[] memory calls = new SpendingAccount.Call[](2);
        calls[0] = SpendingAccount.Call({target: payable(address(0x1)), value: 0.5 ether, data: ""});
        calls[1] = SpendingAccount.Call({target: payable(address(0x2)), value: 1 ether, data: ""});
        account.executeBatch(calls);
    }

    /// @notice Attacker tries zero-value ETH call with USDC calldata (malformed)
    function test_Adversarial_ZeroValueWithUsdcCalldataReverts() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(SpendingAccount.InvalidTargetOrSelector.selector);
        account.execute(
            address(0x1),
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, attacker, 100e6)
        );
    }

    /// @notice Attacker tries to call USDC with approve (not transfer) - rejected
    function test_Adversarial_UsdcApproveRejected() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(SpendingAccount.InvalidSelector.selector);
        account.execute(
            USDC,
            0,
            abi.encodeWithSelector(IERC20.approve.selector, attacker, type(uint256).max)
        );
    }

    /// @notice ETH send to USDC contract would burn ETH - rejected
    function test_Adversarial_EthToUsdcReverts() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(SpendingAccount.InvalidTargetOrSelector.selector);
        account.execute(
            USDC,
            1 ether,
            abi.encodeWithSelector(IERC20.transfer.selector, attacker, 100e6)
        );
    }

    /// @notice Direct call (not from EntryPoint) cannot execute
    function test_Adversarial_BypassEntryPointCannotExecute() public {
        vm.prank(attacker);
        vm.expectRevert(SpendingAccount.NotFromEntryPoint.selector);
        account.execute(payable(attacker), 0.5 ether, "");
    }

    /// @notice Non-owner cannot call payForGasInUsdc
    function test_Adversarial_NonPaymasterCannotCallPayForGas() public {
        vm.prank(attacker);
        vm.expectRevert(SpendingAccount.NotFromPaymaster.selector);
        account.payForGasInUsdc(100e6);
    }

    // ========== GRIEF ==========

    /// @notice Attacker tries to grief via repeated window reset edge timing
    function test_Adversarial_WindowResetEdgeTiming_CannotExceedLimit() public {
        vm.prank(address(entryPoint));
        account.execute(payable(attacker), 0.5 ether, "");
        assertEq(account.dailyEthSpent(), 0.5 ether);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(address(entryPoint));
        account.execute(payable(attacker), 0.5 ether, "");
        assertEq(account.dailyEthSpent(), 0.5 ether);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(LimitPolicy.DailyLimitExceeded.selector, 1.5 ether, DAILY_ETH)
        );
        account.execute(payable(attacker), 1.5 ether, "");
    }

    /// @notice Non-vaultOwner cannot request emergency withdraw
    function test_Adversarial_NonOwnerCannotRequestEmergencyWithdraw() public {
        vm.prank(attacker);
        vm.expectRevert(SpendingAccount.NotVaultOwner.selector);
        account.requestEmergencyWithdraw();
    }

    /// @notice Non-vaultOwner cannot execute emergency withdraw even after timelock
    function test_Adversarial_NonOwnerCannotEmergencyWithdraw() public {
        vm.prank(vaultOwner);
        account.requestEmergencyWithdraw();
        vm.warp(block.timestamp + 49 hours);
        vm.prank(attacker);
        vm.expectRevert(SpendingAccount.NotVaultOwner.selector);
        account.emergencyWithdraw(payable(attacker));
    }

    // ========== DRAIN ==========

    /// @notice Attacker cannot execute emergency withdraw before timelock
    function test_Adversarial_EmergencyWithdrawBeforeTimelock() public {
        vm.prank(vaultOwner);
        account.requestEmergencyWithdraw();
        vm.warp(block.timestamp + 47 hours);
        vm.prank(vaultOwner);
        vm.expectRevert(SpendingAccount.WithdrawTimelockNotMet.selector);
        account.emergencyWithdraw(payable(vaultOwner));
    }

    /// @notice Request can be overwritten by owner (new request resets timer)
    function test_Adversarial_EmergencyWithdrawRequestReset() public {
        vm.startPrank(vaultOwner);
        account.requestEmergencyWithdraw();
        vm.warp(block.timestamp + 24 hours);
        account.requestEmergencyWithdraw();
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(SpendingAccount.WithdrawTimelockNotMet.selector);
        account.emergencyWithdraw(payable(vaultOwner));
        vm.stopPrank();
    }

    /// @notice Batch partial failure: if second call reverts, first does not apply
    function test_Adversarial_BatchPartialFailureRevertsAll() public {
        SpendingAccount.Call[] memory calls = new SpendingAccount.Call[](2);
        calls[0] = SpendingAccount.Call({target: payable(address(0x1)), value: 0.5 ether, data: ""});
        calls[1] = SpendingAccount.Call({
            target: address(0xDEAD),
            value: 0,
            data: abi.encodeWithSelector(bytes4(0xdeadbeef))
        });
        vm.prank(address(entryPoint));
        vm.expectRevert();
        account.executeBatch(calls);
        assertEq(account.dailyEthSpent(), 0);
    }

    /// @notice Attacker cannot execute without passing through EntryPoint
    function test_Adversarial_CannotExecuteBatchDirectly() public {
        vm.prank(attacker);
        vm.expectRevert(SpendingAccount.NotFromEntryPoint.selector);
        SpendingAccount.Call[] memory calls = new SpendingAccount.Call[](1);
        calls[0] = SpendingAccount.Call({target: payable(attacker), value: 1 ether, data: ""});
        account.executeBatch(calls);
    }

    /// @notice Prefund: addDeposit sends to EntryPoint only; no arbitrary recipient
    function test_Adversarial_AddDepositOnlyFundsEntryPoint() public {
        uint256 epBalanceBefore = entryPoint.balanceOf(address(account));
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        account.addDeposit{value: 1 ether}();
        assertEq(entryPoint.balanceOf(address(account)) - epBalanceBefore, 1 ether);
        assertEq(address(account).balance, 5 ether);
    }
}
