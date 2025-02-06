// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USD is ERC20 {
    constructor(address[] memory arr) ERC20("USD", "USD"){
        for(uint i = 0; i < arr.length; i++) {
            _mint(arr[i], 1e12 * 1e6);
        }
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}
