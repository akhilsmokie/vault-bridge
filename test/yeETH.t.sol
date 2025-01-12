// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {YeETH} from "../src/yeTokens/yeETH/yeETH.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMetaMorphoV1_1Factory} from "./interfaces/IMetaMorphoV1_1Factory.sol";
import {ILxLyBridge} from "../src/etc/ILxLyBridge.sol";

contract yeETHTest is Test {
    YeETH public implementation;
    YeETH public yeETH;
    uint256 mainnetFork;
    uint256 zkevmFork;
    address public morphoVault;

    address constant METAMORPHO_FACTORY = 0x1897A8997241C1cD4bD0698647e4EB7213535c24;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LXLY_BRIDGE = 0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe;
    uint8 constant MINIMUM_RESERVE_PERCENTAGE = 10;
    uint32 constant ZKEVM_NETWORK_ID = 1; // zkEVM

    function setUp() public {
        mainnetFork = vm.createFork("mainnet");
        // zkevmFork = vm.createFork("polygon_zkevm");
        vm.selectFork(mainnetFork);

        morphoVault = IMetaMorphoV1_1Factory(METAMORPHO_FACTORY).createMetaMorpho(
            address(this), // Owner
            0, // No timelock
            WETH, // Asset
            "Morpho WETH Vault",
            "yeETH",
            0
        );

        // Deploy implementation
        implementation = new YeETH();

        // prepare calldata
        bytes memory initData = abi.encodeCall(
            yeETH.initialize,
            (
                address(this), // owner
                "Yield Exposed ETH", // name
                "yeETH", // symbol
                WETH, // underlyging token
                MINIMUM_RESERVE_PERCENTAGE,
                morphoVault, // Use our deployed Morpho vault
                makeAddr("yield"), // mock yield recipient
                LXLY_BRIDGE,
                makeAddr("migration") // mock migration manager
            )
        );

        // deploy proxy and initialize implementation
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);

        // Get the proxy instance
        yeETH = YeETH(address(proxyContract));
    }

    function test_basicFunctions() public view {
        assertEq(yeETH.name(), "Yield Exposed ETH");
        assertEq(yeETH.symbol(), "yeETH");
        assertEq(yeETH.asset(), WETH);
    }

    function test_depositGasToken(address receiver, uint256 depositAmount) public {
        vm.assume(receiver != address(0));
        vm.assume(depositAmount > 0 && depositAmount < 100 ether);

        // Get initial balance
        uint256 initialReceiverBalance = yeETH.balanceOf(receiver);

        // Deposit ETH
        vm.deal(address(this), depositAmount);
        uint256 shares = yeETH.depositGasToken{value: depositAmount}(receiver);

        // Verify
        assertGt(shares, 0, "Should receive shares for deposit");
        assertEq(yeETH.balanceOf(receiver), initialReceiverBalance + shares, "Receiver should get correct shares");
    }

    function test_depositGasTokenAndBridge(address receiver, uint256 depositAmount) public {
        vm.assume(receiver != address(0));
        vm.assume(depositAmount > 0 && depositAmount < 100 ether);

        // Deposit ETH
        vm.deal(address(this), depositAmount);
        uint256 shares = yeETH.depositGasTokenAndBridge{value: depositAmount}(receiver, ZKEVM_NETWORK_ID, true);

        assertGt(shares, 0, "Should receive shares for deposit");
    }
}
