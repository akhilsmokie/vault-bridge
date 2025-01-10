// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {MigrationManager} from "../MigrationManager.sol";

/// @title Generic Native Converter
/// @dev This contract can be used to deploy Native Converters that do not require any customization.
abstract contract GenericMigrationManager is MigrationManager {
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address yeToken_, address nativeConverter_) external initializer {
        // Initialize the base implementation.
        __MigrationManager_init(owner_, yeToken_, nativeConverter_);
    }

    /// @dev The underlying token does not have a transfer fee.
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return assetsBeforeTransferFee;
    }
}
