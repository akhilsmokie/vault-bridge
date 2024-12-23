// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

// @todo Inspect these contracts later.
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CommonAdminOwner} from "./CommonAdminOwner.sol";
import {IERC20Plus} from "./interfaces/IERC20Plus.sol";
import {LibPermit} from "./helpers/LibPermit.sol";

import {
    ERC20PermitUpgradeable,
    ERC20Upgradeable
} from "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title Yield Exposed Token
/// @dev A base contract to create yield exposed tokens.
// @todo Account for possible USDC fees.
abstract contract YieldExposedToken is CommonAdminOwner, IERC4626, ERC20PermitUpgradeable {
    using SafeERC20 for IERC20Plus;

    /// @dev Used in cross-chain communication.
    enum Instruction {
        COMPLETE_MIGRATION
    }

    /**
     * @dev Storage of the YieldExposedToken contract.
     * @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with upgradeable contracts.
     * @custom:storage-location erc7201:0xpolygon.storage.YieldExposedToken
     */
    // @note Some of these can be be immutable values.
    struct YieldExposedTokenStorage {
        uint8 decimals;
        IERC20Plus underlyingToken;
        /// @dev 100 is 100%.
        uint8 minimumReservePercentage;
        IERC4626 yieldGeneratingVault;
        address yieldRecipient;
        IPolygonZkEVMBridge lxlyBridge;
        address nativeConverter;
    }

    /// @dev The storage slot at which Gas Porter storage starts, following the EIP-7201 standard.
    /// @dev Calculated as `keccak256(abi.encode(uint256(keccak256("0xpolygon.storage.YieldExposedToken")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _YIELD_EXPOSED_TOKEN_STORAGE =
        0xed23de664e59f2cbf6ba852da776346da171cf53c9d06b116fea0fc5ee912500;

    event Deposit(address indexed from, address indexed to, uint256 amount);
    event ReserveReplenished(uint256 newReserve);
    event YieldAccrued(address indexed yieldRecipient, uint256 shares);
    event USDCClaimed(address indexed destinationAddress, uint256 amount);

    constructor() {
        _disableInitializers();
        // @todo Inspect this.
        // override default OZ behaviour that sets msg.sender as the owner
        // set the owner of the implementation to an address that can not change anything
        renounceOwnership();
    }

    // @todo Inspect the modifiers.
    /// @dev `decimals` will match the underlying token.
    function initialize(
        address owner_,
        string calldata name_,
        string calldata symbol_,
        address underlyingToken_,
        uint8 minReservePercentage_,
        address yieldGeneratingVault_,
        address yieldRecipient_,
        address lxlyBridge_,
        address nativeConverter_
    ) external onlyProxy onlyAdmin initializer {
        require(underlyingToken_ != address(0), "INVALID_TOKEN");
        require(minReservePercentage_ <= 100, "INVALID_PERCENTAGE");
        require(yieldGeneratingVault_ != address(0), "INVALID_VAULT");
        require(yieldRecipient_ != address(0), "INVALID_BENEFICIARY");
        require(lxlyBridge_ != address(0), "INVALID_BRIDGE");

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        // @todo Inspect these.
        __CommonAdminOwner_init();
        _transferOwnership(owner_);

        YieldExposedTokenStorage storage s = _getYieldExposedTokenStorage();
        s.decimals = ERC20Upgradeable(underlyingToken_).decimals();
        s.underlyingToken = IERC20Plus(underlyingToken_);
        s.minimumReservePercentage = minReservePercentage_;
        s.yieldGeneratingVault = IERC4626(yieldGeneratingVault_);
        s.yieldRecipient = yieldRecipient_;
        s.lxlyBridge = IPolygonZkEVMBridge(lxlyBridge_);
        s.nativeConverter = nativeConverter_;

        IERC20Plus(underlyingToken_).approve(yieldGeneratingVault_, type(uint256).max);
        IERC20Plus(address(this)).approve(lxlyBridge_, type(uint256).max);
    }

    function underlyingToken() public view returns (IERC20Plus) {
        return _getYieldExposedTokenStorage().underlyingToken;
    }

    function minReservePercentage() public view returns (uint256) {
        return _getYieldExposedTokenStorage().minimumReservePercentage;
    }

    function yieldGeneratingVault() public view returns (IERC4626) {
        return _getYieldExposedTokenStorage().yieldGeneratingVault;
    }

    function yieldRecipient() public view returns (address) {
        return _getYieldExposedTokenStorage().yieldRecipient;
    }

    function lxlyBridge() public view returns (IPolygonZkEVMBridge) {
        return _getYieldExposedTokenStorage().lxlyBridge;
    }

    function nativeConverter() public view returns (address) {
        return _getYieldExposedTokenStorage().nativeConverter;
    }

    // @notice The underlying asset that backs yeUSDC.
    function asset() external view override returns (address assetTokenAddress) {
        return address(underlyingToken());
    }

    // @notice The total backing of yeUSDC in USDC.
    // @notice May be less that the actual amount if Native Converter on L2 has minted USDC-e and has not migrated its to L1 yet.
    function totalAssets() public view override returns (uint256 totalManagedAssets) {
        return underlyingToken().balanceOf(address(this))
            + yieldGeneratingVault().convertToAssets(yieldGeneratingVault().balanceOf(address(this)));
    }

    // @notice yeUSDC is backed 1:1 by USDC.
    function convertToShares(uint256 assets) external pure override returns (uint256 shares) {
        return assets;
    }

    // @notice yeUSDC is backed 1:1 by USDC.
    function convertToAssets(uint256 shares) external pure override returns (uint256 assets) {
        return shares;
    }

    // @notice How much USDC a specific user can deposit. (Depositing USDC mints yeUSDC).
    function maxDeposit(address) external pure override returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    // @notice How much yeUSDC one would get if they deposited a specific amount of USDC right now.
    function previewDeposit(uint256 assets) external pure override returns (uint256 shares) {
        return assets;
    }

    // @notice Deposit a specific amount of USDC and receive yeUSDC.
    function deposit(uint256 assets, address destinationAddress) external override returns (uint256 shares) {
        return _deposit(assets, 0, destinationAddress, false, false);
    }

    // @notice Deposit a specific amount of USDC and receive yeUSDC.
    // @dev Uses EIP-2612 permit.
    function deposit(uint256 assets, bytes calldata permitData, address destinationAddress)
        external
        returns (uint256 shares)
    {
        return _deposit(assets, permitData, 0, destinationAddress, false, false);
    }

    // @notice Deposit a specific amount of USDC, and bridge yeUSDC to L2.
    // @dev If yeUSDC is custom mapped to USDC-e on L2, the user will receive USDC-e. If not, they will receive WYeUSDC.
    function depositAndBridge(
        uint256 assets,
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot
    ) external returns (uint256 shares) {
        return _deposit(assets, destinationNetworkId, destinationAddress, true, forceUpdateGlobalExitRoot);
    }

    // @notice Deposit a specific amount of USDC, and bridge yeUSDC to L2.
    // dev If yeUSDC is custom mapped to USDC-e on L2, the user will receive USDC-e. If not, they will receive WYeUSDC.
    // @dev Uses EIP-2612 permit.
    function depositAndBridge(
        uint256 assets,
        address destinationAddress,
        uint32 destinationNetworkId,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) external returns (uint256 shares) {
        return _deposit(assets, permitData, destinationNetworkId, destinationAddress, true, forceUpdateGlobalExitRoot);
    }

    // @notice Deposits USDC, mints the equal amount of yeUSDC, and optionally bridges it.
    function _deposit(
        uint256 amount,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool bridge,
        bool forceUpdateGlobalExitRoot
    ) internal returns (uint256 shares) {
        // Check inputs.
        require(destinationAddress != address(0), "INVALID_RECEIVER");
        require(amount > 0, "INVALID_AMOUNT");

        // Transfer the USDC from the sender to the contract.
        underlyingToken().safeTransferFrom(msg.sender, address(this), amount);

        // Keep the reserve amount in the contract (i.e., the reserve).
        uint256 amountToReserve = (amount * minReservePercentage()) / 100;
        uint256 amountToDeposit = amount - amountToReserve;

        // Deposit the remaining amount in the yield generating vault, if possible.
        uint256 maxDeposit_ = yieldGeneratingVault().maxDeposit(address(this));
        amountToDeposit = amountToDeposit > maxDeposit_ ? maxDeposit_ : amountToDeposit;
        if (amountToDeposit > 0) {
            yieldGeneratingVault().deposit(amountToDeposit, address(this));
        }

        if (bridge) {
            // Mint yeUSDC to self and bridge it to the recipient.
            _mint(address(this), amount);
            lxlyBridge().bridgeAsset(
                destinationNetworkId, destinationAddress, amount, address(this), forceUpdateGlobalExitRoot, ""
            );
        } else {
            // Mint yeUSDC to the recipient.
            _mint(destinationAddress, amount);
        }

        // Emit the ERC-4626 event.
        emit Deposit(msg.sender, destinationAddress, amount);

        return amount;
    }

    // @notice Deposits USDC, mints the equal amount of yeUSDC, and optionally bridges it.
    // @dev Uses EIP-2612 permit.
    function _deposit(
        uint256 amount,
        bytes calldata permitData,
        uint32 destinationNetworkId,
        address destinationAddress,
        bool bridge,
        bool forceUpdateGlobalExitRoot
    ) internal returns (uint256 shares) {
        // Apply the permit if provided.
        if (permitData.length > 0) {
            LibPermit.permit(address(underlyingToken()), amount, permitData);
        }

        return _deposit(amount, destinationNetworkId, destinationAddress, bridge, forceUpdateGlobalExitRoot);
    }

    // @notice How much yeUSDC a specific user can mint. (Minting yeUSDC locks USDC).
    function maxMint(address) external pure override returns (uint256 maxShares) {
        return type(uint256).max;
    }

    // @notice How much USDC it would take to mint a specific amount of yeUSDC right now.
    function previewMint(uint256 shares) external pure override returns (uint256 assets) {
        return shares;
    }

    // @notice Mint a specific amount of yeUSDC by depositing USDC.
    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        return _deposit(shares, 0, receiver, false, false);
    }

    // @notice How much USDC a specific user can withdraw. (Withdrawing USDC burns yeUSDC).
    function maxWithdraw(address owner) external view override returns (uint256 maxAssets) {
        return _withdrawable(balanceOf(owner), false);
    }

    // @notice How much yeUSDC would be burned if a specific amount of USDC were withdrawn right now.
    function previewWithdraw(uint256 assets) external view override returns (uint256 shares) {
        return _withdrawable(assets, true);
    }

    // @notice Withdraw a specific amount of USDC by burning the same amount of yeUSDC.
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        // @todo Check if the owner allowed the sender to withdraw on their behalf.

        uint256 originalAmount = assets;

        // Attempt to withdraw from the reserve first
        uint256 currentBalance = underlyingToken().balanceOf(address(this));

        if (currentBalance >= assets) {
            _burn(owner, originalAmount);
            underlyingToken().safeTransfer(receiver, assets);
            return originalAmount;
        } else if (currentBalance > 0) {
            assets -= currentBalance;
        }

        // Withdraw the remaining amount from the vault

        uint256 maxWithdraw_ = yieldGeneratingVault().maxWithdraw(address(this));
        maxWithdraw_ = assets > maxWithdraw_ ? maxWithdraw_ : assets;

        // 2. always return USDC from the vault (if there's any)
        if (maxWithdraw_ > 0) {
            yieldGeneratingVault().withdraw(maxWithdraw_, receiver, address(this));
            if (assets == maxWithdraw_) {
                _burn(owner, originalAmount);
                underlyingToken().safeTransfer(receiver, originalAmount);
                return originalAmount;
            }
            assets -= maxWithdraw_;
        }

        revert("WITHDRAWAL_TOO_LARGE");
    }

    function _withdrawable(uint256 amount, bool force) internal view returns (uint256) {
        uint256 originalAmount = amount;

        // Attempt to withdraw from the reserve first
        uint256 currentBalance = underlyingToken().balanceOf(address(this));

        if (currentBalance >= amount) {
            return originalAmount;
        } else {
            amount -= currentBalance;
        }

        // Withdraw the remaining amount from the vault

        uint256 maxWithdraw_ = yieldGeneratingVault().maxWithdraw(address(this));
        maxWithdraw_ = amount > maxWithdraw_ ? maxWithdraw_ : amount;

        // 2. always return USDC from the vault (if there's any)
        if (amount == maxWithdraw_) return originalAmount;
        amount -= maxWithdraw_;

        if (force && amount > 0) revert("WITHDRAWAL_TOO_LARGE");

        return originalAmount - amount;
    }

    // @notice How much yeUSDC a specific user can burn. (Burning yeUSDC unlocks USDC).
    function maxRedeem(address owner) external view override returns (uint256 maxShares) {
        return _withdrawable(balanceOf(owner), false);
    }

    // @notice How much USDC would be unlocked if a specific amount of yeUSDC were burned right now.
    function previewRedeem(uint256 shares) external view override returns (uint256 assets) {
        return _withdrawable(shares, true);
    }

    // @notice Burn a specific amount of yeUSDC and unlock the same amount of USDC.
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        // @todo Check if the owner allowed the sender to redeem on their behalf.

        return withdraw(shares, receiver, owner);
    }

    /// @notice Refills the USDC reserve by withdrawing USDC from the yield generating vault, if the reserve is below the minimum threshold.
    function replenishReserve() external whenNotPaused {
        uint256 currentReserve = underlyingToken().balanceOf(address(this));
        uint256 targetReserve = (totalSupply() * minReservePercentage()) / 100;

        if (currentReserve < targetReserve) {
            uint256 shortfall = targetReserve - currentReserve;
            uint256 maxWithdraw_ = yieldGeneratingVault().maxWithdraw(address(this));
            uint256 amountToWithdraw = shortfall > maxWithdraw_ ? maxWithdraw_ : shortfall;
            yieldGeneratingVault().withdraw(amountToWithdraw, address(this), address(this));
        } else {
            revert("NO_NEED_TO_REPLANISH_RESERVE");
        }

        emit ReserveReplenished(underlyingToken().balanceOf(address(this)));
    }

    /// @notice Transfers yield generating vault shares worth of excess USDC backing to the yield recipient.
    function accrueYield() external whenNotPaused {
        uint256 currentReserve = underlyingToken().balanceOf(address(this));
        uint256 targetReserve = (totalSupply() * minReservePercentage()) / 100;

        if (currentReserve > targetReserve) {
            uint256 excess = currentReserve - targetReserve;
            uint256 maxDeposit_ = yieldGeneratingVault().maxDeposit(address(this));
            excess = excess > maxDeposit_ ? maxDeposit_ : excess;
            yieldGeneratingVault().deposit(excess, address(this));
        }

        uint256 totalAssets_ = totalAssets();

        uint256 shares;

        // Transfer yield generating vault shares to the yield recipient if there is yield.
        if (totalAssets_ > totalSupply()) {
            uint256 excess = totalAssets_ - totalSupply();
            // @todo Check whether fluctuations in liquidity affect the conversion rate.
            shares = yieldGeneratingVault().convertToShares(excess);
            yieldGeneratingVault().transfer(yieldRecipient(), shares);
        } else {
            revert("NO_YIELD");
        }

        emit YieldAccrued(yieldRecipient(), shares);
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
        uint256 currentBalance = IERC20Plus(address(this)).balanceOf(destinationAddress);

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

        uint256 newBalance = IERC20Plus(address(this)).balanceOf(destinationAddress);

        uint256 difference = newBalance - currentBalance;

        if (difference > 0) {
            _burn(destinationAddress, difference);
            underlyingToken().safeTransfer(destinationAddress, difference);
        }

        emit USDCClaimed(destinationAddress, difference);
    }

    /// @notice The number of decimals of the yield exposed token.
    /// @notice The number of decimals is the same as that of the underlying token.
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return _getYieldExposedTokenStorage().decimals;
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
