// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {YieldExposedToken} from "./YieldExposedToken.sol";
import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Migration Manager
/// @notice Backing for the custom token that was minted on a Layer Y by Native Converter is migrated to Migration Manager on Layer X, which completes migrations by calling yeToken to mint and bridge yeToken to address zero on that Layer Y.
abstract contract MigrationManager is Initializable, OwnableUpgradeable, PausableUpgradeable, IVersioned {
    // Libraries.
    using SafeERC20 for IERC20;

    /// @dev Used in cross-network communication.
    enum CrossNetworkInstruction {
        COMPLETE_MIGRATION
    }

    /**
     * @dev Storage of the Migration Manager contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.MigrationManager
     */
    struct MigrationManagerStorage {
        YieldExposedToken yeToken;
        IERC20 underlyingToken;
        ILxLyBridge lxlyBridge;
        address nativeConverter;
    }

    /// @dev The storage slot at which Migration Manager storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.MigrationManager")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _MIGRATION_MANAGER_STORAGE =
        0xaec447ccc4dc1a1a20af7f847edd1950700343642e68dd8266b4de5e0e190a00;

    /// @param nativeConverter_ The address of Native Converter on Layer Ys.
    function __MigrationManager_init(address owner_, address yeToken_, address nativeConverter_)
        internal
        onlyInitializing
    {
        // Check the inputs.
        require(owner_ != address(0), "INVALID_OWNER");
        require(yeToken_ != address(0), "INVALID_YETOKEN");
        require(nativeConverter_ != address(0), "INVALID_CONVERTER");

        // Initialize the inherited contracts.
        __Ownable_init(owner_);
        __Pausable_init();

        // Initialize the storage.
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        $.yeToken = YieldExposedToken(yeToken_);
        $.underlyingToken = YieldExposedToken(yeToken_).underlyingToken();
        $.lxlyBridge = YieldExposedToken(yeToken_).lxlyBridge();
        $.nativeConverter = nativeConverter_;

        // Approve yeToken.
        $.underlyingToken.forceApprove(yeToken_, type(uint256).max);
    }

    // -----================= ::: STORAGE ::: =================-----

    /// @notice yeToken this Migration Manager belongs to.
    function yeToken() public view returns (YieldExposedToken) {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        return $.yeToken;
    }

    /// @notice The underlying token that backs yeToken.
    function underlyingToken() public view returns (IERC20) {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        return $.underlyingToken;
    }

    /// @notice LxLy Bridge, which connects AggLayer networks.
    function lxlyBridge() public view returns (ILxLyBridge) {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        return $.lxlyBridge;
    }

    /// @notice The address of Native Converter on Layer Ys.
    function nativeConverter() public view returns (address) {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        return $.nativeConverter;
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getMigrationManagerStorage() private pure returns (MigrationManagerStorage storage $) {
        assembly {
            $.slot := _MIGRATION_MANAGER_STORAGE
        }
    }

    // -----================= ::: MIGRATION MANAGER ::: =================-----

    /// @dev Native Converter on a Layer Y calls both `bridgeAsset` and `bridgeMessage` on LxLy Bridge on `migrateBackingToLayerX`.
    /// @dev The assets must be claimed before claiming the message.
    /// @dev The message tells Migration Manager on Layer X how much yeToken must be minted and bridged to address zero on that Layer Y in order to equalize the total supply of yeToken and the custom token, and provide liquidity on LxLy Bridge when bridging from Layer Ys.
    function onMessageReceived(address originAddress, uint32 originNetwork, bytes memory data)
        external
        payable
        whenNotPaused
    {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Check the input.
        require(msg.sender == address($.lxlyBridge), "NOT_LXLY_BRIDGE");

        // Decode the cross-network instruction.
        (CrossNetworkInstruction instruction, bytes memory instructionData) =
            abi.decode(data, (CrossNetworkInstruction, bytes));

        // Execute the instruction.
        if (instruction == CrossNetworkInstruction.COMPLETE_MIGRATION) {
            // Check the input.
            // @note Do we need a whitelist of Layer Ys with Native Converter deployed?
            require(originAddress == $.nativeConverter, "NOT_NATIVE_CONVERTER");

            // Decode the amount.
            (uint256 assets, uint256 shares) = abi.decode(instructionData, (uint256, uint256));

            // Complete the migration.
            $.yeToken.completeMigration(_assetsAfterTransferFee(assets), originNetwork, shares);
        } else {
            revert("INVALID_CROSS_NETWORK_INSTRUCTION");
        }
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

    /// @notice Accounts for the transfer fee of the underlying token.
    /// @dev You must implement the same behavior as that of the underlying token for calculating the transfer fee.
    /// @dev If the underlying token does not have a transfer fee, the output must equal the input.
    /// @dev This function is used for estimation purposes only.
    /// @dev Example:
    /// @dev Fee: 2% flat
    /// @dev Input: `100`
    /// @dev Output: `98`
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee) internal view virtual returns (uint256);
}

// @todo @notes.
