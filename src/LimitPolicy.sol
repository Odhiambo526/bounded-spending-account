// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LimitPolicy
 * @notice Minimal logic for rolling spending limits and window resets.
 * @dev Pure functions for validation and state updates. No storage.
 *
 * WINDOW SEMANTICS:
 * - Rolling windows: reset is anchored to the *first tx after expiry*.
 * - When nowTs >= lastReset + WINDOW, we set newReset = nowTs and zero the counter.
 * - Users can intentionally delay txs to "re-anchor" windows (e.g. extend spend capacity).
 * - This is acceptable and by design; no calendar-month locking.
 */
library LimitPolicy {
    /// @notice Rolling window: 24 hours in seconds
    uint256 internal constant DAILY_WINDOW = 24 hours;

    /// @notice Rolling window: 30 days in seconds
    uint256 internal constant MONTHLY_WINDOW = 30 days;

    error DailyLimitExceeded(uint256 current, uint256 limit);
    error MonthlyLimitExceeded(uint256 current, uint256 limit);

    /**
     * @notice Reset counters if their rolling windows have expired.
     * @param lastDailyReset Last timestamp when daily counters were reset.
     * @param lastMonthlyReset Last timestamp when monthly counters were reset.
     * @param nowTs Current block timestamp.
     * @return newDailyReset New lastDailyResetTimestamp (unchanged if window not expired).
     * @return newMonthlyReset New lastMonthlyResetTimestamp (unchanged if window not expired).
     * @return dailySpent Reset daily spent to 0 if window expired.
     * @return monthlySpent Reset monthly spent to 0 if window expired.
     */
    function maybeResetWindows(
        uint256 lastDailyReset,
        uint256 lastMonthlyReset,
        uint256 currentDailySpent,
        uint256 currentMonthlySpent,
        uint256 nowTs
    ) internal pure returns (
        uint256 newDailyReset,
        uint256 newMonthlyReset,
        uint256 dailySpent,
        uint256 monthlySpent
    ) {
        newDailyReset = lastDailyReset;
        newMonthlyReset = lastMonthlyReset;
        dailySpent = currentDailySpent;
        monthlySpent = currentMonthlySpent;

        if (nowTs >= lastDailyReset + DAILY_WINDOW) {
            newDailyReset = nowTs;
            dailySpent = 0;
        }
        if (nowTs >= lastMonthlyReset + MONTHLY_WINDOW) {
            newMonthlyReset = nowTs;
            monthlySpent = 0;
        }
    }

    /**
     * @notice Validate ETH spend against limits. Reverts if exceeded.
     */
    function validateEthSpend(
        uint256 dailySpent,
        uint256 monthlySpent,
        uint256 dailyLimit,
        uint256 monthlyLimit,
        uint256 amount
    ) internal pure {
        if (dailySpent + amount > dailyLimit) {
            revert DailyLimitExceeded(dailySpent + amount, dailyLimit);
        }
        if (monthlySpent + amount > monthlyLimit) {
            revert MonthlyLimitExceeded(monthlySpent + amount, monthlyLimit);
        }
    }

    /**
     * @notice Validate USDC spend against limits. Reverts if exceeded.
     */
    function validateUsdcSpend(
        uint256 dailySpent,
        uint256 monthlySpent,
        uint256 dailyLimit,
        uint256 monthlyLimit,
        uint256 amount
    ) internal pure {
        if (dailySpent + amount > dailyLimit) {
            revert DailyLimitExceeded(dailySpent + amount, dailyLimit);
        }
        if (monthlySpent + amount > monthlyLimit) {
            revert MonthlyLimitExceeded(monthlySpent + amount, monthlyLimit);
        }
    }
}
