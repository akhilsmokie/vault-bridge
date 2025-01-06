// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {YieldExposedToken} from "../YieldExposedToken.sol";
import {IWETH9} from "../etc/WETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";


/// @title Yield Exposed gas token
contract YeETH is YieldExposedToken {

    /// @dev deposit ETH to get yeETH
    function depositGasToken(address receiver) external payable whenNotPaused returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        uint256 assets = msg.value;

        (shares,) = _deposit(assets, $.lxlyId, receiver, false, 0);
    }

    /// @dev deposit ETH to get yeETH and bridge to an L2
    function depositGasTokenAndBridge(
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot
    ) external payable whenNotPaused returns (uint256 shares) {
        uint256 assets = msg.value;

        (shares,) = _deposit(assets, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot, 0);
    }

    /// @notice OVERRIDES _deposit from YieldExposedToken to handle ETH deposits
    /// @notice Locks the underlying token, mints yeToken, and optionally bridges it to an L2.
    /// @param maxShares Caps the amount of yeToken that can be minted. The difference is refunded to the sender. Set to `0` to disable.
    function _deposit(
        uint256 assets,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot,
        uint256 maxShares
    ) internal override returns (uint256 shares, uint256 spentAssets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the input.
        require(assets > 0, "INVALID_AMOUNT");

        // Check for a refund.
        if (maxShares > 0) {
            uint256 requiredAssets = _convertToAssets(maxShares);
            if (assets > requiredAssets) {
                uint256 refund = assets - requiredAssets;
                (bool success,) = payable(msg.sender).call{value: refund}("");
                assert(success);
                assets = requiredAssets;
            }
        }

        // convert ETH to WETH
        IWETH9 weth = IWETH9(address($.underlyingToken));
        weth.deposit{value: assets}();

        // Set the return values.
        shares = _convertToShares(assets);
        spentAssets = assets;

        // Calculate the amount to reserve and the amount to deposit into the yield vault.
        uint256 assetsToReserve = (assets * $.minimumReservePercentage) / 100;
        uint256 assetsToDeposit = assets - assetsToReserve;

        // Deposit into the yield vault.
        uint256 maxDeposit_ = $.yieldVault.maxDeposit(address(this));
        assetsToDeposit = assetsToDeposit > maxDeposit_ ? maxDeposit_ : assetsToDeposit;
        if (assetsToDeposit > 0) {
            $.yieldVault.deposit(assetsToDeposit, address(this));
        }

        // Mint yeToken.
        if (destinationNetworkId != $.lxlyId) {
            // Mint to self and bridge to the receiver.
            _mint(address(this), shares);
            lxlyBridge().bridgeAsset(
                destinationNetworkId, destinationAddress, shares, address(this), forceUpdateGlobalExitRoot, ""
            );
        } else {
            // Mint to the receiver.
            _mint(destinationAddress, shares);
        }

        // Emit the ERC-4626 event.
        if (destinationNetworkId != $.lxlyId) destinationAddress = address(this);
        emit IERC4626.Deposit(msg.sender, destinationAddress, assets, shares);
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
