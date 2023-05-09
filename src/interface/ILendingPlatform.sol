// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../BorrowLendStructs.sol";

interface ILendingPlatform {
    event Close(uint256 indexed id);

    event SeizeCollateral(uint256 indexed id, address sendCollateralTo);

    function seizeCollateral(uint256 loanId, address sendCollateralTo) external;

    function loanInfo(uint256 loanId)
    external
    view
    returns (
        bool closed,
        uint40 startTime,
        address loanAssetContractAddress,
        uint128 loanAmount,
        uint256 collateralAmount,
        address borrowerAddress
    );

    function loanInfoStruct(uint256 loanId) external view returns (Loan memory);

    function interestOwed(uint256 loanId) view external returns (uint256);
}
