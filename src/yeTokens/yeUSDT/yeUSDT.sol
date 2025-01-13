// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {YieldExposedToken} from "../../YieldExposedToken.sol";
import {USDTTransferFeeCalculator} from "./USDTTransferFeeCalculator.sol";

/// @title Yield Exposed USDT
contract YeUSDT is YieldExposedToken, USDTTransferFeeCalculator {
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

        // Initialize the inherited module.
        __USDTTransferFeeCalculator_init(underlyingToken_);
    }

    // -----================= ::: DEV ::: =================-----

    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override(YieldExposedToken, USDTTransferFeeCalculator)
        returns (uint256)
    {
        return USDTTransferFeeCalculator._assetsAfterTransferFee(assetsBeforeTransferFee);
    }

    function _assetsBeforeTransferFee(uint256 minimumAssetsAfterTransferFee)
        internal
        view
        virtual
        override(YieldExposedToken, USDTTransferFeeCalculator)
        returns (uint256)
    {
        return USDTTransferFeeCalculator._assetsBeforeTransferFee(minimumAssetsAfterTransferFee);
    }
}
