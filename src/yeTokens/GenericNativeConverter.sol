// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {NativeConverter} from "../NativeConverter.sol";

/// @title Generic Native Converter
/// @dev This contract can be used to deploy Native Converters that do not require any customization.
abstract contract GenericNativeConverter is NativeConverter {
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint8 originalUnderlyingTokenDecimals_,
        address customToken_,
        address wrappedUnderlyingToken_,
        uint256 dailyMigrationLimit_,
        address lxlyBridge_,
        uint32 layerXNetworkId_,
        address migrationManager_
    ) external initializer {
        // Initialize the base implementation.
        __NativeConverter_init(
            owner_,
            originalUnderlyingTokenDecimals_,
            customToken_,
            wrappedUnderlyingToken_,
            dailyMigrationLimit_,
            lxlyBridge_,
            layerXNetworkId_,
            migrationManager_
        );
    }
}
