// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {GenericMigrationManager} from "../GenericMigrationManager.sol";

/// @title DAI Native Converter
/// @dev No customization is required.
/// @dev This contract does not need to be deployed. You can point DAIMigrationManager proxy to GenericMigrationManager instead.
contract DAIMigrationManager is GenericMigrationManager {}
