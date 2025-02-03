// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import {IUniswapV3PoolDeployer} from "./interfaces/IUniswapV3PoolDeployer.sol";
import "openzeppelin-v5/utils/Create2.sol";

import {ICodeStorage} from "contracts/lib/ICodeStorage.sol";

contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    address public immutable electorCreationCode;
    address public immutable creationCode;
    address private transient token0;
    address private transient token1;
    uint24 private transient fee;
    int24 private transient tickSpacing;

    constructor(address creationCode_, address electorCreationCode_) {
        creationCode = creationCode_;
        electorCreationCode = electorCreationCode_;
    }

    function deploy(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) internal returns (address pool, address elector) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;

        pool = Create2.deploy(0, keccak256(abi.encode(token0_, token1_, fee_)), ICodeStorage(creationCode).getCreationCode());
        elector = Create2.deploy(0, keccak256(abi.encode(token0_, token1_, fee_)), abi.encodePacked(ICodeStorage(electorCreationCode).getCreationCode(), abi.encode(pool)));
    }

    function parameters() external view returns (address, address, uint24, int24) {
        return (token0, token1, fee, tickSpacing);
    }
}
