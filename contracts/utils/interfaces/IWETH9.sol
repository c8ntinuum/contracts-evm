pragma solidity ^0.8.27;

interface IWETH9 {
    function deposit() external  payable;
    function withdraw(uint) external;
}