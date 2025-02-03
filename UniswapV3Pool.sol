// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import {IUniswapV3Pool, IUniswapV3PoolActions, IUniswapV3PoolDerivedState, IUniswapV3PoolImmutables, IUniswapV3PoolOwnerActions, IUniswapV3PoolState} from "./interfaces/IUniswapV3Pool.sol";

import {Oracle} from "./libraries/Oracle.sol";
import {Position} from "./libraries/Position.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Tick} from "./libraries/Tick.sol";
import {TickBitmap} from "./libraries/TickBitmap.sol";

import {FixedPoint128} from "./libraries/FixedPoint128.sol";
import {FullMath} from "./libraries/FullMath.sol";

import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";
import {SwapMath} from "./libraries/SwapMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3PoolDeployer} from "./interfaces/IUniswapV3PoolDeployer.sol";

import {IUniswapV3FlashCallback} from "./interfaces/callback/IUniswapV3FlashCallback.sol";
import {IUniswapV3MintCallback} from "./interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "./interfaces/callback/IUniswapV3SwapCallback.sol";

import {ITokenStreamEmitter} from "contracts/reward/interfaces/ITokenStreamEmitter.sol";

import {Math} from "openzeppelin-v4/utils/math/Math.sol";

contract UniswapV3Pool is IUniswapV3Pool {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable token1;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // left for compatibility. this was the slot for protocolFee in the original implementation
        uint8 unused;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState

    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;
    uint256 public rewardGrowthGlobalX128;

    address public immutable rewardToken;
    uint128 private lastPendingReward;

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState

    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    uint128 public override liquidity;
    uint128 public liquidityStaked;

    mapping(int24 => Tick.Info) _ticks;
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;
    mapping(bytes32 => Position.Info) internal _positions;
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        if (!slot0.unlocked) revert LOK();
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    constructor() {
        int24 _tickSpacing;
        factory = msg.sender;
        (token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
        rewardToken = ITokenStreamEmitter(factory).outputTokens()[0];
    }

    /// @inheritdoc IUniswapV3PoolState
    function ticks(int24 i) external view override returns (uint128 liquidityGross, int128 liquidityNet, uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128, int56 tickCumulativeOutside, uint160 secondsPerLiquidityOutsideX128, uint32 secondsOutside, bool initialized) {
        Tick.Info storage tick = _ticks[i];
        return (tick.liquidityGross, tick.liquidityNet, tick.feeGrowthOutside0X128, tick.feeGrowthOutside1X128, tick.tickCumulativeOutside, tick.secondsPerLiquidityOutsideX128, tick.secondsOutside, tick.initialized);
    }

    /// @inheritdoc IUniswapV3PoolState
    function positions(bytes32 i) external view override returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) {
        Position.Info memory pos = _positions[i];
        return (pos.liquidity, pos.feeGrowthInside0LastX128, pos.feeGrowthInside1LastX128, pos.tokensOwed0, pos.tokensOwed1);
    }

    function positionRewardInformation(bytes32 i) external view override returns (uint128, uint256, uint128) {
        Position.Info storage pos = _positions[i];
        return (pos.liquidityStaked, pos.rewardGrowthInsideLastX128, pos.rewardsOwed);
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) revert TLU();
        if (tickLower < TickMath.MIN_TICK) revert TLM();
        if (tickUpper > TickMath.MAX_TICK) revert TUM();
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper) external view override returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside) {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = _ticks[tickLower];
            Tick.Info storage upper = _ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (lower.tickCumulativeOutside, lower.secondsPerLiquidityOutsideX128, lower.secondsOutside, lower.initialized);
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (upper.tickCumulativeOutside, upper.secondsPerLiquidityOutsideX128, upper.secondsOutside, upper.initialized);
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        unchecked {
            if (_slot0.tick < tickLower) {
                return (tickCumulativeLower - tickCumulativeUpper, secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128, secondsOutsideLower - secondsOutsideUpper);
            } else if (_slot0.tick < tickUpper) {
                (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(0, _slot0.tick, _slot0.observationIndex, liquidity, _slot0.observationCardinality);
                return (tickCumulative - tickCumulativeLower - tickCumulativeUpper, secondsPerLiquidityCumulativeX128 - secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128, uint32(block.timestamp) - secondsOutsideLower - secondsOutsideUpper);
            } else {
                return (tickCumulativeUpper - tickCumulativeLower, secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128, secondsOutsideUpper - secondsOutsideLower);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function observe(uint32[] calldata secondsAgos) external view override returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        return observations.observe(secondsAgos, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality);
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external override lock {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew) emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        if (slot0.sqrtPriceX96 != 0) revert AI();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize();

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, observationIndex: 0, observationCardinality: cardinality, observationCardinalityNext: cardinalityNext, unused: 0, unlocked: true});
        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
        int128 liquidityStakedDelta;
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    function _modifyPosition(ModifyPositionParams memory params) private returns (Position.Info storage position, int256 amount0, int256 amount1) {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, params.liquidityStakedDelta, _slot0.tick);

        if (params.liquidityDelta != 0 || params.liquidityStakedDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(TickMath.getSqrtRatioAtTick(params.tickLower), TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta);
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization
                uint128 liquidityStakedBefore = liquidityStaked; // SLOAD for gas optimization

                if (params.liquidityDelta != 0) {
                    // write an oracle entry
                    (slot0.observationIndex, slot0.observationCardinality) = observations.write(_slot0.observationIndex, _slot0.tick, liquidityBefore, _slot0.observationCardinality, _slot0.observationCardinalityNext);
                }

                amount0 = SqrtPriceMath.getAmount0Delta(_slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta);
                amount1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(params.tickLower), _slot0.sqrtPriceX96, params.liquidityDelta);

                liquidity = params.liquidityDelta < 0 ? liquidityBefore - uint128(-params.liquidityDelta) : liquidityBefore + uint128(params.liquidityDelta);

                liquidityStaked = params.liquidityStakedDelta < 0 ? liquidityStakedBefore - uint128(-params.liquidityStakedDelta) : liquidityStakedBefore + uint128(params.liquidityStakedDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(params.tickLower), TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta);
            }
        }
    }

    function _updateRewardGrowth() internal {
        if (liquidityStaked == 0) return;

        try ITokenStreamEmitter(factory).collectableAmountWithUpdate(rewardToken, address(this)) returns (uint128 pendingReward) {
            if (pendingReward > lastPendingReward) {
                // this should always be true, if gauge works correctly
                rewardGrowthGlobalX128 += FullMath.mulDiv(pendingReward - lastPendingReward, FixedPoint128.Q128, liquidityStaked);
                emit Reward(pendingReward - lastPendingReward);
                lastPendingReward = pendingReward;
            }
        } catch {}
    }

    function _bribe(uint256 amount0, uint256 amount1) internal {
        if (amount0 == 0 && amount1 == 0) return;
        ProtocolFees memory _protocolFeees = protocolFees;
        protocolFees.token0 = uint128(Math.min(type(uint128).max, amount0 + _protocolFeees.token0));
        protocolFees.token1 = uint128(Math.min(type(uint128).max, amount1 + _protocolFeees.token1));
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int128 liquidityStakedDelta, int24 tick) private returns (Position.Info storage position) {
        position = _positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization
        uint256 _rewardGrowthGlobalX128 = rewardGrowthGlobalX128; // SLOAD for gas optimization

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0 || liquidityStakedDelta != 0) {
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(0, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality);

            flippedLower = _ticks.update(tickLower, tick, liquidityDelta, liquidityStakedDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, _rewardGrowthGlobalX128, secondsPerLiquidityCumulativeX128, tickCumulative, false, maxLiquidityPerTick);
            flippedUpper = _ticks.update(tickUpper, tick, liquidityDelta, liquidityStakedDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, _rewardGrowthGlobalX128, secondsPerLiquidityCumulativeX128, tickCumulative, true, maxLiquidityPerTick);

            if (flippedLower) tickBitmap.flipTick(tickLower, tickSpacing);
            if (flippedUpper) tickBitmap.flipTick(tickUpper, tickSpacing);
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128, uint256 rewardGrowthInsideX128) = _ticks.getGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, _rewardGrowthGlobalX128);

        position.update(liquidityDelta, liquidityStakedDelta, feeGrowthInside0X128, feeGrowthInside1X128, rewardGrowthInsideX128);

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) _ticks.clear(tickLower);
            if (flippedUpper) _ticks.clear(tickUpper);
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        _updateRewardGrowth();
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(ModifyPositionParams({owner: recipient, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(amount)).toInt128(), liquidityStakedDelta: 0}));

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        balance0Before = balance0();
        balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        require(balance0Before + amount0 <= balance0(), M0());
        require(balance1Before + amount1 <= balance1(), M1());

        position.log(msg.sender, tickLower, tickUpper);
        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) external override lock returns (uint128 amount0, uint128 amount1) {
        _updateRewardGrowth();
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = _positions.get(msg.sender, tickLower, tickUpper);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        position.log(msg.sender, tickLower, tickUpper);
        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    function collectReward(address recipient, int24 tickLower, int24 tickUpper, uint128 amountRewardRequested) external override lock returns (uint128 amountReward) {
        _updateRewardGrowth();

        Position.Info storage position = _positions.get(msg.sender, tickLower, tickUpper);

        amountReward = amountRewardRequested > position.rewardsOwed ? position.rewardsOwed : amountRewardRequested;

        if (amountReward > 0) {
            position.rewardsOwed -= amountReward;
            ITokenStreamEmitter(factory).collect(rewardToken, recipient, amountReward);
            lastPendingReward -= amountReward;
        }

        position.log(msg.sender, tickLower, tickUpper);
        emit CollectReward(msg.sender, recipient, tickLower, tickUpper, amountReward);
    }

    /// @inheritdoc IUniswapV3PoolActions
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external override lock returns (uint256 amount0, uint256 amount1) {
        _updateRewardGrowth();
        unchecked {
            (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(ModifyPositionParams({owner: msg.sender, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(amount)).toInt128(), liquidityStakedDelta: 0}));

            amount0 = uint256(-amount0Int);
            amount1 = uint256(-amount1Int);

            if (amount0 > 0 || amount1 > 0) (position.tokensOwed0, position.tokensOwed1) = (position.tokensOwed0 + uint128(amount0), position.tokensOwed1 + uint128(amount1));

            emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
        }
    }

    function stake(int24 tickLower, int24 tickUpper, uint128 amount) external lock {
        require(amount <= uint256(int256(type(int128).max)));
        _updateRewardGrowth();
        (Position.Info storage position,,) = _modifyPosition(ModifyPositionParams({owner: msg.sender, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, liquidityStakedDelta: int128(amount)}));
        position.log(msg.sender, tickLower, tickUpper);
        emit Stake(msg.sender, tickLower, tickUpper, amount);
    }

    function unstake(int24 tickLower, int24 tickUpper, uint128 amount) external lock {
        require(amount > 0 && amount <= uint256(-int256(type(int128).min)));
        _updateRewardGrowth();
        (Position.Info storage position,,) = _modifyPosition(ModifyPositionParams({owner: msg.sender, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, liquidityStakedDelta: -int256(uint256(amount)).toInt128()}));
        position.log(msg.sender, tickLower, tickUpper);
        emit Unstake(msg.sender, tickLower, tickUpper, amount);
    }

    struct SwapCache {
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // staked liquidity at the beginning of the swap
        uint128 liquidityStakedStart;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
        // the current staked liquidity in range
        uint128 liquidityStaked;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external override returns (int256 amount0, int256 amount1) {
        _updateRewardGrowth();
        if (amountSpecified == 0) revert AS();

        Slot0 memory slot0Start = slot0;

        uint24 _protocolFee = IUniswapV3Factory(factory).getProtocolFeeRate(address(this));
        bool exempted = IUniswapV3Factory(factory).feeExempted(tx.origin);
        if (exempted) emit FeeExempted(tx.origin);
        uint24 _fee = exempted ? 0 : fee;

        if (!slot0Start.unlocked) revert LOK();
        require(zeroForOne ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO, SPL());

        slot0.unlocked = false;

        SwapCache memory cache = SwapCache({liquidityStart: liquidity, liquidityStakedStart: liquidityStaked, secondsPerLiquidityCumulativeX128: 0, tickCumulative: 0, computedLatestObservation: false});

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({amountSpecifiedRemaining: amountSpecified, amountCalculated: 0, sqrtPriceX96: slot0Start.sqrtPriceX96, tick: slot0Start.tick, feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128, protocolFee: 0, liquidity: cache.liquidityStart, liquidityStaked: cache.liquidityStakedStart});

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
            else if (step.tickNext > TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(state.sqrtPriceX96, (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96) ? sqrtPriceLimitX96 : step.sqrtPriceNextX96, state.liquidity, state.amountSpecifiedRemaining, _fee);

            if (exactInput) {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                }
                state.amountCalculated -= step.amountOut.toInt256();
            } else {
                unchecked {
                    state.amountSpecifiedRemaining += step.amountOut.toInt256();
                }
                state.amountCalculated += (step.amountIn + step.feeAmount).toInt256();
            }

            // update global fee tracker and protocol fees
            if (step.feeAmount > 0) {
                (uint256 lpFeeAmount, uint256 protocolFeeAmount) = splitFees(step.feeAmount, _protocolFee, state.liquidity, state.liquidityStaked);
                state.protocolFee += uint128(protocolFeeAmount);
                if (lpFeeAmount > 0) {
                    // allow overflow
                    unchecked {
                        state.feeGrowthGlobalX128 += FullMath.mulDiv(lpFeeAmount, FixedPoint128.Q128, state.liquidity - state.liquidityStaked);
                    }
                }
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(0, slot0Start.tick, slot0Start.observationIndex, cache.liquidityStart, slot0Start.observationCardinality);
                        cache.computedLatestObservation = true;
                    }
                    (int128 liquidityNet, int128 liquidityStakedNet) = _ticks.cross(step.tickNext, (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128), (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128), rewardGrowthGlobalX128, cache.secondsPerLiquidityCumulativeX128, cache.tickCumulative);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) {
                            liquidityNet = -liquidityNet;
                            liquidityStakedNet = -liquidityStakedNet;
                        }
                    }

                    state.liquidity = liquidityNet < 0 ? state.liquidity - uint128(-liquidityNet) : state.liquidity + uint128(liquidityNet);
                    state.liquidityStaked = liquidityStakedNet < 0 ? state.liquidityStaked - uint128(-liquidityStakedNet) : state.liquidityStaked + uint128(liquidityStakedNet);
                }

                unchecked {
                    state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and write an oracle entry if the tick change
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(slot0Start.observationIndex, slot0Start.tick, cache.liquidityStart, slot0Start.observationCardinality, slot0Start.observationCardinalityNext);
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
        } else {
            // otherwise just update the price
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update liquidity if it changed
        if (cache.liquidityStakedStart != state.liquidityStaked) liquidityStaked = state.liquidityStaked;

        // update fee growth global and, if necessary, protocol fees
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            _bribe(state.protocolFee, 0);
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            _bribe(0, state.protocolFee);
        }

        unchecked {
            (amount0, amount1) = zeroForOne == exactInput ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated) : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);
        }

        // do the transfers and collect payment
        if (zeroForOne) {
            unchecked {
                if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));
            }

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            if (balance0Before + uint256(amount0) > balance0()) revert IIA();
        } else {
            unchecked {
                if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));
            }

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            if (balance1Before + uint256(amount1) > balance1()) revert IIA();
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override lock {
        uint128 _liquidity = liquidity;
        if (_liquidity <= 0) revert L();

        uint24 _protocolFeeRate = IUniswapV3Factory(factory).getProtocolFeeRate(address(this));
        uint24 _feeRate = fee;
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, _feeRate, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, _feeRate, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        if (balance0Before + fee0 > balance0After) revert F0();
        if (balance1Before + fee1 > balance1After) revert F1();

        unchecked {
            // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
            uint256 paid0 = balance0After - balance0Before;
            uint256 paid1 = balance1After - balance1Before;

            if (paid0 > 0) {
                (uint256 lpFee, uint256 protocolFee) = splitFees(paid0, _protocolFeeRate, _liquidity, liquidityStaked);
                _bribe(protocolFee, 0);
                feeGrowthGlobal0X128 += FullMath.mulDiv(lpFee, FixedPoint128.Q128, _liquidity - liquidityStaked);
            }
            if (paid1 > 0) {
                (uint256 lpFee, uint256 protocolFee) = splitFees(paid1, _protocolFeeRate, _liquidity, liquidityStaked);
                _bribe(0, protocolFee);
                feeGrowthGlobal1X128 += FullMath.mulDiv(lpFee, FixedPoint128.Q128, _liquidity - liquidityStaked);
            }

            emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
        }
    }

    function splitFees(uint256 feeAmount, uint24 protocolFeeRate, uint256 totalLiquidity, uint256 stakedLiquidity) internal pure returns (uint256 lpFee, uint256 protocolFee) {
        if (totalLiquidity == 0) return (0, feeAmount);
        lpFee = ((1e6 - protocolFeeRate) * FullMath.mulDiv(feeAmount, totalLiquidity - stakedLiquidity, totalLiquidity)) / 1e6;
        protocolFee = feeAmount - lpFee;
    }

    function collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested) external override lock returns (uint128 amount0, uint128 amount1) {
        require(msg.sender == factory);

        if (amount0Requested > 0) {
            amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
            if (amount0 > 0) {
                protocolFees.token0 -= amount0;
                TransferHelper.safeTransfer(token0, recipient, amount0);
            }
        }

        if (amount1Requested > 0) {
            amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;
            if (amount1 > 0) {
                protocolFees.token1 -= amount1;
                TransferHelper.safeTransfer(token1, recipient, amount1);
            }
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
