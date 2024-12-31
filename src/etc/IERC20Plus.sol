// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Plus is IERC20 {
    function mint(address to, uint256 value) external;
    function burn(address from, uint256 value) external;
}
