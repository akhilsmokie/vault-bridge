// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {YieldExposedToken} from "../YieldExposedToken.sol";

/// @title Yield Exposed USDC
contract yeUSDC is YieldExposedToken {
    /// @dev USDC does not have a transfer fee.
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return assetsBeforeTransferFee;
    }

    /// @dev USDC does not have a transfer fee.
    function _assetsBeforeTransferFee(uint256 minimumAssetsAfterTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return minimumAssetsAfterTransferFee;
    }
}
