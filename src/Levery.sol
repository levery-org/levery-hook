// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "v4-core/lib/forge-std/src/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PermissionManager} from "./utils/PermissionManager.sol";

/**
 * @title Levery
 * @dev Extends BaseHook to provide dynamic fee management and oracle integration for Uniswap V4 pools.
 */
contract Levery is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @dev Manages permissions for liquidity and swap actions.
    PermissionManager private permissionManager;

    /// @dev Admin address with special privileges.
    address public admin;

    /// @dev Base fee for swaps (in basis points, e.g., 3000 = 0.3%).
    uint24 public baseFee;

    /// @dev Multiplier for calculating liquidity provider fees.
    uint256 public lpFeeMultiplier;

    /// @dev Struct to store oracle information for a pool.
    struct PoolOracle {
        address oracle;
        bool compareWithPrice0;
    }

    /// @dev Mapping from pool identifiers to base fees.
    mapping(bytes32 => uint24) public poolBaseFees;

    /// @dev Mapping from pool identifiers to associated oracles and comparison flags.
    mapping(bytes32 => PoolOracle) public poolOracles;

    /// @dev Constant used in price calculations.
    uint256 constant Q96 = 2 ** 96;

    /**
     * @dev Initializes the contract with the provided IPoolManager and sets default values for baseFee and lpFeeMultiplier.
     * @param _poolManager Address of the Pool Manager.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        baseFee = 3000;
        lpFeeMultiplier = 1000000;
    }

    /**
     * @dev Modifier to restrict function access to the admin.
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not the admin");
        _;
    }

    /**
     * @notice Sets the admin address.
     * @dev Can only be called once.
     * @param _admin Address of the new admin.
     */
    function setAdmin(address _admin) external {
        require(admin == address(0), "Admin is already set");
        admin = _admin;
    }

    /**
     * @notice Updates the admin address.
     * @dev Can only be called by the current admin.
     * @param _admin Address of the new admin.
     */
    function updateAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    /**
     * @notice Updates the base fee for swaps.
     * @dev Can only be called by the admin.
     * @param _baseFee New base fee in basis points.
     */
    function updateBaseFee(uint24 _baseFee) external onlyAdmin {
        baseFee = _baseFee; // 3000 = 0.3%
    }

    /**
     * @notice Sets the LP fee multiplier.
     * @dev Can only be called by the admin.
     * @param _lpFeeMultiplier New LP fee multiplier. 1000000 = 100%. Must not exceed 1000000.
     */
    function setLpFeeMultiplier(uint256 _lpFeeMultiplier) external onlyAdmin {
        require(
            _lpFeeMultiplier <= 1000000,
            "LP Fee Multiplier cannot exceed 1000000"
        );
        lpFeeMultiplier = _lpFeeMultiplier;
    }

    /**
     * @notice Sets the base fee for a specific pool.
     * @dev Can only be called by the admin.
     * @param key Pool key identifying the pool.
     * @param _baseFee New base fee for a specific pool.
     */
    function setPoolBaseFee(
        PoolKey calldata key,
        uint24 _baseFee
    ) external onlyAdmin {
        PoolId poolId = key.toId();
        poolBaseFees[PoolId.unwrap(poolId)] = _baseFee;
    }

    /**
     * @notice Retrieves the base fee for a specific pool.
     * @param key Pool key identifying the pool.
     * @return Base fee in basis points.
     */
    function getPoolBaseFee(PoolKey calldata key) public view returns (uint24) {
        PoolId poolId = key.toId();
        return poolBaseFees[PoolId.unwrap(poolId)];
    }

    /**
     * @notice Returns the current permission manager.
     * @return Address of the permission manager.
     */
    function getPermissionManager() public view returns (PermissionManager) {
        return permissionManager;
    }

    /**
     * @notice Sets the permission manager.
     * @dev Can only be called by the admin.
     * @param _permissionManager Address of the new permission manager.
     */
    function setPermissionManager(
        PermissionManager _permissionManager
    ) external onlyAdmin {
        permissionManager = _permissionManager;
    }

    /**
     * @notice Sets the oracle for a specific pool.
     * @dev Can only be called by the admin.
     * @param key Pool key identifying the pool.
     * @param _oracle Address of the oracle.
     * @param _compareWithPrice0 Flag indicating whether to compare with price0.
     */
    function setPoolOracle(
        PoolKey calldata key,
        address _oracle,
        bool _compareWithPrice0
    ) external onlyAdmin {
        PoolId poolId = key.toId();
        poolOracles[PoolId.unwrap(poolId)] = PoolOracle({
            oracle: _oracle,
            compareWithPrice0: _compareWithPrice0
        });
    }

    /**
     * @notice Retrieves the oracle details for a specific pool.
     * @param key Pool key identifying the pool.
     * @return Address of the oracle and comparison flag.
     */
    function getPoolOracle(
        PoolKey calldata key
    ) public view returns (address, bool) {
        PoolId poolId = PoolIdLibrary.toId(key);
        PoolOracle storage poolOracle = poolOracles[PoolId.unwrap(poolId)];
        return (poolOracle.oracle, poolOracle.compareWithPrice0);
    }

    /**
     * @notice Fetches the latest price from an oracle and adjusts it according to token decimals.
     * @param _oracle Address of the oracle.
     * @param key Pool key identifying the pool.
     * @return Adjusted oracle price.
     */
    function getLastOraclePrice(
        address _oracle,
        PoolKey calldata key
    ) public view returns (int) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_oracle);
        uint8 feedDecimals = priceFeed.decimals();

        (, int answer, , , ) = priceFeed.latestRoundData();

        // Determine which currency decimals to use
        uint8 currencyDecimals;
        if (poolOracles[PoolId.unwrap(key.toId())].compareWithPrice0) {
            IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
            currencyDecimals = token0.decimals();
        } else {
            IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
            currencyDecimals = token1.decimals();
        }

        // Convert the answer to have the same number of decimals as the currency
        if (feedDecimals > currencyDecimals) {
            answer = answer / int(10 ** (feedDecimals - currencyDecimals));
        } else if (feedDecimals < currencyDecimals) {
            answer = answer * int(10 ** (currencyDecimals - feedDecimals));
        }

        return answer;
    }

    /**
     * @notice Calculates and returns the current prices of tokens in a pool.
     * @param key Pool key identifying the pool.
     * @return _price0 Current price of token0 in Wei.
     * @return _price1 Current price of token1 in Wei.
     */
    function getCurrentPrices(
        PoolKey calldata key
    ) public view returns (uint256 _price0, uint256 _price1) {
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(
            poolManager,
            key.toId()
        );

        // Ensure the sqrtPriceX96 is within the range allowed by TickMath
        require(
            sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE &&
                sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE,
            "sqrtPriceX96 out of bounds"
        );

        // Calculate _price0 and _price1 in Wei
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 sqrtPriceSquared = FullMath.mulDiv(sqrtPrice, sqrtPrice, Q96);

        // Adjust rounding to improve precision
        _price0 = FullMath.mulDivRoundingUp(sqrtPriceSquared, 1e18, Q96);
        _price1 = FullMath.mulDivRoundingUp(Q96, 1e18, sqrtPriceSquared);

        // Ensure precision by checking calculated prices
        require(_price0 > 0, "Price0 calculation error");
        require(_price1 > 0, "Price1 calculation error");

        return (_price0, _price1);
    }

    /** -----------------------------------------------
     * Hook Functions
     * ------------------------------------------------
     */

    /**
     * @dev Checks if the user is allowed to add liquidity before the operation is executed.
     * @return Returns the selector for the beforeAddLiquidity function of BaseHook.
     */
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        address user = tx.origin;
        require(
            permissionManager.isLiquidityAllowed(user),
            "Liquidity not allowed for this user. Request access at https://levery.org"
        );
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @dev Checks if the user is allowed to remove liquidity before the operation is executed.
     * @return Returns the selector for the beforeRemoveLiquidity function of BaseHook.
     */
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        address user = tx.origin;
        require(
            permissionManager.isLiquidityAllowed(user),
            "Liquidity not allowed for this user. Request access at https://levery.org"
        );
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @dev Performs checks and adjusts the swap fee before executing the swap operation.
     * Verifies if the user is allowed to swap and calculates the new swap fee based on real-time market conditions.
     * @param key PoolKey structure identifying the liquidity pool.
     * @param params SwapParams structure containing the swap parameters.
     * @return Returns the selector for the beforeSwap function of BaseHook, beforeSwapDelta, and the new swap fee.
     */
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        {
            // Check if the user is allowed to perform swaps
            address user = tx.origin;
            require(
                permissionManager.isSwapAllowed(user),
                "Swap not allowed for this user. Request access at https://levery.org"
            );
        }

        // Set the initial base fee for the swap
        uint24 newSwapFee = baseFee;

        {
            // Get the pool-specific base fee if available
            uint24 poolBaseFee = getPoolBaseFee(key);
            if (poolBaseFee != 0) {
                newSwapFee = poolBaseFee;
            }
        }

        // Get the current prices for price0 and price1
        uint256 price0;
        uint256 price1;
        {
            // Retrieve the current token prices from the pool state
            (price0, price1) = getCurrentPrices(key);
        }

        // Get the PoolOracle structure
        PoolId poolId = key.toId();
        PoolOracle memory poolOracle = poolOracles[PoolId.unwrap(poolId)];

        // Checks whether a market price oracle has been defined for the pool
        if (poolOracle.oracle != address(0)) {
            // Get the real-time market price from the Oracle
            int marketPrice;
            {
                marketPrice = getLastOraclePrice(poolOracle.oracle, key);
            }

            {
                // Adjust the swap fee based on price comparisons
                if (poolOracle.compareWithPrice0) {
                    // Compare market price with price of the token 0
                    if (price0 > uint256(marketPrice) && params.zeroForOne) {
                        // If price0 is higher than the market price and the swap is from token0 to token1,
                        // increase the swap fee proportionally to the price difference
                        uint256 priceDifference = price0 - uint256(marketPrice);
                        uint256 percentageDifference = (priceDifference *
                            lpFeeMultiplier) / uint256(marketPrice);
                        newSwapFee += uint24(percentageDifference); // Increase the swap fee
                    } else if (
                        price0 < uint256(marketPrice) && !params.zeroForOne
                    ) {
                        // If price0 is lower than the market price and the swap is from token1 to token0,
                        // increase the swap fee proportionally to the price difference
                        uint256 priceDifference = uint256(marketPrice) - price0;
                        uint256 percentageDifference = (priceDifference *
                            lpFeeMultiplier) / uint256(marketPrice);
                        newSwapFee += uint24(percentageDifference); // Increase the swap fee
                    }
                } else {
                    // Compare market price with price of the token 1
                    if (price1 < uint256(marketPrice) && params.zeroForOne) {
                        // If price1 is lower than the market price and the swap is from token0 to token1,
                        // increase the swap fee proportionally to the price difference
                        uint256 priceDifference = uint256(marketPrice) - price1;
                        uint256 percentageDifference = (priceDifference *
                            lpFeeMultiplier) / uint256(marketPrice);
                        newSwapFee += uint24(percentageDifference); // Increase the swap fee
                    } else if (
                        price1 > uint256(marketPrice) && !params.zeroForOne
                    ) {
                        // If price1 is higher than the market price and the swap is from token1 to token0,
                        // increase the swap fee proportionally to the price difference
                        uint256 priceDifference = price1 - uint256(marketPrice);
                        uint256 percentageDifference = (priceDifference *
                            lpFeeMultiplier) / uint256(marketPrice);
                        newSwapFee += uint24(percentageDifference); // Increase the swap fee
                    }
                }
            }
        }

        // Update the dynamic swap fee in the pool
        poolManager.updateDynamicLPFee(key, newSwapFee);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /**
     * @dev Returns the permissions for various hook functions.
     * Specifies which hooks are enabled for this contract.
     * @return Hooks.Permissions structure with boolean flags indicating the enabled hooks.
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }
}
