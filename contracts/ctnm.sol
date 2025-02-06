// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CTNM is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint public constant maxSupply = 8888888888 ether;

    constructor() ERC20("C8NTINUUM", "CTNM") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + value <= maxSupply, "Cannot mint more than maxSupply");
        _mint(account, value);
    }

    function burn(uint value) external {
        _burn(_msgSender(), value);
    }
}