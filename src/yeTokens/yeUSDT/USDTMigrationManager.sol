// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {GenericMigrationManager} from "../GenericMigrationManager.sol";

/// @title USDT Native Converter
/// @dev No customization is required.
/// @dev This contract does not need to be deployed. You can point `USDTMigrationManager` proxy to `GenericMigrationManager` instead.
contract USDTMigrationManager is GenericMigrationManager {}
