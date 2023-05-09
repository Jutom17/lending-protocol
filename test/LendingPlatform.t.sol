// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/BorrowLendStructs.sol";
import "forge-std/Test.sol";

import "forge-std/console.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import "./utils/ExposedLendingPlatform.sol";
import "./mocks/MockPriceOracle.sol";
import "solmate/test/utils/DSTestPlus.sol";
import "../src/TestToken.sol";

contract LendingPlatformTest is DSTestPlus {
    ERC20 collateralToken;
    MockERC20 borrowedAssetToken;
    ExposedLendingPlatform pool;
    uint16 interestRate = 10;

    uint256 collateralizationRatio;
    MockPriceOracle oracle;
    uint32 loanDuration = 10000;
    uint256 startTimestamp = 5;

    function setUp() public {
        collateralToken = new TestToken();
        borrowedAssetToken = new MockERC20("USDC", "USDC", 6);

        collateralizationRatio = 0.5e18;

        pool = new ExposedLendingPlatform(address(collateralToken), collateralizationRatio);

        pool.configureAsset(ERC20(address(collateralToken)), false);
        pool.configureAsset(ERC20(address(borrowedAssetToken)), true);

        pool.setInterestRate(ERC20(address(borrowedAssetToken)), interestRate);

        oracle = new MockPriceOracle();
        oracle.updatePrice(ERC20(collateralToken), 1e18);
        pool.setOracle(PriceOracle(address(oracle)));

        hevm.warp(startTimestamp);
    }

    function testIRConfiguration() public {
        assertEq(pool.interestRates(ERC20(address(borrowedAssetToken))), uint(interestRate));
    }

    function testNewIRConfiguration(uint16 rate) public {
        pool.setInterestRate(ERC20(address(borrowedAssetToken)), rate);

        assertEq(pool.interestRates(ERC20(address(borrowedAssetToken))), uint(rate));
    }

    function testFailNewIRConfigurationNotOwner(uint16 rate) public {

        hevm.prank(address(0xBABE));
        pool.setInterestRate(ERC20(address(borrowedAssetToken)), rate);
    }

    function testBorrow() public {
        ERC20 borrowAsset = ERC20(address(borrowedAssetToken));

        (, uint256 loanId) = setUpLoanForTest();
        uint256 borrowed = pool.loanInfoStruct(loanId).loanAmount;

        assertEq(borrowAsset.balanceOf(address(this)), borrowed);
        assertEq(pool.borrowBalance(borrowAsset, address(this)), borrowed);
    }

    function testInterestAccruesCorrectly() public {
        (, uint256 loanId) = setUpLoanForTest();
        uint256 interestAccrued = pool.interestOwed(loanId);
        assertEq(interestAccrued, 0);

        // 1 year with 1% annual on 10^8 = 10^6
        // tiny loss of precision, 10^6 - 999999 = 1
        hevm.warp(startTimestamp + 365 days);
        assertEq(pool.interestOwed(loanId), 999999);
    }

    function testMaxAllowedToWithdraw() public {
        uint64 collateralPrice = 400;
        uint64 borrowAssetPrice = 1;

        oracle.updatePrice(ERC20(collateralToken), collateralPrice);
        oracle.updatePrice(ERC20(address(borrowedAssetToken)), borrowAssetPrice);

        uint256 deposited = 1e18;
        uint256 borrowed = 100e6;
        pool.HACKED_setAccountAssets(
            address(this),
            ERC20(address(borrowedAssetToken)),
            deposited,
            borrowed
        );

        uint256 maxAllowed = pool.maxAllowedToWithdraw(address(this));

        {
            require(maxAllowed == 0.5e18, "maxAllowed != expected");
        }

        pool.HACKED_resetAccountAssets(address(this), ERC20(address(borrowedAssetToken)));
    }

    function testMaxAllowedToBorrow() public {
        uint64 collateralPrice = 400;
        uint64 borrowAssetPrice = 1;

        oracle.updatePrice(ERC20(collateralToken), collateralPrice);
        oracle.updatePrice(ERC20(address(borrowedAssetToken)), borrowAssetPrice);

        uint256 deposited = 1e18;
        uint256 borrowed = 100e6;
        pool.HACKED_setAccountAssets(
            address(this),
            ERC20(address(borrowedAssetToken)),
            deposited,
            borrowed
        );

        uint256 maxAllowed = pool.maxAllowedToBorrow(address(this), ERC20(address(borrowedAssetToken)));

        {
            require(maxAllowed == 100e6, "maxAllowed != expected");
        }

        pool.HACKED_resetAccountAssets(address(this), ERC20(address(borrowedAssetToken)));
    }

    function testUserLiquidatable() public returns (uint256 loanId) {
        uint256 deposited = 1e18;
        uint256 borrowed = 100e6;
        ERC20 asset = collateralToken;
        ERC20 borrowAsset = ERC20(address(borrowedAssetToken));

        collateralToken.approve(address(pool), deposited);
        pool.deposit(deposited);

        mintAndApprove(borrowedAssetToken, borrowed * 4);
        borrowAsset.transfer(address(pool), borrowed * 4);

        oracle.updatePrice(asset, 1e18);

        oracle.updatePrice(borrowAsset, 1e18);

        loanId = pool.borrow(borrowAsset, pool.maxAllowedToBorrow(address(this), borrowAsset) - 1);

        assertGe(pool.calculateHealthFactor(ERC20(address(0)), address(this), 0), 1e18);

        oracle.updatePrice(asset, 0.9e18);

        assertTrue(pool.userLiquidatable(address(this)));
    }

    function testSeizeCollateralSuccessful() public {
        uint loanId = testUserLiquidatable();

        pool.seizeCollateral(loanId, address(this));

        (bool closed, , , , ,) = pool.loanInfo(loanId);
        assertTrue(closed);
    }

    function testSeizeCollateralFailsIfNonAdminCalls() public {
        uint loanId = testUserLiquidatable();
        address randomAddress = address(4);
        hevm.prank(randomAddress);

        hevm.expectRevert("Only admin can perform this action");
        pool.seizeCollateral(loanId, randomAddress);
    }

    function testSeizeCollateralFailsIfLoanIsClosed() public {
        uint loanId = testUserLiquidatable();
        pool.repayAndCloseLoan(loanId);

        hevm.expectRevert("loan closed");
        pool.seizeCollateral(loanId, address(this));
    }

    function mintAndApprove(MockERC20 underlying, uint256 amount) internal {
        underlying.mint(address(this), amount);
        underlying.approve(address(pool), amount);
    }

    function setUpLoanForTest()
    public
    returns (uint256 collateralAmount, uint256 loanId)
    {
        uint256 deposited = 1e18;
        uint256 borrowed = 100e6;
        ERC20 asset = collateralToken;
        ERC20 borrowAsset = ERC20(address(borrowedAssetToken));

        collateralToken.approve(address(pool), deposited);
        pool.deposit(deposited);

        mintAndApprove(borrowedAssetToken, borrowed * 4);
        borrowAsset.transfer(address(pool), borrowed * 4);

        oracle.updatePrice(asset, 400);

        oracle.updatePrice(borrowAsset, 1);

        loanId = pool.borrow(borrowAsset, borrowed);
        Loan memory loan = pool.loanInfoStruct(loanId);
        collateralAmount = loan.collateralAmount;
        //        console.log("closed", loan.closed);
        //        console.log("startTime", loan.startTime);
        //        console.log("loanAssetContractAddress", loan.loanAssetContractAddress);
        //        console.log("loanAmount", loan.loanAmount);
        //        console.log("collateralAmount", loan.collateralAmount);
        //        console.log("borrowerAddress", loan.borrowerAddress);
    }
}