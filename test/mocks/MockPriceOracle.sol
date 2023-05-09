pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPriceOracle {
    mapping(ERC20 => uint64) public prices;

    function updatePrice(ERC20 asset, uint64 price) external {
        prices[asset] = price;
    }

    function getUnderlyingPrice(ERC20 asset) public view returns (uint64) {
        return prices[asset];
    }
}
