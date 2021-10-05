// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.6;

import "./ComptrollerInterface.sol";
import "./CTokenInterfaces.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./EIP20Interface.sol";
import "./InterestRateModel.sol";

/**
 * @title tropykus CToken Contract
 * @notice Abstract base for CTokens
 * @author tropykus
 */
abstract contract CToken is CTokenInterface, Exponential, TokenErrorReporter {
    /**
     * @notice Initialize the money market
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ EIP-20 name of this token
     * @param symbol_ EIP-20 symbol of this token
     * @param decimals_ EIP-20 decimal precision of this token
     */
    function initialize(
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) public {
        require(msg.sender == admin, "CT01");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "CT02");

        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "CT03");

        uint256 err = _setComptroller(comptroller_);
        require(err == uint256(Error.NO_ERROR), "CT04");

        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;

        err = _setInterestRateModelFresh(interestRateModel_);
        require(err == uint256(Error.NO_ERROR), "CT05");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        _notEntered = true;
    }

    /**
     * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
     * @dev Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferTokens(
        address spender,
        address src,
        address dst,
        uint256 tokens
    ) internal returns (uint256) {
        uint256 allowed = comptroller.transferAllowed(
            address(this),
            src,
            dst,
            tokens
        );
        require(allowed == 0);

        require(src != dst);

        uint256 startingAllowance = 0;
        if (spender == src) {
            startingAllowance = type(uint256).max;
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        MathError mathErr;
        uint256 allowanceNew;
        uint256 srcTokensNew;
        uint256 dstTokensNew;

        (mathErr, allowanceNew) = subUInt(startingAllowance, tokens);
        require(mathErr == MathError.NO_ERROR);

        (mathErr, srcTokensNew) = subUInt(accountTokens[src].tokens, tokens);
        require(mathErr == MathError.NO_ERROR);

        (mathErr, dstTokensNew) = addUInt(accountTokens[dst].tokens, tokens);
        require(mathErr != MathError.NO_ERROR);

        accountTokens[src].tokens = srcTokensNew;
        accountTokens[dst].tokens = dstTokensNew;

        if (startingAllowance != type(uint256).max) {
            transferAllowances[src][spender] = allowanceNew;
        }

        emit Transfer(src, dst, tokens);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint256 amount)
        external
        override
        nonReentrant
        returns (bool)
    {
        return
            transferTokens(msg.sender, msg.sender, dst, amount) ==
            uint256(Error.NO_ERROR);
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external override nonReentrant returns (bool) {
        return
            transferTokens(msg.sender, src, dst, amount) ==
            uint256(Error.NO_ERROR);
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint256 amount)
        external
        override
        returns (bool)
    {
        transferAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(address owner, address spender)
        external
        view
        override
        returns (uint256)
    {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external view override returns (uint256) {
        return accountTokens[owner].tokens;
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @dev This also accrues interest in a transaction
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(address owner)
        external
        override
        returns (uint256)
    {
        (MathError mErr, uint256 balance) = mulScalarTruncate(
            Exp({mantissa: exchangeRateCurrent()}),
            accountTokens[owner].tokens
        );
        require(mErr == MathError.NO_ERROR, "CT06");
        return balance;
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(address account)
        external
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 cTokenBalance = accountTokens[account].tokens;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;

        MathError mErr;

        (mErr, borrowBalance) = borrowBalanceStoredInternal(account);
        require(mErr == MathError.NO_ERROR);

        (mErr, exchangeRateMantissa) = exchangeRateStoredInternal();
        require(mErr == MathError.NO_ERROR);

        return (
            uint256(Error.NO_ERROR),
            cTokenBalance,
            borrowBalance,
            exchangeRateMantissa
        );
    }

    /**
     * @dev Function to simply retrieve block number
     *  This exists mainly for inheriting test contracts to stub this result.
     */
    function getBlockNumber() internal view virtual returns (uint256) {
        return block.number;
    }

    /**
     * @notice Returns the current per-block borrow interest rate for this cToken
     * @return The borrow interest rate per block, scaled by 1e18
     */
    function borrowRatePerBlock() external view override returns (uint256) {
        return
            interestRateModel.getBorrowRate(
                getCashPrior(),
                totalBorrows,
                totalReserves
            );
    }

    /**
     * @notice Returns the current per-block supply interest rate for this cToken
     * @return The supply interest rate per block, scaled by 1e18
     */
    function supplyRatePerBlock() external view override returns (uint256) {
        return
            interestRateModel.getSupplyRate(
                getCashPrior(),
                totalBorrows,
                totalReserves,
                reserveFactorMantissa
            );
    }

    /**
     * @notice Returns the current total borrows plus accrued interest
     * @return The total borrows with interest
     */
    function totalBorrowsCurrent()
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(accrueInterest() == uint256(Error.NO_ERROR), "CT07");
        return totalBorrows;
    }

    /**
     * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
     * @param account The address whose balance should be calculated after updating borrowIndex
     * @return The calculated balance
     */
    function borrowBalanceCurrent(address account)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(accrueInterest() == uint256(Error.NO_ERROR), "CT07");
        return borrowBalanceStored(account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(address account)
        public
        view
        override
        returns (uint256)
    {
        (MathError err, uint256 result) = borrowBalanceStoredInternal(account);
        require(err == MathError.NO_ERROR, "CT08");
        return result;
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return (error code, the calculated balance or 0 if error code is non-zero)
     */
    function borrowBalanceStoredInternal(address account)
        internal
        view
        returns (MathError, uint256)
    {
        MathError mathErr;
        uint256 principalTimesIndex;
        uint256 result;

        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        require(borrowSnapshot.principal != 0);

        (mathErr, principalTimesIndex) = mulUInt(
            borrowSnapshot.principal,
            borrowIndex
        );
        require(mathErr == MathError.NO_ERROR);

        (mathErr, result) = divUInt(
            principalTimesIndex,
            borrowSnapshot.interestIndex
        );
        require(mathErr == MathError.NO_ERROR);

        return (MathError.NO_ERROR, result);
    }

    function getBorrowerPrincipalStored(address account)
        public
        view
        returns (uint256 borrowed)
    {
        borrowed = accountBorrows[account].principal;
    }

    function getSupplierSnapshotStored(address account)
        public
        view
        returns (
            uint256 tokens,
            uint256 underlyingAmount,
            uint256 suppliedAt,
            uint256 promisedSupplyRate
        )
    {
        tokens = accountTokens[account].tokens;
        underlyingAmount = accountTokens[account].underlyingAmount;
        suppliedAt = accountTokens[account].suppliedAt;
        promisedSupplyRate = accountTokens[account].promisedSupplyRate;
    }

    /**
     * @notice Accrue interest then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent()
        public
        override
        nonReentrant
        returns (uint256)
    {
        require(accrueInterest() == uint256(Error.NO_ERROR), "CT07");
        return exchangeRateStored();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public view override returns (uint256) {
        (MathError err, uint256 result) = exchangeRateStoredInternal();
        require(err == MathError.NO_ERROR, "CT09");
        return result;
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return (error code, calculated exchange rate scaled by 1e18)
     */
    function exchangeRateStoredInternal()
        internal
        view
        virtual
        returns (MathError, uint256)
    {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return (MathError.NO_ERROR, initialExchangeRateMantissa);
        } else {
            MathError error;
            uint256 exchangeRate;
            uint256 totalCash = getCashPrior();
            if (interestRateModel.isTropykusInterestRateModel()) {
                (error, exchangeRate) = tropykusExchangeRateStoredInternal(
                    msg.sender
                );
                if (error == MathError.NO_ERROR) {
                    return (MathError.NO_ERROR, exchangeRate);
                } else {
                    return (MathError.NO_ERROR, initialExchangeRateMantissa);
                }
            }
            return
                interestRateModel.getExchangeRate(
                    totalCash,
                    totalBorrows,
                    totalReserves,
                    totalSupply
                );
        }
    }

    function tropykusExchangeRateStoredInternal(address redeemer)
        internal
        view
        returns (MathError, uint256)
    {
        if (totalSupply == 0) {
            return (MathError.NO_ERROR, initialExchangeRateMantissa);
        } else {
            SupplySnapshot storage supplySnapshot = accountTokens[redeemer];
            if (supplySnapshot.suppliedAt == 0) {
                return (MathError.DIVISION_BY_ZERO, 0);
            }
            (, uint256 interestFactorMantissa, ) = tropykusInterestAccrued(
                redeemer
            );
            Exp memory interestFactor = Exp({mantissa: interestFactorMantissa});
            uint256 currentUnderlying = supplySnapshot.underlyingAmount;
            Exp memory redeemerUnderlying = Exp({mantissa: currentUnderlying});
            (, Exp memory realAmount) = mulExp(
                interestFactor,
                redeemerUnderlying
            );
            (, Exp memory exchangeRate) = getExp(
                realAmount.mantissa,
                supplySnapshot.tokens
            );
            return (MathError.NO_ERROR, exchangeRate.mantissa);
        }
    }

    function tropykusInterestAccrued(address account)
        public
        view
        returns (
            MathError,
            uint256,
            uint256
        )
    {
        SupplySnapshot storage supplySnapshot = accountTokens[account];
        uint256 promisedSupplyRate = supplySnapshot.promisedSupplyRate;
        Exp memory expectedSupplyRatePerBlock = Exp({
            mantissa: promisedSupplyRate
        });
        (, uint256 delta) = subUInt(
            accrualBlockNumber,
            supplySnapshot.suppliedAt
        );
        (, Exp memory expectedSupplyRatePerBlockWithDelta) = mulScalar(
            expectedSupplyRatePerBlock,
            delta
        );
        (, Exp memory interestFactor) = addExp(
            Exp({mantissa: 1e18}),
            expectedSupplyRatePerBlockWithDelta
        );
        uint256 currentUnderlying = supplySnapshot.underlyingAmount;
        Exp memory redeemerUnderlying = Exp({mantissa: currentUnderlying});
        (, Exp memory realAmount) = mulExp(interestFactor, redeemerUnderlying);
        (, uint256 interestEarned) = subUInt(
            realAmount.mantissa,
            currentUnderlying
        );
        return (MathError.NO_ERROR, interestFactor.mantissa, interestEarned);
    }

    /**
     * @notice Get cash balance of this cToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() external view override returns (uint256) {
        return getCashPrior();
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * @dev This calculates interest accrued from the last checkpointed block
     *   up to the current block and writes new checkpoint to storage.
     */
    function accrueInterest() public override returns (uint256) {
        uint256 currentBlockNumber = getBlockNumber();
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == currentBlockNumber) {
            return uint256(Error.NO_ERROR);
        }

        uint256 cashPrior = getCashPrior();
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        uint256 borrowRateMantissa = interestRateModel.getBorrowRate(
            cashPrior,
            borrowsPrior,
            reservesPrior
        );
        require(borrowRateMantissa <= borrowRateMaxMantissa, "CT10");

        (MathError mathErr, uint256 blockDelta) = subUInt(
            currentBlockNumber,
            accrualBlockNumberPrior
        );
        require(mathErr == MathError.NO_ERROR, "CT11");

        Exp memory simpleInterestFactor;
        uint256 interestAccumulated;
        uint256 totalBorrowsNew;
        uint256 totalReservesNew;
        uint256 borrowIndexNew;

        (mathErr, simpleInterestFactor) = mulScalar(
            Exp({mantissa: borrowRateMantissa}),
            blockDelta
        );
        require(mathErr == MathError.NO_ERROR);

        (mathErr, interestAccumulated) = mulScalarTruncate(
            simpleInterestFactor,
            borrowsPrior
        );
        require(mathErr == MathError.NO_ERROR);

        (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
        require(mathErr == MathError.NO_ERROR);

        (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(
            Exp({mantissa: reserveFactorMantissa}),
            interestAccumulated,
            reservesPrior
        );
        require(mathErr == MathError.NO_ERROR);

        if (interestRateModel.isTropykusInterestRateModel()) {
            (mathErr, totalReservesNew) = newReserves(
                borrowRateMantissa,
                cashPrior,
                borrowsPrior,
                reservesPrior,
                interestAccumulated
            );
            require(mathErr == MathError.NO_ERROR);
        }

        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(
            simpleInterestFactor,
            borrowIndexPrior,
            borrowIndexPrior
        );
        require(mathErr == MathError.NO_ERROR);

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(
            cashPrior,
            interestAccumulated,
            borrowIndexNew,
            totalBorrowsNew
        );

        return uint256(Error.NO_ERROR);
    }

    function newReserves(
        uint256 borrowRateMantissa,
        uint256 cashPrior,
        uint256 borrowsPrior,
        uint256 reservesPrior,
        uint256 interestAccumulated
    ) internal view returns (MathError mathErr, uint256 totalReservesNew) {
        uint256 newReserveFactorMantissa;
        uint256 utilizationRate = interestRateModel.utilizationRate(
            cashPrior,
            borrowsPrior,
            reservesPrior
        );
        uint256 expectedSupplyRate = interestRateModel.getSupplyRate(
            cashPrior,
            borrowsPrior,
            reservesPrior,
            reserveFactorMantissa
        );
        if (
            interestRateModel.isAboveOptimal(
                cashPrior,
                borrowsPrior,
                reservesPrior
            )
        ) {
            (mathErr, newReserveFactorMantissa) = mulScalarTruncate(
                Exp({mantissa: utilizationRate}),
                borrowRateMantissa
            );
            require(mathErr == MathError.NO_ERROR);
            (mathErr, newReserveFactorMantissa) = subUInt(
                newReserveFactorMantissa,
                expectedSupplyRate
            );
            require(mathErr == MathError.NO_ERROR);
            (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(
                Exp({mantissa: newReserveFactorMantissa}),
                interestAccumulated,
                reservesPrior
            );
            require(mathErr == MathError.NO_ERROR);
        } else {
            mathErr = MathError.NO_ERROR;
            totalReservesNew = reservesPrior;
        }
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint256, uint256) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintInternal(uint256 mintAmount)
        internal
        nonReentrant
        returns (uint256, uint256)
    {
        uint256 error;
        MintLocalVars memory vars;
        vars.mintAmount = mintAmount;
        error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));
        mintCommonVerifications(msg.sender, mintAmount);
        (
            vars.mathErr,
            vars.exchangeRateMantissa
        ) = exchangeRateStoredInternal();
        require(vars.mathErr == MathError.NO_ERROR);
        mintInternalVerifications(msg.sender, vars);
        (error, vars) = mintFresh(msg.sender, vars);
        vars = mintInternalUnderlyingUpdate(msg.sender, vars);
        writeMintLocalVars(msg.sender, vars);
        return (uint256(Error.NO_ERROR), vars.accountTokensNew);
    }

    struct MintLocalVars {
        Error err;
        MathError mathErr;
        uint256 exchangeRateMantissa;
        uint256 mintTokens;
        uint256 totalSupplyNew;
        uint256 accountTokensNew;
        uint256 actualMintAmount;
        uint256 mintAmount;
        uint256 updatedUnderlying;
        uint256 currentSupplyRate;
    }

    function mintCommonVerifications(address minter, uint256 mintAmount)
        internal
    {
        uint256 allowed = comptroller.mintAllowed(
            address(this),
            minter,
            mintAmount
        );
        require(allowed == 0);
        require(accrualBlockNumber == getBlockNumber());
        require(accountBorrows[minter].principal == 0, "CT25");
    }

    function mintInternalVerifications(
        address minter,
        MintLocalVars memory vars
    ) internal virtual {
        minter;
        vars;
    }

    /**
     * @notice User supplies assets into the market and receives cTokens in exchange
     * @dev Assumes interest has already been accrued up to the current block
     * @param minter The address of the account which is supplying the assets
     * @param vars The MintLocalVars where the amount is kept
     * @return (uint, MintLocalVars) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintFresh(address minter, MintLocalVars memory vars)
        internal
        returns (uint256, MintLocalVars memory)
    {
        vars.actualMintAmount = doTransferIn(minter, vars.mintAmount);

        (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(
            vars.actualMintAmount,
            Exp({mantissa: vars.exchangeRateMantissa})
        );
        require(vars.mathErr == MathError.NO_ERROR, "CT12");

        (vars.mathErr, vars.totalSupplyNew) = addUInt(
            totalSupply,
            vars.mintTokens
        );
        require(vars.mathErr == MathError.NO_ERROR, "CT13");

        (vars.mathErr, vars.accountTokensNew) = addUInt(
            accountTokens[minter].tokens,
            vars.mintTokens
        );
        require(vars.mathErr == MathError.NO_ERROR, "CT14");

        vars.currentSupplyRate = interestRateModel.getSupplyRate(
            getCashPrior(),
            totalBorrows,
            totalReserves,
            reserveFactorMantissa
        );

        emit Mint(minter, vars.actualMintAmount, vars.mintTokens);
        emit Transfer(address(this), minter, vars.mintTokens);

        return (uint256(Error.NO_ERROR), vars);
    }

    function mintInternalUnderlyingUpdate(
        address minter,
        MintLocalVars memory vars
    ) internal virtual returns (MintLocalVars memory) {
        Exp memory updatedUnderlying;
        if (accountTokens[minter].tokens > 0) {
            uint256 currentTokens = accountTokens[minter].tokens;
            MathError mErrorUpdatedUnderlying;
            (mErrorUpdatedUnderlying, updatedUnderlying) = mulExp(
                Exp({mantissa: currentTokens}),
                Exp({mantissa: vars.exchangeRateMantissa})
            );
            require(mErrorUpdatedUnderlying == MathError.NO_ERROR);
            vars.updatedUnderlying = updatedUnderlying.mantissa;
            (, vars.mintAmount) = addUInt(
                vars.updatedUnderlying,
                vars.mintAmount
            );
        }
        return vars;
    }

    function writeMintLocalVars(address minter, MintLocalVars memory vars)
        internal
    {
        totalSupply = vars.totalSupplyNew;
        accountTokens[minter] = SupplySnapshot({
            tokens: vars.accountTokensNew,
            underlyingAmount: vars.mintAmount,
            suppliedAt: accrualBlockNumber,
            promisedSupplyRate: vars.currentSupplyRate
        });
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to receive from redeeming cTokens
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlyingInternal(uint256 redeemAmount)
        internal
        nonReentrant
        returns (uint256)
    {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));
        return redeemFresh(payable(msg.sender), redeemAmount);
    }

    struct RedeemLocalVars {
        Error err;
        MathError mathErr;
        uint256 exchangeRateMantissa;
        uint256 redeemTokens;
        uint256 redeemAmount;
        uint256 totalSupplyNew;
        uint256 accountTokensNew;
        uint256 newSubsidyFund;
    }

    /**
     * @notice User redeems cTokens in exchange for the underlying asset
     * @dev Assumes interest has already been accrued up to the current block
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming cTokens
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemFresh(address payable redeemer, uint256 redeemAmountIn)
        internal
        returns (uint256)
    {
        RedeemLocalVars memory vars;

        SupplySnapshot storage supplySnapshot = accountTokens[redeemer];

        (
            vars.mathErr,
            vars.exchangeRateMantissa
        ) = exchangeRateStoredInternal();
        require(vars.mathErr == MathError.NO_ERROR);

        uint256 interestEarned;
        uint256 subsidyFundPortion;
        uint256 currentUnderlying;

        bool isTropykusInterestRateModel = interestRateModel
            .isTropykusInterestRateModel();
        if (isTropykusInterestRateModel) {
            currentUnderlying = supplySnapshot.underlyingAmount;
            (, , interestEarned) = tropykusInterestAccrued(redeemer);
        }
        supplySnapshot.promisedSupplyRate = interestRateModel.getSupplyRate(
            getCashPrior(),
            totalBorrows,
            totalReserves,
            reserveFactorMantissa
        );

        if (
            isTropykusInterestRateModel &&
            !interestRateModel.isAboveOptimal(
                getCashPrior(),
                totalBorrows,
                totalReserves
            )
        ) {
            uint256 borrowRate = interestRateModel.getBorrowRate(
                getCashPrior(),
                totalBorrows,
                totalReserves
            );

            uint256 utilizationRate = interestRateModel.utilizationRate(
                getCashPrior(),
                totalBorrows,
                totalReserves
            );

            (, uint256 estimatedEarning) = mulScalarTruncate(
                Exp({mantissa: borrowRate}),
                utilizationRate
            );

            (, subsidyFundPortion) = subUInt(
                supplySnapshot.promisedSupplyRate,
                estimatedEarning
            );
            (, Exp memory subsidyFactor) = getExp(
                subsidyFundPortion,
                supplySnapshot.promisedSupplyRate
            );
            (, subsidyFundPortion) = mulScalarTruncate(
                subsidyFactor,
                interestEarned
            );
        }

        if (redeemAmountIn == 0) {
            vars.redeemAmount = supplySnapshot.underlyingAmount;
            redeemAmountIn = supplySnapshot.underlyingAmount;
        } else {
            vars.redeemAmount = redeemAmountIn;
        }

        if (isTropykusInterestRateModel) {
            (, Exp memory num) = mulExp(
                vars.redeemAmount,
                supplySnapshot.tokens
            );
            (, Exp memory realTokensWithdrawAmount) = getExp(
                num.mantissa,
                currentUnderlying
            );
            vars.redeemTokens = realTokensWithdrawAmount.mantissa;
        } else {
            (vars.mathErr, vars.redeemTokens) = divScalarByExpTruncate(
                redeemAmountIn,
                Exp({mantissa: vars.exchangeRateMantissa})
            );
            if (vars.mathErr != MathError.NO_ERROR) {
                return
                    failOpaque(
                        Error.MATH_ERROR,
                        FailureInfo.REDEEM_EXCHANGE_AMOUNT_CALCULATION_FAILED,
                        uint256(vars.mathErr)
                    );
            }
        }

        uint256 allowed = comptroller.redeemAllowed(
            address(this),
            redeemer,
            vars.redeemTokens
        );
        require(allowed == 0);

        require(accrualBlockNumber == getBlockNumber());

        (vars.mathErr, vars.totalSupplyNew) = subUInt(
            totalSupply,
            vars.redeemTokens
        );
        require(vars.mathErr == MathError.NO_ERROR);

        (, vars.newSubsidyFund) = subUInt(subsidyFund, subsidyFundPortion);

        (vars.mathErr, vars.accountTokensNew) = subUInt(
            supplySnapshot.tokens,
            vars.redeemTokens
        );
        require(vars.mathErr == MathError.NO_ERROR);

        uint256 cash = getCashPrior();
        if (isTropykusInterestRateModel) {
            cash = address(this).balance;
        }

        require(cash >= vars.redeemAmount);

        doTransferOut(redeemer, vars.redeemAmount);

        totalSupply = vars.totalSupplyNew;
        subsidyFund = vars.newSubsidyFund;
        supplySnapshot.tokens = vars.accountTokensNew;
        supplySnapshot.suppliedAt = accrualBlockNumber;
        (, supplySnapshot.underlyingAmount) = subUInt(
            supplySnapshot.underlyingAmount,
            vars.redeemAmount
        );

        emit Transfer(redeemer, address(this), vars.redeemTokens);
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

        comptroller.redeemVerify(
            address(this),
            redeemer,
            vars.redeemAmount,
            vars.redeemTokens
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrowInternal(uint256 borrowAmount)
        internal
        nonReentrant
        returns (uint256)
    {
        BorrowLocalVars memory vars;
        vars.borrowAmount = borrowAmount;
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));
        vars = borrowCommonValidations(payable(msg.sender), vars);
        vars = borrowInternalValidations(payable(msg.sender), vars);
        return borrowFresh(payable(msg.sender), vars);
    }

    struct BorrowLocalVars {
        MathError mathErr;
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
        uint256 borrowAmount;
    }

    function borrowCommonValidations(
        address payable borrower,
        BorrowLocalVars memory vars
    ) internal returns (BorrowLocalVars memory) {
        uint256 allowed = comptroller.borrowAllowed(
            address(this),
            borrower,
            vars.borrowAmount
        );
        require(allowed == 0);
        require(accrualBlockNumber == getBlockNumber());
        require(getCashPrior() >= vars.borrowAmount);

        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(
            borrower
        );
        require(vars.mathErr == MathError.NO_ERROR);

        (vars.mathErr, vars.accountBorrowsNew) = addUInt(
            vars.accountBorrows,
            vars.borrowAmount
        );
        require(vars.mathErr == MathError.NO_ERROR);

        (vars.mathErr, vars.totalBorrowsNew) = addUInt(
            totalBorrows,
            vars.borrowAmount
        );
        require(vars.mathErr == MathError.NO_ERROR);

        return vars;
    }

    function borrowInternalValidations(
        address payable borrower,
        BorrowLocalVars memory vars
    ) internal virtual returns (BorrowLocalVars memory) {
        borrower;
        return vars;
    }

    /**
     * @notice Users borrow assets from the protocol to their own address
     * @param borrower The borrower address
     * @param vars BorrowLocalVars struct where computed borrow vars are
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrowFresh(address payable borrower, BorrowLocalVars memory vars)
        internal
        returns (uint256)
    {
        doTransferOut(borrower, vars.borrowAmount);

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        emit Borrow(
            borrower,
            vars.borrowAmount,
            vars.accountBorrowsNew,
            vars.totalBorrowsNew
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowInternal(uint256 repayAmount)
        internal
        nonReentrant
        returns (uint256, uint256)
    {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));
        return repayBorrowFresh(msg.sender, msg.sender, repayAmount);
    }

    struct RepayBorrowLocalVars {
        Error err;
        MathError mathErr;
        uint256 repayAmount;
        uint256 borrowerIndex;
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
        uint256 actualRepayAmount;
    }

    /**
     * @notice Borrows are repaid by another user (possibly the borrower).
     * @param payer the account paying off the borrow
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of undelrying tokens being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowFresh(
        address payer,
        address borrower,
        uint256 repayAmount
    ) internal returns (uint256, uint256) {
        uint256 allowed = comptroller.repayBorrowAllowed(
            address(this),
            payer,
            borrower,
            repayAmount
        );
        require(allowed == 0);
        require(accrualBlockNumber == getBlockNumber());

        RepayBorrowLocalVars memory vars;

        vars.borrowerIndex = accountBorrows[borrower].interestIndex;

        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(
            borrower
        );
        require(vars.mathErr == MathError.NO_ERROR);

        if (repayAmount == 0) {
            vars.repayAmount = vars.accountBorrows;
        } else {
            vars.repayAmount = repayAmount;
        }

        vars.actualRepayAmount = doTransferIn(payer, vars.repayAmount);

        (vars.mathErr, vars.accountBorrowsNew) = subUInt(
            vars.accountBorrows,
            vars.actualRepayAmount
        );
        require(vars.mathErr == MathError.NO_ERROR, "CT16");

        (vars.mathErr, vars.totalBorrowsNew) = subUInt(
            totalBorrows,
            vars.actualRepayAmount
        );
        require(vars.mathErr == MathError.NO_ERROR, "CT17");

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        emit RepayBorrow(
            payer,
            borrower,
            vars.actualRepayAmount,
            vars.accountBorrowsNew,
            vars.totalBorrowsNew
        );

        return (uint256(Error.NO_ERROR), vars.actualRepayAmount);
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBorrowInternal(
        address borrower,
        uint256 repayAmount,
        CTokenInterface cTokenCollateral
    ) internal nonReentrant returns (uint256, uint256) {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));

        error = cTokenCollateral.accrueInterest();
        require(error == uint256(Error.NO_ERROR));

        // liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
        return
            liquidateBorrowFresh(
                msg.sender,
                borrower,
                repayAmount,
                cTokenCollateral
            );
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param liquidator The address repaying the borrow and seizing collateral
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBorrowFresh(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        CTokenInterface cTokenCollateral
    ) internal returns (uint256, uint256) {
        uint256 allowed = comptroller.liquidateBorrowAllowed(
            address(this),
            address(cTokenCollateral),
            liquidator,
            borrower,
            repayAmount
        );
        require(allowed == 0);
        require(accrualBlockNumber == getBlockNumber());
        require(cTokenCollateral.accrualBlockNumber() == getBlockNumber());
        require(borrower != liquidator);
        require(repayAmount != 0);
        require(repayAmount != type(uint256).max);

        (
            uint256 repayBorrowError,
            uint256 actualRepayAmount
        ) = repayBorrowFresh(liquidator, borrower, repayAmount);
        require(repayBorrowError == uint256(Error.NO_ERROR));

        (uint256 amountSeizeError, uint256 seizeTokens) = comptroller
            .liquidateCalculateSeizeTokens(
                address(this),
                address(cTokenCollateral),
                actualRepayAmount
            );
        require(amountSeizeError == uint256(Error.NO_ERROR), "CT18");

        require(cTokenCollateral.balanceOf(borrower) >= seizeTokens, "CT19");

        uint256 seizeError;
        if (address(cTokenCollateral) == address(this)) {
            seizeError = seizeInternal(
                address(this),
                liquidator,
                borrower,
                seizeTokens
            );
        } else {
            seizeError = cTokenCollateral.seize(
                liquidator,
                borrower,
                seizeTokens
            );
        }

        require(seizeError == uint256(Error.NO_ERROR), "CT20");

        emit LiquidateBorrow(
            liquidator,
            borrower,
            actualRepayAmount,
            address(cTokenCollateral),
            seizeTokens
        );

        return (uint256(Error.NO_ERROR), actualRepayAmount);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Will fail unless called by another cToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed cToken and not a parameter.
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of cTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seize(
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override nonReentrant returns (uint256) {
        return seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
    }

    struct SeizeVars {
        uint256 seizeAmount;
        uint256 exchangeRate;
        uint256 borrowerTokensNew;
        uint256 borrowerAmountNew;
        uint256 liquidatorTokensNew;
        uint256 liquidatorAmountNew;
        uint256 totalCash;
        uint256 supplyRate;
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another CToken.
     *  Its absolutely critical to use msg.sender as the seizer cToken and not a parameter.
     * @param seizerToken The contract seizing the collateral (i.e. borrowed cToken)
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of cTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seizeInternal(
        address seizerToken,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) internal returns (uint256) {
        uint256 allowed = comptroller.seizeAllowed(
            address(this),
            seizerToken,
            liquidator,
            borrower,
            seizeTokens
        );
        require(allowed == 0);
        require(borrower != liquidator);

        SeizeVars memory seizeVars;

        MathError mathErr;

        (mathErr, seizeVars.borrowerTokensNew) = subUInt(
            accountTokens[borrower].tokens,
            seizeTokens
        );
        require(mathErr == MathError.NO_ERROR);

        seizeVars.totalCash = getCashPrior();
        seizeVars.supplyRate = interestRateModel.getSupplyRate(
            seizeVars.totalCash,
            totalBorrows,
            totalReserves,
            reserveFactorMantissa
        );

        (, seizeVars.exchangeRate) = interestRateModel.getExchangeRate(
            seizeVars.totalCash,
            totalBorrows,
            totalReserves,
            totalSupply
        );

        if (interestRateModel.isTropykusInterestRateModel()) {
            (, seizeVars.exchangeRate) = tropykusExchangeRateStoredInternal(
                borrower
            );
        }

        (, seizeVars.seizeAmount) = mulUInt(
            seizeTokens,
            seizeVars.exchangeRate
        );
        (, seizeVars.seizeAmount) = divUInt(seizeVars.seizeAmount, 1e18);

        (, seizeVars.borrowerAmountNew) = subUInt(
            accountTokens[borrower].underlyingAmount,
            seizeVars.seizeAmount
        );

        (mathErr, seizeVars.liquidatorTokensNew) = addUInt(
            accountTokens[liquidator].tokens,
            seizeTokens
        );
        require(mathErr == MathError.NO_ERROR);

        (, seizeVars.liquidatorAmountNew) = addUInt(
            accountTokens[liquidator].underlyingAmount,
            seizeVars.seizeAmount
        );

        accountTokens[borrower].tokens = seizeVars.borrowerTokensNew;
        accountTokens[borrower].underlyingAmount = seizeVars.borrowerAmountNew;
        accountTokens[borrower].suppliedAt = getBlockNumber();
        accountTokens[borrower].promisedSupplyRate = seizeVars.supplyRate;

        accountTokens[liquidator].tokens = seizeVars.liquidatorTokensNew;
        accountTokens[liquidator].underlyingAmount = seizeVars
            .liquidatorAmountNew;
        accountTokens[liquidator].suppliedAt = getBlockNumber();
        accountTokens[liquidator].promisedSupplyRate = seizeVars.supplyRate;

        emit Transfer(borrower, liquidator, seizeTokens);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPendingAdmin(address payable newPendingAdmin)
        external
        override
        returns (uint256)
    {
        require(msg.sender == admin);

        address oldPendingAdmin = pendingAdmin;

        pendingAdmin = newPendingAdmin;

        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
     * @dev Admin function for pending admin to accept role and update admin
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _acceptAdmin() external override returns (uint256) {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.ACCEPT_ADMIN_PENDING_ADMIN_CHECK
                );
        }

        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        admin = pendingAdmin;

        pendingAdmin = payable(address(0));

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets a new comptroller for the market
     * @dev Admin function to set a new comptroller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setComptroller(ComptrollerInterface newComptroller)
        public
        override
        returns (uint256)
    {
        require(msg.sender == admin);

        ComptrollerInterface oldComptroller = comptroller;
        require(newComptroller.isComptroller(), "CT21");

        comptroller = newComptroller;

        emit NewComptroller(oldComptroller, newComptroller);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
     * @dev Admin function to accrue interest and set a new reserve factor
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setReserveFactor(uint256 newReserveFactorMantissa)
        external
        override
        nonReentrant
        returns (uint256)
    {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));
        return _setReserveFactorFresh(newReserveFactorMantissa);
    }

    /**
     * @notice Sets a new reserve factor for the protocol (*requires fresh interest accrual)
     * @dev Admin function to set a new reserve factor
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setReserveFactorFresh(uint256 newReserveFactorMantissa)
        internal
        returns (uint256)
    {
        require(msg.sender == admin);
        require(accrualBlockNumber == getBlockNumber());
        require(newReserveFactorMantissa <= reserveFactorMaxMantissa);

        uint256 oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(
            oldReserveFactorMantissa,
            newReserveFactorMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring from msg.sender
     * @param addAmount Amount of addition to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReservesInternal(uint256 addAmount)
        internal
        nonReentrant
        returns (uint256)
    {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));

        uint256 totalReservesNew;
        uint256 actualAddAmount;

        require(accrualBlockNumber == getBlockNumber());

        actualAddAmount = doTransferIn(msg.sender, addAmount);

        totalReservesNew = totalReserves + actualAddAmount;

        require(totalReservesNew >= totalReserves, "CT22");

        totalReserves = totalReservesNew;

        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

        return (uint256(Error.NO_ERROR));
    }

    function _addSubsidyInternal(uint256 addAmount)
        internal
        nonReentrant
        returns (uint256)
    {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));

        uint256 subsidyFundNew;
        uint256 actualAddAmount;

        require(accrualBlockNumber == getBlockNumber());

        actualAddAmount = doTransferIn(msg.sender, addAmount);

        subsidyFundNew = subsidyFund + actualAddAmount;

        require(subsidyFundNew >= subsidyFund, "CT22");

        subsidyFund = subsidyFundNew;

        emit SubsidyAdded(msg.sender, actualAddAmount, subsidyFundNew);

        return (uint256(Error.NO_ERROR));
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReserves(uint256 reduceAmount)
        external
        override
        nonReentrant
        returns (uint256)
    {
        uint256 error = accrueInterest();
        require(error == uint256(Error.NO_ERROR));
        return _reduceReservesFresh(reduceAmount);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReservesFresh(uint256 reduceAmount)
        internal
        returns (uint256)
    {
        uint256 totalReservesNew;

        require(msg.sender == admin);
        require(accrualBlockNumber == getBlockNumber());
        require(getCashPrior() >= reduceAmount);
        require(reduceAmount <= totalReserves);

        totalReservesNew = totalReserves - reduceAmount;
        require(totalReservesNew <= totalReserves, "CT23");

        totalReserves = totalReservesNew;

        doTransferOut(admin, reduceAmount);

        emit ReservesReduced(admin, reduceAmount, totalReservesNew);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModel(InterestRateModel newInterestRateModel)
        public
        override
        returns (uint256)
    {
        uint256 error = accrueInterest();
        require (error == uint256(Error.NO_ERROR));
        return _setInterestRateModelFresh(newInterestRateModel);
    }

    /**
     * @notice updates the interest rate model (*requires fresh interest accrual)
     * @dev Admin function to update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel)
        internal
        returns (uint256)
    {
        InterestRateModel oldInterestRateModel;

        require (msg.sender == admin);
        require (accrualBlockNumber == getBlockNumber());

        oldInterestRateModel = interestRateModel;

        require(newInterestRateModel.isInterestRateModel(), "CT21");

        interestRateModel = newInterestRateModel;

        emit NewMarketInterestRateModel(
            oldInterestRateModel,
            newInterestRateModel
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying owned by this contract
     */
    function getCashPrior() internal view virtual returns (uint256);

    /**
     * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
     *  This may revert due to insufficient balance or insufficient allowance.
     */
    function doTransferIn(address from, uint256 amount)
        internal
        virtual
        returns (uint256);

    /**
     * @dev Performs a transfer out, ideally returning an explanatory error code upon failure tather than reverting.
     *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
     *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
     */
    function doTransferOut(address payable to, uint256 amount) internal virtual;

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true;
    }
}
