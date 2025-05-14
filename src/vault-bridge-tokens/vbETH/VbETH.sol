//
pragma solidity 0.8.29;

import {VaultBridgeToken, ILxLyBridge} from "../../VaultBridgeToken.sol";
import {IWETH9} from "../../etc/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVersioned} from "../../etc/IVersioned.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Vault Bridge gas token
/// @dev CAUTION! As-is, this contract MUST NOT be used on a network if the gas token is not ETH.
contract VbETH is VaultBridgeToken {
    using SafeERC20 for IWETH9;

    bool private transient _receiveViaMsgValue;
    uint256 private transient _designatedMsgValue;

    error ContractNotSupportedOnThisNetwork();
    error InsufficientDesignatedMsgValue (uint256 designatedMsgValue, uint256 msgValue, uint256 requiredAssets);

    constructor() {
        _disableInitializers();
    }

    function initialize(address initializer_, VaultBridgeToken.InitializationParameters calldata initParams)
        external
        initializer
    {
        require(
            ILxLyBridge(initParams.lxlyBridge).gasTokenAddress() == address(0)
                && ILxLyBridge(initParams.lxlyBridge).gasTokenNetwork() == 0,
            ContractNotSupportedOnThisNetwork()
        );

        // Initialize the base implementation.
        __VaultBridgeToken_init(initializer_, initParams);
    }

    /// @dev deposit ETH to get vbETH
    function depositGasToken(address receiver) external payable whenNotPaused nonReentrant returns (uint256 shares) {
        (shares,) = _depositViaMsgValue(msg.value, msg.value, lxlyId(), receiver, false, 0);
    }

    /// @dev deposit ETH to get vbETH and bridge to an L2
    function depositGasTokenAndBridge(
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot
    ) external payable whenNotPaused nonReentrant returns (uint256 shares) {
        (shares,) = _depositViaMsgValue(
            msg.value, msg.value, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot, 0
        );
    }

    function _depositViaMsgValue(
        uint256 designatedMsgValue,
        uint256 assets,
        uint32 destinationNetworkId,
        address receiver,
        bool forceUpdateGlobalExitRoot,
        uint256 maxShares
    ) internal returns (uint256 shares, uint256 spentAssets) {
        _receiveViaMsgValue = true;
        _designatedMsgValue = designatedMsgValue;

        (shares, spentAssets) = _deposit(assets, destinationNetworkId, receiver, forceUpdateGlobalExitRoot, maxShares);

        _receiveViaMsgValue = false;
        _designatedMsgValue = 0;
    }

    function mintWithGasToken(uint256 shares, address receiver)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        require(shares > 0, InvalidShares());
        // The receiver is checked in the `_deposit` function.

        // Mint vbToken to the receiver.
        uint256 mintedShares;
        (mintedShares, assets) =
        // msg.value is used as assets value, if it exceeds shares value, WETH will be refunded
         _depositViaMsgValue(msg.value, msg.value, lxlyId(), receiver, false, shares);

        // Check the output.
        require(mintedShares == shares, IncorrectAmountOfSharesMinted(mintedShares, shares));
    }

    function _receiveUnderlyingToken(address from, uint256 assets) internal override {
        IWETH9 weth = IWETH9(address(underlyingToken()));

        uint256 balanceBefore = weth.balanceOf(address(this));

        if (_receiveViaMsgValue) {
            assert(from == msg.sender);
            assert(_designatedMsgValue != 0);

            require(_designatedMsgValue == assets, InsufficientDesignatedMsgValue(_designatedMsgValue, msg.value, assets));

            assets = _designatedMsgValue;

            _receiveViaMsgValue = false;
            _designatedMsgValue = 0;

            // deposit everything, excess funds will be refunded in WETH
            weth.deposit{value: assets}();
        } else {
            weth.safeTransferFrom(from, address(this), assets);
        }

        uint256 balanceAfter = weth.balanceOf(address(this));

        uint256 receivedAssets = balanceAfter - balanceBefore;

        require(receivedAssets == assets, InsufficientUnderlyingTokenReceived(receivedAssets, assets));
    }

    /// @inheritdoc IVersioned
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }
}
