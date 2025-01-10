// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Plus} from "./etc/IERC20Plus.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Native Converter
/// @notice Native Converter lives on Layer Ys and converts the bridge-wrapped underlying token to the custom token on demand, and vice versa, and can migrate backing of the custom token it has minted on Layer Y to Layer X.
/// @dev This contract must have mint and burn permission on the custom token.
abstract contract NativeConverter is Initializable, OwnableUpgradeable, PausableUpgradeable, IVersioned {
    // Libraries.
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Plus;

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
        uint256 backingOnLayerY;
        uint256 dailyMigrationLimit;
        uint256 dailyMigratedAmount;
        uint256 midnightTimestamp;
        ILxLyBridge lxlyBridge;
        uint32 layerXNetworkId;
        address migrationManager;
    }

    /// @dev The storage slot at which Migration Manager storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.NativeConverter")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _NATIVE_CONVERTER_STORAGE =
        0xb6887066a093cfbb0ec14b46507f657825a892fd6a4c4a1ef4fc83e8c7208c00;

    // Events.
    event MigrationStarted(address indexed sender, uint256 amount);
    event DailyMigrationLimitSet(uint256 dailyMigrationLimit);

    /// @param customToken_ The token custom mapped to yeToken on LxLy Bridge on Layer Y.
    /// @param wrappedUnderlyingToken_ The original wrapped token created by LxLy Bridge represent the underlying token on Layer Y.
    /// @param dailyMigrationLimit_ The maximum amount of backing anyone can be migrate to Layer X in 24 hours; the owner can migrate any amount at any time.
    /// @param migrationManager_ The address of Migration Manager on Layer X.
    function __NativeConverter_init(
        address owner_,
        address customToken_,
        address wrappedUnderlyingToken_,
        uint256 dailyMigrationLimit_,
        address lxlyBridge_,
        uint32 layerXNetworkId_,
        address migrationManager_
    ) external onlyInitializing {
        // Check the inputs.
        require(owner_ != address(0), "INVALID_OWNER");
        require(customToken_ != address(0), "INVALID_CUSTOM_TOKEN");
        require(wrappedUnderlyingToken_ != address(0), "INVALID_WRAPPED_UNDERLYING_TOKEN");
        require(dailyMigrationLimit_ > 0, "INVALID_MIGRATION_24_HOUR_LIMIT");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");
        require(migrationManager_ != address(0), "INVALID_MIGRATION_MANAGER");

        // Initialize the inherited contracts.
        __Ownable_init(owner_);
        __Pausable_init();

        // Initialize the storage.
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        $.customToken = IERC20Plus(customToken_);
        $.wrappedUnderlyingToken = IERC20(wrappedUnderlyingToken_);
        $.dailyMigrationLimit = dailyMigrationLimit_;
        $.lxlyBridge = ILxLyBridge(lxlyBridge_);
        $.layerXNetworkId = layerXNetworkId_;
        $.migrationManager = migrationManager_;

        // @note Check security implications.
        // Approve LxLy Bridge.
        $.wrappedUnderlyingToken.forceApprove(address($.lxlyBridge), type(uint256).max);
    }

    // -----================= ::: STORAGE ::: =================-----

    /// @notice The token custom mapped to yeToken on LxLy Bridge on Layer Y.
    function customToken() public view returns (IERC20) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.customToken;
    }

    /// @notice The original wrapped token created by LxLy Bridge represent the underlying token on Layer Y.
    function wrappedUnderlyingToken() public view returns (IERC20) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.wrappedUnderlyingToken;
    }

    /// @notice The amount of the wrapped underlying token that backs the custom token minted by Native Converter that has not been migrated to Layer X.
    function backingOnLayerY() public view returns (uint256) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.backingOnLayerY;
    }

    /// @notice The maximum amount of backing anyone can be migrate to Layer X in 24 hours.
    /// @notice The owner can migrate any amount at any time.
    function dailyMigrationLimit() public view returns (uint256) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.dailyMigrationLimit;
    }

    /// @notice LxLy Bridge, which connects AggLayer networks.
    function lxlyBridge() public view returns (ILxLyBridge) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.lxlyBridge;
    }

    /// @notice The LxLy ID of Layer X.
    function layerXNetworkId() public view returns (uint32) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.layerXNetworkId;
    }

    /// @notice The address of Migration Manager on Layer X.
    function migrationManager() public view returns (address) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.migrationManager;
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getNativeConverterStorage() private pure returns (NativeConverterStorage storage $) {
        assembly {
            $.slot := _NATIVE_CONVERTER_STORAGE
        }
    }

    // -----================= ::: NATIVE CONVERTER ::: =================-----

    /// @notice Locks the wrapped underlying token and mints the custom token.
    function convert(uint256 amount) external whenNotPaused {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Transfer the wrapped underlying token from the caller to itself.
        // Bridge-wrapped tokens do not have a transfer fee.
        $.wrappedUnderlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        // @note Handle different decimals.
        // Mint the custom token to the caller.
        $.customToken.mint(msg.sender, amount);

        // Update the amount backing for migration.
        $.backingOnLayerY += amount;
    }

    /// @notice Burns the custom token and unlocks the wrapped underlying token.
    function deconvert(uint256 amount) external whenNotPaused {
        _deconvert(amount, address(0), false);
    }

    /// @notice Burns the custom token and bridges the wrapped underlying token to the destination address on Layer X.
    function deconvertAndBridgeToLayerX(uint256 amount, address destinationAddress, bool forceUpdateGlobalExitRoot)
        external
        whenNotPaused
    {
        _deconvert(amount, destinationAddress, forceUpdateGlobalExitRoot);
    }

    /// @notice Burns the custom token and unlocks the wrapped underlying token or bridges it to the destination address on Layer X.
    function _deconvert(uint256 amount, address destinationAddress, bool forceUpdateGlobalExitRoot) internal {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Burn the custom token from the caller.
        $.customToken.burn(msg.sender, amount);

        // If no address is specified, deconvert without bridging.
        if (destinationAddress == address(0)) {
            // @note Handle different decimals.
            // Transfer the wrapped underlying token to the caller.
            $.wrappedUnderlyingToken.safeTransfer(msg.sender, amount);
        } else {
            // @note Handle different decimals.
            // Bridge the wrapped underlying token to the destination address on Layer X.
            $.lxlyBridge.bridgeAsset(
                $.layerXNetworkId,
                destinationAddress,
                amount,
                address($.wrappedUnderlyingToken),
                forceUpdateGlobalExitRoot,
                ""
            );
        }

        // @note Handle different decimals.
        // Update the amount of backing for migration.
        $.backingOnLayerY -= amount;
    }

    /// @notice Migrates a limited amount of backing to Layer X.
    /// @notice This action provides yeToken liquidity on LxLy Bridge on Layer X.
    /// @notice The bridged assets and message must be claimed for Migration Manager on Layer X to complete the migration.
    /// @notice This function can be called by anyone.
    function migrateBackingToLayerX() external whenNotPaused {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Reset the daily migration limit if a new day has started.
        if (block.timestamp > $.midnightTimestamp + 1 days) {
            $.midnightTimestamp = block.timestamp;
            $.dailyMigratedAmount = 0;
        }

        // Check the daily migration limit.
        require($.dailyMigratedAmount <= $.dailyMigrationLimit, "DAILY_MIGRATION_LIMIT_REACHED");

        // Calculate the amount to migrate.
        uint256 amountToMigrate = $.dailyMigrationLimit - $.dailyMigratedAmount;
        amountToMigrate = amountToMigrate > $.backingOnLayerY ? $.backingOnLayerY : amountToMigrate;

        // Update the daily migrated amount.
        $.dailyMigratedAmount += amountToMigrate;

        // Migrate the backing to Layer X.
        _migrateBackingToLayerX(amountToMigrate);
    }

    /// @notice Migrates a specific amount of backing to Layer X.
    /// @notice This action provides yeToken liquidity on LxLy Bridge on Layer X.
    /// @notice The bridged assets and message must be claimed for Migration Manager on Layer X to complete the migration.
    /// @notice This function can be called by the owner only.
    /// @dev This function does not update the daily migration limit.
    function migrateBackingToLayerX(uint256 amount) external whenNotPaused onlyOwner {
        _migrateBackingToLayerX(amount);
    }

    /// @dev Migrates a specific amount of backing to Layer X.
    function _migrateBackingToLayerX(uint256 amount) internal {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Update the amount of backing for migration.
        $.backingOnLayerY -= amount;

        // Bridge the backing to Migration Manager on Layer X.
        $.lxlyBridge.bridgeAsset(
            $.layerXNetworkId, $.migrationManager, amount, address($.wrappedUnderlyingToken), true, ""
        );

        // Bridge a message to Migration Manager on Layer X to complete the migration.
        $.lxlyBridge.bridgeMessage(
            $.layerXNetworkId, $.migrationManager, true, abi.encode(CrossNetworkInstruction.COMPLETE_MIGRATION, amount)
        );

        // Emit the event.
        emit MigrationStarted(msg.sender, amount);
    }

    /// @notice Sets the daily migration limit.
    /// @notice This function can be called by the owner only.
    function setDailyMigrationLimit(uint256 dailyMigrationLimit_) external onlyOwner whenNotPaused {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Set the daily migration limit.
        $.dailyMigrationLimit = dailyMigrationLimit_;

        // Emit the event.
        emit DailyMigrationLimitSet(dailyMigrationLimit_);
    }

    // -----================= ::: ADMIN ::: =================-----

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

    // -----================= ::: INFO ::: =================-----

    /// @inheritdoc IVersioned
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}

// @todo Reentrancy review.
// @todo @notes.
