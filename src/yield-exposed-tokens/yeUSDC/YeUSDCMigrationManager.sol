// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {GenericMigrationManager} from "../GenericMigrationManager.sol";

/// @title yeUSDC Native Converter
/// @dev No customization is required.
/// @dev This contract does not need to be deployed. You can point `YeUSDCMigrationManager` proxy to `GenericMigrationManager` instead.
contract YeUSDCMigrationManager is GenericMigrationManager {}
