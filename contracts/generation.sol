// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


import "./v2-periphery/interfaces/IUniswapV2Router02.sol";
import "./v2-core/interfaces/IUniswapV2Factory.sol";
import "./v2-core/interfaces/IUniswapV2Pair.sol";
import "./interfaces/IWETH9.sol";

import "hardhat/console.sol";

interface ICtnmERC20 is IERC20 {
    function mint(address,uint256) external;
    function burn(uint256) external;
    function maxSupply() external view returns (uint);
    function localMaxCtnmSupply() external view returns (uint);
    function availableSupply() external view returns (uint);

    function setMaxCtnmSupply(uint) external;
}

interface INumController {
    function ctnm() external view returns(address);
    function mainReferrals(address) external view returns(bool);
    function referralPairs(address) external view returns(address);
    function lockedCtnmSupply() external view returns(uint);
}

struct UnlockInfo {
    uint256 timestamp;
    uint256 amount;
}

contract Generation is Context, Ownable {
    using SafeERC20 for ICtnmERC20;

    INumController immutable public numController;
    ICtnmERC20 immutable public ctnm;
    IUniswapV2Router02 immutable public router;
    IUniswapV2Factory immutable public factory;
    address immutable public wETH;
    address immutable public usdt;
    // The (WETH / USDT) pair address
    address public wEthUsdtPair;
    // The (WETH / CTNM) pair address
    address public wEthCtnmPair;

    uint public constant minFloorGenerationPriceUsdt = 22400; // 0.0224 * 10^6 -> 0.0224$
    uint public constant maxFloorGenerationPriceUsdt = minFloorGenerationPriceUsdt * 8; // 8 * 0.0224 * 10^6 -> 0.1792$
    uint public globalGenerationPriceUsdt = minFloorGenerationPriceUsdt;

    uint public constant floorPriceMultiplier1 = 1500; // 150%
    uint public constant floorPriceMultiplier2 = 3000; // 300%
    uint public constant floorPriceMultiplier3 = 5000; // 500%
    uint public constant oneCtnm = 1 * 1e18;

    uint public liqPercentage;
    uint public mainReferralPercentage;
    uint public secondReferralPercentage;
    uint public treasuryPercentage;
    uint public validatorRewardsPercentage;
    uint public constant percentageDivider = 1000; // 100%

    // todo make constants for mainnet
    uint public secondsInAMonth = 60 * 60 * 24 * 30;
    // todo maybe increase the period
    uint public baseLockPeriod = 60 * 60 * 24; // 1 day

    uint public oneMonthAmountMultiplier = 1100; // 10%
    uint public sixMonthsAmountMultiplier = 1300; // 30%
    uint public twelveMonthsAmountMultiplier = 1500; // 50%

    address payable public treasury;
    address payable public validatorRewards;
    address[] public swapPath;

    constructor(address numControllerAddress, address usdtAddress, address routerAddress, address payable validatorRewardsAddress, address payable treasuryAddress) Ownable(numControllerAddress) {
        numController = INumController(numControllerAddress);
        ctnm = ICtnmERC20(numController.ctnm());

        router = IUniswapV2Router02(routerAddress);
        factory = IUniswapV2Factory(router.factory());
        wETH = router.WETH();

        usdt = usdtAddress;
        wEthUsdtPair = factory.getPair(wETH, usdt);
        wEthCtnmPair = factory.getPair(wETH, address(ctnm));

        swapPath = new address[](2);
        swapPath[0] = wETH;
        swapPath[1] = address(ctnm);

        validatorRewards = validatorRewardsAddress;
        treasury = treasuryAddress;

        // 100% is 1000
        // 20 + 2 + 8 + 60 + 10 == 100
        liqPercentage = 200; // 20%
        mainReferralPercentage = 20; // 2%
        secondReferralPercentage = 80; // 8%
        treasuryPercentage = 600; // 60%
        validatorRewardsPercentage = 100; // 10%
    }

    receive() external payable {}

    function getBaseNumAmount(uint msgValue) public view returns (uint) {
        uint pairWETHBalance = IERC20(wETH).balanceOf(wEthUsdtPair);
        uint pairUsdtBalance = IERC20(usdt).balanceOf(wEthUsdtPair);
        // todo use quote or getAmountOut ? test it, can you make profit? test with big sell
        uint ethRatio = router.getAmountOut(getPrice(), pairUsdtBalance, pairWETHBalance);
        return (msgValue * oneCtnm / ethRatio);
    }

    function getGenerationInfo(uint msgValue, address referral, uint vestingPeriodInMonths) public view returns (uint , address, bool) {
        uint generationAmount = getBaseNumAmount(msgValue);
        if (vestingPeriodInMonths > 0) {
            generationAmount = generationAmount * getLockAmountMultiplierBasedOnVesting(vestingPeriodInMonths) / percentageDivider;
        }
        // if the user has a valid referral, he receives a bonus 1%
        bool isMainReferral = numController.mainReferrals(referral);
        address referralPair = numController.referralPairs(referral);
        if (isMainReferral || referralPair != address(0)) {
            generationAmount = generationAmount * 101 / 100;
        }
        address computedReferral = referralPair;
        if (isMainReferral) {
            computedReferral = referral;
        }
        return (generationAmount, computedReferral, isMainReferral);
    }

    function generate(address referral, uint vestingPeriodInMonths, uint amount, uint slippage) external payable onlyOwner returns(uint, uint) {
        require(msg.value > 5e15 wei, "Value less than min value");

        (uint lockedAmount, address computedReferral, bool isMainReferral) = getGenerationInfo(msg.value, referral, vestingPeriodInMonths);
        require((amount * (percentageDivider - slippage) / percentageDivider) <= lockedAmount, "Generated amount is less than slippage interval");
        require(lockedAmount <= (amount * (percentageDivider + slippage) / percentageDivider), "Generated amount is greater than slippage interval");

        uint liqAmount = msg.value * liqPercentage / percentageDivider;
        uint mainReferralAmount = msg.value * mainReferralPercentage / percentageDivider;
        uint secondReferralAmount = msg.value * secondReferralPercentage / percentageDivider;
        // todo We removed this variable because stack was too deep
//        uint treasuryAmount = msg.value * treasuryPercentage / percentageDivider;
        uint validatorRewardsAmount = msg.value * validatorRewardsPercentage / percentageDivider;

        // Referral logic
        if (isMainReferral) {
            // In this case we send the 10% to the mainReferral
            mainReferralAmount += secondReferralAmount;
            secondReferralAmount = 0;
        } else if (computedReferral == address(0)) {
            // The address has not registered as an affiliate, in this case we send the 10% to the validatorRewards
            validatorRewardsAmount += (mainReferralAmount + secondReferralAmount);
            mainReferralAmount = 0;
            secondReferralAmount = 0;
        }
        // Otherwise it means that a valid secondReferral was used and the percentages don't change

        // Send ETH
        if (mainReferralAmount > 0) {
            (bool success, ) = payable(computedReferral).call{value: mainReferralAmount}(new bytes(0));
            require(success, 'ETH transfer to mainReferral failed');
        }
        if (secondReferralAmount > 0) {
            (bool success, ) = payable(referral).call{value: secondReferralAmount}(new bytes(0));
            require(success, 'ETH transfer to secondReferral failed');
        }
        if (validatorRewardsAmount > 0) {
            (bool success, ) = validatorRewards.call{value: validatorRewardsAmount}(new bytes(0));
            require(success, 'ETH transfer to validatorRewards failed');
        }
        // It will always be greater than 0, and does not change
        (bool success, ) = treasury.call{value: (msg.value * treasuryPercentage / percentageDivider)}(new bytes(0));
        require(success, 'ETH transfer to treasury failed');

        // Liquidity logic

        // Buy with 10%
        uint[] memory amounts = router.swapExactETHForTokens{value: (liqAmount / 2)}(0, swapPath, address(this), block.timestamp);

        ctnm.safeIncreaseAllowance(address(router), amounts[1]);
        router.addLiquidityETH{value: address(this).balance }
            (address(ctnm), amounts[1], 0, 0, address(0), block.timestamp);

        // burn remaining ctnm
        if(ctnm.balanceOf(address(this)) > 0){
            ctnm.burn(ctnm.balanceOf(address(this)));
        }


        uint lockedPeriod = 0;
        // todo test generate with referral and sell and generate with referral again
        if (computedReferral != address(0) || vestingPeriodInMonths != 0) {
            lockedPeriod = vestingPeriodInMonths == 0 ? baseLockPeriod : (vestingPeriodInMonths * secondsInAMonth);
        }

        // We check at the end if there is still some available supply in order to lock
        require(ctnm.availableSupply() >= lockedAmount, "Mint limit has been reached");
        return (lockedAmount, lockedPeriod);
    }

    // Calculate the max price between floor price and market price
    function getPrice() public view returns (uint) {
        uint pairCtnmBalance = ctnm.balanceOf(wEthCtnmPair);
        uint pairWETHBalance = IERC20(wETH).balanceOf(wEthCtnmPair);
        uint wethRatio = router.quote(oneCtnm, pairCtnmBalance, pairWETHBalance);

        pairWETHBalance = IERC20(wETH).balanceOf(wEthUsdtPair);
        uint pairUsdtBalance = IERC20(usdt).balanceOf(wEthUsdtPair);
        uint usdtRatio = router.quote(wethRatio, pairWETHBalance, pairUsdtBalance);

        return usdtRatio >= globalGenerationPriceUsdt ? usdtRatio : globalGenerationPriceUsdt;
    }

    // Todo what other checks to add?
    function setTreasury(address payable newTreasury) onlyOwner external {
        require(newTreasury != address(0), "Address cannot be 0 address");
        treasury = newTreasury;
    }

    // Todo what other checks to add?
    function setValidatorRewards(address payable newValidatorRewards) onlyOwner external {
        require(newValidatorRewards != address(0), "Address cannot be 0 address");
        validatorRewards = newValidatorRewards;
    }

    function setPercentages(uint liqP, uint mainReferralP, uint secondReferralP, uint treasuryP, uint validatorRewardsP) onlyOwner external {
        uint sum = liqP + mainReferralP + secondReferralP + treasuryP + validatorRewardsP;
        require(sum == percentageDivider, "Percentage sum is not 1000");
        liqPercentage = liqP;
        mainReferralPercentage = mainReferralP;
        secondReferralPercentage = secondReferralP;
        treasuryPercentage = treasuryP;
        validatorRewardsPercentage = validatorRewardsP;
    }

    function setMultipliers(uint oneMonth, uint sixMonths, uint twelveMonths) onlyOwner external {
        require(percentageDivider <= oneMonth, "Invalid parameters");
        require(oneMonth <= sixMonths, "Invalid parameters");
        require(sixMonths <= twelveMonths, "Invalid parameters");

        oneMonthAmountMultiplier = oneMonth;
        sixMonthsAmountMultiplier = sixMonths;
        twelveMonthsAmountMultiplier = twelveMonths;
    }

    function getLockAmountMultiplierBasedOnVesting(uint vestingInMonths) public view returns (uint) {
        if (vestingInMonths >= 12) {
            return twelveMonthsAmountMultiplier;
        } else if(vestingInMonths >= 6) {
            return sixMonthsAmountMultiplier;
        } else if (vestingInMonths >= 1) {
            return oneMonthAmountMultiplier;
        }

        return percentageDivider;
    }

    function setGlobalGenerationPrice(uint generationPrice) onlyOwner external {
        require(minFloorGenerationPriceUsdt <= generationPrice , "Generation price less than min");
        require(generationPrice <= maxFloorGenerationPriceUsdt, "Generation price greater than max");
        globalGenerationPriceUsdt = generationPrice;
    }

    // Todo remove for mainnet
    function setTestnet(uint lockPeriod, uint secondsAMonth) onlyOwner external{
        baseLockPeriod = lockPeriod;
        secondsInAMonth = secondsAMonth;
    }
}