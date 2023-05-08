// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./BorrowLendStructs.sol";

contract BorrowLendStorage {
    struct State {
        uint256 collateralizationRatioPrecision;
        uint256 interestRatePrecision;
        // mock pyth price oracle
        address mockPythAddress;
        bytes32 targetContractAddress;
        // borrow and lend activity
        address collateralAssetAddress;
        bytes32 collateralAssetPythId;
        uint256 collateralizationRatio;
        address borrowingAssetAddress;
        DepositedBorrowedUints interestAccrualIndex;
        uint256 interestAccrualIndexPrecision;
        uint256 lastActivityBlockTimestamp;
        DepositedBorrowedUints totalAssets;
        uint256 repayGracePeriod;
        mapping(address => DepositedBorrowedUints) accountAssets;
    }
}

contract BorrowLendState {
    BorrowLendStorage.State state;
}
