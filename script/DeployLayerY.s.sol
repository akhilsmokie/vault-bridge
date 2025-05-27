// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity ^0.8.29;

import "forge-std/Script.sol";

contract DeployLayerY is Script {
    using stdJson for string;

    uint256 deployerPrivateKey = uint256(uint160(address(this))); // default placeholder for tests

    function run() public {
        deployerPrivateKey = vm.promptSecretUint("PRIVATE_KEY");

        deployLayerY();
    }

    function deployLayerY() public {
        vm.startBroadcast(deployerPrivateKey);        

        vm.stopBroadcast();
    }
}
