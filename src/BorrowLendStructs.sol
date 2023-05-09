// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

struct DepositedBorrowedUints {
    uint256 deposited;
    uint256 borrowed;
}

struct Loan {
    bool closed;
    uint40 startTime;
    address loanAssetContractAddress;
    uint128 loanAmount;
    uint256 collateralAmount;
    address borrowerAddress;
}
