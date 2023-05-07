pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface PriceOracle {
    function getUnderlyingPrice(ERC20 asset) external view returns (uint256);
}
