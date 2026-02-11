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

contract SpendingAccountTest is Test {
    EntryPoint entryPoint;
    SpendingPaymaster paymaster;
    SpendingAccountFactory factory;
    SpendingAccount account;

    address vaultOwner;
    uint256 constant DAILY_ETH = 1 ether;
    uint256 constant MONTHLY_ETH = 10 ether;
    uint256 constant DAILY_USDC = 1000e6;
    uint256 constant MONTHLY_USDC = 10000e6;

    uint256 constant USDC_PER_ETH = 2000e6;

    function setUp() public {
        vaultOwner = makeAddr("vaultOwner");
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

    function test_LimitsEnforced() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                LimitPolicy.DailyLimitExceeded.selector,
                2 ether,
                DAILY_ETH
            )
        );
        account.execute(
            payable(address(0x1)),
            2 ether,
            ""
        );
    }

    function test_EthSpendWithinLimit() public {
        address recipient = makeAddr("recipient");
        uint256 before = recipient.balance;
        vm.prank(address(entryPoint));
        account.execute(payable(recipient), 0.5 ether, "");
        assertEq(recipient.balance - before, 0.5 ether);
        assertEq(account.dailyEthSpent(), 0.5 ether);
    }

    function test_InvalidTargetReverts() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(SpendingAccount.InvalidTargetOrSelector.selector);
        account.execute(address(0x1), 0, abi.encodeWithSelector(bytes4(0xdeadbeef)));
    }

    function test_TransferFromReverts() public {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        vm.prank(address(entryPoint));
        vm.expectRevert(SpendingAccount.InvalidSelector.selector);
        account.execute(
            usdc,
            0,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(0x1), address(0x2), 100e6)
        );
    }

    function test_EmergencyWithdraw() public {
        vm.startPrank(vaultOwner);
        account.requestEmergencyWithdraw();
        vm.warp(block.timestamp + 49 hours);
        address recipient = makeAddr("recipient");
        uint256 balBefore = recipient.balance;
        account.emergencyWithdraw(payable(recipient));
        assertEq(recipient.balance - balBefore, 5 ether);
        vm.stopPrank();
    }

    function test_EmergencyWithdrawRevertsBeforeTimelock() public {
        vm.prank(vaultOwner);
        account.requestEmergencyWithdraw();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(vaultOwner);
        vm.expectRevert(SpendingAccount.WithdrawTimelockNotMet.selector);
        account.emergencyWithdraw(payable(vaultOwner));
    }
}
