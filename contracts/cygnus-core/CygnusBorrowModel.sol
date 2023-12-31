//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  CygnusBorrowModel.sol
//
//  Copyright (C) 2023 CygnusDAO
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this prograinterestRateModel.  If not, see <https://www.gnu.org/licenses/>.
pragma solidity >=0.8.17;

// Dependencies
import {ICygnusBorrowModel} from "./interfaces/ICygnusBorrowModel.sol";
import {CygnusBorrowControl} from "./CygnusBorrowControl.sol";

// Libraries
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {SafeCastLib} from "./libraries/SafeCastLib.sol";

// Interfaces
import {IPillarsOfCreation} from "./interfaces/IPillarsOfCreation.sol";

// Overrides
import {CygnusTerminal, ICygnusTerminal} from "./CygnusTerminal.sol";

/**
 *  @title  CygnusBorrowModel Contract that accrues interest and stores borrow data of each user
 *  @author CygnusDAO
 *  @notice Contract that accrues interest and tracks borrows for this shuttle. It accrues interest on any borrow,
 *          liquidation or repay. The Accrue function uses 1 memory slot per accrual. This contract is also used
 *          by CygnusCollateral contracts to get the latest borrow balance of a borrower to calculate current debt
 *          ratio, liquidity or shortfall.
 *
 *          The interest accrual mechanism is similar to Compound Finance's with the exception of reserves.
 *          If the reserveRate is set (> 0) then the contract mints the vault token (CygUSD) to the daoReserves
 *          contract set at the factory.
 *
 *          There's also 2 functions `trackLender` & `trackBorrower` which are used to give out rewards to lenders
 *          and borrowers respectively. The way rewards are calculated is by querying the latest balance of
 *          CygUSD for lenders and the latest borrow balance for borrowers. See the `_afterTokenTransfer` function
 *          in CygnusBorrow.sol. After any token transfer of CygUSD we pass the balance of CygUSD of the `from`
 *          and `to` address. After any borrow, repay or liquidate we track the latest borrow balance of the
 *          borrower.
 */
contract CygnusBorrowModel is ICygnusBorrowModel, CygnusBorrowControl {
    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            1. LIBRARIES
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:library FixedPointMathLib Arithmetic library with operations for fixed-point numbers
     */
    using FixedPointMathLib for uint256;

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            2. STORAGE
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @custom:struct BorrowSnapshot Container for individual user's borrow balance information
     *  @custom:member principal The total borrowed amount without interest accrued
     *  @custom:member interestIndex Borrow index as of the most recent balance-changing action
     */
    struct BorrowSnapshot {
        uint128 principal;
        uint128 interestIndex;
    }

    /**
     *  @notice Internal snapshot of each borrower. To get the principal and current owed amount use `getBorrowBalance(account)`
     */
    mapping(address => BorrowSnapshot) internal borrowBalances;

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    // Use one memory slot per accrual

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    uint96 public override totalBorrows;

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    uint80 public override borrowIndex;

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    uint48 public override borrowRate;

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    uint32 public override lastAccrualTimestamp;

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            3. CONSTRUCTOR
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @notice Constructs the borrow tracker contract
     */
    constructor() {
        // Set initial borrow index to 1
        borrowIndex = 1e18;

        // Set last accrual timestamp to deployment time
        lastAccrualTimestamp = uint32(block.timestamp);
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            5. CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Private ────────────────────────────────────────────────  */

    /**
     *  @notice We keep this internal as our borrowRate state variable gets stored during accruals
     *  @param cash Total current balance of assets this contract holds
     *  @param borrows Total amount of borrowed funds
     */
    function borrowRatePrivate(uint256 cash, uint256 borrows) private view returns (uint256) {
        // Utilization rate = borrows / (cash + borrows). We don't take into account reserves since we mint CygUSD
        uint256 util = borrows == 0 ? 0 : borrows.divWad(cash + borrows);

        // If utilization <= kink return normal rate
        if (util <= interestRateModel.kink) {
            // Normal rate = slope + base
            return util.mulWad(interestRateModel.multiplierPerSecond) + interestRateModel.baseRatePerSecond;
        }

        // else return normal rate + kink rate
        uint256 normalRate = uint256(interestRateModel.kink).mulWad(interestRateModel.multiplierPerSecond) +
            interestRateModel.baseRatePerSecond;

        // Get the excess utilization rate
        uint256 excessUtil = util - interestRateModel.kink;

        // Return per second borrow rate
        return excessUtil.mulWad(interestRateModel.jumpMultiplierPerSecond) + normalRate;
    }

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    /**
     *  @notice Overrides the previous totalAssets from CygnusTerminal
     *  @inheritdoc CygnusTerminal
     */
    function totalAssets() public view override(ICygnusTerminal, CygnusTerminal) returns (uint256) {
        // The total stablecoins we own including borrows
        return totalBalance + totalBorrows;
    }

    /**
     *  @notice Overrides the previous exchange rate from CygnusTerminal
     *  @inheritdoc CygnusTerminal
     */
    function exchangeRate() public view override(ICygnusTerminal, CygnusTerminal) returns (uint256) {
        // Gas savings if non-zero
        uint256 _totalSupply = totalSupply();

        // Compute the exchange rate as the total balance plus the total borrows of the underlying asset
        // Unlike cTokens we don't take into account totalReserves since our reserves are minted CygUSD
        return _totalSupply == 0 ? 1e18 : totalAssets().divWad(_totalSupply);
    }

    /**
     *  @dev It is used by CygnusCollateral contract to check a borrower's position
     *  @inheritdoc ICygnusBorrowModel
     */
    function getBorrowBalance(address borrower) public view override returns (uint256 principal, uint256 borrowBalance) {
        // Load user struct to storage (gas savings when called from Collateral.sol)
        BorrowSnapshot storage borrowSnapshot = borrowBalances[borrower];

        // If interestIndex = 0 then user has no borrows
        if (borrowSnapshot.interestIndex == 0) return (0, 0);

        // The original loaned amount without interest accruals
        principal = borrowSnapshot.principal;

        // Calculate borrow balance with latest borrow index
        borrowBalance = principal.fullMulDiv(borrowIndex, borrowSnapshot.interestIndex);
    }

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function utilizationRate() external view override returns (uint256) {
        // Gas savings
        uint256 _totalBorrows = totalBorrows;

        // Return the current pool utilization rate - we don't take into account reserves since we mint CygUSD
        return _totalBorrows == 0 ? 0 : _totalBorrows.divWad(totalAssets());
    }

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function supplyRate() external view override returns (uint256) {
        // Current burrow rate taking into account the reserve factor
        uint256 rateToPool = uint256(borrowRate).mulWad(1e18 - reserveFactor);

        // Current balance of USDC + owed, with interest (ie cash + borrows)
        uint256 balance = totalAssets();

        // Avoid divide by 0
        if (balance == 0) return 0;

        // Utilization rate
        uint256 util = uint256(totalBorrows).divWad(balance);

        // Return pool supply rate
        return util.mulWad(rateToPool);
    }

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function getLenderPosition(address lender) external view returns (uint256 cygUsdBalance, uint256 rate, uint256 positionUsd) {
        // CygUSD balance
        cygUsdBalance = balanceOf(lender);

        // Exchange Rate between CygUSD and USD
        rate = exchangeRate();

        // Position in USD = CygUSD balance * Exchange Rate
        positionUsd = cygUsdBalance.mulWad(rate);
    }

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function getBorrowTokenPrice() external view override returns (uint256) {
        // Return price of the denom token
        return nebula.denominationTokenPrice();
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            6. NON-CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Private ────────────────────────────────────────────────  */

    /**
     *  @notice Mints reserves to the DAO based on the interest accumulated.
     *  @param interestAccumulated The interest the contract has accrued from borrows since the last interest accrual
     *  @return newReserves The amount of CygUSD minted based on `interestAccumulated and the current exchangeRate
     */
    function mintReservesPrivate(uint256 interestAccumulated) private returns (uint256 newReserves) {
        // Calculate new reserves to mint based on the reserve factor and latest exchange rate
        newReserves = _convertToShares(interestAccumulated.mulWad(reserveFactor));

        // Check to mint new reserves
        if (newReserves > 0) {
            // Get the DAO Reserves current address
            address daoReserves = hangar18.daoReserves();

            // Mint to Hangar18's latest `daoReserves`
            _mint(daoReserves, newReserves);
        }
    }

    /**
     *  @notice Track borrows and lending rewards
     *  @param account The address of the lender or borrower
     *  @param balance Record of this borrower's total borrows up to this point
     *  @param collateral Whether the position is a lend or borrow position
     */
    function trackRewardsPrivate(address account, uint256 balance, address collateral) internal {
        // Latest pillars of creation address
        address rewarder = pillarsOfCreation;

        // If pillars of creation is set then track reward
        if (rewarder != address(0)) IPillarsOfCreation(rewarder).trackRewards(account, balance, collateral);
    }

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @notice Applies accrued interest to total borrows and reserves
     *  @notice Calculates the interest accumulated during the time elapsed since the last accrual and mints reserves accordingly.
     */
    function _accrueInterest() internal {
        // Get the present timestamp
        uint256 currentTimestamp = block.timestamp;

        // Get the last accrual timestamp
        uint256 accrualTimestampStored = lastAccrualTimestamp;

        // Time elapsed between present timestamp and last accrued period
        uint256 timeElapsed = currentTimestamp - accrualTimestampStored;

        // Escape if no time has past since last accrue
        if (timeElapsed == 0) return;

        // ──────────────────── Load values from storage ────────────────────────
        // Total borrows stored
        uint256 totalBorrowsStored = totalBorrows;

        // Total balance of underlying held by this contract
        uint256 cashStored = totalBalance;

        // Current borrow index
        uint256 borrowIndexStored = borrowIndex;

        // ──────────────────────────────────────────────────────────────────────
        // 1. Get per-second BorrowRate
        uint256 borrowRateStored = borrowRatePrivate(cashStored, totalBorrowsStored);

        // 2. BorrowRate by the time elapsed
        uint256 interestFactor = borrowRateStored * timeElapsed;

        // 3. Calculate the interest accumulated in time elapsed
        uint256 interestAccumulated = interestFactor.mulWad(totalBorrowsStored);

        // 4. Add the interest accumulated to total borrows
        totalBorrowsStored += interestAccumulated;

        // 5. Update the borrow index (new_index = index + (interestfactor * index / 1e18))
        borrowIndexStored += interestFactor.mulWad(borrowIndexStored);

        // ──────────────────── Store values: 1 memory slot ─────────────────────
        // Store total borrows
        totalBorrows = SafeCastLib.toUint96(totalBorrowsStored);

        // New borrow index
        borrowIndex = SafeCastLib.toUint80(borrowIndexStored);

        // Borrow rate
        borrowRate = SafeCastLib.toUint48(borrowRateStored);

        // This accruals' timestamp
        lastAccrualTimestamp = SafeCastLib.toUint32(currentTimestamp);

        // ──────────────────────────────────────────────────────────────────────
        // New minted reserves (if any)
        uint256 newReserves = mintReservesPrivate(interestAccumulated);

        /// @custom:event AccrueInterest
        emit AccrueInterest(cashStored, totalBorrowsStored, interestAccumulated, newReserves);
    }

    /**
     * @notice Updates the borrow balance of a borrower and the total borrows of the protocol.
     * @param borrower The address of the borrower whose borrow balance is being updated.
     * @param borrowAmount The amount of tokens being borrowed by the borrower.
     * @param repayAmount The amount of tokens being repaid by the borrower.
     * @return accountBorrows The borrower's updated borrow balance
     */
    function _updateBorrow(address borrower, uint256 borrowAmount, uint256 repayAmount) internal returns (uint256 accountBorrows) {
        // Get the borrower's current borrow balance
        (, uint256 borrowBalance) = getBorrowBalance(borrower);

        // If the borrow amount is equal to the repay amount, return the current borrow balance
        if (borrowAmount == repayAmount) return borrowBalance;

        // Get the current borrow index
        uint256 borrowIndexStored = borrowIndex;

        // Get the borrower's current borrow balance and borrow index
        BorrowSnapshot storage borrowSnapshot = borrowBalances[borrower];

        // Increase the borrower's borrow balance if the borrow amount is greater than the repay amount
        if (borrowAmount > repayAmount) {
            // Amount to increase
            uint256 increaseBorrowAmount;

            // Never underflows
            unchecked {
                // Calculate the actual amount to increase the borrow balance by
                increaseBorrowAmount = borrowAmount - repayAmount;
            }

            // Calculate the borrower's updated borrow balance
            accountBorrows = borrowBalance + increaseBorrowAmount;

            // Update the snapshot record of the borrower's principal
            borrowSnapshot.principal = SafeCastLib.toUint128(accountBorrows);

            // Update the snapshot record of the present borrow index
            borrowSnapshot.interestIndex = SafeCastLib.toUint128(borrowIndexStored);

            // Total borrows of the protocol
            uint256 totalBorrowsStored = totalBorrows + increaseBorrowAmount;

            // Update total borrows to storage
            totalBorrows = SafeCastLib.toUint96(totalBorrowsStored);
        }
        // Decrease the borrower's borrow balance if the repay amount is greater than the borrow amount
        else {
            // Never underflows
            unchecked {
                // Calculate the actual amount to decrease the borrow balance by
                uint256 decreaseBorrowAmount = repayAmount - borrowAmount;

                // Calculate the borrower's updated borrow balance
                accountBorrows = borrowBalance > decreaseBorrowAmount ? borrowBalance - decreaseBorrowAmount : 0;
            }

            // Update the snapshot record of the borrower's principal
            borrowSnapshot.principal = SafeCastLib.toUint128(accountBorrows);

            // Update the snapshot record of the borrower's interest index, if no borrows then interest index is 0
            borrowSnapshot.interestIndex = accountBorrows == 0 ? 0 : SafeCastLib.toUint128(borrowIndexStored);

            // Calculate the actual decrease amount
            uint256 actualDecreaseAmount = borrowBalance - accountBorrows;

            // Total protocol borrows and gas savings
            uint256 totalBorrowsStored = totalBorrows;

            // Never underflows
            unchecked {
                // Condition check to update protocols total borrows
                totalBorrowsStored = totalBorrowsStored > actualDecreaseAmount ? totalBorrowsStored - actualDecreaseAmount : 0;
            }

            // Update total protocol borrows
            totalBorrows = SafeCastLib.toUint96(totalBorrowsStored);
        }

        // Track borrower
        trackRewardsPrivate(borrower, borrowSnapshot.principal, twinstar);
    }

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function trackLender(address lender) public override {
        // Get latest CygUSD balance
        uint256 balance = balanceOf(lender);

        // Pass balance with address(0) as collateral - The rewarder will calculate the exchange rate of CygUSD to USD to
        // correctly track how much USD the user currently has.
        trackRewardsPrivate(lender, balance, address(0));
    }

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function accrueInterest() external override {
        // Accrue interest to borrows internally
        _accrueInterest();
    }

    /**
     *  @inheritdoc ICygnusBorrowModel
     */
    function trackBorrower(address borrower) external override {
        // Latest borrow balance (with interest)
        (uint256 principal, ) = getBorrowBalance(borrower);

        // Pass borrower info to the Rewarder (if any)
        trackRewardsPrivate(borrower, principal, twinstar);
    }
}
