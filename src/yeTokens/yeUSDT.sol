// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {YieldExposedToken} from "../YieldExposedToken.sol";

/// @title Yield Exposed USDT
contract yeUSDT is YieldExposedToken {
    /// @notice The cached basis points rate.
    /// @dev USDT emits an event when the transfer fee changes. Make sure to recache the parameters when that happens.
    uint256 internal _cachedBasisPointsRate;

    /// @notice The cached maximum fee.
    /// @dev USDT emits an event when the transfer fee changes. Make sure to recache the parameters when that happens.
    uint256 internal _cachedMaximumFee;

    function initialize(
        address owner_,
        string calldata name_,
        string calldata symbol_,
        address underlyingToken_,
        uint8 minimumReservePercentage_,
        address yieldVault_,
        address yieldRecipient_,
        address lxlyBridge_,
        address migrationManager_
    ) public override {
        // Initialize the base implementation.
        super.initialize(
            owner_,
            name_,
            symbol_,
            underlyingToken_,
            minimumReservePercentage_,
            yieldVault_,
            yieldRecipient_,
            lxlyBridge_,
            migrationManager_
        );

        // Cache the USDT transfer fee parameters.
        cacheUSDTTransferFeeParameters();
    }

    /// @notice Cache the USDT transfer fee parameters.
    function cacheUSDTTransferFeeParameters() public {
        _cachedBasisPointsRate = IUSDT(asset())._cachedBasisPointsRate();
        _cachedMaximumFee = IUSDT(asset())._cachedMaximumFee();
    }

    /// @dev USDT has a transfer fee.
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        if (_cachedBasisPointsRate == 0) {
            return assetsBeforeTransferFee;
        }

        uint256 fee = (assetsBeforeTransferFee * _cachedBasisPointsRate) / 10000;
        if (fee > _cachedMaximumFee) {
            fee = _cachedMaximumFee;
        }

        return assetsBeforeTransferFee - fee;
    }

    /// @dev USDT has a transfer fee.
    function _assetsBeforeTransferFee(uint256 minimumAssetsAfterTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        if (_cachedBasisPointsRate == 0) {
            return minimumAssetsAfterTransferFee;
        }

        uint256 denom = 10000 - _cachedBasisPointsRate;
        uint256 candidate = (minimumAssetsAfterTransferFee * 10000 + (denom - 1)) / denom;

        uint256 feeCandidate = (candidate * _cachedBasisPointsRate) / 10000;
        if (feeCandidate > _cachedMaximumFee) {
            return minimumAssetsAfterTransferFee + _cachedMaximumFee;
        }

        while (candidate > 0) {
            uint256 feeCandidateMinus1 = ((candidate - 1) * _cachedBasisPointsRate) / 10000;
            if (feeCandidateMinus1 > _cachedMaximumFee) {
                feeCandidateMinus1 = _cachedMaximumFee;
            }

            uint256 afterFeeMinus1 = (candidate - 1) - feeCandidateMinus1;
            if (afterFeeMinus1 >= minimumAssetsAfterTransferFee) {
                candidate--;
            } else {
                break;
            }
        }

        return candidate;
    }
}

/// @notice Interface of USDT.
interface IUSDT {
    function _cachedBasisPointsRate() external view returns (uint256);
    function _cachedMaximumFee() external view returns (uint256);
}

// @todo Revisit and document.
