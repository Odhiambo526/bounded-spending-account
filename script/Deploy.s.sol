// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "account-abstraction/core/EntryPoint.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "../src/SpendingAccount.sol";
import "../src/SpendingAccountFactory.sol";
import "../src/SpendingPaymaster.sol";

/**
 * @title Deploy
 * @notice Deploys EntryPoint (if needed), SpendingAccountFactory, Paymaster, and optionally a SpendingAccount.
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            revert("PRIVATE_KEY must be set in .env");
        }
        address deployer = vm.addr(deployerPrivateKey);
        address vaultOwner = vm.envOr("VAULT_OWNER", deployer);
        uint256 dailyEthLimit = vm.envOr("DAILY_ETH_LIMIT", uint256(0.1 ether));
        uint256 monthlyEthLimit = vm.envOr("MONTHLY_ETH_LIMIT", uint256(2 ether));
        uint256 dailyUsdcLimit = vm.envOr("DAILY_USDC_LIMIT", uint256(500e6));
        uint256 monthlyUsdcLimit = vm.envOr("MONTHLY_USDC_LIMIT", uint256(10000e6));
        uint256 usdcPerEth = vm.envOr("USDC_PER_ETH", uint256(2000e6)); // 1 ETH = 2000 USDC (6 decimals). Operator-updated.

        // Fund deployer for paymaster deposit (local/anvil simulation)
        if (block.chainid == 31337) {
            vm.deal(deployer, 100 ether);
        }

        vm.startBroadcast(deployerPrivateKey);

        // Deploy EntryPoint for compatibility with our account-abstraction lib. Use canonical on mainnet if desired.
        EntryPoint ep = new EntryPoint();
        IEntryPoint entryPoint = IEntryPoint(address(ep));

        SpendingPaymaster paymaster = new SpendingPaymaster(entryPoint, usdcPerEth);
        uint256 defaultDeposit = block.chainid == 31337 ? 0.1 ether : 0.01 ether;
        uint256 paymasterDeposit = vm.envOr("PAYMASTER_DEPOSIT", defaultDeposit);
        if (paymasterDeposit > 0) {
            paymaster.deposit{value: paymasterDeposit}();
        }

        SpendingAccountFactory factory = new SpendingAccountFactory(
            entryPoint,
            address(paymaster),
            usdcPerEth
        );

        SpendingAccount account = factory.createAccount(
            vaultOwner,
            dailyEthLimit,
            monthlyEthLimit,
            dailyUsdcLimit,
            monthlyUsdcLimit,
            bytes32(uint256(1))
        );

        vm.stopBroadcast();

        console.log("EntryPoint:", address(entryPoint));
        console.log("Paymaster:", address(paymaster));
        console.log("Factory:", address(factory));
        console.log("SpendingAccount:", address(account));
    }
}
