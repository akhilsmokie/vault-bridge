// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {MigrationManager} from "../../MigrationManager.sol";
import {USDTTransferFeeCalculator} from "./USDTTransferFeeCalculator.sol";

/// @title USDT Native Converter
contract USDTMigrationManager is MigrationManager, USDTTransferFeeCalculator {
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address yeToken_, address nativeConverter_) external initializer {
        // Initialize the base implementation.
        __MigrationManager_init(owner_, yeToken_, nativeConverter_);

        // Initialize the inherited module.
        __USDTTransferFeeCalculator_init(address(underlyingToken()));
    }

    // -----================= ::: DEV ::: =================-----

    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override(MigrationManager, USDTTransferFeeCalculator)
        returns (uint256)
    {
        return USDTTransferFeeCalculator._assetsAfterTransferFee(assetsBeforeTransferFee);
    }
}
