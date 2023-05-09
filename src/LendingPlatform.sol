// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {PriceOracle} from "./interface/PriceOracle.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "./BorrowLendState.sol";
import "./interface/ILendingPlatform.sol";

contract LendingPlatform is Context, BorrowLendState, ReentrancyGuard, ILendingPlatform {
    using SafeERC20 for ERC20;
    using SafeTransferLib for ERC20;

    ERC20 public tokenContract;

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

    PriceOracle public oracle;

    event OracleUpdated(address indexed user, PriceOracle indexed newOracle);

    function setOracle(PriceOracle newOracle) external onlyAdmin {
        oracle = newOracle;

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
        ERC20 asset,
        bool enabled
    ) external onlyAdmin {
        configurations[asset] = enabled;
        baseUnits[asset] = 10 ** asset.decimals();

        emit AssetConfigured(msg.sender, asset, enabled);
    }

    /*///////////////////////////////////////////////////////////////
                       DEPOSIT/WITHDRAW INTERFACE
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed from, ERC20 indexed asset, uint256 amount);

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

    event Borrow(address indexed from, ERC20 indexed asset, uint256 amount);

    event Repay(address indexed from, ERC20 indexed asset, uint256 amount);

    function borrow(ERC20 asset, uint256 amount) external returns (uint256 id) {
        require(amount > 0, "AMOUNT_TOO_LOW");

        enableLoan(asset);

        require(
            amount < maxAllowedToBorrow(_msgSender(), asset),
            "amount >= maxAllowedToBorrow(msg.sender)"
        );

        unchecked {
            internalDebt[asset][msg.sender] += amount;
            id = _nonce++;
        }

        uint64 collateralPrice = oracle.getUnderlyingPrice(tokenContract);

        uint64 borrowAssetPrice = oracle.getUnderlyingPrice(asset);

        Loan storage loan = loanInfo[id];
        loan.loanAssetContractAddress = address(asset);
        loan.loanAmount = uint128(amount);
        loan.startTime = uint40(block.timestamp);
        loan.collateralAmount =
            (amount *
                state.collateralizationRatioPrecision *
                borrowAssetPrice *
                baseUnits[tokenContract]) /
            (state.collateralizationRatio *
                collateralPrice *
                baseUnits[asset]);
        loan.borrowerAddress = msg.sender;

        totalInternalDebt[asset] += amount;

        asset.transfer(msg.sender, amount);

        emit Borrow(msg.sender, asset, amount);
    }

    function repayAndCloseLoan(uint256 loanId) public notClosed(loanId) {
        Loan storage loan = loanInfo[loanId];

        ERC20 asset = ERC20(loan.loanAssetContractAddress);
        uint256 interest = _interestOwed(
            loan.loanAmount,
            loan.startTime,
            interestRates[ERC20(asset)]
        );
        loan.closed = true;

        internalDebt[asset][msg.sender] -= loan.loanAmount;

        unchecked {
            totalInternalDebt[asset] -= loan.loanAmount;
        }

        asset.safeTransferFrom(msg.sender, address(this), interest + loan.loanAmount);

        disableLoan(asset);

        emit Repay(msg.sender, asset, interest + loan.loanAmount);
    }

    /*///////////////////////////////////////////////////////////////
                          LIQUIDATION INTERFACE
    //////////////////////////////////////////////////////////////*/

    function userLiquidatable(address user) public view returns (bool) {
        return !(calculateHealthFactor(ERC20(address(0)), user, 0) >= 1e18);
    }

    function seizeCollateral(uint256 loanId, address sendCollateralTo) external override notClosed(loanId) onlyAdmin {
        Loan storage loan = loanInfo[loanId];

        require(userLiquidatable(loan.borrowerAddress), "CANNOT_LIQUIDATE_HEALTHY_USER");

        loan.closed = true;
        tokenContract.safeTransfer(
            sendCollateralTo,
            loan.collateralAmount
        );

        emit SeizeCollateral(loanId, sendCollateralTo);
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
        if (enabledLoan[msg.sender][asset]) {
            return;
        }

        userLoan[msg.sender].push(asset);
        enabledLoan[msg.sender][asset] = true;

        emit AssetEnabled(msg.sender, asset, false);
    }

    function disableAsset(ERC20 asset) public {
        if (internalDebt[asset][msg.sender] > 0) return;

        if (!enabledCollateral[msg.sender][asset]) return;

        for (uint256 i = 0; i < userCollateral[msg.sender].length; i++) {
            if (userCollateral[msg.sender][i] == asset) {
                ERC20 last = userCollateral[msg.sender][userCollateral[msg.sender].length - 1];

                delete userCollateral[msg.sender][userCollateral[msg.sender].length - 1];

                userCollateral[msg.sender][i] = last;
            }
        }

        enabledCollateral[msg.sender][asset] = false;

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
                        BALANCE ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    mapping(ERC20 => uint256) internal totalAssets;

    function balanceOf(ERC20 asset, address user) public view returns (uint256) {
        return state.accountAssets[user].deposited;
    }

    mapping(ERC20 => mapping(address => uint256)) internal internalDebt;

    mapping(ERC20 => uint256) internal totalInternalDebt;

    function borrowBalance(ERC20 asset, address user) public view returns (uint256) {
        return internalDebt[asset][user];
    }

    /*///////////////////////////////////////////////////////////////
                      BORROW ALLOWANCE CHECKS
    //////////////////////////////////////////////////////////////*/

    struct AccountLiquidity {
        uint256 borrowBalance;
        uint256 maximumBorrowable;
    }

    function calculateHealthFactor(
        ERC20 asset,
        address user,
        uint256 amount
    ) public view returns (uint256) {
        AccountLiquidity memory liquidity;

        liquidity.maximumBorrowable = balanceOf(tokenContract, user)
            * oracle.getUnderlyingPrice(tokenContract) / baseUnits[tokenContract]
            * state.collateralizationRatio / state.collateralizationRatioPrecision;

        ERC20[] memory utilized = userLoan[user];

        uint256 hypotheticalBorrowBalance;

        ERC20 currentAsset;

        for (uint256 i = 0; i < utilized.length; i++) {

            currentAsset = utilized[i];

            hypotheticalBorrowBalance = currentAsset == asset ? amount : 0;

            if (internalDebt[currentAsset][msg.sender] > 0) {
                hypotheticalBorrowBalance += borrowBalance(currentAsset, user);
            }

            liquidity.borrowBalance += hypotheticalBorrowBalance
                * oracle.getUnderlyingPrice(currentAsset) / baseUnits[currentAsset];
        }

        return liquidity.maximumBorrowable * 1e18 / liquidity.borrowBalance;
    }

    function canBorrow(
        ERC20 asset,
        address user,
        uint256 amount
    ) internal view returns (bool) {
        return calculateHealthFactor(asset, user, amount) >= 1e18;
    }

    function collateralTokenDecimals() internal view returns (uint8) {
        return IERC20Metadata(state.collateralAssetAddress).decimals();
    }

    function denormalizeAmount(
        uint256 normalizedAmount,
        uint256 interest
    ) public pure returns (uint256) {
        return
            (normalizedAmount * interest) / 1e18;
    }

    function normalizeAmount(
        uint256 denormalizedAmount,
        uint256 interest
    ) public pure returns (uint256) {
        return
            (denormalizedAmount * 1e18) / interest;
    }

    function maxAllowedToBorrow(address account, ERC20 borrowAsset) public view returns (uint256) {
        ERC20[] memory utilized = userLoan[account];

        ERC20 currentAsset;

        uint64 collateralPrice = oracle.getUnderlyingPrice(tokenContract);
        uint64 borrowAssetPrice = oracle.getUnderlyingPrice(borrowAsset);

        uint256 deposited = state.accountAssets[account].deposited;
        uint256 denormalizedBorrowed;

        for (uint256 i = 0; i < utilized.length; i++) {

            currentAsset = utilized[i];

            if (internalDebt[currentAsset][msg.sender] > 0) {
                uint64 _borrowAssetPrice = oracle.getUnderlyingPrice(currentAsset);

                denormalizedBorrowed += internalDebt[currentAsset][msg.sender] * _borrowAssetPrice;
            }
        }

        return
            (deposited *
                state.collateralizationRatio *
                collateralPrice *
                baseUnits[borrowAsset]) /
            (state.collateralizationRatioPrecision *
                borrowAssetPrice *
                baseUnits[tokenContract]) -
            denormalizedBorrowed;
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

        for (uint256 i = 0; i < utilized.length; i++) {

            currentAsset = utilized[i];

            if (internalDebt[currentAsset][msg.sender] > 0) {
                uint64 borrowAssetPrice = oracle.getUnderlyingPrice(currentAsset);

                denormalizedBorrowed += internalDebt[currentAsset][msg.sender];

                maxAllowedToWithdrawWithPrices = maxAllowedToWithdrawWithPrices -
                    (denormalizedBorrowed *
                        state.collateralizationRatioPrecision *
                        borrowAssetPrice *
                        baseUnits[tokenContract]) /
                    (state.collateralizationRatio *
                        collateralPrice *
                        baseUnits[currentAsset]);
            }
        }
        return maxAllowedToWithdrawWithPrices;
    }

    function loanInfoStruct(uint256 loanId) external view override returns (Loan memory) {
        return loanInfo[loanId];
    }

    function interestOwed(uint256 loanId) external view override returns (uint256) {
        Loan storage loan = loanInfo[loanId];
        if (loan.closed || loan.startTime == 0) return 0;

        return _interestOwed(
            loan.loanAmount,
            loan.startTime,
            interestRates[ERC20(loan.loanAssetContractAddress)]
        );
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
