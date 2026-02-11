// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Create2.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "./SpendingAccount.sol";

/**
 * @title SpendingAccountFactory
 * @notice Factory for deploying SpendingAccount instances. No proxies. Uses Create2 for deterministic addresses.
 */
contract SpendingAccountFactory {
    IEntryPoint public immutable entryPoint;
    address public immutable paymaster;
    uint256 public immutable usdcPerEth;

    constructor(IEntryPoint _entryPoint, address _paymaster, uint256 _usdcPerEth) {
        entryPoint = _entryPoint;
        paymaster = _paymaster;
        usdcPerEth = _usdcPerEth;
    }

    function createAccount(
        address vaultOwner,
        uint256 dailyEthLimit,
        uint256 monthlyEthLimit,
        uint256 dailyUsdcLimit,
        uint256 monthlyUsdcLimit,
        bytes32 salt
    ) external returns (SpendingAccount account) {
        account = new SpendingAccount{salt: salt}(
            entryPoint,
            vaultOwner,
            paymaster,
            usdcPerEth,
            dailyEthLimit,
            monthlyEthLimit,
            dailyUsdcLimit,
            monthlyUsdcLimit
        );
    }

    function getAddress(
        address vaultOwner,
        uint256 dailyEthLimit,
        uint256 monthlyEthLimit,
        uint256 dailyUsdcLimit,
        uint256 monthlyUsdcLimit,
        bytes32 salt
    ) external view returns (address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(SpendingAccount).creationCode,
                    abi.encode(
                        entryPoint,
                        vaultOwner,
                        paymaster,
                        usdcPerEth,
                        dailyEthLimit,
                        monthlyEthLimit,
                        dailyUsdcLimit,
                        monthlyUsdcLimit
                    )
                )
            )
        );
    }
}
