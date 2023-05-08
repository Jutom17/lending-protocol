// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

contract BorrowLendGetter is Context {
    function denormalizeAmount(
        uint256 normalizedAmount,
        uint256 interest
    ) public view returns (uint256) {
        return
        (normalizedAmount * interest) /
        interestPrecision;
    }

    function normalizeAmount(
        uint256 denormalizedAmount,
        uint256 interest
    ) public view returns (uint256) {
        return
        (denormalizedAmount * interestPrecision) /
        interest;
    }
}
