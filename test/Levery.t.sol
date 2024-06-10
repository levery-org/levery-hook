// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IQuoter} from "v4-periphery/interfaces/IQuoter.sol";
import {Quoter} from "v4-periphery/lens/Quoter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {Levery} from "../src/Levery.sol";
import {PermissionManager} from "../src/utils/PermissionManager.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockOracle} from "./utils/MockOracle.sol";

contract LeveryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address alice = msg.sender;

    Levery levery;
    PoolId poolId;
    Quoter quoter;
    PermissionManager permissionManager;
    MockOracle mockOracle;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        quoter = new Quoter(address(manager));
        permissionManager = new PermissionManager();
        mockOracle = new MockOracle();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(Levery).creationCode,
            abi.encode(address(manager))
        );
        levery = new Levery{salt: salt}(IPoolManager(address(manager)));
        assertTrue(
            address(levery) == hookAddress,
            "LeveryTest: hook address mismatch"
        );
        levery.setAdmin(address(this));
        levery.setLpFeeMultiplier(900000);
        levery.setPermissionManager(permissionManager);
        assertTrue(
            address(levery.getPermissionManager()) ==
                address(permissionManager),
            "PermissionManager was not set correctly"
        );

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(levery))
        );
        poolId = key.toId();
        uint160 sqrtPrice = calculateSqrtPriceForRatio(3800, 1);

        manager.initialize(key, sqrtPrice, ZERO_BYTES);

        // Allow user Provide liquidity
        permissionManager.setLiquidityPermission(msg.sender, true);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-60, 60, 1000000 ether, 0),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-120, 120, 1000000 ether, 0),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                1000000 ether,
                0
            ),
            ZERO_BYTES
        );
    }

    function calculateSqrtPriceForRatio(
        uint256 numerator,
        uint256 denominator
    ) public pure returns (uint160) {
        require(denominator > 0, "Denominator must be greater than zero");

        // Calculate the ratio in Q128.128 format
        uint256 ratio = (numerator << 192) / denominator;

        // Calculate the square root of the ratio in Q64.64 format
        uint256 sqrtRatio = sqrt(ratio);

        // Convert to Q64.96 format by shifting left by 32 bits
        return uint160(sqrtRatio);
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return z;
    }

    // Start New Tests

    function test_BuySwapPoolPriceLowerThanMarket() public {
        levery.setPoolOracle(key, address(mockOracle), true);
        levery.setPoolBaseFee(key, 500); // set pool base fee 0.05%
        mockOracle.setLatestRoundData(
            uint80(0),
            int256(3900 * 10 ** 8),
            uint256(0),
            uint256(0),
            uint80(0)
        );

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        permissionManager.setSwapPermission(alice, true);
        token0.transfer(alice, 10 ether);
        token1.transfer(alice, 10000 ether);

        PoolKey memory poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(levery))
        );

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        uint256 balanceToken1Before = token1.balanceOf(alice);

        bool zeroForOne = false;
        int256 amountSpecified = 1e18; // negative number indicates exact input swap!
        uint256 amountIn = uint256(-amountSpecified);

        quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                recipient: address(this),
                exactAmount: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        (uint256 price0, ) = levery.getCurrentPrices(key);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        uint256 balanceToken1After = token1.balanceOf(alice);

        (, , , uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());

        int marketPrice = levery.getLastOraclePrice(address(mockOracle), key);
        uint256 paidByAlice = balanceToken1Before - balanceToken1After;
        assertTrue(
            lpFee > levery.getPoolBaseFee(key),
            "Liquidity providers receive much higher fees than the base fee"
        );
        assertTrue(
            uint256(marketPrice) > paidByAlice,
            "The market price needs to be higher to keep user interest buy in the pool"
        );

        console.log("==== Buy: Using Levery Dynamic Fees ===");
        console.log("Pool Price:", (price0 / 10 ** 18), "mUSDC");
        console.log(
            "Market Price for 1 mETH:",
            uint256(marketPrice / 10 ** 18),
            "mUSDC"
        );
        console.log(
            "Paid by Alice for 1 mETH:",
            (paidByAlice / 10 ** 18),
            "mUSDC"
        );
        console.log("Pool Base Fee:", levery.getPoolBaseFee(key));
        console.log("LPs Fee:", lpFee);
        console.log(
            "LPs received",
            lpFee / levery.getPoolBaseFee(key),
            "times higher fee and toxic arbitration was mitigated."
        );
    }

    function test_SellSwapPoolPriceHigherThanMarket() public {
        levery.setPoolOracle(key, address(mockOracle), true);
        levery.setPoolBaseFee(key, 500); // set pool base fee 0.05%
        mockOracle.setLatestRoundData(
            uint80(0),
            int256(3700 * 10 ** 8),
            uint256(0),
            uint256(0),
            uint80(0)
        );

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        permissionManager.setSwapPermission(alice, true);
        token0.transfer(alice, 10 ether);
        token1.transfer(alice, 10000 ether);

        PoolKey memory poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(levery))
        );

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        uint256 balanceToken1Before = token1.balanceOf(alice);

        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        uint256 amountIn = uint256(-amountSpecified);

        quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                recipient: address(this),
                exactAmount: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        (uint256 price0, ) = levery.getCurrentPrices(key);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        uint256 balanceToken1After = token1.balanceOf(alice);

        (, , , uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());

        int marketPrice = levery.getLastOraclePrice(address(mockOracle), key);
        uint256 receivedByAlice = balanceToken1After - balanceToken1Before;
        assertTrue(
            lpFee > levery.getPoolBaseFee(key),
            "Liquidity providers receive much higher fees than the base fee"
        );
        assertTrue(
            uint256(marketPrice) < receivedByAlice,
            "The market price needs to be lower to keep user interest sell in the pool"
        );

        console.log("==== Sell: Using Levery Dynamic Fees ===");
        console.log("Pool Price:", (price0 / 10 ** 18), "mUSDC");
        console.log(
            "Market Price for 1 mETH:",
            uint256(marketPrice / 10 ** 18),
            "mUSDC"
        );
        console.log(
            "Received by Alice for 1 mETH:",
            (receivedByAlice / 10 ** 18),
            "mUSDC"
        );
        console.log("Pool Base Fee:", levery.getPoolBaseFee(key));
        console.log("LPs Fee:", lpFee);
        console.log(
            "LPs received",
            lpFee / levery.getPoolBaseFee(key),
            "times higher fee and toxic arbitration was mitigated."
        );
    }

    function test_SwapWithoutPermissionThenGrantPermission() public {
        // Initially, do not give swap permission to Alice
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        token0.transfer(alice, 10 ether);
        token1.transfer(alice, 10000 ether);

        PoolKey memory poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(levery))
        );

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        bool zeroForOne = true;
        int256 amountSpecified = 1e18; // negative number indicates exact input swap!

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectRevert();
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        vm.stopPrank();

        // Now grant swap permission to Alice
        permissionManager.setSwapPermission(alice, true);

        vm.startPrank(alice);
        uint256 balanceToken1BeforeRetry = token1.balanceOf(alice);
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        uint256 balanceToken1AfterRetry = token1.balanceOf(alice);
        assertTrue(
            balanceToken1BeforeRetry < balanceToken1AfterRetry,
            "The balance needs to be greater after retry swap"
        );

        vm.stopPrank();
    }

    function test_AddLiquidityWithoutPermissionThenGrantPermission() public {
        // Initially, do not give liquidity permission to Alice
        permissionManager.setLiquidityPermission(alice, false);

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        token0.transfer(alice, 100 ether);
        token1.transfer(alice, 100000 ether);

        PoolKey memory poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(levery))
        );

        vm.startPrank(alice);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                10 ether,
                0
            ),
            ZERO_BYTES
        );

        vm.stopPrank();

        // Now grant liquidity permission to Alice
        permissionManager.setLiquidityPermission(alice, true);

        vm.startPrank(alice);
        uint256 balanceToken0Before = token0.balanceOf(alice);
        uint256 balanceToken1Before = token1.balanceOf(alice);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                100 ether,
                0
            ),
            ZERO_BYTES
        );

        uint256 balanceToken0After = token0.balanceOf(alice);
        uint256 balanceToken1After = token1.balanceOf(alice);

        assertTrue(
            balanceToken0Before > balanceToken0After,
            "The balance of token0 should decrease after adding liquidity"
        );
        assertTrue(
            balanceToken1Before > balanceToken1After,
            "The balance of token1 should decrease after adding liquidity"
        );

        vm.stopPrank();
    }

    function test_AddAndRemoveLiquidityWithPermissionChecks() public {
        // Initially, give liquidity permission to Alice
        permissionManager.setLiquidityPermission(alice, true);

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        token0.transfer(alice, 100 ether);
        token1.transfer(alice, 100000 ether);

        PoolKey memory poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(levery))
        );

        vm.startPrank(alice);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Alice adds liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                100 ether,
                0
            ),
            ZERO_BYTES
        );

        vm.stopPrank();

        // Remove liquidity permission from Alice
        permissionManager.setLiquidityPermission(alice, false);

        vm.startPrank(alice);

        // Alice attempts to remove liquidity, which should fail
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                -100 ether,
                0
            ),
            ZERO_BYTES
        );

        vm.stopPrank();
    }
}
