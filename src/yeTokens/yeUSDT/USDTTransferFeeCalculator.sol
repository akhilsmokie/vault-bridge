// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Yield Exposed USDT
abstract contract USDTTransferFeeCalculator is Initializable {
    /**
     * @dev Storage of the Yield Exposed USDT contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.USDTTransferFeeCalculator
     */
    struct USDTTransferFeeCalculatorStorage {
        address _usdt;
        uint256 cachedBasisPointsRate;
        uint256 cachedMaximumFee;
    }

    /// @dev The storage slot at which Yield Exposed USDT storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.USDTTransferFeeCalculator")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _USDT_TRANSFER_FEE_CALCULATOR_STORAGE =
        0x2129ebf4f8f01a752a913500fce7539b3197582370ad69b3760f2894f19a2700;

    /// @param usdt_ The address of the USDT token.
    function __USDTTransferFeeCalculator_init(address usdt_) internal onlyInitializing {
        // Check the input.
        require(usdt_ != address(0), "INVALID_USDT");

        // Initialize the storage.
        USDTTransferFeeCalculatorStorage storage $ = _getUSDTTransferFeeCalculatorStorage();

        $._usdt = usdt_;

        // Cache the USDT transfer fee parameters.
        recacheUsdtTransferFeeParameters();
    }

    // -----================= ::: STORAGE ::: =================-----

    /// @notice The cached basis points rate.
    /// @dev USDT emits an event when the transfer fee changes. Make sure to recache the parameters when that happens.
    function cachedBasisPointsRate() public view returns (uint256) {
        USDTTransferFeeCalculatorStorage storage $ = _getUSDTTransferFeeCalculatorStorage();
        return $.cachedBasisPointsRate;
    }

    /// @notice The cached maximum fee.
    /// @dev USDT emits an event when the transfer fee changes. Make sure to recache the parameters when that happens.
    function cachedMaximumFee() public view returns (uint256) {
        USDTTransferFeeCalculatorStorage storage $ = _getUSDTTransferFeeCalculatorStorage();
        return $.cachedMaximumFee;
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getUSDTTransferFeeCalculatorStorage() private pure returns (USDTTransferFeeCalculatorStorage storage $) {
        assembly {
            $.slot := _USDT_TRANSFER_FEE_CALCULATOR_STORAGE
        }
    }

    // -----================= ::: YEUSDT ::: =================-----

    /// @notice Recache the USDT transfer fee parameters.
    function recacheUsdtTransferFeeParameters() public {
        USDTTransferFeeCalculatorStorage storage $ = _getUSDTTransferFeeCalculatorStorage();

        $.cachedBasisPointsRate = IUSDT($._usdt).basisPointsRate();
        $.cachedMaximumFee = IUSDT($._usdt).maximumFee();
    }

    /// @dev USDT has a transfer fee.
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee) internal view virtual returns (uint256) {
        USDTTransferFeeCalculatorStorage storage $ = _getUSDTTransferFeeCalculatorStorage();

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
    function _assetsBeforeTransferFee(uint256 minimumAssetsAfterTransferFee) internal view virtual returns (uint256) {
        USDTTransferFeeCalculatorStorage storage $ = _getUSDTTransferFeeCalculatorStorage();

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
}

/// @notice The interface of USDT token.
interface IUSDT {
    function basisPointsRate() external view returns (uint256);
    function maximumFee() external view returns (uint256);
}

// @todo Review and document.
