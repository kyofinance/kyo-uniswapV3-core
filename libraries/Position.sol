// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FixedPoint128} from "./FixedPoint128.sol";
import {FullMath} from "./FullMath.sol";

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    /*
    event PositionUpdated(address user, int24 tickLower, int24 tickUpper, uint128 liquidity, uint128 liquidityStaked, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint256 rewardGrowthInsideX128, uint128 tokensOwed0, uint128 tokensOwed1, uint128 rewardsOwed);
    */
    error ISD();
    error NP();

    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        uint128 liquidityStaked;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint256 rewardGrowthInsideLastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint128 rewardsOwed;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(mapping(bytes32 => Info) storage self, address owner, int24 tickLower, int24 tickUpper) internal view returns (Position.Info storage position) {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @param feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function update(Info storage self, int128 liquidityDelta, int128 liquidityStakedDelta, uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128, uint256 rewardGrowthInsideX128) internal {
        Info memory _self = self;

        uint128 liquidityNext = liquidityDelta < 0 ? _self.liquidity - uint128(-liquidityDelta) : _self.liquidity + uint128(liquidityDelta);

        uint128 liquidityStakedNext = liquidityStakedDelta < 0 ? _self.liquidityStaked - uint128(-liquidityStakedDelta) : _self.liquidityStaked + uint128(liquidityStakedDelta);

        unchecked {
            // calculate accumulated fees. overflow in the subtraction of fee growth is expected
            uint128 tokensOwed0 = uint128(FullMath.mulDiv(feeGrowthInside0X128 - _self.feeGrowthInside0LastX128, _self.liquidity - _self.liquidityStaked, FixedPoint128.Q128));
            uint128 tokensOwed1 = uint128(FullMath.mulDiv(feeGrowthInside1X128 - _self.feeGrowthInside1LastX128, _self.liquidity - _self.liquidityStaked, FixedPoint128.Q128));
            uint128 rewardsOwed = uint128(FullMath.mulDiv(rewardGrowthInsideX128 - _self.rewardGrowthInsideLastX128, _self.liquidityStaked, FixedPoint128.Q128));

            require(liquidityNext != 0 || _self.liquidity > 0, NP());
            require(liquidityNext >= liquidityStakedNext, ISD());

            self.liquidity = liquidityNext;
            self.liquidityStaked = liquidityStakedNext;

            self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
            self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
            self.rewardGrowthInsideLastX128 = rewardGrowthInsideX128;

            // overflow is acceptable, user must withdraw before they hit type(uint128).max fees
            if (tokensOwed0 != 0) self.tokensOwed0 += tokensOwed0;
            if (tokensOwed1 != 0) self.tokensOwed1 += tokensOwed1;
            if (rewardsOwed != 0) self.rewardsOwed += rewardsOwed;
        }
    }

    function log(Info storage self, address owner, int24 tickLower, int24 tickUpper) internal {
        /*
        emit PositionUpdated(owner, tickLower, tickUpper, self.liquidity, self.liquidityStaked, self.feeGrowthInside0LastX128, self.feeGrowthInside1LastX128, self.rewardGrowthInsideLastX128, self.tokensOwed0, self.tokensOwed1, self.rewardsOwed);
        */
    }
}
