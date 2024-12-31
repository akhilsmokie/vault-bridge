// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {YieldExposedToken} from "./YieldExposedToken.sol";
import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Migration Manager
/// @notice Backing for the custom token that was minted on an L2 by Native Converter is migrated to Migration Manager on the L1, which completes migrations by calling yeToken to mint and bridge yeToken to address zero on that L2.
abstract contract MigrationManager is Initializable, OwnableUpgradeable, PausableUpgradeable, IVersioned {
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
        bool premigrating;
    }

    /// @dev The storage slot at which Migration Manager storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.MigrationManager")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _MIGRATION_MANAGER_STORAGE =
        0xaec447ccc4dc1a1a20af7f847edd1950700343642e68dd8266b4de5e0e190a00;

    constructor() {
        _disableInitializers();
    }

    /// @param nativeConverter_ The address of Native Converter on L2s.
    /// @param premigrating_ Plese, see `premigrate`.
    function initialize(
        address owner_,
        address yeToken_,
        address lxlyBridge_,
        address nativeConverter_,
        bool premigrating_
    ) external initializer {
        // Check the inputs.
        require(owner_ != address(0), "INVALID_OWNER");
        require(yeToken_ != address(0), "INVALID_YETOKEN");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");
        require(nativeConverter_ != address(0), "INVALID_CONVERTER");

        // Initialize the inherited contracts.
        __Ownable_init(owner_);
        __Pausable_init();

        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Initialize the storage.
        $.yeToken = YieldExposedToken(yeToken_);
        $.underlyingToken = IERC20(YieldExposedToken(yeToken_).asset());
        $.lxlyBridge = ILxLyBridge(lxlyBridge_);
        $.nativeConverter = nativeConverter_;
        $.premigrating = premigrating_;

        // Pause the contract if premigrating.
        if (premigrating_) _pause();

        // Approve yeToken.
        $.underlyingToken.approve(yeToken_, type(uint256).max);
    }

    /// @notice Completes migrations of backing from L2s that happened before the STB system existed. If the underlying token had never went through an escrow, premigration may not be needed. Please, consult with the Smart Contracts team.
    /// @notice Important! Please, read the documentation before using this function!
    /// @notice First, the legacy contracts must be upgraded and/or paused, such as that the old escrow contract on the L1 does not receive the underlying token anymore (neither by deposits, nor migrations). A premigration plan for each yeToken should be prepared by the Smart Contracts team and approved by Security.
    /// @notice Second, the entire backing must be transferred from the old escrow contract to this Migration Manager AFTER THE CONTRACT HAS BEEN INITIALIZED (otherwise, anyone could steal the funds by frontrunning the initialization and setting themeselves as the owner).
    /// @notice Third, the calldata must be prepared such as that the `shares` for each `destinationNetworkId` represent the total amount of yeToken (backing) to mint and lock up in LxLy Bridge for that L2. These amounts must not be inclusive of any transfer fees of the underlying token, and must represent the exact suppy of the custom token minted on an L2 for which the backing was migrated to the L1.
    /// @notice This function can be called only once - make sure the calldata is correct.
    /// @notice This function can be called by the owner only.
    /// @dev `premigrating` must be set to `true` during the initialization in order to use this function.
    function premigrate(uint32[] calldata destinationNetworkIds, uint256[] calldata shares) external onlyOwner {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Check input.
        require($.premigrating, "NOT_PREMIGRATING");

        // Cache the balance of the underlying token.
        uint256 balance = $.underlyingToken.balanceOf(address(this));

        // Complete the migrations.
        // If the underlying token has a transfer fee, you may need to prefund yeToken by transferring some amount of the underlying token to it (not depositing) in order for the migrations to succeed. Please, see `completeMigration` in `YieldExposedToken` for more information.
        for (uint256 i; i < destinationNetworkIds.length; ++i) {
            uint256 assets = _convertToAssets(shares[i]);
            $.yeToken.completeMigration(assets <= balance ? assets : balance, destinationNetworkIds[i], shares[i]);
            balance = assets <= balance ? balance - assets : 0;
        }

        // End the premigration and unpause the contract.
        $.premigrating = false;
        _unpause();
    }

    /// @dev Native Converter on an L2 calls both `bridgeAsset` and `bridgeMessage` on `migrate`.
    /// @dev The assets must be claimed before claiming the message.
    /// @dev The message tells Migration Manager on the L1 how much yeToken must be minted and bridged to adress zero on that L2 in order to equalize the total supply of yeToken and the custom token, and provide liquidity on LxLy Bridge when bridging from L2s.
    function onMessageReceived(address originAddress, uint32 originNetwork, bytes memory data)
        external
        payable
        whenNotPaused
    {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Check the input.
        require(msg.sender == address($.lxlyBridge), "NOT_LXLY_BRIDGE");

        // Decode the cross-network instruction.
        (CrossNetworkInstruction instruction, bytes memory instuctionData) =
            abi.decode(data, (CrossNetworkInstruction, bytes));

        // Execute the instruction.
        if (instruction == CrossNetworkInstruction.COMPLETE_MIGRATION) {
            // Check the input.
            require(originAddress == $.nativeConverter, "NOT_NATIVE_CONVERTER");

            // Decode the amount.
            uint256 shares = abi.decode(instuctionData, (uint256));

            // Complete the migration.
            $.yeToken.completeMigration(_assetsAfterTransferFee(_convertToAssets(shares)), originNetwork, shares);
        } else {
            revert("INVALID_CROSS_NETWORK_INSTRUCTION");
        }
    }

    /// @notice Prevents usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allowes usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function unpause() external onlyOwner {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Prevent unpausing while premigrating.
        require(!$.premigrating, "PREMIGRATING");

        // Unpause the contract.
        _unpause();
    }

    /// @notice yeToken is backed by the underlying token 1:1.
    /// @dev Caution! Changing this function will affect the exchange rate.
    function _convertToAssets(uint256 shares) internal pure returns (uint256 assets) {
        assets = shares;
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getMigrationManagerStorage() private pure returns (MigrationManagerStorage storage $) {
        assembly {
            $.slot := _MIGRATION_MANAGER_STORAGE
        }
    }

    /// @inheritdoc IVersioned
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    /// @notice Accounts for the transfer fee of the underlying token.
    /// @dev You must implement the same behavior as that of the underlying token for calculating the transfer fee.
    /// @dev If the underlying token does not have a transfer fee, the output must equal the input.
    /// @dev This function is used for estamation purposes only.
    /// @dev Example:
    /// @dev Fee: 2% flat
    /// @dev Input: `100`
    /// @dev Output: `98`
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee) internal view virtual returns (uint256);
}
