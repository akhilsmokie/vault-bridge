// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/YieldExposedToken.sol";
import {IMetaMorpho} from "test/interfaces/IMetaMorpho.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// MOCKS
contract YeUSDC is YieldExposedToken {
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
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    uint8 internal constant MINIMUM_RESERVE_PERCENTAGE = 10;
    uint256 internal constant TRANSFER_FEE = 10;
    uint32 internal constant NETWORK_ID_L1 = 0;
    uint32 internal constant NETWORK_ID_L2 = 1;
    uint8 internal constant LEAF_TYPE_ASSET = 0;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes4 internal constant PERMIT_SIGNATURE = 0xd505accf;
    string internal constant YEUSDC_VERSION = "1.0.0";

    uint256 internal mainnetFork;
    YeUSDC internal yeUSDC;
    IMetaMorpho internal usdcVault = IMetaMorpho(USDC_VAULT);
    uint256 internal beforeInit;

    // vault addresses
    address internal allocator = makeAddr("allocator");
    address internal curator = makeAddr("curator");

    // initialization arguments
    address internal migrationManager = makeAddr("migrationManager");
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal yieldRecipient = makeAddr("yieldRecipient");
    string internal name = "Yield Exposed USDC";
    string internal symbol = "yeUSDC";
    bytes internal yeUSDCMetaData = abi.encode(name, symbol, 6);
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
    event YieldCollected(address indexed yieldRecipient, uint256 yeTokenAmount);
    event YieldRecipientSet(address indexed yieldRecipient);
    event MinimumReservePercentageSet(uint8 minimumReservePercentage);
    event MigrationCompleted(uint32 destinationNetworkId, uint256 shares, uint256 utilizedYield);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        mainnetFork = vm.createSelectFork("mainnet", 21590932);

        yeUSDC = new YeUSDC();
        beforeInit = vm.snapshotState();
        bytes memory initData = abi.encodeCall(
            yeUSDC.initialize,
            (
                owner,
                name,
                symbol,
                USDC,
                MINIMUM_RESERVE_PERCENTAGE,
                address(usdcVault),
                yieldRecipient,
                LXLY_BRIDGE,
                migrationManager
            )
        );
        yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));

        vm.label(allocator, "Allocator");
        vm.label(curator, "Curator");
        vm.label(USDC, "usdc");
        vm.label(address(usdcVault), "usdcVault");
        vm.label(address(yeUSDC), "yeUSDC");
        vm.label(LXLY_BRIDGE, "lxlyBridge");
        vm.label(migrationManager, "migrationManager");
        vm.label(owner, "owner");
        vm.label(recipient, "recipient");
        vm.label(sender, "sender");
        vm.label(yieldRecipient, "yieldRecipient");
        vm.label(address(this), "defaultAddress");
    }

    function test_setup() public view {
        assertEq(yeUSDC.owner(), owner);
        assertEq(yeUSDC.name(), name);
        assertEq(yeUSDC.symbol(), symbol);
        assertEq(yeUSDC.decimals(), 6);
        assertEq(yeUSDC.asset(), USDC);
        assertEq(yeUSDC.minimumReservePercentage(), MINIMUM_RESERVE_PERCENTAGE);
        assertEq(address(yeUSDC.yieldVault()), address(usdcVault));
        assertEq(yeUSDC.yieldRecipient(), yieldRecipient);
        assertEq(address(yeUSDC.lxlyBridge()), LXLY_BRIDGE);
        assertEq(yeUSDC.migrationManager(), migrationManager);
        assertEq(IERC20(USDC).allowance(address(yeUSDC), address(yeUSDC.yieldVault())), type(uint256).max);
        assertEq(yeUSDC.allowance(address(yeUSDC), LXLY_BRIDGE), type(uint256).max);
    }

    function test_initialize() public {
        uint256 totalInitParams = 9;
        vm.revertToState(beforeInit);

        bytes memory initData;
        for (uint256 paramNum = 0; paramNum < totalInitParams; paramNum++) {
            if (paramNum == 0) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        address(0),
                        name,
                        symbol,
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_OWNER");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 1) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        "",
                        symbol,
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_NAME");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 2) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        name,
                        "",
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_SYMBOL");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 3) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        address(0),
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_UNDERLYING_TOKEN");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 4) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (owner, name, symbol, USDC, 101, address(usdcVault), yieldRecipient, LXLY_BRIDGE, migrationManager)
                );
                vm.expectRevert("INVALID_PERCENTAGE");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 5) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(0),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_VAULT");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 6) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        address(0),
                        LXLY_BRIDGE,
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_YIELD_RECIPIENT");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else if (paramNum == 7) {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        yieldRecipient,
                        address(0),
                        migrationManager
                    )
                );
                vm.expectRevert("INVALID_LXLY_BRIDGE");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            } else {
                initData = abi.encodeCall(
                    yeUSDC.initialize,
                    (
                        owner,
                        name,
                        symbol,
                        USDC,
                        MINIMUM_RESERVE_PERCENTAGE,
                        address(usdcVault),
                        yieldRecipient,
                        LXLY_BRIDGE,
                        address(0)
                    )
                );
                vm.expectRevert("INVALID_MIGRATION_MANAGER");
                yeUSDC = YeUSDC(_proxify(address(yeUSDC), address(this), initData));
                vm.revertToState(beforeInit);
            }
        }
    }

    function test_deposit() public {
        uint256 amount = 100;

        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.deposit(amount, recipient);

        yeUSDC.unpause();
        vm.stopPrank();

        deal(USDC, sender, amount);

        vm.startPrank(sender);
        vm.expectRevert("INVALID_AMOUNT");
        yeUSDC.deposit(0, recipient);

        vm.expectRevert("INVALID_ADDRESS");
        yeUSDC.deposit(amount, address(0));

        IERC20(USDC).approve(address(yeUSDC), amount);
        vm.expectEmit();
        emit Deposit(sender, recipient, amount, amount);
        yeUSDC.deposit(amount, recipient);

        vm.stopPrank();
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount);
        assertEq(yeUSDC.balanceOf(recipient), amount); // shares minted to the recipient
        assertEq(yeUSDC.reservedAssets(), reserveAmount);
        assertEq(yeUSDC.stakedAssets(), amount - reserveAmount - 1); // minus 1 because of rounding
        assertEq(yeUSDC.totalAssets(), amount - 1); // minus 1 because of rounding
    }

    function test_depositPermit() public {
        uint256 amount = 100;

        deal(USDC, sender, amount);

        bytes32 domainSeparator = IERC20Permit(USDC).DOMAIN_SEPARATOR();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            senderPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domainSeparator, // remember to use the domain separator of the underlying token
                    keccak256(
                        abi.encode(
                            PERMIT_TYPEHASH, sender, address(yeUSDC), amount, vm.getNonce(sender), block.timestamp
                        )
                    )
                )
            )
        );
        bytes memory permitData =
            abi.encodeWithSelector(PERMIT_SIGNATURE, sender, address(yeUSDC), amount, block.timestamp, v, r, s);

        vm.startPrank(sender);
        vm.expectEmit();
        emit Deposit(sender, recipient, amount, amount);
        yeUSDC.depositPermit(amount, recipient, permitData);
        vm.stopPrank();

        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount);
        assertEq(yeUSDC.balanceOf(recipient), amount); // shares minted to the recipient
        assertEq(yeUSDC.reservedAssets(), reserveAmount);
        assertEq(yeUSDC.stakedAssets(), amount - reserveAmount - 1); // minus 1 because of rounding
        assertEq(yeUSDC.totalAssets(), amount - 1); // minus 1 because of rounding
    }

    function test_depositAndBridge() public {
        uint256 amount = 100;

        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.depositAndBridge(amount, recipient, NETWORK_ID_L2, true);

        yeUSDC.unpause();
        vm.stopPrank();

        deal(USDC, sender, amount);

        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        vm.expectEmit();
        emit BridgeEvent(
            LEAF_TYPE_ASSET, NETWORK_ID_L1, address(yeUSDC), NETWORK_ID_L2, recipient, amount, yeUSDCMetaData, 214030
        );
        yeUSDC.depositAndBridge(amount, recipient, NETWORK_ID_L2, true);

        vm.stopPrank();
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount);
        assertEq(yeUSDC.balanceOf(LXLY_BRIDGE), amount); // shares locked in bridge
        assertEq(yeUSDC.reservedAssets(), reserveAmount);
        assertEq(yeUSDC.stakedAssets(), amount - reserveAmount - 1);
        assertEq(yeUSDC.totalAssets(), amount - 1);
    }

    function test_depositAndBridgePermit() public {
        uint256 amount = 100;

        deal(USDC, sender, amount);

        bytes32 domainSeparator = IERC20Permit(USDC).DOMAIN_SEPARATOR();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            senderPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domainSeparator, // remember to use the domain separator of the underlying token
                    keccak256(
                        abi.encode(
                            PERMIT_TYPEHASH, sender, address(yeUSDC), amount, vm.getNonce(sender), block.timestamp
                        )
                    )
                )
            )
        );
        bytes memory permitData =
            abi.encodeWithSelector(PERMIT_SIGNATURE, sender, address(yeUSDC), amount, block.timestamp, v, r, s);

        vm.startPrank(sender);
        vm.expectEmit();
        emit BridgeEvent(
            LEAF_TYPE_ASSET, NETWORK_ID_L1, address(yeUSDC), NETWORK_ID_L2, recipient, amount, yeUSDCMetaData, 214030
        );
        yeUSDC.depositAndBridgePermit(amount, recipient, NETWORK_ID_L2, true, permitData);
        vm.stopPrank();

        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount);
        assertEq(yeUSDC.balanceOf(LXLY_BRIDGE), amount); // shares locked in bridge
        assertEq(yeUSDC.reservedAssets(), reserveAmount);
        assertEq(yeUSDC.stakedAssets(), amount - reserveAmount - 1);
        assertEq(yeUSDC.totalAssets(), amount - 1);
    }

    function test_mint() public {
        uint256 amount = 100;

        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.mint(amount, recipient);

        yeUSDC.unpause();
        vm.stopPrank();

        deal(USDC, sender, amount + TRANSFER_FEE);

        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount + TRANSFER_FEE);
        yeUSDC.mint(amount, sender);
        vm.stopPrank();

        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100;
        assertEq(yeUSDC.balanceOf(sender), amount); // shares minted to the sender
        assertEq(yeUSDC.reservedAssets(), reserveAmount);
        assertEq(yeUSDC.stakedAssets(), amount - reserveAmount - 1);
        assertEq(yeUSDC.totalAssets(), amount - 1);
    }

    function test_withdraw() public {
        uint256 initialAmount = 100;
        uint256 reserveAmount = (initialAmount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.withdraw(initialAmount, recipient, owner);
        yeUSDC.unpause();
        vm.stopPrank();

        deal(USDC, sender, initialAmount);

        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), initialAmount);
        yeUSDC.deposit(initialAmount, sender);
        assertEq(IERC20(USDC).balanceOf(sender), 0); // make sure sender has not deposited all USDC
        assertEq(yeUSDC.balanceOf(sender), initialAmount); // sender gets 100 shares

        uint256 withdrawAmount = 110; // withdraw amount is greater than total assets (100)
        vm.expectRevert("AMOUNT_TOO_LARGE");
        yeUSDC.withdraw(withdrawAmount, sender, sender);

        uint256 reserveWithdrawAmount = 5;
        reserveAmount -= reserveWithdrawAmount;
        yeUSDC.withdraw(reserveWithdrawAmount, sender, sender);
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount); // reserve assets reduced
        assertEq(IERC20(USDC).balanceOf(sender), reserveWithdrawAmount); // assets returned to sender
        assertEq(yeUSDC.balanceOf(sender), initialAmount - reserveWithdrawAmount); // shares reduced

        uint256 stakeWithdrawAmount = 10; // withdraw amount is greater than reserve amount (5)
        yeUSDC.withdraw(stakeWithdrawAmount, sender, sender);
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), 0); // reserve assets remain same
        assertEq(IERC20(USDC).balanceOf(sender), reserveWithdrawAmount + stakeWithdrawAmount); // assets returned to sender
        assertEq(yeUSDC.balanceOf(sender), initialAmount - reserveWithdrawAmount - stakeWithdrawAmount); // shares reduced
        vm.stopPrank();
    }

    function test_replenishReserve() public {
        uint256 amount = 100;
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

        vm.expectRevert("NO_NEED_TO_REBALANCE_RESERVE");
        yeUSDC.replenishReserve();

        deal(USDC, sender, amount);
        // create reserve
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, recipient);
        vm.stopPrank();

        vm.prank(address(yeUSDC));
        IERC20(USDC).transfer(address(0xdeed), reserveAmount - 5); // reduce reserve assets
        vm.expectEmit();
        emit ReserveRebalanced(reserveAmount);
        yeUSDC.replenishReserve();
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount);
    }

    function test_rebalanceReserve() public {
        uint256 amount = 100;
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

        deal(USDC, sender, amount);
        // create reserve
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, recipient);
        vm.stopPrank();

        deal(USDC, address(yeUSDC), amount); // add more assets to the reserve
        vm.expectRevert(); // only owner can rebalance reserve
        yeUSDC.rebalanceReserve();

        vm.expectEmit();
        emit ReserveRebalanced(reserveAmount);
        vm.prank(owner);
        yeUSDC.rebalanceReserve();
        assertEq(IERC20(USDC).balanceOf(address(yeUSDC)), reserveAmount);
    }

    function test_collectYield() public {
        vm.expectRevert(); // only owner can claim yield
        yeUSDC.collectYield();

        vm.expectRevert("NO_YIELD"); // no reserved and staked assets
        vm.prank(owner);
        yeUSDC.collectYield();

        uint256 amount = 100;

        // create reserve of 10 assets and 89 staked assets
        deal(USDC, sender, amount + TRANSFER_FEE);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount + TRANSFER_FEE);
        yeUSDC.mint(amount, sender);
        vm.stopPrank();

        uint256 stakedShares = 84403857686151; // 89 assets (value according to USDC vault market price)
        uint256 yield = 89;

        deal(USDC_VAULT, address(yeUSDC), stakedShares * 2); // doubling the staked assets will create a yield of 89

        vm.expectEmit();
        emit YieldCollected(yieldRecipient, yield);
        vm.prank(owner);
        yeUSDC.collectYield();

        vm.assertEq(yeUSDC.balanceOf(yieldRecipient), yield);
    }

    function test_setYieldRecipient_no_yield() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectRevert(); // only owner can claim yield
        yeUSDC.setYieldRecipient(newRecipient);

        vm.expectRevert("INVALID_YIELD_RECIPIENT");
        vm.prank(owner);
        yeUSDC.setYieldRecipient(address(0));

        assertEq(yeUSDC.yieldRecipient(), yieldRecipient);

        vm.expectEmit();
        emit YieldRecipientSet(newRecipient);
        vm.prank(owner);
        yeUSDC.setYieldRecipient(newRecipient);
        assertEq(yeUSDC.yieldRecipient(), newRecipient);
    }

    function test_setYieldRecipient_with_yield() public {
        address newRecipient = makeAddr("newRecipient");
        uint256 amount = 100;

        // generate yield
        uint256 stakedShares = 84403857686151;
        uint256 yield = 89;
        deal(USDC, sender, amount + TRANSFER_FEE);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount + TRANSFER_FEE);
        yeUSDC.mint(amount, sender);
        vm.stopPrank();
        deal(USDC_VAULT, address(yeUSDC), stakedShares * 2);

        assertEq(yeUSDC.yieldRecipient(), yieldRecipient);

        vm.expectEmit();
        emit YieldCollected(yieldRecipient, yield);
        vm.prank(owner);
        yeUSDC.setYieldRecipient(newRecipient);
        assertEq(yeUSDC.balanceOf(yieldRecipient), yield); // yield collected to the old recipient
        assertEq(yeUSDC.yieldRecipient(), newRecipient);
    }

    function test_setMinimumReservePercentage_no_rebalance() public {
        uint8 percentage = 20;
        vm.expectRevert(); // only owner can set minimum reserve percentage
        yeUSDC.setMinimumReservePercentage(percentage);

        vm.expectRevert("INVALID_PERCENTAGE");
        vm.prank(owner);
        yeUSDC.setMinimumReservePercentage(101);

        assertEq(yeUSDC.minimumReservePercentage(), MINIMUM_RESERVE_PERCENTAGE);

        vm.expectEmit();
        emit MinimumReservePercentageSet(percentage);
        vm.prank(owner);
        yeUSDC.setMinimumReservePercentage(percentage);
        assertEq(yeUSDC.minimumReservePercentage(), percentage);
    }

    function test_setMinimumReservePercentage_with_rebalance() public {
        uint256 amount = 100;
        uint8 percentage = 20;
        uint256 reserveAmount = (amount * MINIMUM_RESERVE_PERCENTAGE) / 100; // 10

        deal(USDC, sender, amount);
        // create reserve
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, recipient);
        vm.stopPrank();

        deal(USDC, address(yeUSDC), amount); // add more assets to the reserve
        vm.expectEmit();
        emit ReserveRebalanced(reserveAmount * 2);
        vm.expectEmit();
        emit MinimumReservePercentageSet(percentage);
        vm.prank(owner);
        yeUSDC.setMinimumReservePercentage(percentage);
        assertEq(yeUSDC.minimumReservePercentage(), percentage);
    }

    function testFuzz_setMinimumReservePercentage(uint8 percentage) public {
        vm.assume(percentage <= 100);
        vm.prank(owner);
        yeUSDC.setMinimumReservePercentage(percentage);
        assertEq(yeUSDC.minimumReservePercentage(), percentage);
    }

    function test_redeem() public {
        uint256 initialAmount = 100;
        uint256 redeemAmount = 99; // 1 lost due to rounding

        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.redeem(redeemAmount, sender, sender);
        yeUSDC.unpause();
        vm.stopPrank();

        deal(USDC, sender, initialAmount);

        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), initialAmount);
        yeUSDC.deposit(initialAmount, sender);
        assertEq(IERC20(USDC).balanceOf(sender), 0);
        assertEq(yeUSDC.balanceOf(sender), initialAmount);

        yeUSDC.redeem(redeemAmount, sender, sender); // redeem from both staked and reserved assets
        assertEq(IERC20(USDC).balanceOf(sender), redeemAmount);
    }

    function test_completeMigration_no_discrepancy() public {
        uint256 assets = 100;
        uint256 shares = 100;

        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.completeMigration(assets, NETWORK_ID_L2, shares);
        yeUSDC.unpause();
        vm.stopPrank();

        vm.expectRevert("UNAUTHORIZED");
        yeUSDC.completeMigration(assets, NETWORK_ID_L2, shares);

        vm.expectRevert("INVALID_NETWORK_ID");
        vm.prank(migrationManager);
        yeUSDC.completeMigration(assets, NETWORK_ID_L1, shares);

        vm.expectRevert("INVALID_AMOUNT");
        vm.prank(migrationManager);
        yeUSDC.completeMigration(assets, NETWORK_ID_L2, 0);

        deal(USDC, migrationManager, assets);
        vm.startPrank(migrationManager);
        IERC20(USDC).approve(address(yeUSDC), assets);

        vm.expectEmit();
        emit BridgeEvent(
            LEAF_TYPE_ASSET, NETWORK_ID_L1, address(yeUSDC), NETWORK_ID_L2, address(0), shares, yeUSDCMetaData, 214030
        );
        vm.expectEmit();
        emit Deposit(migrationManager, address(yeUSDC), assets, shares);
        vm.expectEmit();
        emit MigrationCompleted(NETWORK_ID_L2, shares, 0);
        yeUSDC.completeMigration(assets, NETWORK_ID_L2, shares);
        vm.stopPrank();
    }

    function test_completeMigration_with_discrepancy() public {
        uint256 assets = 100;
        uint256 shares = 110;

        deal(USDC, migrationManager, assets);

        vm.startPrank(migrationManager);
        IERC20(USDC).approve(address(yeUSDC), assets);

        vm.expectRevert("INSUFFICIENT_YIELD_TO_COVER_FOR_DISCREPANCY");
        yeUSDC.completeMigration(assets, NETWORK_ID_L2, shares);
        vm.stopPrank();

        // generate yield
        uint256 stakedShares = 84403857686151;
        deal(USDC, sender, assets + TRANSFER_FEE);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), assets + TRANSFER_FEE);
        yeUSDC.mint(assets, sender);
        vm.stopPrank();
        deal(USDC_VAULT, address(yeUSDC), stakedShares * 2);

        vm.expectEmit();
        emit BridgeEvent(
            LEAF_TYPE_ASSET, NETWORK_ID_L1, address(yeUSDC), NETWORK_ID_L2, address(0), shares, yeUSDCMetaData, 214030
        );
        vm.expectEmit();
        emit Deposit(migrationManager, address(yeUSDC), assets, shares);
        vm.expectEmit();
        emit MigrationCompleted(NETWORK_ID_L2, shares, shares - assets); // 10 shares utilized for discrepancy
        vm.prank(migrationManager);
        yeUSDC.completeMigration(assets, NETWORK_ID_L2, shares);
    }

    function test_maxDeposit() public {
        assertEq(yeUSDC.maxDeposit(address(0)), type(uint256).max);

        vm.prank(owner);
        yeUSDC.pause();
        assertEq(yeUSDC.maxDeposit(address(0)), 0);
    }

    function test_previewDeposit() public {
        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.previewDeposit(100);
        yeUSDC.unpause();
        vm.stopPrank();

        vm.expectRevert("INVALID_AMOUNT");
        yeUSDC.previewDeposit(0);

        yeUSDC.previewDeposit(100);
        vm.assertEq(yeUSDC.previewDeposit(100), 100);
    }

    function test_maxMint() public {
        assertEq(yeUSDC.maxMint(address(0)), type(uint256).max);

        vm.prank(owner);
        yeUSDC.pause();
        assertEq(yeUSDC.maxMint(address(0)), 0);
    }

    function test_previewMint() public {
        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.previewMint(100);
        yeUSDC.unpause();
        vm.stopPrank();

        vm.expectRevert("INVALID_AMOUNT");
        yeUSDC.previewMint(0);

        yeUSDC.previewMint(100);
        vm.assertEq(yeUSDC.previewMint(100), 110);
    }

    function test_maxWithdraw() public {
        vm.startPrank(owner);
        yeUSDC.pause();
        vm.assertEq(yeUSDC.maxWithdraw(address(0)), 0);
        yeUSDC.unpause();
        vm.stopPrank();

        assertEq(yeUSDC.maxWithdraw(address(0)), 0); // 0 if no shares

        uint256 amount = 100;
        deal(USDC, sender, amount);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, sender);
        vm.stopPrank();

        assertEq(yeUSDC.maxWithdraw(sender), amount - 1); // 1 lost due to rounding
    }

    function test_previewWithdraw() public {
        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.previewWithdraw(100);
        yeUSDC.unpause();
        vm.stopPrank();

        vm.expectRevert("INVALID_AMOUNT");
        yeUSDC.previewWithdraw(0);

        // create reserve of 10 assets
        uint256 amount = 100;
        deal(USDC, sender, amount);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, sender);
        vm.stopPrank();

        vm.expectRevert("AMOUNT_TOO_LARGE");
        yeUSDC.previewWithdraw(110);

        vm.assertEq(yeUSDC.previewWithdraw(10), 10); // reserve assets
        vm.assertEq(yeUSDC.previewWithdraw(99), 99); // reserve + staked assets
    }

    function test_maxRedeem() public {
        vm.startPrank(owner);
        yeUSDC.pause();
        vm.assertEq(yeUSDC.maxRedeem(sender), 0);
        yeUSDC.unpause();
        vm.stopPrank();

        assertEq(yeUSDC.maxRedeem(sender), 0); // 0 if no shares

        // create reserve of 10 assets and 89 staked assets
        uint256 amount = 100;
        deal(USDC, sender, amount);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, sender);
        vm.stopPrank();

        assertEq(yeUSDC.maxRedeem(sender), amount - 1); // 1 lost due to rounding
    }

    function test_previewRedeem() public {
        vm.startPrank(owner);
        yeUSDC.pause();
        vm.expectRevert(EnforcedPause.selector);
        yeUSDC.previewRedeem(100);
        yeUSDC.unpause();
        vm.stopPrank();

        vm.expectRevert("INVALID_AMOUNT");
        yeUSDC.previewRedeem(0);

        // create reserve of 10 assets and 89 staked assets
        uint256 amount = 100;
        deal(USDC, sender, amount);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, sender);
        vm.stopPrank();

        vm.expectRevert("AMOUNT_TOO_LARGE");
        yeUSDC.previewRedeem(110);

        vm.assertEq(yeUSDC.previewRedeem(10), 10); // reserve assets
        vm.assertEq(yeUSDC.previewRedeem(99), 99); // reserve + staked assets
    }

    function test_reservePercentage() public {
        // create reserve of 10 assets
        uint256 amount = 100;
        deal(USDC, sender, amount);
        vm.startPrank(sender);
        IERC20(USDC).approve(address(yeUSDC), amount);
        yeUSDC.deposit(amount, sender);
        vm.stopPrank();

        assertEq(yeUSDC.reservePercentage(), MINIMUM_RESERVE_PERCENTAGE);
    }

    function test_pause_unpause() public {
        vm.expectRevert();
        yeUSDC.pause();

        vm.expectRevert();
        yeUSDC.unpause();

        vm.startPrank(owner);
        vm.expectEmit();
        emit Paused(owner);
        yeUSDC.pause();

        vm.expectEmit();
        emit Unpaused(owner);
        yeUSDC.unpause();
        vm.stopPrank();
    }

    function test_version() public view {
        assertEq(yeUSDC.version(), YEUSDC_VERSION);
    }

    //TODO: test claimAndWithdraw

    function test_approve() public {
        assertTrue(yeUSDC.approve(address(0xBEEF), 1e18));

        assertEq(yeUSDC.allowance(address(this), address(0xBEEF)), 1e18);
    }

    function test_transfer() public {
        deal(address(yeUSDC), address(this), 1e18);

        assertTrue(yeUSDC.transfer(address(0xBEEF), 1e18));

        assertEq(yeUSDC.balanceOf(address(this)), 0);
        assertEq(yeUSDC.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_transferFrom() public {
        address from = address(0xABCD);
        deal(address(yeUSDC), from, 1e18);

        vm.prank(from);
        yeUSDC.approve(address(this), 1e18);

        assertTrue(yeUSDC.transferFrom(from, address(0xBEEF), 1e18));

        assertEq(yeUSDC.allowance(from, address(this)), 0);

        assertEq(yeUSDC.balanceOf(from), 0);
        assertEq(yeUSDC.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_infiniteApproveTransferFrom() public {
        address from = address(0xABCD);
        deal(address(yeUSDC), from, 1e18);

        vm.prank(from);
        yeUSDC.approve(address(this), type(uint256).max);

        assertTrue(yeUSDC.transferFrom(from, address(0xBEEF), 1e18));

        assertEq(yeUSDC.allowance(from, address(this)), type(uint256).max);

        assertEq(yeUSDC.balanceOf(from), 0);
        assertEq(yeUSDC.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_failTransferInsufficientBalance() public {
        deal(address(yeUSDC), address(this), 0.9e18);
        vm.expectRevert();
        yeUSDC.transfer(address(0xBEEF), 1e18);
    }

    function test_failTransferFromInsufficientAllowance() public {
        address from = address(0xABCD);

        deal(address(yeUSDC), address(this), 1e18);

        vm.prank(from);
        yeUSDC.approve(address(this), 0.9e18);

        vm.expectRevert();
        yeUSDC.transferFrom(from, address(0xBEEF), 1e18);
    }

    function test_failTransferFromInsufficientBalance() public {
        address from = address(0xABCD);

        deal(address(yeUSDC), address(this), 0.9e18);

        vm.prank(from);
        yeUSDC.approve(address(this), 1e18);

        vm.expectRevert();
        yeUSDC.transferFrom(from, address(0xBEEF), 1e18);
    }

    function test_permit() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            senderPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    yeUSDC.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(PERMIT_TYPEHASH, sender, address(0xCAFE), 1e18, vm.getNonce(sender), block.timestamp)
                    )
                )
            )
        );

        vm.prank(sender);
        yeUSDC.permit(sender, address(0xCAFE), 1e18, block.timestamp, v, r, s);

        assertEq(yeUSDC.allowance(sender, address(0xCAFE)), 1e18);
        assertEq(yeUSDC.nonces(sender), 1);
    }

    function _proxify(address logic, address admin, bytes memory initData) internal returns (address proxy) {
        proxy = address(new TransparentUpgradeableProxy(logic, admin, initData));
    }
}
