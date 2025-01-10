// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVersioned} from "./etc/IVersioned.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibPermit} from "./etc/LibPermit.sol";

import {ILxLyBridge} from "./etc/ILxLyBridge.sol";

/// @title Yield Exposed Token
/// @dev A base contract to create yield exposed tokens.
/// @dev In order to not drive the complexity of the STB system up, yeToken MUST NOT have transfer or deposit and/or withdrawal fees. The underlying token on Layer X and the custom token on Layer Ys MAY have transfer fees. The yield vault MAY have deposit and/or withdrawal fees.
/// @dev It is expected for yield to offset any costs incurred when transferring the underlying token to and from the yield vault, or depositing to and withdrawing from the yield vault, for the purpose of generating yield or rebalancing reserve. Those things should be taken into account when setting up or choosing the yield vault.
abstract contract YieldExposedToken is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    IERC4626,
    ERC20PermitUpgradeable,
    IVersioned
{
    using SafeERC20 for IERC20;

    /**
     * @dev Storage of the Yield Exposed Token contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.YieldExposedToken
     */
    struct YieldExposedTokenStorage {
        IERC20 underlyingToken;
        uint8 decimals;
        // @note Using 1 for 1%.
        uint8 minimumReservePercentage;
        IERC4626 yieldVault;
        address yieldRecipient;
        uint32 lxlyId;
        ILxLyBridge lxlyBridge;
        address migrationManager;
    }

    /// @dev The storage slot at which Yield Exposed Token storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.YieldExposedToken")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _YIELD_EXPOSED_TOKEN_STORAGE =
        0xed23de664e59f2cbf6ba852da776346da171cf53c9d06b116fea0fc5ee912500;

    event ReserveRebalanced(uint256 reservedAssets);
    event YieldCollected(address indexed yieldRecipient, uint256 underlyingTokenAmount);
    event MigrationCompleted(uint32 destinationNetworkId, uint256 shares, uint256 utilizedYield);
    event YieldRecipientSet(address indexed yieldRecipient);
    event MinimumReservePercentageSet(uint8 minimumReservePercentage);

    /// @dev `decimals` will match the underlying token.
    /// @param minimumReservePercentage_ 1 is 1%.
    function __YieldExposedToken_init(
        address owner_,
        string calldata name_,
        string calldata symbol_,
        address underlyingToken_,
        uint8 minimumReservePercentage_,
        address yieldVault_,
        address yieldRecipient_,
        address lxlyBridge_,
        address migrationManager_
    ) internal onlyInitializing {
        // Check the inputs.
        require(owner_ != address(0), "INVALID_OWNER");
        require(bytes(name_).length > 0, "INVALID_NAME");
        require(bytes(symbol_).length > 0, "INVALID_SYMBOL");
        require(underlyingToken_ != address(0), "INVALID_UNDERLYING_TOKEN");
        require(minimumReservePercentage_ <= 100, "INVALID_PERCENTAGE");
        require(yieldVault_ != address(0), "INVALID_VAULT");
        require(yieldRecipient_ != address(0), "INVALID_YIELD_RECIPIENT");
        require(lxlyBridge_ != address(0), "INVALID_LXLY_BRIDGE");
        require(migrationManager_ != address(0), "INVALID_MIGRATION_MANAGER");

        // Initialize the inherited contracts.
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        __Ownable_init(owner_);
        __Pausable_init();

        // Initialize the storage.
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        $.underlyingToken = IERC20(underlyingToken_);
        $.decimals = IERC20Metadata(underlyingToken_).decimals();
        $.minimumReservePercentage = minimumReservePercentage_;
        $.yieldVault = IERC4626(yieldVault_);
        $.yieldRecipient = yieldRecipient_;
        $.lxlyId = ILxLyBridge(lxlyBridge_).networkID();
        $.lxlyBridge = ILxLyBridge(lxlyBridge_);
        $.migrationManager = migrationManager_;

        // @note Check security implications.
        // Approve the yield vault and LxLy Bridge.
        IERC20(underlyingToken_).forceApprove(yieldVault_, type(uint256).max);
        _approve(address(this), address(lxlyBridge_), type(uint256).max);
    }

    // -----================= ::: STORAGE ::: =================-----

    /// @notice The underlying token that backs yeToken.
    function underlyingToken() public view returns (IERC20) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.underlyingToken;
    }

    /// @notice The number of decimals of the yield exposed token.
    /// @notice The number of decimals is the same as that of the underlying token.
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.decimals;
    }

    /// @notice Yield exposed tokens have an internal reserve of the underlying token from which withdrawals are serviced first.
    /// @notice When the reserve is below the minimum threshold, it can be replenished by calling `replenishReserve`.
    function minimumReservePercentage() public view returns (uint256) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.minimumReservePercentage;
    }

    /// @notice An external, ERC-4246 compatible vault into which the underlying token is deposited to generate yield.
    function yieldVault() public view returns (IERC4626) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.yieldVault;
    }

    /// @notice The address that receives yield generated by the yield vault.
    function yieldRecipient() public view returns (address) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.yieldRecipient;
    }

    /// @notice The LxLy ID of this network.
    function lxlyId() public view returns (uint32) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.lxlyId;
    }

    /// @notice LxLy Bridge, which connects AggLayer networks.
    function lxlyBridge() public view returns (ILxLyBridge) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.lxlyBridge;
    }

    /// @notice The address of Migration Manager for this yeToken.
    /// @notice Migration Manager on Layer X is used in combination with Native Converter on Layer Ys to migrate backing of yeToken from Layer Ys to Layer X. This is because Native Converters can mint the custom token on Layer Ys.
    function migrationManager() public view returns (address) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.migrationManager;
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getYieldExposedTokenStorage() private pure returns (YieldExposedTokenStorage storage $) {
        assembly {
            $.slot := _YIELD_EXPOSED_TOKEN_STORAGE
        }
    }

    // -----================= ::: ERC-4626 ::: =================-----

    /// @notice The underlying token that backs yeToken.
    function asset() public view override returns (address assetTokenAddress) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return address($.underlyingToken);
    }

    /// @notice The total backing of yeToken in the underlying token.
    /// @notice May be less that the actual amount if backing in Native Converter on Layer Ys hasn't been migrated to Layer X yet.
    function totalAssets() public view override returns (uint256 totalManagedAssets) {
        return stakedAssets() + reservedAssets();
    }

    /// @notice Tells how much a specific amount of underlying token is worth in yeToken.
    function convertToShares(uint256 assets) public pure override returns (uint256 shares) {
        // The underlying token backs yeToken 1:1.
        // Caution! Changing this function will affect the exchange rate.
        shares = assets;
    }

    /// @notice Tells how much a specific amount of yeToken is worth in the underlying token.
    function convertToAssets(uint256 shares) public pure override returns (uint256 assets) {
        // yeToken is backed by the underlying token 1:1.
        // Caution! Changing this function will affect the exchange rate.
        assets = shares;
    }

    /// @notice How much underlying token a specific user can deposit. (Depositing the underlying token mints yeToken).
    function maxDeposit(address) external view override returns (uint256 maxAssets) {
        return !paused() ? type(uint256).max : 0;
    }

    /// @notice How much yeToken would be minted if a specific amount of the underlying token were deposited right now.
    function previewDeposit(uint256 assets) external view override whenNotPaused returns (uint256 shares) {
        // Check the input.
        require(assets > 0, "INVALID_AMOUNT");

        return convertToShares(_assetsAfterTransferFee(assets));
    }

    /// @notice Deposit a specific amount of the underlying token and get yeToken.
    function deposit(uint256 assets, address receiver) external override whenNotPaused returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        (shares,) = _deposit(assets, $.lxlyId, receiver, false, 0);
    }

    /// @notice Deposit a specific amount of the underlying token, and bridge yeToken to a Layer Y.
    /// @dev If yeToken is custom mapped on LxLy Bridge on Layer Y, the user will receive the custom token. If not, they will receive wrapped yeToken.
    function depositAndBridge(
        uint256 assets,
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot
    ) external whenNotPaused returns (uint256 shares) {
        (shares,) = _deposit(assets, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot, 0);
    }

    /// @notice Deposit a specific amount of the underlying token, and bridge yeToken to a Layer Y.
    // dev If yeToken is custom mapped on LxLy Bridge on Layer Y, the user will receive the custom token. If not, they will receive wrapped yeToken.
    /// @dev Uses EIP-2612 permit to transfer the underlying token from the sender to itself.
    function depositAndBridge(
        uint256 assets,
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) external whenNotPaused returns (uint256 shares) {
        (shares,) = _deposit(assets, permitData, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot, 0);
    }

    /// @notice Locks the underlying token, mints yeToken, and optionally bridges it to a Layer Y.
    /// @dev Uses EIP-2612 permit to transfer the underlying token from the sender to itself.
    function _deposit(
        uint256 assets,
        bytes calldata permitData,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot,
        uint256 maxShares
    ) internal returns (uint256 shares, uint256 spentAssets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Use the permit.
        if (permitData.length > 0) {
            LibPermit.permit(address($.underlyingToken), assets, permitData);
        }

        return _deposit(assets, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot, maxShares);
    }

    /// @notice Locks the underlying token, mints yeToken, and optionally bridges it to a Layer Y.
    /// @param maxShares Caps the amount of yeToken that can be minted. The difference is refunded to the sender. Set to `0` to disable.
    function _deposit(
        uint256 assets,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot,
        uint256 maxShares
    ) internal returns (uint256 shares, uint256 spentAssets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the inputs.
        require(assets > 0, "INVALID_AMOUNT");
        require(destinationAddress != address(0), "INVALID_ADDRESS");

        // Transfer the underlying token from the sender to itself.
        uint256 previousBalance = $.underlyingToken.balanceOf(address(this));
        $.underlyingToken.safeTransferFrom(msg.sender, address(this), assets);
        assets = $.underlyingToken.balanceOf(address(this)) - previousBalance;

        // Check for a refund.
        if (maxShares > 0) {
            uint256 requiredAssets = convertToAssets(maxShares);
            if (assets > requiredAssets) {
                uint256 refund = assets - requiredAssets;
                $.underlyingToken.safeTransfer(msg.sender, refund);
                assets = requiredAssets;
            }
        }

        // Set the return values.
        shares = convertToShares(assets);
        spentAssets = assets;

        // Calculate the amount to reserve and the amount to deposit into the yield vault.
        // @note Check rounding.
        uint256 assetsToReserve = (assets * $.minimumReservePercentage) / 100;
        uint256 assetsToDeposit = assets - assetsToReserve;

        // Deposit into the yield vault.
        // @note Yield vault usage.
        uint256 maxDeposit_ = $.yieldVault.maxDeposit(address(this));
        assetsToDeposit = assetsToDeposit > maxDeposit_ ? maxDeposit_ : assetsToDeposit;
        if (assetsToDeposit > 0) {
            $.yieldVault.deposit(assetsToDeposit, address(this));
        }

        // Mint yeToken.
        if (destinationNetworkId != $.lxlyId) {
            // Mint to self and bridge to the receiver.
            _mint(address(this), shares);
            lxlyBridge().bridgeAsset(
                destinationNetworkId, destinationAddress, shares, address(this), forceUpdateGlobalExitRoot, ""
            );
        } else {
            // Mint to the receiver.
            _mint(destinationAddress, shares);
        }

        // Update the receiver.
        if (destinationNetworkId != $.lxlyId) destinationAddress = address(this);

        // Emit the ERC-4626 event.
        emit IERC4626.Deposit(msg.sender, destinationAddress, assets, shares);
    }

    /// @notice How much yeToken a specific user can mint. (Minting yeToken locks the underlying token).
    function maxMint(address) external view override returns (uint256 maxShares) {
        return !paused() ? type(uint256).max : 0;
    }

    /// @notice How much underlying token would be required to mint a specific amount of yeToken right now.
    function previewMint(uint256 shares) external view override whenNotPaused returns (uint256 assets) {
        // Check the input.
        require(shares > 0, "INVALID_AMOUNT");

        return _assetsBeforeTransferFee(convertToAssets(shares));
    }

    /// @notice Mint a specific amount of yeToken by depositing a required amount of the underlying token.
    function mint(uint256 shares, address receiver) external override whenNotPaused returns (uint256 assets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the input.
        require(shares > 0, "INVALID_AMOUNT");
        // The receiver is checked in the `_deposit` function.

        // Mint yeToken to the receiver.
        uint256 mintedShares;
        (mintedShares, assets) =
            _deposit(_assetsBeforeTransferFee(convertToAssets(shares)), $.lxlyId, receiver, false, shares);

        // Check the output.
        require(mintedShares == shares, "COULD_NOT_MINT_SHARES");
    }

    /// @notice How much underlying token a specific user can withdraw. (Withdrawing the underlying token burns yeToken).
    function maxWithdraw(address owner) external view override returns (uint256 maxAssets) {
        return !paused() ? _simulateWithdraw(convertToAssets(balanceOf(owner)), false) : 0;
    }

    /// @notice How much yeToken would be burned if a specific amount of the underlying token were withdrawn right now.
    function previewWithdraw(uint256 assets) external view override whenNotPaused returns (uint256 shares) {
        return convertToShares(_simulateWithdraw(assets, true));
    }

    /// @dev Calculates the amount of the underlying token that can be withdrawn right now.
    /// @param assets The maximum amount of the underlying token to simulate a withdrawal for.
    /// @param force Whether to enforce the amount, reverting if it cannot be met.
    function _simulateWithdraw(uint256 assets, bool force) internal view returns (uint256 withdrawnAssets) {
        // Check the input.
        require(assets > 0, "INVALID_AMOUNT");

        // The amount that cannot be withdrawn at the moment.
        uint256 remainingAssets = assets;

        // Simulate withdrawal from the reserve.
        uint256 reservedAssets_ = reservedAssets();
        if (reservedAssets_ >= remainingAssets) return assets;
        remainingAssets -= reservedAssets_;

        // Simulate withdrawal from the yield vault.
        uint256 maxWithdraw_ = yieldVault().maxWithdraw(address(this));
        maxWithdraw_ = remainingAssets > maxWithdraw_ ? maxWithdraw_ : remainingAssets;
        if (remainingAssets == maxWithdraw_) return assets;
        remainingAssets -= maxWithdraw_;

        // Revert if the `assets` is enforced and there is a remaining amount.
        if (force) require(remainingAssets == 0, "AMOUNT_TOO_LARGE");

        // Return the amount of the underlying token that can be withdrawn right now.
        return assets - remainingAssets;
    }

    /// @notice Withdraw a specific amount of the underlying token by burning a required amount of yeToken.
    /// @notice Transfer fees of the underlying token may apply.
    /// @notice Withdrawal fees of the yield vault may apply.
    function withdraw(uint256 assets, address receiver, address owner)
        external
        override
        whenNotPaused
        returns (uint256 shares)
    {
        return _withdraw(assets, receiver, owner);
    }

    /// @notice Claim yeToken from LxLy Bridge and withdraw the underlying token.
    /// @notice Transfer fees of the underlying token may apply.
    /// @notice Withdrawal fees of the yield vault may apply.
    function claimAndWithdraw(
        bytes32[32] calldata smtProof,
        uint32 index,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        uint32 originNetwork,
        address originTokenAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes calldata metadata,
        address receiver
    ) external whenNotPaused returns (uint256 shares) {
        // Claim yeToken from LxLy Bridge.
        lxlyBridge().claimAsset(
            smtProof,
            index,
            mainnetExitRoot,
            rollupExitRoot,
            originNetwork,
            originTokenAddress,
            destinationNetwork,
            address(this),
            amount,
            metadata
        );

        // Withdraw the underlying token to the receiver.
        return _withdraw(amount, receiver, destinationAddress);
    }

    /// @notice Withdraw a specific amount of the underlying token by burning a required amount of yeToken.
    function _withdraw(uint256 assets, address receiver, address owner) internal returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the inputs.
        require(assets > 0, "INVALID_AMOUNT");
        require(receiver != address(0), "INVALID_ADDRESS");
        require(owner != address(0), "INVALID_OWNER");

        // Set the return value.
        shares = convertToShares(assets);

        // Check the input.
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // The amount that cannot be withdrawn at the moment.
        uint256 remainingAssets = assets;

        // Calculate the amount to withdraw from the reserve.
        uint256 reservedAssets_ = reservedAssets();
        uint256 amountToWithdraw = reservedAssets_ >= remainingAssets ? remainingAssets : reservedAssets_;

        // Withdraw from the reserve.
        _burn(owner, convertToShares(amountToWithdraw));
        $.underlyingToken.safeTransfer(receiver, amountToWithdraw);

        // Check if the amount in the reserve was sufficient.
        if (amountToWithdraw == remainingAssets) {
            emit IERC4626.Withdraw(msg.sender, receiver, owner, assets, shares);
            return shares;
        }

        // Update the remaining assets.
        remainingAssets -= amountToWithdraw;

        // Calculate the amount to withdraw from the yield vault.
        // @note Yield vault usage.
        uint256 maxWithdraw_ = $.yieldVault.maxWithdraw(address(this));

        // Withdraw from the yield vault.
        if (maxWithdraw_ >= remainingAssets) {
            _burn(owner, shares);
            $.yieldVault.withdraw(remainingAssets, receiver, address(this));
            emit IERC4626.Withdraw(msg.sender, receiver, owner, assets, shares);
            return shares;
        }

        // Revert if all of the `assets` could not be withdrawn.
        revert("AMOUNT_TOO_LARGE");
    }

    /// @notice How much yeToken a specific user can burn. (Burning yeToken unlocks the underlying token).
    function maxRedeem(address owner) external view override returns (uint256 maxShares) {
        return !paused() ? convertToShares(_simulateWithdraw(convertToAssets(balanceOf(owner)), false)) : 0;
    }

    /// @notice How much underlying token would be unlocked if a specific amount of yeToken were burned right now.
    function previewRedeem(uint256 shares) external view override whenNotPaused returns (uint256 assets) {
        return _simulateWithdraw(convertToAssets(shares), true);
    }

    /// @notice Burn a specific amount of yeToken and unlock a respective amount of the underlying token.
    /// @notice Transfer fees of the underlying token may apply.
    /// @notice Withdrawal fees of the yield vault may apply.
    function redeem(uint256 shares, address receiver, address owner)
        external
        override
        whenNotPaused
        returns (uint256 assets)
    {
        // Set the return value.
        assets = convertToAssets(shares);

        // Burn yeToken.
        uint256 redeemedShares = _withdraw(assets, receiver, owner);

        // Check the output.
        require(redeemedShares == shares, "COULD_NOT_REDEEM_SHARES");
    }

    // -----================= ::: ERC-20 ::: =================-----

    /// @dev Pausable ERC-20 `transfer` function.
    function transfer(address to, uint256 value) public virtual override(ERC20Upgradeable, IERC20) returns (bool) {
        return super.transfer(to, value);
    }

    /// @dev Pausable ERC-20 `transferFrom` function.
    function transferFrom(address from, address to, uint256 value)
        public
        virtual
        override(ERC20Upgradeable, IERC20)
        whenNotPaused
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }

    /// @dev Pausable ERC-20 `approve` function.
    function approve(address spender, uint256 value)
        public
        virtual
        override(ERC20Upgradeable, IERC20)
        whenNotPaused
        returns (bool)
    {
        return super.approve(spender, value);
    }

    /// @dev Pausable ERC-20 Permit `permit` function.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        virtual
        override
        whenNotPaused
    {
        super.permit(owner, spender, value, deadline, v, r, s);
    }

    // -----================= ::: YETOKEN ::: =================-----

    /// @notice The amount of the underlying token in the yield vault, as reported by the yield vault.
    function stakedAssets() public view returns (uint256) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.yieldVault.convertToAssets($.yieldVault.balanceOf(address(this)));
    }

    /// @notice Yield exposed tokens have an internal reserve of the underlying token from which withdrawals are serviced first.
    /// @notice The reserve can be refilled by calling `replenishReserve` when it is below the `minimumReservePercentage`.
    function reservedAssets() public view returns (uint256) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.underlyingToken.balanceOf(address(this));
    }

    /// @notice The current reserve percentage.
    /// @notice The reserve is based on the total supply of yeToken, and may not account for uncompleted migrations of backing from Layer Ys to Layer X. Please refer to `completeMigration` for more information.
    function reservePercentage() external view returns (uint256) {
        // @note Check rounding.
        return (reservedAssets() * 100) / totalAssets();
    }

    /// @notice The amount of yield available for collection.
    function yield() public view returns (uint256) {
        // The formula for caclulating yield is:
        // yield = assets reported by yield vault + reserve - yeToken total supply in assets
        return stakedAssets() + reservedAssets() - convertToAssets(totalSupply());
    }

    /// @notice Refill the internal reserve of the underlying token by withdrawing from the yield vault.
    /// @notice This function can be called by anyone.
    function replenishReserve() public whenNotPaused {
        _rebalanceReserve(true, false);
    }

    /// @notice Rebalances the internal reserve by withdrawing the underlying token from, or depositing the underlying token into, the yield vault.
    /// @notice This function can be called by the owner only.
    function rebalanceReserve() external onlyOwner whenNotPaused {
        _rebalanceReserve(true, true);
    }

    /// @notice Rebalances the internal reserve by withdrawing the underlying token from, or depositing the underlying token into, the yield vault.
    /// @param force Whether to revert if the reserve cannot be rebalanced.
    /// @param allowRebalanceDown Whether to allow the reserve to be rebalanced down (by depositing into the yield vault).
    function _rebalanceReserve(bool force, bool allowRebalanceDown) public {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Caclulate the minimum reserve amount.
        uint256 reservedAssets_ = reservedAssets();
        // @note Check rounding.
        uint256 minimumReserve = convertToAssets((totalSupply() * $.minimumReservePercentage) / 100);

        // Check if the reserve is below, above, or at the minimum threshold.
        if (reservedAssets_ < minimumReserve) {
            // Calculate how much to withdraw.
            uint256 shortfall = minimumReserve - reservedAssets_;
            // @note Yield vault usage.
            uint256 maxWithdraw_ = $.yieldVault.maxWithdraw(address(this));
            uint256 assetsToWithdraw = shortfall > maxWithdraw_ ? maxWithdraw_ : shortfall;

            // Withdraw from the yield vault.
            if (assetsToWithdraw > 0) {
                $.yieldVault.withdraw(assetsToWithdraw, address(this), address(this));
                // Emit the event.
                emit ReserveRebalanced(reservedAssets());
            } else if (force) {
                revert("CANNOT_REBALANCE_RESERVE_AT_THIS_MOMENT");
            }
        } else if (reservedAssets_ > minimumReserve && allowRebalanceDown) {
            // Calculate how much to deposit.
            uint256 excess = reservedAssets_ - minimumReserve;
            // @note Yield vault usage.
            uint256 maxDeposit_ = $.yieldVault.maxDeposit(address(this));
            uint256 assetsToDeposit = excess > maxDeposit_ ? maxDeposit_ : excess;

            // Deposit into the yield vault.
            if (assetsToDeposit > 0) {
                $.yieldVault.deposit(assetsToDeposit, address(this));
                // Emit the event.
                emit ReserveRebalanced(reservedAssets());
            } else if (force) {
                revert("CANNOT_REBALANCE_RESERVE_AT_THIS_MOMENT");
            }
        } else if (force) {
            revert("NO_NEED_TO_REBALANCE_RESERVE");
        }
    }

    /// @notice Transfers yield generated by the yield vault to the yield recipient in the form of the underlying token.
    /// @notice The reserve will be rebalanced before collecting yield. This may result in the amount of yield being slightly different than reported by the `yield` function.
    /// @notice This function can be called by the owner only.
    /// @notice Transfer fees of the underlying token may apply.
    /// @notice Withdrawal fees of the yield vault may apply.
    function collectYield() external whenNotPaused onlyOwner {
        _collectYield(true);
    }

    /// @notice Transfers yield generated by the yield vault to the yield recipient in the form of the underlying token.
    /// @notice The reserve will be rebalanced before collecting yield. This may result in the amount of yield being slightly different than reported by the `yield` function.
    /// @param force Whether to revert if no yield can be collected.
    function _collectYield(bool force) internal {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Try to rebalance the reserve.
        _rebalanceReserve(false, true);

        // Calculate the yield.
        uint256 yield_ = yield();

        if (yield_ > 0) {
            // Calculate the amount to withdraw.
            uint256 maxWithdraw_ = $.yieldVault.maxWithdraw(address(this));
            uint256 amountToWithdraw = yield_ > maxWithdraw_ ? maxWithdraw_ : yield_;

            if (amountToWithdraw == 0) {
                if (force) revert("CANNOT_COLLECT_YIELD_AT_THIS_MOMENT");
                else return;
            }

            // Withdraw the yield to the yield recipient.
            $.yieldVault.withdraw(amountToWithdraw, $.yieldRecipient, address(this));

            // Emit the event.
            emit YieldCollected(yieldRecipient(), amountToWithdraw);
        } else if (force) {
            revert("NO_YIELD");
        }
    }

    /// @notice Completes migration of backing in the underlying token from a Layer Y to Layer X by minting and locking up the required amount of yeToken in LxLy Bridge.
    /// @notice This function can be called by the Migration Manager only.
    /// @param assets The amount of the underlying token to transfer from Migration Manager to self.
    /// @param destinationNetworkId The LxLy ID of Layer Y the backing is being migrated from.
    /// @param shares The required amount of yeToken to mint and lock up in LxLy Bridge. Yield may be utilized to offset transfer fees of the underlying token.
    function completeMigration(uint256 assets, uint32 destinationNetworkId, uint256 shares) external whenNotPaused {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the inputs.
        require(msg.sender == $.migrationManager, "UNAUTHORIZED");
        require(destinationNetworkId != $.lxlyId, "INVALID_NETWORK_ID");
        require(shares > 0, "INVALID_AMOUNT");

        // Transfer the underlying token from the sender to itself.
        uint256 previousBalance = $.underlyingToken.balanceOf(address(this));
        $.underlyingToken.safeTransferFrom(msg.sender, address(this), assets);
        assets = $.underlyingToken.balanceOf(address(this)) - previousBalance;

        // Calculate discrepancy between the required amount of yeToken (`shares`) and the amount of the underlying token transferred from Migration Manager (`assets`).
        // Discrepancy is possible due to transfer fees of the underlying token. To offset the discrepancy, we mint more yeToken backed by the yield in the yield vault.
        // This ensures that the amount of yeToken locked up in LxLy Bridge on Layer X matches the supply of the custom token on Layer Ys.
        uint256 discrepancy = convertToAssets(shares) - assets;
        uint256 yield_ = yield();
        if (discrepancy > 0) {
            require(yield_ >= assets && discrepancy <= yield_ - assets, "INSUFFICIENT_YIELD_TO_COVER_FOR_DISCREPANCY");
        }

        // Calculate the amount to reserve and the amount to deposit into the yield vault.
        // @note Check rounding.
        uint256 assetsToReserve = (assets * $.minimumReservePercentage) / 100;
        uint256 assetsToDeposit = assets - assetsToReserve;

        // Deposit into the yield vault.
        // @note Yield vault usage.
        uint256 maxDeposit_ = $.yieldVault.maxDeposit(address(this));
        assetsToDeposit = assetsToDeposit > maxDeposit_ ? maxDeposit_ : assetsToDeposit;
        if (assetsToDeposit > 0) {
            $.yieldVault.deposit(assetsToDeposit, address(this));
        }

        // Mint yeToken to self and bridge it to address zero on the destination network.
        // The yeToken will not be claimable on the destination network, but provides liquidity for bridging from Layer Ys to Layer X.
        _mint(address(this), shares);
        lxlyBridge().bridgeAsset(destinationNetworkId, address(0), shares, address(this), true, "");

        // Emit the ERC-4626 event.
        emit IERC4626.Deposit(msg.sender, address(this), assets, shares);

        // Emit the event.
        emit MigrationCompleted(destinationNetworkId, shares, discrepancy);
    }

    /// @notice Sets the yield recipient.
    /// @notice Yield will be collected before changing the recipient.
    /// @notice This function can be called by the owner only.
    function setYieldRecipient(address yieldRecipient_) external onlyOwner whenNotPaused {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the input.
        require(yieldRecipient_ != address(0), "INVALID_YIELD_RECIPIENT");

        // Try to collect yield.
        _collectYield(false);

        // Set the yield recipient.
        $.yieldRecipient = yieldRecipient_;

        // Emit the event.
        emit YieldRecipientSet(yieldRecipient_);
    }

    /// @notice Sets the minimum reserve percentage.
    /// @notice The reserve will be rebalanced after changing the minimum reserve percentage.
    /// @notice This function can be called by the owner only.
    function setMinimumReservePercentage(uint8 minimumReservePercentage_) external onlyOwner whenNotPaused {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Check the input.
        require(minimumReservePercentage_ <= 100, "INVALID_PERCENTAGE");

        // Set the minimum reserve percentage.
        $.minimumReservePercentage = minimumReservePercentage_;

        // Try to rebalance the reserve.
        _rebalanceReserve(false, true);

        // Emit the event.
        emit MinimumReservePercentageSet(minimumReservePercentage_);
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

    // -----================= ::: DEV ::: =================-----

    /// @notice Accounts for the transfer fee of the underlying token.
    /// @dev You must implement the same behavior as that of the underlying token for calculating the transfer fee.
    /// @dev If the underlying token does not have a transfer fee, the output must equal the input.
    /// @dev This function is used for estamation purposes only.
    /// @dev Example:
    /// @dev Fee: 2% flat
    /// @dev Input: `100`
    /// @dev Output: `98`
    function _assetsAfterTransferFee(uint256 assetsBeforeTransferFee) internal view virtual returns (uint256);

    /// @notice Accounts for the transfer fee of the underlying token.
    /// @dev You must implement the same behavior as that of the underlying token for calculating the transfer fee.
    /// @dev If the underlying token does not have a transfer fee, the output must equal the input.
    /// @dev This function is used for estamation purposes only.
    /// @dev Example:
    /// @dev Fee: 2% flat
    /// @dev Input:  `100`
    /// @dev Output: `102`
    /// @param minimumAssetsAfterTransferFee It may not always be mathematically possible to calculate the assets before a transfer fee (because of fee tiers, etc). In those cases, the output should be the closest higher amount.
    function _assetsBeforeTransferFee(uint256 minimumAssetsAfterTransferFee) internal view virtual returns (uint256);
}

// @todo Reentrancy review.
// @todo Review with Morpho: pre function calls (e.g., before `withdraw`), the possibility unfavorable rates, etc.
// @todo Check Morpho skim and fee recipients.
// @todo @notes.
