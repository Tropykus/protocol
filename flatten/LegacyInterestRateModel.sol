// Root file: contracts/LegacyInterestRateModel.sol

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.6;

/**
 * @title tropykus Legacy InterestRateModel Interface
 * @author tropykus (modified by Arr00)
 */
abstract contract LegacyInterestRateModel {
    /// @notice Indicator that this is an InterestRateModel contract (for inspection)
    bool public constant isInterestRateModel = true;

    /**
     * @notice Calculates the current supply interest rate per block
     * @param cash The total amount of cash the market has
     * @param borrows The total amount of borrows the market has outstanding
     * @param reserves The total amount of reserves the market has
     * @param reserveFactorMantissa The current reserve factor the market has
     * @return The supply rate per block (as a percentage, and scaled by 1e18)
     */
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) external view virtual returns (uint256);
}
