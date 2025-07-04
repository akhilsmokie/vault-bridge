// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

// Main functionality.
import {VaultBridgeToken} from "./VaultBridgeToken.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// Other functionality.
import {IVersioned} from "./etc/IVersioned.sol";

// Libraries.
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// External contracts.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// @remind Document.
/// @title Vault Bridge Token: Part 2 (singleton)
/// @author See https://github.com/agglayer/vault-bridge
contract VaultBridgeTokenPart2 is VaultBridgeToken {
    // Libraries.
    using SafeERC20 for IERC20;

    // -----================= ::: SETUP ::: =================-----

    constructor() {
        _disableInitializers();
    }

    // -----================= ::: SOLIDITY ::: =================-----

    fallback() external payable override {
        revert UnknownFunction(bytes4(msg.data));
    }

    // -----================= ::: VAULT BRIDGE TOKEN ::: =================-----

    /// @notice Rebalances the internal reserve by withdrawing the underlying token from, or depositing the underlying token into, the yield vault.
    /// @notice This function can be called by the rebalancer only.
    function rebalanceReserve() external whenNotPaused onlyRole(REBALANCER_ROLE) nonReentrant {
        _rebalanceReserve(true, true);
    }

    /// @notice Transfers yield generated by the yield vault to the yield recipient in the form of vbToken.
    /// @notice Does not rebalance the reserve after collecting yield to allow usage while the contract is paused.
    /// @notice This function can be called by the yield collector only.
    function collectYield() external onlyRole(YIELD_COLLECTOR_ROLE) nonReentrant {
        _collectYield(true);
    }

    /// @notice Transfers yield generated by the yield vault to the yield recipient in the form of vbToken.
    /// @dev Does not rebalance the reserve after collecting yield to allow usage while the contract is paused.
    /// @param force Whether to revert if no yield can be collected.
    function _collectYield(bool force) internal {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Calculate the yield.
        uint256 yield_ = yield();

        if (yield_ > 0) {
            // Update the net collected yield.
            $._netCollectedYield += yield_;

            // Mint vbToken to the yield recipient.
            _mint($.yieldRecipient, yield_);

            // Emit the event.
            emit YieldCollected(yieldRecipient(), yield_);
        } else if (force) {
            revert NoYield();
        }
    }

    /// @notice Burns a specific amount of vbToken.
    /// @notice This function can be used if the yield recipient has collected an unrealistic (excessive) amount of yield historically.
    /// @notice This function can be called by the yield recipient only.
    /// @dev Does not rebalance the reserve after burning to allow usage while the contract is paused.
    function burn(uint256 shares) external onlyYieldRecipient nonReentrant {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the inputs.
        require(shares > 0, InvalidShares());

        // Update the net collected yield.
        $._netCollectedYield -= shares;

        // Burn vbToken.
        _burn(msg.sender, shares);

        // Emit the event.
        emit Burned(shares);
    }

    /// @notice Adds a specific amount of the underlying token to the reserve by transferring it from the sender.
    /// @notice This function can be used to restore backing difference by donating the underlying token.
    /// @notice This function can be called by anyone.
    function donateAsYield(uint256 assets) external nonReentrant {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the input.
        require(assets > 0, InvalidAssets());

        // Transfer the underlying token from the sender to self.
        _receiveUnderlyingToken(msg.sender, assets);

        // Update the reserve.
        $.reservedAssets += assets;

        // Emit the event.
        emit DonatedAsYield(msg.sender, assets);
    }

    // @remind Redocument (the entire function).
    /// @notice Completes a migration of backing from a Layer Y to Layer X by minting and locking the required amount of vbToken in LxLy Bridge.
    /// @notice Anyone can trigger the execution of this function by claiming the asset and message on LxLy Bridge. Please refer to `NativeConverter.sol` for more information.
    /// @dev Backing for Custom Token minted by Native Converter on Layer Ys can be migrated to Layer X.
    /// @dev When Native Converter migrates backing, it calls both `bridgeAsset` and `bridgeMessage` on LxLy Bridge to `migrateBackingToLayerX`.
    /// @dev The asset must be claimed before the message on LxLy Bridge.
    /// @dev The message tells vbToken how much Custom Token must be backed by vbToken, which is minted and bridged to address zero on the respective Layer Y. This action provides liquidity when bridging Custom Token to from Layer Ys to Layer X and increments the pessimistic proof.
    /// @param originNetwork The LxLy ID of Layer Y the backing is being migrated from.
    /// @param shares The required amount of vbToken to mint and lock up in LxLy Bridge. Assets from a dedicated migration fees fund may be used to offset transfer fees of the underlying token. If a migration cannot be completed due to insufficient assets, anyone can donate the underlying token to the migration fees fund. Please refer to `donateForCompletingMigration` for more information.
    /// @param assets The amount of the underlying token migrated from Layer Y (before transfer fees on Layer X).
    function completeMigration(uint32 originNetwork, uint256 shares, uint256 assets)
        external
        whenNotPaused
        onlyMigrationManager
        nonReentrant
    {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the inputs.
        require(originNetwork != $.lxlyId, InvalidOriginNetwork());
        require(shares > 0, InvalidShares());

        // Transfer the underlying token from the sender to self.
        _receiveUnderlyingToken(msg.sender, assets);

        // Calculate the discrepancy between the required amount of vbToken (`shares`) and the amount of the underlying token received from LxLy Bridge (`assets`).
        // A discrepancy is possible due to transfer fees of the underlying token. To offset the discrepancy, we mint more vbToken, backed by assets from the dedicated migration fees fund.
        // This ensures that the amount of vbToken locked up in LxLy Bridge on Layer X matches the supply of Custom Token on Layer Ys exactly.
        uint256 requiredAssets = convertToAssets(shares);
        uint256 discrepancy = requiredAssets - assets;
        uint256 assetsInMigrationFund = $.migrationFeesFund;
        if (discrepancy > 0) {
            // Check if there are enought assets in the migration fees fund to cover the discrepancy.
            require(
                assetsInMigrationFund >= discrepancy,
                CannotCompleteMigration(requiredAssets, assets, assetsInMigrationFund)
            );

            // Move the discrepancy from the migration fees fund to the reserve.
            $.migrationFeesFund -= discrepancy;
            $.reservedAssets += discrepancy;
        }

        // Calculate the amount to reserve.
        uint256 assetsToReserve = _calculateAmountToReserve(assets, shares);

        // Calculate the amount to try to deposit into the yield vault.
        uint256 assetsToDeposit = assets - assetsToReserve;

        // Try to deposit into the yield vault.
        if (assetsToDeposit > 0) {
            // Deposit, and update the amount to reserve if necessary.
            assetsToReserve += _depositIntoYieldVault(assetsToDeposit, false);
        }

        // Update the reserve.
        $.reservedAssets += assetsToReserve;

        // Mint vbToken to self and bridge it to address zero on the origin network.
        // The vbToken will not be claimable on the origin network, but provides liquidity when bridging from Layer Ys to Layer X and increments the pessimistic proof.
        _mint(address(this), shares);
        $.lxlyBridge.bridgeAsset(originNetwork, address(0), shares, address(this), true, "");

        // Emit the ERC-4626 event.
        emit IERC4626.Deposit(msg.sender, address(this), assets, shares);

        // Emit the event.
        emit MigrationCompleted(originNetwork, shares, assets, discrepancy);
    }

    /// @notice Adds a specific amount of the underlying token to a dedicated fund for covering the underlying token's transfer fees during a migration by transferring it from the sender. Please refer to `_completeMigration` for more information.
    function donateForCompletingMigration(uint256 assets) external whenNotPaused nonReentrant {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the input.
        require(assets > 0, InvalidAssets());

        // Transfer the underlying token from the sender to self.
        _receiveUnderlyingToken(msg.sender, assets);

        // Update the migration fees fund.
        $.migrationFeesFund += assets;

        // Emit the event.
        emit DonatedForCompletingMigration(msg.sender, assets);
    }

    /// @notice Sets the yield recipient.
    /// @notice Yield will be collected before changing the recipient.
    /// @notice This function can be called by the owner only.
    function setYieldRecipient(address yieldRecipient_)
        external
        whenNotPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the input.
        require(yieldRecipient_ != address(0), InvalidYieldRecipient());

        // Try to collect yield.
        _collectYield(false);

        // Set the yield recipient.
        $.yieldRecipient = yieldRecipient_;

        // Emit the event.
        emit YieldRecipientSet(yieldRecipient_);
    }

    /// @notice Sets the minimum reserve percentage.
    /// @notice This function can be called by the owner only.
    function setMinimumReservePercentage(uint256 minimumReservePercentage_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the input.
        require(minimumReservePercentage_ <= 1e18, InvalidMinimumReservePercentage());

        // Set the minimum reserve percentage.
        $.minimumReservePercentage = minimumReservePercentage_;

        // Emit the event.
        emit MinimumReservePercentageSet(minimumReservePercentage_);
    }

    // @remind Document (the entire function).
    /// @notice Consider collecting yield before calling this function.
    function drainYieldVault(uint256 shares, bool exact) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        require(shares > 0, InvalidShares());

        uint256 originalTotalSupply = totalSupply();
        uint256 originalReservedAssets = $.reservedAssets;
        uint256 originalYieldVaultSharesBalance = $.yieldVault.balanceOf(address(this));

        if (shares == type(uint256).max) {
            shares = originalYieldVaultSharesBalance;
        }

        uint256 maxShares = $.yieldVault.maxRedeem(address(this));

        if (exact) {
            require(shares <= maxShares, YieldVaultRedemptionFailed(shares, maxShares));
        }

        shares = shares > maxShares ? maxShares : shares;

        if (shares == 0) return;

        uint256 balanceBefore = $.underlyingToken.balanceOf(address(this));

        $.yieldVault.redeem(shares, address(this), address(this));

        uint256 balanceAfter = $.underlyingToken.balanceOf(address(this));

        uint256 receivedAssets = balanceAfter - balanceBefore;

        $.reservedAssets += receivedAssets;

        // Redeeming all shares at this exchange rate would need to give enough assets to back the total supply of vbToken together with the reserved assets.
        // Does not check uncollected yield to relax the condition a bit. Instead, yield can be collected manually before calling this function, if the yield collector wishes to do so.
        require(
            Math.mulDiv(originalYieldVaultSharesBalance, receivedAssets, shares)
                >= Math.mulDiv(
                    convertToAssets(originalTotalSupply) - originalReservedAssets,
                    1e18 - $.yieldVaultMaximumSlippagePercentage,
                    1e18
                ),
            ExcessiveYieldVaultSharesBurned(shares, receivedAssets)
        );

        emit YieldVaultDrained(shares, receivedAssets);
    }

    // @remind Redocument (the entire function).
    /// @notice Sets a new yieldVault. Be careful to only call this once the current vault has been emptied.
    /// @notice This function can be called by the owner only.
    function setYieldVault(address yieldVault_) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        require(yieldVault_ != address(0), InvalidYieldVault());

        $.underlyingToken.forceApprove(address($.yieldVault), 0);

        $.yieldVault = IERC4626(yieldVault_);

        $.underlyingToken.forceApprove(yieldVault_, type(uint256).max);

        // Emit the event.
        emit YieldVaultSet(yieldVault_);
    }

    /// @notice Sets the minimum deposit amount that triggers a yield vault deposit.
    /// @notice This function can be called by the owner only.
    function setMinimumYieldVaultDeposit(uint256 minimumYieldVaultDeposit_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();
        $.minimumYieldVaultDeposit = minimumYieldVaultDeposit_;
    }

    // @remind Document.
    function setYieldVaultMaximumSlippagePercentage(uint256 maximumSlippagePercentage)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        VaultBridgeTokenStorage storage $ = _getVaultBridgeTokenStorage();

        // Check the input.
        require(maximumSlippagePercentage <= 1e18, InvalidYieldVaultMaximumSlippagePercentage());

        // Set the maximum slippage percentage.
        $.yieldVaultMaximumSlippagePercentage = maximumSlippagePercentage;

        // Emit the event.
        emit YieldVaultMaximumSlippagePercentageSet(maximumSlippagePercentage);
    }

    // -----================= ::: ADMIN ::: =================-----

    /// @notice Prevents usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the pauser only.
    function pause() external onlyRole(PAUSER_ROLE) nonReentrant {
        _pause();
    }

    /// @notice Allows usage of functions with the `whenNotPaused` modifier.
    /// @notice This function can be called by the owner only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _unpause();
    }

    // -----================= ::: INFO ::: =================-----

    /// @inheritdoc IVersioned
    function version() external pure override returns (string memory) {
        return "0.5.0";
    }
}
