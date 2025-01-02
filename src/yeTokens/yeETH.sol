// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {YieldExposedToken} from "../YieldExposedToken.sol";

/// @title Yield Exposed gas token
contract yeETH is YieldExposedToken {
    function depositGasToken(address receiver) external payable whenNotPaused returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        uint256 assets = msg.value;

        (shares,) = _deposit(assets, $.lxlyId, receiver, false, 0);
    }

    function depositGasTokenAndBridge(
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot
    ) external payable whenNotPaused returns (uint256 shares) {
        uint256 assets = msg.value;

        (shares,) = _deposit(assets, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot, 0);
    }

    /// @dev yeETH does not have a transfer fee.
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return assetsBeforeTransferFee;
    }

    /// @dev yeETH does not have a transfer fee.
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
