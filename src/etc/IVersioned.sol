// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

interface IVersioned {
    /// @notice The version of the contract.
    function version() external pure returns (string memory);
}
