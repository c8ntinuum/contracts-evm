// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./utils/v2-periphery/interfaces/IUniswapV2Router02.sol";
import "./utils/v2-core/interfaces/IUniswapV2Factory.sol";
import "./utils/v2-core/interfaces/IUniswapV2Pair.sol";
import "./utils/interfaces/IWETH9.sol";

interface ICtnmERC20 is IERC20 {
    function mint(address,uint256) external;
    function burn(uint256) external;
    function maxSupply() external view returns (uint);
}

struct UnlockInfo {
    uint256 weiAmount;
    uint256 weiAmountInUsd;
    uint256 ctnmUsdPriceOracle;
    uint256 ctnmUsdPricePool;
    uint256 timestamp;
}

contract Generate is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for ICtnmERC20;
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    bytes32 public constant SYNCER_ROLE = keccak256("SYNCER_ROLE");

    ICtnmERC20 public ctnm;
    address payable public treasury;
    address public verifier;

    mapping(address => uint) public referralEarnings;

    mapping(address => uint) public lockedEntriesCount;
    mapping(address => mapping(uint => UnlockInfo)) public lockedEntries;

    mapping(address => bool) public blackListed;

    uint public liqPercentage;
    uint public mainReferralPercentage;
    uint public secondReferralPercentage;
    uint public treasuryPercentage;
    uint public constant maxReferralPercentagesSum = 200; // 20%

    IUniswapV2Router02 immutable public router;
    IUniswapV2Factory immutable public factory;
    address immutable public wETH;
    address immutable public usd;
    IUniswapV2Pair public wEthUsdPair;
    IUniswapV2Pair public wEthCtnmPair;

    uint public constant minFloorGenerationPriceUsd = 22400; // 0.0224 * 10^6 -> 0.0224$
    uint public globalGenerationPriceUsd = minFloorGenerationPriceUsd;
    uint public constant oneCtnm = 1 * 1e18;
    uint public constant percentageDivider = 1000; // 100%
    address[] public swapPath;

    event Generated(address indexed sender, uint index, address referral1, address referral2);

    constructor(address verifierAddress, address syncerAddress, address payable treasuryAddress, address ctnmAddress, address usdAddress, address routerAddress) {
        verifier = verifierAddress;
        _grantRole(SYNCER_ROLE, syncerAddress);
        treasury = treasuryAddress;
        ctnm = ICtnmERC20(ctnmAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        // 100% is 1000
        // 20 + 2 + 8 + 70 == 100
        liqPercentage = 200; // 20%
        mainReferralPercentage = 20; // 2%
        secondReferralPercentage = 80; // 8%
        treasuryPercentage = 700; // 70%

        router = IUniswapV2Router02(routerAddress);
        // Call allowance only once for adding liq, set it to uint max
        ctnm.safeIncreaseAllowance(address(router), type(uint256).max);

        factory = IUniswapV2Factory(router.factory());
        wETH = router.WETH();

        usd = usdAddress;
        wEthUsdPair = IUniswapV2Pair(factory.getPair(wETH, usd));
        wEthCtnmPair = IUniswapV2Pair(factory.getPair(wETH, address(ctnm)));

        swapPath = new address[](2);
        swapPath[0] = wETH;
        swapPath[1] = address(ctnm);
    }

    receive() external payable {}

    function generate(uint ctnmUsdPriceOracle, uint deadline, address referral1, address referral2, uint slippage, bytes memory signature)
    whenNotPaused nonReentrant payable external {
        require(slippage <= (percentageDivider / 5), "Wrong slippage value");
        require(msg.value >= 5e15 wei, "Value less than min value");
        require(blackListed[_msgSender()] == false, "User is blacklisted");
        // This ensures that that msg sender is an EOA and not a smart contract
        require(_msgSender() == tx.origin, "Sender is not an EOA");
        require(block.timestamp <= deadline, "Deadline has passed");

        // The referral must be valid
        require(referral1 != address(0), "Cannot generate without a valid referral1");

        bytes32 messageHash = keccak256(abi.encode(block.chainid, address(this), address(ctnm), deadline, referral1, referral2, ctnmUsdPriceOracle, _msgSender()));
        messageHash = messageHash.toEthSignedMessageHash();
        address signer = messageHash.recover(signature);
        require(signer == verifier, "wrong signature");

        uint index = lockedEntriesCount[_msgSender()];
        lockedEntries[_msgSender()][index].weiAmount = msg.value;
        lockedEntries[_msgSender()][index].weiAmountInUsd = weiToUsd(msg.value);
        lockedEntries[_msgSender()][index].ctnmUsdPriceOracle = ctnmUsdPriceOracle;
        lockedEntries[_msgSender()][index].ctnmUsdPricePool = getPrice();

        require(lockedEntries[_msgSender()][index].ctnmUsdPricePool <= (ctnmUsdPriceOracle * (slippage + percentageDivider) / percentageDivider), "Price higher than slippage");
        require((ctnmUsdPriceOracle * (percentageDivider - slippage) / percentageDivider) <= lockedEntries[_msgSender()][index].ctnmUsdPricePool, "Price lower than slippage");

        lockedEntries[_msgSender()][index].timestamp = block.timestamp;
        lockedEntriesCount[_msgSender()] += 1;

        ///////////// Distribution

        uint liqAmount = msg.value * liqPercentage / percentageDivider;
        uint mainReferralAmount = msg.value * mainReferralPercentage / percentageDivider;
        uint secondReferralAmount = msg.value * secondReferralPercentage / percentageDivider;

        // Referral logic

        if (referral2 == address(0)) {
            // In this case we send the 10% to the mainReferral
            mainReferralAmount += secondReferralAmount;
            secondReferralAmount = 0;
        }
        // Otherwise it means that a valid secondReferral was used and the amounts don't change

        // Liquidity logic

        // Buy with 10%
        uint[] memory amounts = router.swapExactETHForTokens{value: (liqAmount / 2)}(0, swapPath, address(this), block.timestamp);

        // Add liquidity with 10%
        router.addLiquidityETH{ value: liqAmount / 2 }
        (address(ctnm), amounts[1], 0, 0, address(0), block.timestamp);

        // Burn remaining ctnm
        if(ctnm.balanceOf(address(this)) > 0){
            ctnm.burn(ctnm.balanceOf(address(this)));
        }

        // Send ETH

        // We do not require a success call as one of the referrals could DoS the contract
        if (mainReferralAmount > 0) {
            (bool sent, ) = payable(referral1).call{value: mainReferralAmount}(new bytes(0));
            if (sent) {
                referralEarnings[referral1] += mainReferralAmount;
            }
        }
        if (secondReferralAmount > 0) {
            (bool sent, ) = payable(referral2).call{value: secondReferralAmount}(new bytes(0));
            if (sent) {
                referralEarnings[referral2] += secondReferralAmount;
            }
        }

        // Some spare wei might exist and we send them all
        treasury.call{value: address(this).balance}(new bytes(0));

        emit Generated(_msgSender(), index, referral1, referral2);
    }

    function setPause(bool value) onlyRole(SYNCER_ROLE) external {
        if (value) {
            _pause();
        } else {
            _unpause();
        }
    }

    function setBlacklist(address[] memory addresses, bool[] memory values) onlyRole(SYNCER_ROLE) external {
        require(addresses.length == values.length, "Arrays lengths do not match");
        for(uint i = 0; i < addresses.length; i++) {
            blackListed[addresses[i]] = values[i];
        }
    }

    function setTreasury(address payable newTreasury) onlyRole(SYNCER_ROLE) external {
        require(newTreasury != address(0), "Address cannot be 0 address");
        treasury = newTreasury;
    }

    function setVerifier(address newVerifier) onlyRole(SYNCER_ROLE) external {
        require(newVerifier != address(0), "Address cannot be 0 address");
        verifier = newVerifier;
    }

    function setGlobalGenerationPrice(uint generationPrice) onlyRole(SYNCER_ROLE) external {
        require(minFloorGenerationPriceUsd <= generationPrice , "Generation price less than min");
        globalGenerationPriceUsd = generationPrice;
    }

    function setPercentages(uint liqP, uint mainReferralP, uint secondReferralP, uint treasuryP) onlyRole(SYNCER_ROLE) external {
        uint sum = mainReferralP + secondReferralP;
        require(sum <= maxReferralPercentagesSum, "Referral percentages sum cannot exceed 20%");
        sum += (liqP + treasuryP);
        require(sum == percentageDivider, "Percentage sum is not 1000");
        liqPercentage = liqP;
        mainReferralPercentage = mainReferralP;
        secondReferralPercentage = secondReferralP;
        treasuryPercentage = treasuryP;
    }

    ////////////

    // The first reserve returned is always the one of the token param and the second one is always the one of wETH
    function internalGetReserves(address token) internal view returns(uint, uint) {
        IUniswapV2Pair pair;
        if (token == address(ctnm)) {
            pair = wEthCtnmPair;
        } else if (token == usd) {
            pair = wEthUsdPair;
        } else {
            revert("Pair non existent");
        }
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        address token0 = pair.token0();
        if (token0 == wETH) {
            return (reserve1, reserve0);
        }
        return (reserve0, reserve1);
    }

    function ctnmToWei(uint ctnmAmount) public view returns (uint) {
        (uint pairCtnmReserve, uint pairWETHReserve) = internalGetReserves(address(ctnm));
        uint wethCtnmRatio =  router.quote(oneCtnm, pairCtnmReserve, pairWETHReserve);
        uint wethUsdRatio = usdToWei(globalGenerationPriceUsd);

        uint wethRatio = wethCtnmRatio > wethUsdRatio ? wethCtnmRatio : wethUsdRatio;

        return ctnmAmount * wethRatio / oneCtnm;
    }

    function weiToCtnm(uint weiAmount) public view returns (uint) {
        return oneCtnm * weiAmount / (usdToWei(getPrice()));
    }

    function weiToUsd(uint weiAmount) public view returns (uint) {
        (uint pairUsdReserve, uint pairWETHReserve) = internalGetReserves(usd);
        return router.quote(weiAmount, pairWETHReserve, pairUsdReserve);
    }

    function usdToWei(uint usdAmount) public view returns (uint) {
        (uint pairUsdReserve, uint pairWETHReserve) = internalGetReserves(usd);
        return router.quote(usdAmount, pairUsdReserve, pairWETHReserve);
    }

    // Calculate the max price between floor price and market price
    function getPrice() public view returns (uint) {
        (uint pairCtnmReserve, uint pairWETHReserve) = internalGetReserves(address(ctnm));
        uint wethRatio = router.quote(oneCtnm, pairCtnmReserve, pairWETHReserve);
        uint usdRatio = weiToUsd(wethRatio);

        return usdRatio >= globalGenerationPriceUsd ? usdRatio : globalGenerationPriceUsd;
    }
}