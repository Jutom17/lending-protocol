// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {PriceOracle} from "./interface/PriceOracle.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "solmate/src/utils/SafeTransferLib.sol";
import "./BorrowLendState.sol";

contract LendingPool is BorrowLendState {
    using SafeERC20 for ERC20;
    using SafeTransferLib for ERC20;

    uint8 public constant override INTEREST_RATE_DECIMALS = 3;

    uint256 public constant override SCALAR = 10 ** INTEREST_RATE_DECIMALS;

    /// @notice Pool name.
    string public name;
    ERC20 public tokenContract;

    address public override borrowTicketContract;

    mapping(uint256 => Loan) public loanInfo;

    uint256 private _nonce = 1;
    address public admin;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    modifier notClosed(uint256 loanId) {
        require(!loanInfo[loanId].closed, "loan closed");
        _;
    }

    constructor(address _tokenContract, uint256 _collateralizationRatio) {
        tokenContract = ERC20(_tokenContract);
        state.collateralizationRatio = _collateralizationRatio;
        state.collateralizationRatioPrecision = 1e18;

        admin = msg.sender;
    }

    /*///////////////////////////////////////////////////////////////
                          ORACLE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the price oracle contract.
    PriceOracle public oracle;

    /// @notice Emitted when the price oracle is changed.
    /// @param user The authorized user who triggered the change.
    /// @param newOracle The new price oracle address.
    event OracleUpdated(address indexed user, PriceOracle indexed newOracle);

    /// @notice Sets a new oracle contract.
    /// @param newOracle The address of the new oracle.
    function setOracle(PriceOracle newOracle) external onlyOwner {
        // Update the oracle.
        oracle = newOracle;

        // Emit the event.
        emit OracleUpdated(msg.sender, newOracle);
    }

    /*///////////////////////////////////////////////////////////////
                          CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    mapping(ERC20 => uint256) public interestRates;

    event InterestRateUpdated(address user, ERC20 asset, uint256 newInterestRate);

    function setInterestRate(ERC20 asset, uint256 newInterestRate) external onlyAdmin {
        interestRates[asset] = newInterestRate;

        emit InterestRateUpdated(msg.sender, asset, newInterestRate);
    }

    event CollateralizationRatioUpdated(address user, uint256 newInterestRate);

    function setCollateralRatio(uint256 newInterestRate) external onlyAdmin {
        state.collateralizationRatio = newInterestRate;

        emit CollateralizationRatioUpdated(msg.sender, newInterestRate);
    }

    /*///////////////////////////////////////////////////////////////
                          ASSET CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    mapping(ERC20 => bool) public configurations;

    mapping(ERC20 => uint256) public baseUnits;

    event AssetConfigured(
        address indexed user,
        ERC20 indexed asset,
        bool enabled
    );

    function configureAsset(
        ERC20 asset
    ) external onlyAdmin {
        configurations[asset] = enabled;
        baseUnits[asset] = 10**asset.decimals();

        emit AssetConfigured(msg.sender, asset, enabled);
    }

    /*///////////////////////////////////////////////////////////////
                       DEPOSIT/WITHDRAW INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a sucessful deposit.
    /// @param from The address that triggered the deposit.
    /// @param asset The underlying asset.
    /// @param amount The amount being deposited.
    event Deposit(address indexed from, ERC20 indexed asset, uint256 amount);

    /// @notice Emitted after a successful withdrawal.
    /// @param from The address that triggered the withdrawal.
    /// @param asset The underlying asset.
    /// @param amount The amount being withdrew.
    event Withdraw(address indexed from, ERC20 indexed asset, uint256 amount);

    function deposit(
        uint256 amount
    ) external nonReentrant {
        require(amount > 0, "INVALID_AMOUNT");

        unchecked {
            state.accountAssets[msg.sender].deposited += amount;
        }

        state.totalAssets.deposited += amount;

        tokenContract.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, tokenContract, amount);
    }

    function withdraw(
        uint256 amount
    ) external nonReentrant {
        // Ensure the amount is valid.
        require(amount > 0, "AMOUNT_TOO_LOW");

        require(
            amount < maxAllowedToWithdraw(_msgSender()),
            "amount >= maxAllowedToWithdraw(msg.sender)"
        );

        state.accountAssets[msg.sender].deposited -= amount;

        unchecked {
            state.totalAssets.deposited -= amount;
        }

        tokenContract.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, tokenContract, amount);
    }

    /*///////////////////////////////////////////////////////////////
                      BORROW/REPAYMENT INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful borrow.
    /// @param from The address that triggered the borrow.
    /// @param asset The underlying asset.
    /// @param amount The amount being borrowed.
    event Borrow(address indexed from, ERC20 indexed asset, uint256 amount);

    /// @notice Emitted after a successful repayment.
    /// @param from The address that triggered the repayment.
    /// @param asset The underlying asset.
    /// @param amount The amount being repaid.
    event Repay(address indexed from, ERC20 indexed asset, uint256 amount);

    function borrow(ERC20 asset, uint256 amount) external {
        require(amount > 0, "AMOUNT_TOO_LOW");

        enableLoan(asset);

        require(canBorrow(asset, msg.sender, amount));

        unchecked {
            internalDebt[asset][msg.sender] += amount;
            id = _nonce++;
        }

        uint64 collateralPrice = oracle.getUnderlyingPrice(tokenContract);

        uint64 borrowAssetPrice = oracle.getUnderlyingPrice(currentAsset);

        Loan storage loan = loanInfo[id];
        loan.loanAssetContractAddress = address(asset);
        loan.loanAmount = amount;
        loan.startTime = uint40(block.timestamp);
        loan.collateralAmount =
            (amount *
                state.collateralizationRatioPrecision *
                borrowAssetPrice *
                10 ** collateralTokenDecimals()) /
            (state.collateralizationRatio *
                collateralPrice *
                10 ** borrowTokenDecimals());

        totalInternalDebt[asset] += amount;

        cachedTotalBorrows[asset] += amount;

        asset.transfer(msg.sender, amount);

        emit Borrow(msg.sender, asset, amount);
    }

    function repayAndCloseLoan(uint256 loanId) public notClosed(loanId) {
        Loan storage loan = loanInfo[loanId];

        uint256 interest = _interestOwed(
            loan.loanAmount,
            loan.lastAccumulatedTimestamp,
            loan.perAnumInterestRate
        );
        loan.closed = true;
        uint256 normalizedAmount = normalizeAmount(amount, interestRates[asset]);

        // confirm that the caller has loans to pay back
        require(
            normalizedAmount <= internalDebt[asset][msg.sender],
            "loan payment too large"
        );

        internalDebt[asset][msg.sender] -= amount;

        unchecked {
            totalInternalDebt[asset] -= amount;
        }

        asset.safeTransferFrom(msg.sender, address(this), interest + loan.loanAmount);

        disableLoan(asset);

        // Emit the event.
        emit Repay(msg.sender, asset, interest + loan.loanAmount);
    }

    /*///////////////////////////////////////////////////////////////
                          LIQUIDATION INTERFACE
    //////////////////////////////////////////////////////////////*/

    function userLiquidatable(address user) public view returns (bool) {
        return !(calculateHealthFactor(address(0), user, 0) >= state.collateralizationRatio);
    }

    function liquidateUser(uint256 loanId, address sendCollateralTo) external override notClosed(loanId) onlyAdmin {
        require(userLiquidatable(borrower), "CANNOT_LIQUIDATE_HEALTHY_USER");

        Loan storage loan = loanInfo[loanId];

        loan.closed = true;
        tokenContract.safeTransferFrom(
            address(this),
            sendCollateralTo,
            loan.collateralAmount
        );

        emit SeizeCollateral(loanId);
        emit Close(loanId);
    }
    /*///////////////////////////////////////////////////////////////
                      COLLATERALIZATION INTERFACE
    //////////////////////////////////////////////////////////////*/

    event AssetEnabled(address indexed from, ERC20 indexed asset, bool collateral);

    event AssetDisabled(address indexed from, ERC20 indexed asset, bool collateral);

    mapping(address => ERC20[]) public userCollateral;

    mapping(address => ERC20[]) public userLoan;

    mapping(address => mapping(ERC20 => bool)) public enabledCollateral;

    mapping(address => mapping(ERC20 => bool)) public enabledLoan;

    function enableAsset(ERC20 asset) public {
        if (enabledCollateral[msg.sender][asset]) {
            return;
        }

        userCollateral[msg.sender].push(asset);
        enabledCollateral[msg.sender][asset] = true;

        emit AssetEnabled(msg.sender, asset, true);
    }

    function enableLoan(ERC20 asset) public {
        // Ensure the user has not enabled this asset as collateral.
        if (enabledLoan[msg.sender][asset]) {
            return;
        }

        // Enable the asset as collateral.
        userLoan[msg.sender].push(asset);
        enabledLoan[msg.sender][asset] = true;

        // Emit the event.
        emit AssetEnabled(msg.sender, asset, false);
    }

    /// @notice Disable an asset as collateral.
    function disableAsset(ERC20 asset) public {
        // Ensure that the user is not borrowing this asset.
        if (internalDebt[asset][msg.sender] > 0) return;

        // Ensure the user has already enabled this asset as collateral.
        if (!enabledCollateral[msg.sender][asset]) return;

        // Remove the asset from the user's list of collateral.
        for (uint256 i = 0; i < userCollateral[msg.sender].length; i++) {
            if (userCollateral[msg.sender][i] == asset) {
                // Copy the value of the last element in the array.
                ERC20 last = userCollateral[msg.sender][userCollateral[msg.sender].length - 1];

                // Remove the last element from the array.
                delete userCollateral[msg.sender][userCollateral[msg.sender].length - 1];

                // Replace the disabled asset with the new asset.
                userCollateral[msg.sender][i] = last;
            }
        }

        // Disable the asset as collateral.
        enabledCollateral[msg.sender][asset] = false;

        // Emit the event.
        emit AssetDisabled(msg.sender, asset, true);
    }

    function disableLoan(ERC20 asset) public {
        if (internalDebt[asset][msg.sender] > 0) return;

        if (!enabledLoan[msg.sender][asset]) return;

        for (uint256 i = 0; i < userLoan[msg.sender].length; i++) {
            if (userLoan[msg.sender][i] == asset) {
                ERC20 last = userLoan[msg.sender][userLoan[msg.sender].length - 1];

                delete userLoan[msg.sender][userLoan[msg.sender].length - 1];

                userLoan[msg.sender][i] = last;
            }
        }

        enabledLoan[msg.sender][asset] = false;

        emit AssetDisabled(msg.sender, asset, false);
    }

    /*///////////////////////////////////////////////////////////////
                        LIQUIDITY ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total amount of underlying tokens held by and owed to the pool.
    /// @param asset The underlying asset.
    function totalUnderlying(ERC20 asset) public view returns (uint256) {
        // Return the total amount of underlying tokens in the pool.
        // This includes the LendingPool's currently held assets and all of the assets being borrowed.
        return availableLiquidity(asset) + totalBorrows(asset);
    }

    /// @notice Returns the amount of underlying tokens held in this contract.
    /// @param asset The underlying asset.
    function availableLiquidity(ERC20 asset) public view returns (uint256) {
        address vault = vaults[asset];
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    /*///////////////////////////////////////////////////////////////
                        BALANCE ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Maps assets to user addresses to their balances, which are not denominated in underlying.
    /// Instead, these values are denominated in internal balance units, which internally account
    /// for user balances, increasing in value as the LendingPool earns more interest.
    mapping(ERC20 => mapping(address => uint256)) internal accountAssets;

    /// @dev Maps assets to the total number of internal balance units "distributed" amongst lenders.
    mapping(ERC20 => uint256) internal totalAssets;

    function balanceOf(ERC20 asset, address user) public view returns (uint256) {
        return accountAssets[asset][user];
    }

    /// @dev Returns the exchange rate between underlying tokens and internal balance units.
    /// In other words, this function returns the value of one internal balance unit, denominated in underlying.
    function internalBalanceExchangeRate(ERC20 asset) internal view returns (uint256) {
        // Retrieve the total internal balance supply.
        uint256 totalInternalBalance = totalAssets[asset];

        // If it is 0, return an exchange rate of 1.
        if (totalInternalBalance == 0) return baseUnits[asset];

        // Otherwise, divide the total supplied underlying by the total internal balance units.
        return totalUnderlying(asset).mulDivDown(baseUnits[asset], totalInternalBalance);
    }

    /*///////////////////////////////////////////////////////////////
                          DEBT ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Maps assets to user addresses to their debt, which are not denominated in underlying.
    /// Instead, these values are denominated in internal debt units, which internally account
    /// for user debt, increasing in value as the LendingPool earns more interest.
    mapping(ERC20 => mapping(address => uint256)) internal internalDebt;

    /// @dev Maps assets to the total number of internal debt units "distributed" amongst borrowers.
    mapping(ERC20 => uint256) internal totalInternalDebt;

    function borrowBalance(ERC20 asset, address user) public view returns (uint256) {
        return internalDebt[asset][user] * internalDebtExchangeRate(asset) / baseUnits[asset];
    }

    /// @dev Returns the exchange rate between underlying tokens and internal debt units.
    /// In other words, this function returns the value of one internal debt unit, denominated in underlying.
    function internalDebtExchangeRate(ERC20 asset) internal view returns (uint256) {
        // Retrieve the total debt balance supply.
        uint256 totalInternalDebtUnits = totalInternalDebt[asset];

        // If it is 0, return an exchange rate of 1.
        if (totalInternalDebtUnits == 0) return baseUnits[asset];

        // Otherwise, divide the total borrowed underlying by the total amount of internal debt units.
        return totalBorrows(asset).mulDivDown(baseUnits[asset], totalInternalDebtUnits);
    }

    /*///////////////////////////////////////////////////////////////
                        INTEREST ACCRUAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Maps assets to the total number of underlying loaned out to borrowers.
    /// Note that these values are not updated, instead recording the total borrow amount
    /// each time a borrow/repayment occurs.
    mapping(ERC20 => uint256) internal cachedTotalBorrows;

    /// @dev Store the block number of the last interest accrual for each asset.
    mapping(ERC20 => uint256) internal lastActivityBlockTimestamp;

    function totalBorrows(ERC20 asset) public view returns (uint256) {
        uint256 interestRate = interestRates[asset];

        require(interestRate != 0, "INTEREST_RATE_NOT_SET");

        uint256 secondsElapsed = block.timestamp - lastActivityBlockTimestamp[asset][msg.sender];

        // If the delta is equal to the block number (a borrow/repayment has never occured)
        // return a value of 0.
        if (secondsElapsed == block.number) return internalDebt[asset][msg.sender];

        uint256 interestAccumulator = interestRate * secondsElapsed / (365 * 24 * 60 * 60);

        return internalDebt[asset][msg.sender] * interestAccumulator / 1e18;
    }

    /// @dev Update the cached total borrow amount for a given asset.
    /// @param asset The underlying asset.
    function accrueInterest(ERC20 asset) internal {
        // Set the cachedTotalBorrows to the total borrow amount.
        cachedTotalBorrows[asset] = totalBorrows(asset);

        // Update the block number of the last interest accrual.
        lastActivityBlockTimestamp[asset] = block.number;
    }

    /*///////////////////////////////////////////////////////////////
                      BORROW ALLOWANCE CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Store account liquidity details whilst avoiding stack depth errors.
    struct AccountLiquidity {
        // A user's total borrow balance in ETH.
        uint256 borrowBalance;
        // A user's maximum borrowable value. If their borrowed value
        // reaches this point, they will get liquidated.
        uint256 maximumBorrowable;
        // A user's borrow balance in ETH multiplied by the average borrow factor.
        // TODO: need a better name for this
        uint256 borrowBalancesTimesBorrowFactors;
        // A user's actual borrowable value. If their borrowed value
        // is greater than or equal to this number, the system will
        // not allow them to borrow any more assets.
        uint256 actualBorrowable;
    }

    function calculateHealthFactor(
        ERC20 asset,
        address user,
        uint256 amount
    ) public view returns (uint256) {
        AccountLiquidity memory liquidity;

        liquidity.maximumBorrowable += balanceOf(_tstContract, user)
            * oracle.getUnderlyingPrice(_tstContract) / baseUnits[_tstContract];

        ERC20[] memory utilized = userLoan[user];

        uint256 hypotheticalBorrowBalance;

        ERC20 currentAsset;

        for (uint256 i = 0; i < utilized.length; i++) {

            currentAsset = utilized[i];

            hypotheticalBorrowBalance = currentAsset == asset ? amount : 0;

            if (internalDebt[currentAsset][msg.sender] > 0) {
                hypotheticalBorrowBalance += borrowBalance(currentAsset, user);
            }

            // Add the user's borrow balance in this asset to their total borrow balance.
            liquidity.borrowBalance += hypotheticalBorrowBalance
                * oracle.getUnderlyingPrice(_tstContract) / baseUnits[_tstContract];
        }

        return liquidity.maximumBorrowable * 1e18 / liquidity.borrowBalance;
    }

    function canBorrow(
        ERC20 asset,
        address user,
        uint256 amount
    ) internal view returns (bool) {
        // Ensure the user's health factor will be greater than 1.
        return calculateHealthFactor(asset, user, amount) >= 1e18;
    }

    /// @dev Given user's collaterals, calculate the maximum user can borrow.
    function maxBorrowable() external returns (uint256 maximumBorrowable) {
        // Retrieve the user's utilized assets.
        ERC20[] memory utilized = userCollateral[msg.sender];

        ERC20 currentAsset;

        // Iterate through the user's utilized assets.
        for (uint256 i = 0; i < utilized.length; i++) {

            // Current user utilized asset.
            currentAsset = utilized[i];

            // Calculate the user's maximum borrowable value for this asset.
            // balanceOfUnderlying(asset,user) * ethPrice * lendFactor.
            maximumBorrowable += balanceOf(currentAsset, msg.sender)
                .mulDivDown(oracle.getUnderlyingPrice(currentAsset), baseUnits[currentAsset])
                .mulDivDown(configurations[currentAsset].lendFactor, 1e18);
        }
    }

    /// @dev Get all user collateral assets.
    /// @param user The user.
    function getCollateral(address user) external returns (ERC20[] memory) {
        return userCollateral[user];
    }

    function denormalizeAmount(
        uint256 normalizedAmount,
        uint256 interest
    ) public view returns (uint256) {
        return
            (normalizedAmount * interest) / 1e18;
    }

    function normalizeAmount(
        uint256 denormalizedAmount,
        uint256 interest
    ) public view returns (uint256) {
        return
            (denormalizedAmount * 1e18) / interest;
    }

    function maxAllowedToWithdraw(address account)
    public
    view
    returns (uint256)
    {
        ERC20[] memory utilized = userLoan[account];

        ERC20 currentAsset;

        uint64 collateralPrice = oracle.getUnderlyingPrice(tokenContract);

        uint256 deposited = state.accountAssets[account].deposited;
        uint256 denormalizedBorrowed;
        uint256 maxAllowedToWithdrawWithPrices = deposited;

        // Iterate through the user's utilized assets.
        for (uint256 i = 0; i < utilized.length; i++) {

            // Current user utilized asset.
            currentAsset = utilized[i];

            if (internalDebt[currentAsset][msg.sender] > 0) {
                uint64 borrowAssetPrice = oracle.getUnderlyingPrice(currentAsset);

                denormalizedBorrowed += denormalizeAmount(
                    internalDebt[currentAsset][msg.sender],
                    interestRates[currentAsset]
                );
                maxAllowedToWithdrawWithPrices = maxAllowedToWithdrawWithPrices -
                    (denormalizedBorrowed *
                        state.collateralizationRatioPrecision *
                        borrowAssetPrice *
                        10 ** collateralTokenDecimals()) /
                    (state.collateralizationRatio *
                        collateralPrice *
                        10 ** borrowTokenDecimals());
            }
        }
        return maxAllowedToWithdrawWithPrices;
    }

    function seizeCollateral(
        ERC20 borrowedAsset,
        ERC20 collateralAsset,
        uint256 borrowedAmount
    ) public view returns (uint256) {
        uint64 collateralPrice = oracle.getUnderlyingPrice(tokenContract);

        uint256 deposited = state.accountAssets[account].deposited;

        uint64 borrowAssetPrice = oracle.getUnderlyingPrice(currentAsset);

        maxAllowedToWithdrawWithPrices = deposited -
            (borrowedAmount *
                state.collateralizationRatioPrecision *
                borrowAssetPrice *
                10 ** collateralTokenDecimals()) /
            (state.collateralizationRatio *
                collateralPrice *
                10 ** borrowTokenDecimals());
        return 0;
    }

    function _interestOwed(
        uint256 loanAmount,
        uint256 startTime,
        uint256 interestRate
    )
    internal
    view
    returns (uint256)
    {
        return loanAmount
            * (block.timestamp - startTime)
            * (interestRate * 1e18 / 365 days)
            / 1e21;
    }
}
