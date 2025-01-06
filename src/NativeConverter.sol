// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Plus} from "./etc/IERC20Plus.sol";

import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Native Converter
/// @notice Native Converter lives on L2s and converts the bridge-wrapped underlying token to the custom token on demand, and vice versa, and can migrate backing of the custom token it has minted on an L2 to the L1.
/// @dev This contract must have mint and burn permissions on the custom token.
abstract contract NativeConverter is Initializable, OwnableUpgradeable, PausableUpgradeable, IVersioned {
    /// @dev Used in cross-network communication.
    enum CrossNetworkInstruction {
        COMPLETE_MIGRATION
    }

    /**
     * @dev Storage of the Native Converter contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.NativeConverter
     */
    struct NativeConverterStorage {
        IERC20Plus customToken;
        IERC20 wrappedUnderlyingToken;
        ILxLyBridge lxlyBridge;
        uint32 l1NetworkID;
        address migrationManager;
        uint256 unmigratedBacking;
    }

    /// @dev The storage slot at which Migration Manager storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.NativeConverter")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _NATIVE_CONVERTER_STORAGE =
        0xb6887066a093cfbb0ec14b46507f657825a892fd6a4c4a1ef4fc83e8c7208c00;

    constructor() {
        _disableInitializers();
    }

    /// param customToken_ The token custom mapped to yeToken on LxLy Bridge on the L2.
    /// @param wrappedUnderlyingToken_ The original wrapped token created by LxLy Bridge represent the underlying token on the L2.
    /// @param migrationManager_ The address of Migration Manager on the L1.
    function initialize(
        address owner_,
        address customToken_,
        address wrappedUnderlyingToken_,
        address lxlyBridge_,
        uint32 l1NetworkID_,
        address migrationManager_
    ) external initializer {
        // Check the inputs.
        require(owner_ != address(0), "INVALID_OWNER");
        require(customToken_ != address(0), "INVALID_CUSTOM_TOKEN");
        require(wrappedUnderlyingToken_ != address(0), "INVALID_WRAPPED_UNDERLYING_TOKEN");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");
        require(migrationManager_ != address(0), "INVALID_MIGRATION_MANAGER");

        // Initialize the inherited contracts.
        __Ownable_init(owner_);
        __Pausable_init();

        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Initialize the storage.
        $.customToken = IERC20Plus(customToken_);
        $.wrappedUnderlyingToken = IERC20(wrappedUnderlyingToken_);
        $.lxlyBridge = ILxLyBridge(lxlyBridge_);
        $.l1NetworkID = l1NetworkID_;
        $.migrationManager = migrationManager_;

        // Approve LxLy Bridge.
        $.wrappedUnderlyingToken.approve(address($.lxlyBridge), type(uint256).max);
    }

    /// @notice Locks the wrapped underlying token and mints the custom token.
    /// @notice Transfer fees of the custom token may apply.
    function convert(uint256 amount) external whenNotPaused {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Transfer the wrapped underlying token from the caller to itself.
        // Bridge-wrapped tokens do not have a transfer fee.
        $.wrappedUnderlyingToken.transferFrom(msg.sender, address(this), amount);

        // Mint the custom token to the caller.
        $.customToken.mint(msg.sender, amount);

        // Update the backing for migration.
        $.unmigratedBacking += amount;
    }

    /// @notice Burns the custom token and unlocks the wrapped underlying token.
    /// @notice Transfer fees of the custom token may apply.
    function deconvert(uint256 amount) external whenNotPaused {
        _deconvert(amount, address(0), false);
    }

    /// @notice Burns the custom token and bridges the wrapped underlying token to the destination address on the L1.
    /// @notice Transfer fees of the custom token may apply.
    function deconvertAndBridgeBack(uint256 amount, address destinationAddress, bool forceUpdateGlobalExitRoot)
        external
        whenNotPaused
    {
        _deconvert(amount, destinationAddress, forceUpdateGlobalExitRoot);
    }

    /// @notice Burns the custom token and unlocks the wrapped underlying token or bridges it to the destination address on the L1.
    function _deconvert(uint256 amount, address destinationAddress, bool forceUpdateGlobalExitRoot) internal {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Transfer the custom token from the caller to itself.
        uint256 previousBalance = $.customToken.balanceOf(address(this));
        $.customToken.transferFrom(msg.sender, address(this), amount);
        amount = $.customToken.balanceOf(address(this)) - previousBalance;

        // Burn the custom token.
        $.customToken.burn(msg.sender, amount);

        // If no address is specified, deconvert without bridging.
        if (destinationAddress == address(0)) {
            // Transfer the wrapped underlying token to the caller.
            $.wrappedUnderlyingToken.transfer(msg.sender, amount);
        } else {
            // Bridge the wrapped underlying token to the destination address on the L1.
            $.lxlyBridge.bridgeAsset(
                $.l1NetworkID,
                destinationAddress,
                amount,
                address($.wrappedUnderlyingToken),
                forceUpdateGlobalExitRoot,
                ""
            );
        }

        // Update the backing for migration.
        $.unmigratedBacking -= amount;
    }

    /// @notice Migrates the backing of the custom token to the L1.
    /// @notice This function can be called by anyone.
    function migrateBacking() external whenNotPaused {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Bridge the backing to Migration Manager on the L1.
        $.lxlyBridge.bridgeAsset(
            $.l1NetworkID, $.migrationManager, $.unmigratedBacking, address($.wrappedUnderlyingToken), true, ""
        );

        // Bridge a message to Migration Manager on the L1 to complete the migration.
        $.lxlyBridge.bridgeMessage(
            $.l1NetworkID,
            $.migrationManager,
            true,
            abi.encode(CrossNetworkInstruction.COMPLETE_MIGRATION, $.unmigratedBacking)
        );

        // Reset the unmigrated backing amount.
        $.unmigratedBacking = 0;
    }

    /// @notice Prevents usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allowes usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getNativeConverterStorage() private pure returns (NativeConverterStorage storage $) {
        assembly {
            $.slot := _NATIVE_CONVERTER_STORAGE
        }
    }

    /// @inheritdoc IVersioned
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}

// @todo Handle different decimals in calculations.
