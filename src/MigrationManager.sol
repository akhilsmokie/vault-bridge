// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {YieldExposedToken} from "./YieldExposedToken.sol";
import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Migration Manager
/// @dev This token can deposit and bridge to address zero on the corresponding L2. It holds migrated backing and calls yeToken on message receipt.
// Native Converter should bridge the underlying token to this contract, along with the message, which is claim on LxLy Bridge.
contract MigrationManager is Initializable, OwnableUpgradeable, PausableUpgradeable {
    /// @dev Used for cross-chain communication.
    enum Instruction {
        COMPLETE_MIGRATION
    }

    /**
     * @dev Storage of the YieldExposedToken contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.YieldExposedToken
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

    event MigrationCompleted(uint32 indexed originNetwork, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address yeToken_,
        address lxlyBridge_,
        address nativeConverter_,
        bool premigrating_
    ) external initializer {
        require(owner_ != address(0), "INVALID_OWNER");
        require(yeToken_ != address(0), "INVALID_YETOKEN");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");
        require(nativeConverter_ != address(0), "INVALID_CONVERTER");

        __Ownable_init(owner_);
        __Pausable_init();

        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        $.yeToken = YieldExposedToken(yeToken_);
        $.underlyingToken = IERC20(YieldExposedToken(yeToken_).asset());
        $.lxlyBridge = ILxLyBridge(lxlyBridge_);
        $.nativeConverter = nativeConverter_;
        $.premigrating = premigrating_;

        if (premigrating_) _pause();

        $.underlyingToken.approve(yeToken_, type(uint256).max);
    }

    function premigrate(uint32 originNetwork) external onlyOwner {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        require($.premigrating, "NOT_PREMIGRATING");

        $.yeToken.depositAndBridge($.underlyingToken.balanceOf(address(this)), address(0), originNetwork, true);

        $.premigrating = false;

        _unpause();
    }

    /// @dev Native Converter on an L2 calls both `bridgeAsset` and `bridgeMessage` on `migrate`.
    /// @dev The message tells Migration Manager on the L1 how much yeToken must be minted and bridged to adress zero on that L2 in order to equalize the total supply of yeToken and the custom token, and provide enter liquidity on LxLy Bridge on the L1.
    function onMessageReceived(address originAddress, uint32 originNetwork, bytes memory data)
        external
        payable
        whenNotPaused
    {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();

        require(msg.sender == address($.lxlyBridge), "NOT_LXLY_BRIDGE");

        (Instruction instruction, bytes memory instuctionData) = abi.decode(data, (Instruction, bytes));

        if (instruction == Instruction.COMPLETE_MIGRATION) {
            require(originAddress == $.nativeConverter, "NOT_NATIVE_CONVERTER");

            uint256 amount = abi.decode(instuctionData, (uint256));

            $.yeToken.depositAndBridge(amount, address(0), originNetwork, true);

            emit MigrationCompleted(originNetwork, amount);
        } else {
            revert("INVALID_INSTRUCTION");
        }
    }

    /// @notice Prevents usage of functions with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allowes usage of functions with the `whenNotPaused` modifier.
    function unpause() external onlyOwner {
        MigrationManagerStorage storage $ = _getMigrationManagerStorage();
        require(!$.premigrating, "PREMIGRATING");
        _unpause();
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getMigrationManagerStorage() private pure returns (MigrationManagerStorage storage $) {
        assembly {
            $.slot := _MIGRATION_MANAGER_STORAGE
        }
    }
}

// @todo Any setters.
// @todo Polish.
