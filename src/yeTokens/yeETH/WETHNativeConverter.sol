// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {GenericNativeConverter} from "../GenericNativeConverter.sol";

/// @title WETH Native Converter
/// @dev No customization is required.
/// @dev This contract does not need to be deployed. You can point WETHNativeConverter proxy to GenericNativeConverter instead.
contract WETHNativeConverter is GenericNativeConverter {}
