// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {YieldExposedToken} from "../YieldExposedToken.sol";

/// @title Yield Exposed USDT
contract yeUSDT is YieldExposedToken {
    /**
     * @dev Storage of the Yield Exposed USDT contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.NativeConverter
     */
    struct YeUSDTStorage {
        /// @notice The cached basis points rate.
        /// @dev USDT emits an event when the transfer fee changes. Make sure to recache the parameters when that happens.
        uint256 cachedBasisPointsRate;
        /// @notice The cached maximum fee.
        /// @dev USDT emits an event when the transfer fee changes. Make sure to recache the parameters when that happens.
        uint256 cachedMaximumFee;
    }

    /// @dev The storage slot at which Yield Exposed USDT storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.yeusdt")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _YEUSDT_STORAGE = 0x84ee203f1e1f9edfbb1e849a4d092d07ed40cbb089b8d6192bf4930bf3c7a600;

    constructor() {
        _disableInitializers();
    }

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
    ) external initializer {
        // Initialize the base implementation.
        __YieldExposedToken_init(
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
        recacheUSDTTransferFeeParameters();
    }

    /// @notice Recache the USDT transfer fee parameters.
    function recacheUSDTTransferFeeParameters() public {
        YeUSDTStorage storage $ = _getYeUSDTStorage();

        $.cachedBasisPointsRate = IUSDT(asset()).basisPointsRate();
        $.cachedMaximumFee = IUSDT(asset()).maximumFee();
    }

    /// @dev USDT has a transfer fee.
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        YeUSDTStorage storage $ = _getYeUSDTStorage();

        if ($.cachedBasisPointsRate == 0) {
            return assetsBeforeTransferFee;
        }

        uint256 fee = (assetsBeforeTransferFee * $.cachedBasisPointsRate) / 10000;
        if (fee > $.cachedMaximumFee) {
            fee = $.cachedMaximumFee;
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
        YeUSDTStorage storage $ = _getYeUSDTStorage();

        if ($.cachedBasisPointsRate == 0) {
            return minimumAssetsAfterTransferFee;
        }

        uint256 denom = 10000 - $.cachedBasisPointsRate;
        uint256 candidate = (minimumAssetsAfterTransferFee * 10000 + (denom - 1)) / denom;

        uint256 feeCandidate = (candidate * $.cachedBasisPointsRate) / 10000;
        if (feeCandidate > $.cachedMaximumFee) {
            return minimumAssetsAfterTransferFee + $.cachedMaximumFee;
        }

        while (candidate > 0) {
            uint256 feeCandidateMinus1 = ((candidate - 1) * $.cachedBasisPointsRate) / 10000;
            if (feeCandidateMinus1 > $.cachedMaximumFee) {
                feeCandidateMinus1 = $.cachedMaximumFee;
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

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getYeUSDTStorage() private pure returns (YeUSDTStorage storage $) {
        assembly {
            $.slot := _YEUSDT_STORAGE
        }
    }
}

/// @notice The interface of USDT.
interface IUSDT {
    function basisPointsRate() external view returns (uint256);
    function maximumFee() external view returns (uint256);
}

// @todo Revisit and document.
