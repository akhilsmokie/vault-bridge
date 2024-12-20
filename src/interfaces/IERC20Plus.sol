// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

// @note Copied from 0xPolygon/usdx-lxly-stb

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IERC20Plus is IERC20 {
    function burn(uint256 _amount) external;

    function mint(address _to, uint256 _amount) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
