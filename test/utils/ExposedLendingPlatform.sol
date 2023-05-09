// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "forge-std/console.sol";
import "../../src/LendingPlatform.sol";

contract ExposedLendingPlatform is LendingPlatform {
    constructor(address _tokenContract, uint256 _collateralizationRatio)
        LendingPlatform(_tokenContract, _collateralizationRatio)
    {}

    function HACKED_setAccountAssets(
        address account,
        ERC20 borrowedAsset,
        uint256 deposited,
        uint256 borrowed
    ) public {
        state.accountAssets[account].deposited = deposited;
        state.accountAssets[account].borrowed = borrowed;
        internalDebt[borrowedAsset][account] = borrowed;
        userLoan[account].push(borrowedAsset);

        state.totalAssets.deposited = deposited;
        state.totalAssets.borrowed = borrowed;
    }

    function HACKED_resetAccountAssets(address account, ERC20 borrowedAsset) public {
        HACKED_setAccountAssets(account, borrowedAsset, 0, 0);
    }
}
