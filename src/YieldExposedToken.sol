// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibPermit} from "./etc/LibPermit.sol";

/// @title Yield Exposed Token
/// @dev A base contract to create yield exposed tokens.
// @todo Account for possible fees on transfers of the underlying token.
abstract contract YieldExposedToken is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    IERC4626,
    ERC20PermitUpgradeable
{
    using SafeERC20 for IERC20;

    /// @dev Used for cross-chain communication.
    enum Instruction {
        COMPLETE_MIGRATION
    }

    /**
     * @dev Storage of the YieldExposedToken contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.YieldExposedToken
     * @param minimumReservePercentage 1 is 1%. The reserve is based on the total supply of yeToken, and may not account for uncompleted migrations from L2s. Please refer to `accrueYield` for more information.
     */
    struct YieldExposedTokenStorage {
        IERC20 underlyingToken;
        uint8 decimals;
        uint8 minimumReservePercentage;
        IERC4626 yieldVault;
        address yieldRecipient;
        IPolygonZkEVMBridge lxlyBridge;
        uint32 lxlyId;
        address nativeConverter;
    }

    /// @dev The storage slot at which Gas Porter storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.YieldExposedToken")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _YIELD_EXPOSED_TOKEN_STORAGE =
        0xed23de664e59f2cbf6ba852da776346da171cf53c9d06b116fea0fc5ee912500;

    event ReserveReplenished(uint256 newReserve);
    event YieldAccrued(address indexed yieldRecipient, uint256 yvShares);

    constructor() {
        _disableInitializers();
    }

    /// @dev `decimals` will match the underlying token.
    function initialize(
        address owner_,
        string calldata name_,
        string calldata symbol_,
        address underlyingToken_,
        uint8 minimumReservePercentage_,
        address yieldVault_,
        address yieldRecipient_,
        address lxlyBridge_,
        address nativeConverter_
    ) external initializer {
        require(owner_ != address(0), "INVALID_OWNER");
        require(bytes(name_).length > 0, "INVALID_NAME");
        require(bytes(symbol_).length > 0, "INVALID_SYMBOL");
        require(underlyingToken_ != address(0), "INVALID_UNDERLYING_TOKEN");
        require(minimumReservePercentage_ <= 100, "INVALID_PERCENTAGE");
        require(yieldVault_ != address(0), "INVALID_VAULT");
        require(yieldRecipient_ != address(0), "INVALID_BENEFICIARY");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");
        require(nativeConverter_ != address(0), "INVALID_CONVERTER");

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        __Ownable_init(owner_);
        __Pausable_init();

        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        $.underlyingToken = IERC20(underlyingToken_);
        $.decimals = IERC20Metadata(underlyingToken_).decimals();
        $.minimumReservePercentage = minimumReservePercentage_;
        $.yieldVault = IERC4626(yieldVault_);
        $.yieldRecipient = yieldRecipient_;
        $.lxlyBridge = IPolygonZkEVMBridge(lxlyBridge_);
        $.lxlyId = IPolygonZkEVMBridge(lxlyBridge_).networkID();
        $.nativeConverter = nativeConverter_;

        IERC20(underlyingToken_).approve(yieldVault_, type(uint256).max);
        _approve(address(this), address(lxlyBridge_), type(uint256).max);
    }

    // @todo Remove.
    function underlyingToken() public view returns (IERC20) {
        return _getYieldExposedTokenStorage().underlyingToken;
    }

    /// @notice The number of decimals of the yield exposed token.
    /// @notice The number of decimals is the same as that of the underlying token.
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return _getYieldExposedTokenStorage().decimals;
    }

    /// @notice Yield exposed tokens have an internal reserve of the underlying token from which withdrawals are serviced first.
    /// @notice When the reserve is below the minimum threshold, it can be replenished by calling `replenishReserve`.
    function minReservePercentage() public view returns (uint256) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.minimumReservePercentage;
    }

    /// @notice An external ERC-4246 compatible vault into which the underlying token is deposited to generate yield.
    function yieldVault() public view returns (IERC4626) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.yieldVault;
    }

    /// @notice The address that receives yield generated by the yield vault.
    function yieldRecipient() public view returns (address) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.yieldRecipient;
    }

    /// @notice LxLy Bridge, which connectes AggLayer networks.
    function lxlyBridge() public view returns (IPolygonZkEVMBridge) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.lxlyBridge;
    }

    /// @notice The address of Native Converter on L2s.
    /// @dev Used for authentication in cross-chain communications.
    function nativeConverter() public view returns (address) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return $.nativeConverter;
    }

    /// @notice The underlying token that backs yeToken.
    function asset() external view override returns (address assetTokenAddress) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return address($.underlyingToken);
    }

    /// @notice The total backing of yeToken in the underlying token.
    /// @notice May be less that the actual amount if backing in Native Converter on L2s hasn't been migrated to L1 yet.
    function totalAssets() public view override returns (uint256 totalManagedAssets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        return $.underlyingToken.balanceOf(address(this))
            + $.yieldVault.convertToAssets($.yieldVault.balanceOf(address(this)));
    }

    /// @notice yeToken is backed 1:1 by the underlying token.
    /// @dev Caution: This function determines the amount of yeToken the other ERC-4626 functions mint or burn when working with the underlying token.
    function convertToShares(uint256 assets) public pure override returns (uint256 shares) {
        shares = assets;
    }

    /// @notice yeToken is backed 1:1 by the underlying token.
    /// @dev Caution: This function determines the amount of the underlying token the other ERC-4626 functions transfer to or from the receiver when working with yeToken.
    function convertToAssets(uint256 shares) public pure override returns (uint256 assets) {
        assets = shares;
    }

    /// @notice How much underlying token a specific user can deposit. (Depositing the underlying token mints yeToken).
    function maxDeposit(address) external pure override returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    /// @notice How much yeToken would be minted if a specific amount of the underlying token were deposited right now.
    function previewDeposit(uint256 assets) external pure override returns (uint256 shares) {
        return convertToShares(assets);
    }

    /// @notice Deposit a specific amount of the underlying token and get yeToken.
    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();
        return _deposit(assets, $.lxlyId, receiver, false);
    }

    /// @notice Deposit a specific amount of the underlying token, and bridge yeToken to an L2.
    /// @dev If yeToken is custom mapped on LxLy Bridge on the L2, the user will receive the custom token. If not, they will receive wrapped yeToken.
    function depositAndBridge(
        uint256 assets,
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot
    ) external returns (uint256 shares) {
        return _deposit(assets, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot);
    }

    /// @notice Deposit a specific amount of the underlying token, and bridge yeToken to an L2.
    // dev If yeToken is custom mapped on LxLy Bridge on the L2, the user will receive the custom token. If not, they will receive wrapped yeToken.
    /// @dev Uses EIP-2612 permit to transfer the underlying token from the sender to itself.
    function depositAndBridge(
        uint256 assets,
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) external returns (uint256 shares) {
        return _deposit(assets, permitData, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot);
    }

    /// @notice Locks the underlying token, mints yeToken, and optionally bridges it to an L2.
    function _deposit(
        uint256 assets,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot
    ) internal returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Set the return value.
        shares = convertToShares(assets);

        // Check input.
        require(assets > 0, "INVALID_AMOUNT");

        // Transfer the underlying token from the sender to itself.
        $.underlyingToken.safeTransferFrom(msg.sender, address(this), assets);

        // Calculate the amount to reserve and the amount to deposit into the yield vault.
        uint256 assetsToReserve = (assets * $.minimumReservePercentage) / 100;
        uint256 assetsToDeposit = assets - assetsToReserve;

        // Deposit into the yield vault.
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

        // Emit the ERC-4626 event.
        emit IERC4626.Deposit(msg.sender, destinationAddress, assets, shares);
    }

    /// @notice Locks the underlying token, mints yeToken, and optionally bridges it to an L2.
    /// @dev Uses EIP-2612 permit to transfer the underlying token from the sender to itself.
    function _deposit(
        uint256 assets,
        bytes calldata permitData,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot
    ) internal returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Use the permit.
        if (permitData.length > 0) {
            LibPermit.permit(address($.underlyingToken), assets, permitData);
        }

        return _deposit(assets, destinationNetworkId, destinationAddress, forceUpdateGlobalExitRoot);
    }

    /// @notice How much yeToken a specific user can mint. (Minting yeToken locks the underlying token).
    function maxMint(address) external pure override returns (uint256 maxShares) {
        return type(uint256).max;
    }

    /// @notice How much underlying token would be required to mint a specific amount of yeToken right now.
    /// @dev This function does not revert.
    function previewMint(uint256 shares) external pure override returns (uint256 assets) {
        return convertToAssets(shares);
    }

    /// @notice Mint a specific amount of yeToken by depositing a required amount of the underlying token.
    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Set the return value.
        assets = convertToAssets(shares);

        // Mint yeToken to the receiver.
        uint256 mintedShares = _deposit(assets, $.lxlyId, receiver, false);

        // Check output.
        require(mintedShares >= shares, "INSUFFICIENT_MINT");
    }

    /// @notice How much underlying token a specific user can withdraw. (Withdrawing the underlying token burns yeToken).
    function maxWithdraw(address owner) external view override returns (uint256 maxAssets) {
        return _simulateWithdrawal(convertToAssets(balanceOf(owner)), false);
    }

    /// @notice How much yeToken would be burned if a specific amount of the underlying token were withdrawn right now.
    /// @dev This function may revert.
    function previewWithdraw(uint256 assets) external view override returns (uint256 shares) {
        return _simulateWithdrawal(assets, true);
    }

    /// @dev Calculates the amount of the underlying token that can be withdrawn right now.
    /// @param assets The maximum amount of the underlying token to simulate a withdrawal for.
    /// @param force Whether to enforce the amount, reverting if it cannot be met.
    function _simulateWithdrawal(uint256 assets, bool force) internal view returns (uint256 withdrawableAssets) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // The amount that cannot be withdrawn at the moment.
        uint256 remainingAssets = assets;

        // Simulate withdrawal from the reserve.
        uint256 reserve = $.underlyingToken.balanceOf(address(this));

        if (reserve >= remainingAssets) {
            return assets;
        } else {
            remainingAssets -= reserve;
        }

        // Simulate withdrawal from the yield vault.
        uint256 maxWithdraw_ = yieldVault().maxWithdraw(address(this));
        maxWithdraw_ = remainingAssets > maxWithdraw_ ? maxWithdraw_ : remainingAssets;

        if (remainingAssets == maxWithdraw_) return assets;
        remainingAssets -= maxWithdraw_;

        // Revert if the `assets` is enforced and there is remaining amount.
        if (force) require(remainingAssets == 0, "AMOUNT_TOO_LARGE");

        // Return the amount of the underlying token that can be withdrawn right now.
        return assets - remainingAssets;
    }

    /// @notice Withdraw a specific amount of the underlying token by burning a required amount of yeToken.
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        YieldExposedTokenStorage storage $ = _getYieldExposedTokenStorage();

        // Set the return value.
        shares = convertToShares(assets);

        // Check input.
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // The amount that cannot be withdrawn at the moment.
        uint256 remainingAssets = assets;

        // Withdraw from the reserve.
        uint256 reserve = $.underlyingToken.balanceOf(address(this));

        if (reserve >= remainingAssets) {
            _burn(owner, shares);
            $.underlyingToken.safeTransfer(receiver, assets);
            emit IERC4626.Withdraw(msg.sender, receiver, owner, assets, shares);
            return shares;
        } else {
            remainingAssets -= reserve;
        }

        // Withdraw from the yield vault.
        uint256 maxWithdraw_ = $.yieldVault.maxWithdraw(address(this));
        maxWithdraw_ = remainingAssets > maxWithdraw_ ? maxWithdraw_ : remainingAssets;

        if (maxWithdraw_ > 0) {
            $.yieldVault.withdraw(maxWithdraw_, receiver, address(this));
            if (remainingAssets == maxWithdraw_) {
                _burn(owner, shares);
                emit IERC4626.Withdraw(msg.sender, receiver, owner, assets, shares);
                return shares;
            }
            assets -= maxWithdraw_;
        }

        revert("AMOUNT_TOO_LARGE");
    }

    /// @notice How much yeToken a specific user can burn. (Burning yeToken unlocks the underlying token).
    function maxRedeem(address owner) external view override returns (uint256 maxShares) {
        return convertToShares(_simulateWithdrawal(convertToAssets(balanceOf(owner)), false));
    }

    /// @notice How much underlying token would be unlocked if a specific amount of yeToken were burned right now.
    function previewRedeem(uint256 shares) external view override returns (uint256 assets) {
        return _simulateWithdrawal(convertToAssets(shares), true);
    }

    /// @notice Burn a specific amount of yeToken and unlock a respective amount of the underlying token.
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        // Set the return value.
        assets = convertToAssets(shares);

        // Burn yeToken.
        uint256 redeemedShares = withdraw(assets, receiver, owner);

        // Check output.
        require(redeemedShares >= shares, "INSUFFICIENT_REDEEM");
    }

    /// @notice Refills the USDC reserve by withdrawing USDC from the yield generating vault, if the reserve is below the minimum threshold.
    function replenishReserve() external whenNotPaused {
        uint256 currentReserve = underlyingToken().balanceOf(address(this));
        uint256 targetReserve = (totalSupply() * minReservePercentage()) / 100;

        if (currentReserve < targetReserve) {
            uint256 shortfall = targetReserve - currentReserve;
            uint256 maxWithdraw_ = yieldVault().maxWithdraw(address(this));
            uint256 amountToWithdraw = shortfall > maxWithdraw_ ? maxWithdraw_ : shortfall;
            yieldVault().withdraw(amountToWithdraw, address(this), address(this));
        } else {
            revert("NO_NEED_TO_REPLANISH_RESERVE");
        }

        emit ReserveReplenished(underlyingToken().balanceOf(address(this)));
    }

    /// @notice Transfers yield generating vault shares worth of excess USDC backing to the yield recipient.
    /// @notice Please claim any outstanding messages from Native Converters from L2s before calling this function.
    function accrueYield() external whenNotPaused onlyOwner {
        uint256 currentReserve = underlyingToken().balanceOf(address(this));
        uint256 targetReserve = (totalSupply() * minReservePercentage()) / 100;

        if (currentReserve > targetReserve) {
            uint256 excess = currentReserve - targetReserve;
            uint256 maxDeposit_ = yieldVault().maxDeposit(address(this));
            excess = excess > maxDeposit_ ? maxDeposit_ : excess;
            yieldVault().deposit(excess, address(this));
        }

        uint256 totalAssets_ = totalAssets();

        uint256 shares;

        // Transfer yield generating vault shares to the yield recipient if there is yield.
        if (totalAssets_ > totalSupply()) {
            uint256 excess = totalAssets_ - totalSupply();
            // @todo Check whether fluctuations in liquidity affect the conversion rate.
            shares = yieldVault().convertToShares(excess);
            yieldVault().transfer(yieldRecipient(), shares);
        } else {
            revert("NO_YIELD");
        }

        emit YieldAccrued(yieldRecipient(), shares);

        // @todo Replenish the reserve before accruing yield.
    }

    /// @dev Native Converter on an L2 calls both `bridgeAsset` and `bridgeMessage` on `migrate`.
    /// @dev The message tells yeUSDC on Ethereum how much yeUSDC must be minted and bridged to adress zero on that L2 in order to equalize the total supply of yeUSDC and USDC-e, and provide enter liquidity on LxLy Bridge on Ethereum.
    function onMessageReceived(address originAddress, uint32 originNetwork, bytes memory data)
        external
        payable
        whenNotPaused
    {
        require(msg.sender == address(lxlyBridge()), "NOT_LXLY_BRIDGE");

        (Instruction instruction, bytes memory instuctionData) = abi.decode(data, (Instruction, bytes));

        if (instruction == Instruction.COMPLETE_MIGRATION) {
            require(originAddress == nativeConverter(), "NOT_NATIVE_CONVERTER");

            uint256 amount = abi.decode(instuctionData, (uint256));

            _mint(address(this), amount);
            lxlyBridge().bridgeAsset(originNetwork, address(0), amount, address(this), false, "");
        } else {
            revert("INVALID_INSTRUCTION");
        }
    }

    /// @notice This function can be used to claim yeUSDC from LxLy Bridge and transfers USDC to the recipient.
    /// @notice This is useful when USDC-e is bridged from an L2 to Ethereum, because the recipient would have received yeUSDC otherwise.
    function claimUnderlyingToken(
        bytes32[32] calldata smtProof,
        uint32 index,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        uint32 originNetwork,
        address originTokenAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes calldata metadata
    ) external whenNotPaused {
        uint256 currentBalance = IERC20(address(this)).balanceOf(destinationAddress);

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

        uint256 newBalance = IERC20(address(this)).balanceOf(destinationAddress);

        uint256 difference = newBalance - currentBalance;

        // @todo Change this to a `withdraw` call.
        if (difference > 0) {
            _burn(destinationAddress, difference);
            underlyingToken().safeTransfer(destinationAddress, difference);
        }
    }

    /// @notice Prevents usage of functions with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allowes usage of functions with the `whenNotPaused` modifier.
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns a pointer to the ERC-7201 storage namespace.
     */
    function _getYieldExposedTokenStorage() private pure returns (YieldExposedTokenStorage storage $) {
        assembly {
            $.slot := _YIELD_EXPOSED_TOKEN_STORAGE
        }
    }
}

interface IPolygonZkEVMBridge {
    function networkID() external view returns (uint32);
    function bridgeAsset(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        address token,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) external payable;
    function claimAsset(
        bytes32[32] calldata smtProof,
        uint32 index,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        uint32 originNetwork,
        address originTokenAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes calldata metadata
    ) external;
}

/* 
    @note Solution for the Native Converter:

    (See `onMessageReceived` for the implementation)

    The bridge may not be *fully* liquid (to claim yeUSDC on L1) because Native Converters on L2s will be minting USDC-es, but USDC-e will always be backed.
    But that's what migrate is for - if there's no liquidity on the bridge, the user will be motivated to call migrate on the *upgraded* Native Converter (on any L2), which now uses bridgeAsset for WUSDC.
    [One time action] Transfer everything from L1 Escrow, depositing and bridging to address(0) on Polygon zkEVM. If more funds arive from Polygon zkEVM (because they were in transit) do it again. The L1 Escrow should be empty after. This action increases the total supply of yeUSDC, and provides liquidity on the bridge for the USDC-e that had existed previously.
    From there on, modify L1 Escrow to go through yeUSDC.

    This also partially solves calculating the minimum reserve amount (e.g., 10% of the total supply of yeUSDC).
    When a USDC-e from an L2 with the custom mapping is bridged to Ethereum, the user gets yeUSDC. This yeUSDC needs to be locked up in LxLy Bridge on the Ethereum side. This means that, upon receiveing USDC via `migrate` called on a Native Converter on an L2, yeUSDC needs to bridge those funds to address zero on that L2.
    How to do this: Native Converter should call `bridgeAsset` followed by `bridgeMessage`, and the message should mint and bridge to this L2 to address zero.

    See `onMessageReceived` for the implementation.
*/
