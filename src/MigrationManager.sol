// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

/// @dev Other functionality.
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

/// @dev Libraries.
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev External contracts.
import {YieldExposedToken} from "./YieldExposedToken.sol";
import {ILxLyBridge} from "./etc/ILxLyBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Migration Manager (singleton)
/// @notice Migration Manager is a singleton contract that lives on Layer X.
/// @notice Backing for custom tokens minted by Native Converters on Layer Ys can be migrated to Layer X using Migration Manager. Migration Manager completes migrations by calling `completeMigration` on yeTokens, which mint yeTokens and bridge them to address zero on the Layer Ys, effectively locking the backing in LxLy Bridge. Please refer to `onMessageReceived` for more information.
contract MigrationManager is Initializable, OwnableUpgradeable, PausableUpgradeable, IVersioned {
    // Libraries.
    using SafeERC20 for IERC20;

    /// @dev Used in cross-network communication.
    enum CrossNetworkInstruction {
        COMPLETE_MIGRATION,
        WRAP_COIN_AND_COMPLETE_MIGRATION
    }

    /// @dev Used for mapping Native Converters to yeTokens.
    struct Tokens {
        YieldExposedToken yeToken;
        IERC20 underlyingToken;
    }

    /**
     * @dev Storage of the Migration Manager contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.MigrationManager
     */
    struct MigrationManagerStorage {
        ILxLyBridge lxlyBridge;
        mapping(address nativeConverter => Tokens tokens) nativeConverterToTokens;
    }

    /// @dev The storage slot at which Migration Manager storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.MigrationManager")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _MIGRATION_MANAGER_STORAGE =
        hex"aec447ccc4dc1a1a20af7f847edd1950700343642e68dd8266b4de5e0e190a00";

    /// @dev The function selector for wrapping Layer X's coin, following the WETH9 standard (including no transfer fee).
    /// @dev (ATTENTION) If the method of wrapping the coin for your Layer X differs, you must modify this contract.
    /// @dev Calculated as `bytes4(keccak256("deposit()"))`.
    bytes4 private constant _UNDERLYING_TOKEN_WRAP_SELECTOR = hex"d0e30db0";

    // Errors.
    error InvalidOwner();
    error InvalidYeToken();
    error InvalidNativeConverter();
    error InvalidUnderlyingToken();
    error Unauthorized();
    error CannotWrapCoin();
    error IncorrectBalanceOfUnderlyingTokenAfterWrapping(uint256 newBalance, uint256 expectedBalance);
    error InvalidCrossNetworkInstruction(CrossNetworkInstruction instruction);

    // Events.
    event NativeConverterMappedToTokens(
        address indexed nativeConverter, address indexed yeToken, address indexed underlyingToken
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, ILxLyBridge lxlyBridge_) internal initializer {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Check the inputs.
        require(owner_ != address(0), InvalidOwner());

        // Initialize the inherited contracts.
        __Ownable_init(owner_);
        __Pausable_init();

        // Initialize the storage.
        $.lxlyBridge = lxlyBridge_;
    }

    // -----================= ::: STORAGE ::: =================-----

    /// @notice LxLy Bridge, which connects AggLayer networks.
    function lxlyBridge() public view returns (ILxLyBridge) {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        return $.lxlyBridge;
    }

    /// @notice Tells which yeToken and the underlying token Native Converter on Layer Ys belongs to.
    /// @param nativeConverter_ The address of Native Converter on Layer Ys.
    function nativeConvertToTokens(address nativeConverter_) public view returns (Tokens memory tokens) {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        return $.nativeConverterToTokens[nativeConverter_];
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

    /// @notice Maps Native Converter on Layer Ys to yeToken and underlying token on Layer X.
    /// @notice This function can be called by the owner only.
    /// @param nativeConverter_ The address of Native Converter on Layer Ys.
    /// @param yeToken_ The address of yeToken on Layer X Native Converter belongs to. To unmap the tokens, set to address zero. You can override tokens without unmapping them first.
    function mapNativeConverterToTokens(address nativeConverter_, address yeToken_) external onlyOwner whenNotPaused {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Check the input.
        require(nativeConverter_ != address(0), InvalidNativeConverter());

        // Map or override tokens.
        if (yeToken_ != address(0)) {
            // Cache the tokens.
            IERC20 underlyingToken = YieldExposedToken(yeToken_).underlyingToken();
            Tokens memory oldTokens = $.nativeConverterToTokens[nativeConverter_];

            // Check the input.
            require(address(underlyingToken) != address(0), InvalidUnderlyingToken());

            // Revoke the approval of the old yeToken if tokens were already set.
            if (address(oldTokens.yeToken) != address(0)) {
                oldTokens.underlyingToken.forceApprove(address(oldTokens.yeToken), 0);
            }

            // Set the tokens.
            $.nativeConverterToTokens[nativeConverter_] = Tokens(YieldExposedToken(yeToken_), underlyingToken);

            // Approve yeToken.
            underlyingToken.forceApprove(yeToken_, type(uint256).max);

            // Emit the event.
            emit NativeConverterMappedToTokens(nativeConverter_, yeToken_, address(underlyingToken));

            return;
        }
        // Unset tokens.
        else {
            // Cache the underlying token.
            IERC20 underlyingToken = $.nativeConverterToTokens[nativeConverter_].underlyingToken;

            // Unset the tokens.
            delete $.nativeConverterToTokens[nativeConverter_];

            // Revoke the approval of yeToken.
            underlyingToken.forceApprove(yeToken_, 0);

            // Emit the event.
            emit NativeConverterMappedToTokens(nativeConverter_, address(0), address(0));

            return;
        }
    }

    /// @dev Native Converters on a Layer Ys call both `bridgeAsset` and `bridgeMessage` on LxLy Bridge to `migrateBackingToLayerX`.
    /// @dev The asset must be claimed before the message on LxLy Bridge.
    /// @dev The message tells Migration Manager on Layer X how much custom token must be backed by yeToken, which is minted and bridged to address zero on the respective Layer Y. This action provides liquidity when bridging the custom token to from Layer Ys to Layer X and increments the pessimistic proof.
    function onMessageReceived(address originAddress, uint32 originNetwork, bytes memory data)
        external
        payable
        whenNotPaused
    {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        // Check the input.
        require(msg.sender == address($.lxlyBridge), Unauthorized());

        // Decode the cross-network instruction.
        (CrossNetworkInstruction instruction, bytes memory instructionData) =
            abi.decode(data, (CrossNetworkInstruction, bytes));

        // Dispatch.
        if (
            instruction == CrossNetworkInstruction.COMPLETE_MIGRATION
                || instruction == CrossNetworkInstruction.WRAP_COIN_AND_COMPLETE_MIGRATION
        ) {
            // @note Do we need a whitelist of Layer Ys with Native Converter deployed?
            // Cache yeToken.
            YieldExposedToken yeToken = $.nativeConverterToTokens[originAddress].yeToken;

            // Check the input.
            require(address(yeToken) != address(0), Unauthorized());

            // Decode the amounts.
            (uint256 shares, uint256 assets) = abi.decode(instructionData, (uint256, uint256));

            // Wrap the coin before completing the migration if instructed.
            if (instruction == CrossNetworkInstruction.WRAP_COIN_AND_COMPLETE_MIGRATION) {
                // Cache the underlying token.
                IERC20 underlyingToken = $.nativeConverterToTokens[originAddress].underlyingToken;

                // Cache the previous balance.
                uint256 previousBalance = underlyingToken.balanceOf(address(this));

                // Wrap the coin.
                (bool ok,) =
                    address(underlyingToken).call{value: assets}(abi.encodePacked(_UNDERLYING_TOKEN_WRAP_SELECTOR));

                // Cache the result.
                uint256 expectedBalance = previousBalance + assets;
                uint256 newBalance = underlyingToken.balanceOf(address(this));

                // Check the result.
                require(ok, CannotWrapCoin());
                require(
                    newBalance == expectedBalance,
                    IncorrectBalanceOfUnderlyingTokenAfterWrapping(newBalance, expectedBalance)
                );
            }

            // Complete the migration.
            yeToken.completeMigration(originNetwork, shares, assets);
        } else {
            revert InvalidCrossNetworkInstruction(instruction);
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
}

// @todo @notes.
