// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/YieldExposedToken.sol";
import {IMetaMorpho} from "src/etc/IMetaMorpho.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// MOCKS
contract YeWETH is YieldExposedToken {
    uint256 public constant TRANSFER_FEE = 10;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        string calldata name_,
        string calldata symbol_,
        address underlyingToken_,
        uint8 minimumReservePercentage_,
        address yieldVault_,
        address yieldRecipient_,
        address lxlyBridge_,
        address migrationManager_
    ) external initializer {
        // Initialize the base implementation.
        __YieldExposedToken_init(
            owner_,
            name_,
            symbol_,
            underlyingToken_,
            minimumReservePercentage_,
            yieldVault_,
            yieldRecipient_,
            lxlyBridge_,
            migrationManager_
        );
    }

    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return assetsBeforeTransferFee;
    }

    function _assetsBeforeTransferFee(uint256 minimumAssetsAfterTransferFee)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return minimumAssetsAfterTransferFee + TRANSFER_FEE;
    }
}

contract YieldExposedTokenTest is Test {
    address internal constant LXLY_BRIDGE = 0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WETH_VAULT = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
    uint8 internal constant MINIMUM_RESERVE_PERCENTAGE = 10;
    uint256 internal constant TRANSFER_FEE = 10;
    uint32 internal constant NETWORK_ID_L1 = 0;
    uint32 internal constant NETWORK_ID_L2 = 1;
    uint8 internal constant LEAF_TYPE_ASSET = 0;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal mainnetFork;
    YeWETH internal yeWETH;
    IMetaMorpho internal wethVault = IMetaMorpho(WETH_VAULT);
    uint256 internal beforeInit;

    // vault addresses
    address internal allocator = makeAddr("allocator");
    address internal curator = makeAddr("curator");

    // initialization arguments
    address internal migrationManager = makeAddr("migrationManager");
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal yieldRecipient = makeAddr("yieldRecipient");
    string internal name = "Yield Exposed WETH";
    string internal symbol = "yeWETH";
    bytes internal yeWethMetaData = abi.encode(name, symbol, 18);
    uint256 senderPrivateKey = 0xBEEF;
    address internal sender = vm.addr(senderPrivateKey);

    error EnforcedPause();

    event BridgeEvent(
        uint8 leafType,
        uint32 originNetwork,
        address originAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes metadata,
        uint32 depositCount
    );
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event ReserveRebalanced(uint256 reservedAssets);

    function setUp() public {
        mainnetFork = vm.createSelectFork("mainnet", 21590932);

        yeWETH = new YeWETH();
        beforeInit = vm.snapshotState();
        bytes memory initData = abi.encodeCall(
            yeWETH.initialize,
            (
                owner,
                name,
                symbol,
                WETH,
                MINIMUM_RESERVE_PERCENTAGE,
                address(wethVault),
                yieldRecipient,
                LXLY_BRIDGE,
                migrationManager
            )
        );
        yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));

        vm.label(allocator, "Allocator");
        vm.label(curator, "Curator");
        vm.label(WETH, "weth");
        vm.label(address(wethVault), "wethVault");
        vm.label(address(yeWETH), "yeweth");
        vm.label(LXLY_BRIDGE, "lxlyBridge");
        vm.label(migrationManager, "migrationManager");
        vm.label(owner, "owner");
        vm.label(recipient, "recipient");
        vm.label(sender, "sender");
        vm.label(yieldRecipient, "yieldRecipient");
        vm.label(address(this), "defaultAddress");
    }

    function test_setup() public view {
        assertEq(yeWETH.owner(), owner);
        assertEq(yeWETH.name(), name);
        assertEq(yeWETH.symbol(), symbol);
        assertEq(yeWETH.decimals(), 18);
        assertEq(yeWETH.asset(), WETH);
        assertEq(yeWETH.minimumReservePercentage(), MINIMUM_RESERVE_PERCENTAGE);
        assertEq(address(yeWETH.yieldVault()), address(wethVault));
        assertEq(yeWETH.yieldRecipient(), yieldRecipient);
        assertEq(address(yeWETH.lxlyBridge()), LXLY_BRIDGE);
        assertEq(yeWETH.migrationManager(), migrationManager);
        assertEq(IERC20(WETH).allowance(address(yeWETH), address(yeWETH.yieldVault())), type(uint256).max);
        assertEq(yeWETH.allowance(address(yeWETH), LXLY_BRIDGE), type(uint256).max);
    }

    function test_initialize() public {
        uint256 totalInitParams = 9;
        vm.revertToState(beforeInit);

        bytes memory initData;
        for (uint256 paramNum = 0; paramNum < totalInitParams; paramNum++) {
            if (paramNum == 0) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        address(0),
                        name,
                        symbol,
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_OWNER");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 1) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        "",
                        symbol,
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_NAME");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 2) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        name,
                        "",
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_SYMBOL");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 3) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        address(0),
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_UNDERLYING_TOKEN");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 4) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (owner, name, symbol, WETH, 101, address(wethVault), yieldRecipient, LXLY_BRIDGE, migrationManager)
                );
                vm.expectRevert("INVALID_PERCENTAGE");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 5) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(0),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_VAULT");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 6) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        address(0),
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_YIELD_RECIPIENT");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 7) {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        yieldRecipient,
                        address(0),
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_LXLY_BRIDGE");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            } else {
                initData = abi.encodeCall(
                    yeWETH.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        WETH,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(wethVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        address(0)
                    )
                );
                vm.expectRevert("INVALID_MIGRATION_MANAGER");
                yeWETH = YeWETH(_proxify(address(yeWETH), address(this), initData));
                vm.revertToState(beforeInit);
            }
        }
    }

    function test_deposit() public {
        uint256 amount = 100;

        vm.startPrank(owner);
        yeWETH.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeWETH.deposit(amount, recipient);

        yeWETH.unpause();
        vm.stopPrank();

        deal(WETH, sender, amount);

        vm.startPrank(sender);
        vm.expectRevert("INVALID_AMOUNT");
        yeWETH.deposit(0, recipient);

        vm.expectRevert("INVALID_ADDRESS");
        yeWETH.deposit(amount, address(0));

        IERC20(WETH).approve(address(yeWETH), amount);
        vm.expectEmit();
        emit Deposit(sender, recipient, amount, amount);
        yeWETH.deposit(amount, recipient);

        vm.stopPrank();
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(IERC20(WETH).balanceOf(address(yeWETH)), reserveAmount);
        assertEq(yeWETH.balanceOf(recipient), amount); // shares minted to the recipient
        assertEq(yeWETH.reservedAssets(), reserveAmount);
        assertEq(yeWETH.stakedAssets(), amount - reserveAmount - 1); // minus 1 because of rounding
        assertEq(yeWETH.totalAssets(), amount - 1); // minus 1 because of rounding
    }

    function test_depositAndBridge() public {
        uint256 amount = 100;

        vm.startPrank(owner);
        yeWETH.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeWETH.depositAndBridge(amount, recipient, NETWORK_ID_L2, true);

        yeWETH.unpause();
        vm.stopPrank();

        deal(WETH, sender, amount);

        vm.startPrank(sender);
        IERC20(WETH).approve(address(yeWETH), amount);
        vm.expectEmit();
        emit BridgeEvent(
            LEAF_TYPE_ASSET, NETWORK_ID_L1, address(yeWETH), NETWORK_ID_L2, recipient, amount, yeWethMetaData, 214030
        );
        yeWETH.depositAndBridge(amount, recipient, NETWORK_ID_L2, true);

        vm.stopPrank();
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(IERC20(WETH).balanceOf(address(yeWETH)), reserveAmount);
        assertEq(yeWETH.balanceOf(LXLY_BRIDGE), amount); // shares locked in bridge
        assertEq(yeWETH.reservedAssets(), reserveAmount);
        assertEq(yeWETH.stakedAssets(), amount - reserveAmount - 1);
        assertEq(yeWETH.totalAssets(), amount - 1);
    }

    // TODO: fix allowance issue
    // function test_depositAndBridgePermit() public {
    // uint256 amount = 100;

    // (uint8 v, bytes32 r, bytes32 s) = vm.sign(
    //     senderPrivateKey,
    //     keccak256(
    //         abi.encodePacked(
    //             "\x19\x01",
    //             yeWETH.DOMAIN_SEPARATOR(),
    //             keccak256(
    //                 abi.encode(
    //                     PERMIT_TYPEHASH, sender, address(yeWETH), amount, vm.getNonce(sender), block.timestamp
    //                 )
    //             )
    //         )
    //     )
    // );
    // bytes memory permitData =
    //     abi.encodeWithSelector(bytes4(PERMIT_TYPEHASH), sender, address(yeWETH), amount, block.timestamp, v, r, s);
    // vm.expectEmit();
    // emit BridgeEvent(
    //     LEAF_TYPE_ASSET, NETWORK_ID_L1, address(yeWETH), NETWORK_ID_L2, recipient, amount, yeWethMetaData, 214030
    // );
    // vm.prank(sender);
    // yeWETH.depositAndBridge(amount, recipient, NETWORK_ID_L2, true, permitData);
    // uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
    // assertEq(IERC20(WETH).balanceOf(address(yeWETH)), reserveAmount);
    // assertEq(yeWETH.balanceOf(LXLY_BRIDGE), amount); // shares locked in bridge
    // assertEq(yeWETH.reservedAssets(), reserveAmount);
    // assertEq(yeWETH.stakedAssets(), amount - reserveAmount - 1);
    // assertEq(yeWETH.totalAssets(), amount - 1);
    // }

    function test_mint() public {
        uint256 amount = 100;

        vm.startPrank(owner);
        yeWETH.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeWETH.mint(amount, recipient);

        yeWETH.unpause();
        vm.stopPrank();

        deal(WETH, sender, amount + TRANSFER_FEE);

        vm.startPrank(sender);
        IERC20(WETH).approve(address(yeWETH), amount + TRANSFER_FEE);
        yeWETH.mint(amount, sender);
        vm.stopPrank();

        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(yeWETH.balanceOf(sender), amount); // shares minted to the sender
        assertEq(yeWETH.reservedAssets(), reserveAmount);
        assertEq(yeWETH.stakedAssets(), amount - reserveAmount - 1);
        assertEq(yeWETH.totalAssets(), amount - 1);
    }

    // function test_withdraw() public {
    //     uint256 initialAmount = 100;
    //     uint256 reserveAmount = (initialAmount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

    //     vm.startPrank(owner);
    //     yeWETH.pause();
    //     vm.expectRevert(EnforcedPause.selector);
    //     yeWETH.withdraw(initialAmount, recipient, owner);
    //     yeWETH.unpause();
    //     vm.stopPrank();

    //     deal(WETH, sender, initialAmount);

    //     vm.startPrank(sender);
    //     IERC20(WETH).approve(address(yeWETH), initialAmount);
    //     yeWETH.deposit(initialAmount, sender);
    //     assertEq(IERC20(WETH).balanceOf(sender), 0); // make sure sender has no deposited all WETH
    //     assertEq(yeWETH.balanceOf(sender), initialAmount); // sender gets 100 shares

    //     uint256 withdrawAmount = 110; // withdraw amount is greater than total assets (100)
    //     vm.expectRevert("AMOUNT_TOO_LARGE");
    //     yeWETH.withdraw(withdrawAmount, sender, sender);

    //     uint256 reserveWithdrawAmount = 5;
    //     reserveAmount -= reserveWithdrawAmount;
    //     yeWETH.withdraw(reserveWithdrawAmount, sender, sender);
    //     assertEq(IERC20(WETH).balanceOf(address(yeWETH)), reserveAmount); // reserve assets reduced
    //     assertEq(IERC20(WETH).balanceOf(sender), reserveWithdrawAmount); // assets returned to sender
    //     assertEq(yeWETH.balanceOf(sender), initialAmount - reserveWithdrawAmount); // shares reduced

    //     uint256 stakeWithdrawAmount = 10; // withdraw amount is greater than reserve amount (5)
    //     yeWETH.withdraw(stakeWithdrawAmount, sender, sender);
    //     assertEq(IERC20(WETH).balanceOf(address(yeWETH)), 0); // reserve assets remain same
    //     assertEq(IERC20(WETH).balanceOf(sender), reserveWithdrawAmount + stakeWithdrawAmount); // assets returned to sender
    //     assertEq(yeWETH.balanceOf(sender), initialAmount - reserveWithdrawAmount - stakeWithdrawAmount); // shares reduced
    //     vm.stopPrank();
    // }

    function test_replenishReserve() public {
        uint256 amount = 100;
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

        vm.expectRevert("NO_NEED_TO_REBALANCE_RESERVE");
        yeWETH.replenishReserve();

        deal(WETH, sender, amount);
        // create reserve
        vm.startPrank(sender);
        IERC20(WETH).approve(address(yeWETH), amount);
        yeWETH.deposit(amount, recipient);
        vm.stopPrank();

        vm.prank(address(yeWETH));
        IERC20(WETH).transfer(address(0), reserveAmount - 5); // reduce reserve assets
        vm.expectEmit();
        emit ReserveRebalanced(reserveAmount);
        yeWETH.replenishReserve();
        assertEq(IERC20(WETH).balanceOf(address(yeWETH)), reserveAmount);
    }

    function test_rebalanceReserve() public {
        uint256 amount = 100;
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

        deal(WETH, sender, amount);
        // create reserve
        vm.startPrank(sender);
        IERC20(WETH).approve(address(yeWETH), amount);
        yeWETH.deposit(amount, recipient);
        vm.stopPrank();

        deal(WETH, address(yeWETH), amount); // add more assets to the reserve
        vm.expectRevert(); // only owner can rebalance reserve
        yeWETH.rebalanceReserve();

        vm.expectEmit();
        emit ReserveRebalanced(reserveAmount);
        vm.prank(owner);
        yeWETH.rebalanceReserve();
        assertEq(IERC20(WETH).balanceOf(address(yeWETH)), reserveAmount);
    }

    function test_approve() public {
        assertTrue(yeWETH.approve(address(0xBEEF), 1e18));

        assertEq(yeWETH.allowance(address(this), address(0xBEEF)), 1e18);
    }

    function test_transfer() public {
        deal(address(yeWETH), address(this), 1e18);

        assertTrue(yeWETH.transfer(address(0xBEEF), 1e18));

        assertEq(yeWETH.balanceOf(address(this)), 0);
        assertEq(yeWETH.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_transferFrom() public {
        address from = address(0xABCD);
        deal(address(yeWETH), from, 1e18);

        vm.prank(from);
        yeWETH.approve(address(this), 1e18);

        assertTrue(yeWETH.transferFrom(from, address(0xBEEF), 1e18));

        assertEq(yeWETH.allowance(from, address(this)), 0);

        assertEq(yeWETH.balanceOf(from), 0);
        assertEq(yeWETH.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_infiniteApproveTransferFrom() public {
        address from = address(0xABCD);
        deal(address(yeWETH), from, 1e18);

        vm.prank(from);
        yeWETH.approve(address(this), type(uint256).max);

        assertTrue(yeWETH.transferFrom(from, address(0xBEEF), 1e18));

        assertEq(yeWETH.allowance(from, address(this)), type(uint256).max);

        assertEq(yeWETH.balanceOf(from), 0);
        assertEq(yeWETH.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_failTransferInsufficientBalance() public {
        deal(address(yeWETH), address(this), 0.9e18);
        vm.expectRevert();
        yeWETH.transfer(address(0xBEEF), 1e18);
    }

    function test_failTransferFromInsufficientAllowance() public {
        address from = address(0xABCD);

        deal(address(yeWETH), address(this), 1e18);

        vm.prank(from);
        yeWETH.approve(address(this), 0.9e18);

        vm.expectRevert();
        yeWETH.transferFrom(from, address(0xBEEF), 1e18);
    }

    function test_failTransferFromInsufficientBalance() public {
        address from = address(0xABCD);

        deal(address(yeWETH), address(this), 0.9e18);

        vm.prank(from);
        yeWETH.approve(address(this), 1e18);

        vm.expectRevert();
        yeWETH.transferFrom(from, address(0xBEEF), 1e18);
    }

    // TODO: fix issue related to PERMIT_TYPEHASH
    // function test_permit() public {
    //     (uint8 v, bytes32 r, bytes32 s) = vm.sign(
    //         senderPrivateKey,
    //         keccak256(
    //             abi.encodePacked(
    //                 "\x19\x01",
    //                 yeWETH.DOMAIN_SEPARATOR(),
    //                 keccak256(
    //                     abi.encode(PERMIT_TYPEHASH, sender, address(0xCAFE), 1e18, vm.getNonce(sender), block.timestamp)
    //                 )
    //             )
    //         )
    //     );

    //     vm.prank(sender);
    //     yeWETH.permit(sender, address(0xCAFE), 1e18, block.timestamp, v, r, s);

    //     assertEq(yeWETH.allowance(sender, address(0xCAFE)), 1e18);
    //     assertEq(yeWETH.nonces(sender), 1);
    // }

    function _proxify(address logic, address admin, bytes memory initData) internal returns (address proxy) {
        proxy = address(new TransparentUpgradeableProxy(logic, admin, initData));
    }
}
