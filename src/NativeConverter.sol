// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Plus} from "./etc/IERC20Plus.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibPermit} from "./etc/LibPermit.sol";

import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Native Converter
/// @notice Native Converter lives on Layer Ys and converts the underlying token to the custom token, and vice versa, on demand. It can also migrate backing for the custom token it has minted on Layer Y to Layer X.
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
        IERC20 underlyingToken;
        uint256 backingOnLayerY;
        // @note Using 1 for 1%.
        uint256 nonMigratableBackingPercentage;
        uint256 minimumBackingAfterMigration;
        uint32 lxlyId;
        ILxLyBridge lxlyBridge;
        uint32 layerXNetworkId;
        address migrationManager;
    }

    /// @dev The storage slot at which Migration Manager storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.NativeConverter")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _NATIVE_CONVERTER_STORAGE =
        0xb6887066a093cfbb0ec14b46507f657825a892fd6a4c4a1ef4fc83e8c7208c00;

    // Events.
    event MigrationStarted(address indexed sender, uint256 indexed customTokenAmount, uint256 backingAmount);
    event NonMigratableBackingPercentageChanged(uint256 nonMigratableBackingPercentage);

    /// @param originalUnderlyingTokenDecimals_ The number of decimals of the original underlying token on Layer X. The `customToken` and `underlyingToken` must have the same number of decimals as the original underlying token.
    /// @param customToken_ The token custom mapped to the custom token on LxLy Bridge on Layer Y.
    /// @param underlyingToken_ The token that represents the original underlying token on Layer Y. Important: This token MUST be either the bridge-wrapped version of the original underlying token, or the original underlying token must be custom mapped to this token on LxLy Bridge on Layer Y.
    /// @param nonMigratableBackingPercentage_ The percentage of the total supply of the custom token on Layer Y for which backing cannot be migrated to Layer X; 1 is 1%. The limit does not apply to the owner. Accounts with large custom token balances may be able to circumvent the limit by quickly bridging to another network, migrating backing, and immediately bridging back, which would prevent others to deconvert the custom token on Layer Y. The next parameter is used to mitigate this risk.
    /// @param minimumBackingAfterMigration_ The minimum amount of backing (the underlying token) that must remain on Layer Y after a migration. The limit does not apply to the owner. Mitigates the risk of accounts with large custom token balances completely draining Native Converter.
    /// @param migrationManager_ The address of Migration Manager on Layer X.
    function __NativeConverter_init(
        address owner_,
        uint8 originalUnderlyingTokenDecimals_,
        address customToken_,
        address underlyingToken_,
        uint256 nonMigratableBackingPercentage_,
        uint256 minimumBackingAfterMigration_,
        address lxlyBridge_,
        uint32 layerXNetworkId_,
        address migrationManager_
    ) internal onlyInitializing {
        // Check the inputs.
        require(owner_ != address(0), "INVALID_OWNER");
        require(customToken_ != address(0), "INVALID_CUSTOM_TOKEN");
        require(underlyingToken_ != address(0), "INVALID_UNDERLYING_TOKEN");
        require(nonMigratableBackingPercentage_ <= 100, "INVALID_MINIMUM_BACKING_PERCENTAGE");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");
        require(migrationManager_ != address(0), "INVALID_MIGRATION_MANAGER");

        // Check the custom token's decimals.
        uint8 customTokenDecimals;
        try IERC20Metadata(customToken_).decimals() returns (uint8 decimals) {
            customTokenDecimals = decimals;
        } catch {
            // Default to 18 decimals.
            customTokenDecimals = 18;
        }
        require(customTokenDecimals == originalUnderlyingTokenDecimals_, "INVALID_CUSTOM_TOKEN_DECIMALS");

        // Check the underlying token's decimals.
        uint8 underlyingTokenDecimals;
        try IERC20Metadata(underlyingToken_).decimals() returns (uint8 decimals_) {
            underlyingTokenDecimals = decimals_;
        } catch {
            // Default to 18 decimals.
            underlyingTokenDecimals = 18;
        }
        require(underlyingTokenDecimals == originalUnderlyingTokenDecimals_, "INVALID_UNDERLYING_TOKEN_DECIMALS");

        // Initialize the inherited contracts.
        __Ownable_init(owner_);
        __Pausable_init();

        // Initialize the storage.
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        $.customToken = IERC20Plus(customToken_);
        $.underlyingToken = IERC20(underlyingToken_);
        $.nonMigratableBackingPercentage = nonMigratableBackingPercentage_;
        $.minimumBackingAfterMigration = minimumBackingAfterMigration_;
        $.lxlyId = ILxLyBridge(lxlyBridge_).networkID();
        $.lxlyBridge = ILxLyBridge(lxlyBridge_);
        $.layerXNetworkId = layerXNetworkId_;
        $.migrationManager = migrationManager_;

        // @note Check security implications.
        // Approve LxLy Bridge.
        $.underlyingToken.forceApprove(address($.lxlyBridge), type(uint256).max);
    }

    // -----================= ::: STORAGE ::: =================-----

    /// @notice The token custom mapped to the custom token on LxLy Bridge on Layer Y.
    function customToken() public view returns (IERC20) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.customToken;
    }

    /// @notice The token that represent the original underlying token on Layer Y.
    function underlyingToken() public view returns (IERC20) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.underlyingToken;
    }

    /// @notice The amount of the underlying token that backs the custom token minted by Native Converter on Layer Y that has not been migrated to Layer X.
    /// @dev The amount is used in accounting and may be different from Native Converter's underlying token balance. You may do as you wish with surplus underlying token balance, but you MUST NOT designate it as backing.
    function backingOnLayerY() public view returns (uint256) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.backingOnLayerY;
    }

    /// @notice The percentage of the total supply of the custom token on Layer Y for which backing cannot be migrated to Layer X; 1 is 1%.
    /// @notice The limit does not apply to the owner.
    function nonMigratableBackingPercentage() public view returns (uint256) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.nonMigratableBackingPercentage;
    }

    /// @notice The minimum amount of backing that must remain on Layer Y after a migration.
    /// @notice The limit does not apply to the owner.
    function minimumBackingAfterMigration() public view returns (uint256) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return $.minimumBackingAfterMigration;
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

    // -----================= ::: PSEUDO ERC-4626 ::: =================-----

    /// @notice Deposit a specific amount of the underlying token and get the custom token.
    function convert(uint256 assets, address receiver) public whenNotPaused returns (uint256 shares) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Check the inputs.
        require(assets > 0, "INVALID_AMOUNT");
        require(receiver != address(0), "INVALID_ADDRESS");

        // Transfer the underlying token from the sender to itself.
        assets = _receiveUnderlyingToken(msg.sender, assets);

        // Set the return value.
        shares = _convertToShares(assets);

        // Mint the custom token to the receiver.
        $.customToken.mint(receiver, shares);

        // Update the backing data.
        $.backingOnLayerY += assets;
    }

    /// @notice Deposit a specific amount of the underlying token and get the custom token.
    /// @dev Uses EIP-2612 permit to transfer the underlying token from the sender to itself.
    function convertWithPermit(uint256 assets, address receiver, bytes calldata permitData)
        external
        whenNotPaused
        returns (uint256 shares)
    {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Use the permit.
        if (permitData.length > 0) {
            LibPermit.permit(address($.underlyingToken), assets, permitData);
        }

        return convert(assets, receiver);
    }

    /// @notice How much the custom token a specific user can burn. (Burning the custom token unlocks the underlying token).
    function maxDeconvert(address owner) external view returns (uint256 maxShares) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Return zero if the contract is paused.
        if (paused()) return 0;

        // Return zero if the balance is zero.
        uint256 shares = $.customToken.balanceOf(owner);
        if (shares == 0) return 0;

        return _simulateDeconvert(shares, false);
    }

    /// @dev Calculates the amount of the custom token that can be deconverted right now.
    /// @param shares The maximum amount of the custom token to simulate deconversion for.
    /// @param force Whether to enforce the amount, reverting if it cannot be met.
    function _simulateDeconvert(uint256 shares, bool force) internal view returns (uint256 deconvertedShares) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Check the input.
        require(shares > 0, "INVALID_AMOUNT");

        // Switch to the underlying token.
        uint256 assets = _convertToAssets(shares);

        // The amount that cannot be deconverted at the moment (in the underlying token).
        uint256 remainingAssets = assets;

        // Simulate withdrawal.
        uint256 backingOnLayerY_ = $.backingOnLayerY;
        if (backingOnLayerY_ >= remainingAssets) return shares;
        remainingAssets -= backingOnLayerY_;

        // Revert if the `assets` is enforced and there is a remaining amount.
        if (force) require(remainingAssets == 0, "AMOUNT_TOO_LARGE");

        // Return the amount of the custom token that can be deconverted right now.
        return _convertToShares(assets - remainingAssets);
    }

    /// @notice Burn a specific amount of the custom token and unlock a respective amount of the underlying token.
    function deconvert(uint256 shares, address receiver) external whenNotPaused returns (uint256 assets) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();
        return _deconvert(shares, $.lxlyId, receiver, false);
    }

    /// @notice Burn a specific amount of the custom token and unlock a respective amount of the underlying token, and bridge it to another network.
    function deconvertAndBridge(
        uint256 shares,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot
    ) public whenNotPaused returns (uint256 assets) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Check the input.
        require(destinationNetworkId != $.lxlyId, "INVALID_NETWORK");

        return _deconvert(shares, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot);
    }

    /// @notice Burn a specific amount of the custom token and unlock a respective amount of the underlying token, and optionally bridge it to another network.
    function _deconvert(
        uint256 shares,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot
    ) public whenNotPaused returns (uint256 assets) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Check the inputs.
        require(shares > 0, "INVALID_AMOUNT");
        require(destinationAddress != address(0), "INVALID_ADDRESS");

        // Switch to the underlying token.
        // Set the return value.
        assets = _convertToAssets(shares);

        // Get the available backing.
        uint256 backingOnLayerY_ = backingOnLayerY();

        // Try to deconvert.
        if (backingOnLayerY_ >= assets) {
            // Update the backing data.
            $.backingOnLayerY -= assets;

            // Burn the custom token.
            $.customToken.burn(msg.sender, shares);

            // Withdraw the underlying token.
            if (destinationNetworkId == $.lxlyId) {
                // Withdraw to the receiver.
                _sendUnderlyingToken(destinationAddress, assets);
            } else {
                // Bridge to the receiver.
                $.lxlyBridge.bridgeAsset(
                    destinationNetworkId,
                    destinationAddress,
                    assets,
                    address($.underlyingToken),
                    forceUpdateGlobalExitRoot,
                    ""
                );
            }
        } else {
            // Revert if the backing on Layer Y is insufficient to serve the withdrawal.
            revert("AMOUNT_TOO_LARGE");
        }
    }

    /// @notice Tells how much a specific amount of underlying token is worth in the custom token.
    function _convertToShares(uint256 assets) internal pure returns (uint256 shares) {
        // The underlying token backs the custom token 1:1.
        // Caution! Changing this function will affect the conversion rate for the entire contract.
        shares = assets;
    }

    /// @notice Tells how much a specific amount of the custom token is worth in the underlying token.
    function _convertToAssets(uint256 shares) internal pure returns (uint256 assets) {
        // The custom token is backed by the underlying token 1:1.
        // Caution! Changing this function will affect the conversion rate for the entire contract.
        assets = shares;
    }

    // -----================= ::: NATIVE CONVERTER ::: =================-----

    /// @notice The amount of backing that can be migrated to Layer X right now.
    function migratableBacking() public view returns (uint256) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Calculate the amount that cannot be migrated.
        // @note Check rounding.
        uint256 nonMigratableBacking =
            (_convertToAssets($.customToken.totalSupply()) * $.nonMigratableBackingPercentage) / 100;

        // Increase the amount that cannot be migrated if it is below the minimum.
        if (nonMigratableBacking < $.minimumBackingAfterMigration) {
            nonMigratableBacking = $.minimumBackingAfterMigration;
        }

        // Get the current backing on Layer Y.
        uint256 backingOnLayerY_ = backingOnLayerY();

        // Return zero if the limit has been reached.
        if (backingOnLayerY_ <= nonMigratableBacking) return 0;

        // Calculate the amount that can be migrated.
        return backingOnLayerY_ - nonMigratableBacking;
    }

    /// @notice Migrates a limited amount of backing to Layer X.
    /// @notice This action provides the custom token liquidity on LxLy Bridge on Layer X.
    /// @notice The bridged assets and message must be claimed for Migration Manager on Layer X to complete the migration.
    /// @notice This function can be called by anyone.
    function migrateBackingToLayerX() external whenNotPaused {
        _migrateBackingToLayerX(migratableBacking());
    }

    /// @notice Migrates a specific amount of backing to Layer X. Limits do not apply.
    /// @notice This action provides the custom token liquidity on LxLy Bridge on Layer X.
    /// @notice The bridged assets and message must be claimed for Migration Manager on Layer X to complete the migration.
    /// @notice This function can be called by the owner only.
    function migrateBackingToLayerX(uint256 amount) external whenNotPaused onlyOwner {
        _migrateBackingToLayerX(amount);
    }

    /// @dev Migrates a specific amount of backing to Layer X.
    function _migrateBackingToLayerX(uint256 amount) internal {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Check the input.
        require(amount > 0, "INVALID_AMOUNT");
        require(amount <= $.backingOnLayerY, "AMOUNT_TOO_LARGE");

        // Update the backing data.
        $.backingOnLayerY -= amount;

        // Precalculate the amount of the custom token for which backing is being migrated.
        uint256 amountOfCustomToken = _convertToShares(amount);

        // Bridge the backing to Migration Manager on Layer X.
        uint256 previousBalance = $.underlyingToken.balanceOf(address($.lxlyBridge));
        $.lxlyBridge.bridgeAsset($.layerXNetworkId, $.migrationManager, amount, address($.underlyingToken), true, "");
        amount = $.underlyingToken.balanceOf(address($.lxlyBridge)) - previousBalance;

        // Bridge a message to Migration Manager on Layer X to complete the migration.
        $.lxlyBridge.bridgeMessage(
            $.layerXNetworkId,
            $.migrationManager,
            true,
            abi.encode(CrossNetworkInstruction.COMPLETE_MIGRATION, amountOfCustomToken, amount)
        );

        // Emit the event.
        emit MigrationStarted(msg.sender, amountOfCustomToken, amount);
    }

    /// @notice Sets the non-migratable backing percentage.
    /// @notice The limit does not apply to the owner.
    /// @notice This function can be called by the owner only.
    function changeNonMigratableBackingPercentage(uint256 nonMigratableBackingPercentage_)
        external
        onlyOwner
        whenNotPaused
    {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Check the input.
        require(nonMigratableBackingPercentage_ <= 100, "INVALID_BACKING_PERCENTAGE");

        // Set the non-migratable backing percentage.
        $.nonMigratableBackingPercentage = nonMigratableBackingPercentage_;

        // Emit the event.
        emit NonMigratableBackingPercentageChanged(nonMigratableBackingPercentage_);
    }

    // -----================= ::: ADMIN ::: =================-----

    /// @notice Prevents usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allows usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -----================= ::: INFO ::: =================-----

    /// @inheritdoc IVersioned
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    // -----================= ::: DEV ::: =================-----

    /// @notice Transfers the underlying token from an external account to itself.
    /// @dev This function can be overridden to implement custom transfer logic.
    function _receiveUnderlyingToken(address from, uint256 value) internal virtual returns (uint256 receivedValue) {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Transfer the underlying token.
        uint256 previousBalance = $.underlyingToken.balanceOf(address(this));
        $.underlyingToken.safeTransferFrom(from, address(this), value);
        receivedValue = $.underlyingToken.balanceOf(address(this)) - previousBalance;
    }

    /// @notice Transfers the underlying token to an external account.
    /// @dev This function can be overridden to implement custom transfer logic.
    function _sendUnderlyingToken(address to, uint256 value) internal virtual {
        NativeConverterStorage storage $ = _getNativeConverterStorage();

        // Transfer the underlying token.
        $.underlyingToken.safeTransfer(to, value);
    }
}

// @todo Reentrancy review.
// @todo @notes.
