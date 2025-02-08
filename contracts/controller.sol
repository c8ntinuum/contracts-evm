// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./v2-periphery/interfaces/IUniswapV2Router02.sol";
import "./v2-core/interfaces/IUniswapV2Factory.sol";
import "./v2-core/interfaces/IUniswapV2Pair.sol";
import "./interfaces/IWETH9.sol";

// todo remove
import "hardhat/console.sol";

interface ICtnmERC20 is IERC20 {
    function mint(address,uint256) external;
    function burn(uint256) external;
    function maxSupply() external view returns (uint);
    function localMaxCtnmSupply() external view returns (uint);
    function availableSupply() external view returns (uint);

    function setMaxCtnmSupply(uint) external;
}

interface IGeneration {
    function generate(address, uint, uint, uint) external payable returns(uint, uint);

    function setTreasury(address) external;
    function setValidatorRewards(address) external;
    function setPercentages(uint, uint, uint, uint, uint) external;
    function setGlobalGenerationPrice(uint) external;

    function getBaseNumAmount(uint) external view returns (uint);
    function getPrice() external view returns (uint);
    function globalGenerationPriceUsdt() external view returns (uint);

    function validatorRewards() external view returns (address);
    function treasury() external view returns (address);

    // todo delete
    function setTestnet(uint, uint) external;
}

struct UnlockInfo {
    uint256 timestamp;
    uint256 amount;
}

contract NumController is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    IGeneration public generation;
    ICtnmERC20 public ctnm;

    mapping(address => bool) public mainReferrals;
    // secondReferral => mainReferral
    mapping(address => address) public referralPairs;

    // Total amount of locked ctnm
    uint public lockedCtnmSupply;
    mapping(address => uint) public lockedEntriesCount;
    mapping(address => mapping(uint => UnlockInfo)) public lockedEntries;

    address public verifier;
    mapping(address => bool) public blackListed;

    uint public constant percentageDivider = 1000; // 100%

    event Generated(address indexed sender, address indexed to, uint amount, uint period, address referral);
    event RegisteredReferral(address indexed mainReferral, address indexed secondReferral);
    event Unlocked(address indexed sender, uint index, uint amount);

    // todo add setter for verifier
    constructor(address verifierAddress) Ownable(_msgSender()) {
        verifier = verifierAddress;
    }

    receive() external payable {}

    function availableSupply() external view returns(uint) {
        return ctnm.availableSupply();
    }

    function localMaxCtnmSupply() external view returns(uint) {
        return ctnm.localMaxCtnmSupply();
    }

    function generate(address to, uint amount, uint slippage, uint deadline, address referral, uint vestingPeriodInMonths, bytes memory signature)
        whenNotPaused nonReentrant payable external {
        require(blackListed[_msgSender()] == false, "User is blacklisted");
        require(block.timestamp <= deadline, "Deadline has passed");
//        console.logString("Controller generate 0");
        bytes32 messageHash = keccak256(abi.encode(block.chainid, address(this), address(ctnm), deadline, amount, _msgSender()));
        messageHash = messageHash.toEthSignedMessageHash();
        address signer = messageHash.recover(signature);
        require(signer == verifier, "wrong signature");

//        console.logString("Controller generate 1");
        (uint lockedAmount, uint lockedPeriod) = generation.generate{value: msg.value}(referral, vestingPeriodInMonths, amount, slippage);
//        console.logString("Controller generate 2");
        if(lockedPeriod != 0) {
//            console.logString("Controller in lockedPeriod != 0");
            uint index = lockedEntriesCount[to];
            lockedEntries[to][index].amount = lockedAmount;
            lockedEntries[to][index].timestamp = block.timestamp + lockedPeriod;
            lockedEntriesCount[to] += 1;
            lockedCtnmSupply += lockedAmount;
        } else {
            ctnm.mint(to, lockedAmount);
        }
        emit Generated(_msgSender(), to, lockedAmount, lockedPeriod, referral);
    }

    function unlock(uint index) whenNotPaused external {
        require(index < lockedEntriesCount[_msgSender()], "Invalid index");
        require(lockedEntries[_msgSender()][index].timestamp < block.timestamp, "Unlock not due");
        require(blackListed[_msgSender()] == false, "User is blacklisted");

        lockedEntries[_msgSender()][index].timestamp = type(uint256).max;
        lockedCtnmSupply -= lockedEntries[_msgSender()][index].amount;
        ctnm.mint(_msgSender(), lockedEntries[_msgSender()][index].amount);
        emit Unlocked(_msgSender(), index, lockedEntries[_msgSender()][index].amount);
    }

    function setMainReferrals(address[] memory referrals, bool[] memory values) onlyOwner external {
        require(referrals.length == values.length, "Arrays lengths do not match");
        for(uint i = 0; i < referrals.length; i++) {
            mainReferrals[referrals[i]] = values[i];
        }
    }

    function registerSecondReferral(address mainReferral) external {
        require(mainReferrals[mainReferral] == true, "Specified address is not a main referral");
        require(referralPairs[_msgSender()] == address(0), "Referral is already set");
        referralPairs[_msgSender()] = mainReferral;
        emit RegisteredReferral(mainReferral, _msgSender());
    }

    function setPause(bool value) onlyOwner external {
        if (value) {
            _pause();
        } else {
            _unpause();
        }
    }

    function setBlacklist(address[] memory addresses, bool[] memory values) onlyOwner external {
        require(addresses.length == values.length, "Arrays lengths do not match");
        for(uint i = 0; i < addresses.length; i++) {
            blackListed[addresses[i]] = values[i];
        }
    }

    // Calculate the max price between floor price and market price
    function getPrice() public view returns (uint) {
        return generation.getPrice();
    }

    function getGlobalGenerationPriceUsdt() public view returns (uint) {
        return generation.globalGenerationPriceUsdt();
    }

    function setGlobalGenerationPrice(uint generationPrice) onlyOwner external {
        generation.setGlobalGenerationPrice(generationPrice);
    }

    function setGeneration(address newGeneration) onlyOwner external {
        generation = IGeneration(newGeneration);
    }

    function setTreasury(address payable newTreasury) onlyOwner external {
        generation.setTreasury(newTreasury);
    }

    function setValidatorRewards(address payable newValidatorRewards) onlyOwner external {
        generation.setValidatorRewards(newValidatorRewards);
    }

    function setPercentages(uint liqP, uint mainReferralP, uint secondReferralP, uint treasuryP, uint validatorRewardsP) onlyOwner external {
        generation.setPercentages(liqP, mainReferralP, secondReferralP, treasuryP, validatorRewardsP);
    }

    function setCtnm(address ctnmAddress) external onlyOwner {
        ctnm = ICtnmERC20(ctnmAddress);
    }

    function validatorRewards() external view returns (address) {
        return generation.validatorRewards();
    }

    function treasury() external view returns (address) {
        return generation.treasury();
    }

    ////////////
    // Todo remove for mainnet
    function setTestnet(uint lockPeriod, uint secondsAMonth) onlyOwner external{
        generation.setTestnet(lockPeriod, secondsAMonth);
    }
}