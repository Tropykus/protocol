// Root file: contracts/PriceOracleAdapter.sol

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

abstract contract PriceOracleAdapter {
    /// @notice Event adapter interface updated
    event PriceOracleAdapterUpdated(address oldAddress, address newAddress);

    /**
     * @notice Get the price
     * @return The underlying asset price mantissa (scaled by 1e18).
     *  Zero means the price is unavailable.
     */
    function assetPrices(address cTokenAddress)
        external
        view
        virtual
        returns (uint256);
}
