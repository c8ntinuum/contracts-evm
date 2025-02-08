// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

interface INumController {
    function lockedCtnmSupply() external view returns(uint);
}

contract NUM is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SYNCER_ROLE = keccak256("SYNCER_ROLE");

    INumController public numController;
    uint public constant maxSupply = 8888888888 ether;
    uint public localMaxCtnmSupply;

    // todo create method to setControllerAddress?
    constructor(address numControllerAddress, uint newLocalMaxCtnmSupply) ERC20("C8NTINUUM", "CTNM") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(SYNCER_ROLE, _msgSender());

        numController = INumController(numControllerAddress);
        _grantRole(MINTER_ROLE, numControllerAddress);
        localMaxCtnmSupply = newLocalMaxCtnmSupply;
    }

    modifier localMaxSupplyCap() {
        _;
        require(availableSupply() >= 0, "Local max supply has been reached");
    }

    function availableSupply() public view returns(uint) {
//        console.logString("\n///////////////// available Supply start");
//        console.logString("localMaxCtnmSupply");
//        console.logUint(localMaxCtnmSupply);
//
//        console.logString("totalSupply");
//        console.logUint(totalSupply());
//
//        console.logString("localMaxCtnmSupply - totalSupply()");
//        console.logUint(localMaxCtnmSupply - totalSupply());
//
//        console.logString("numController.lockedCtnmSupply()");
//        console.logUint(numController.lockedCtnmSupply());
//        console.logString("///////////////// available Supply end\n");
        return localMaxCtnmSupply - totalSupply() - numController.lockedCtnmSupply();
    }

    function mint(address account, uint256 value) onlyRole(MINTER_ROLE) localMaxSupplyCap external {
        _mint(account, value);
    }

    function burn(uint value) external {
        _burn(_msgSender(), value);
    }

    function setMaxCtnmSupply(uint ctnmSupply) onlyRole(SYNCER_ROLE) external {
        require(ctnmSupply <= maxSupply, "Invalid parameter");
        localMaxCtnmSupply = ctnmSupply;
    }
}