// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SmoothTokenStreamConsumer} from "contracts/reward/SmoothTokenStreamConsumer.sol";
import {TokenStreamSplitter} from "contracts/reward/TokenStreamSplitter.sol";
import {ITokenStreamEmitter} from "contracts/reward/interfaces/ITokenStreamEmitter.sol";
import {IUniswapV3Factory} from "contracts/univ3/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "contracts/univ3/interfaces/IUniswapV3Pool.sol";

import {Elector} from "contracts/voting/Elector.sol";
import {IUniswapV2Gauge} from "contracts/voting/interfaces/IUniswapV2Gauge.sol";
import {IVoter} from "contracts/voting/interfaces/IVoter.sol";
import {ERC2771Context} from "openzeppelin-v5/metatx/ERC2771Context.sol";

import {ERC20} from "openzeppelin-v5/token/ERC20/ERC20.sol";

import {Ownable} from "openzeppelin-v5/access/Ownable.sol";
import {IERC20} from "openzeppelin-v5/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-v5/token/ERC20/extensions/IERC20Metadata.sol";
import {Context} from "openzeppelin-v5/utils/Context.sol";

contract UniswapV3Elector is Elector, SmoothTokenStreamConsumer {
    IUniswapV3Pool public immutable pool;
    address public immutable factory;
    address private immutable token0;
    address private immutable token1;

    constructor(address pool_) SmoothTokenStreamConsumer(0.999983955055097432e18, _tokens, _surplus, _surplus, _takeBribe) Elector(IVoter(msg.sender), pool_) ERC20(string(abi.encodePacked(IERC20Metadata(IVoter(msg.sender).ballot()).symbol(), " voted for ", IERC20Metadata(IUniswapV3Pool(pool_).token0()).symbol(), "/", IERC20Metadata(IUniswapV3Pool(pool_).token1()).symbol(), " CL Pool")), string(abi.encodePacked(IERC20Metadata(IVoter(msg.sender).ballot()).symbol(), "-voted (CL-", IERC20Metadata(IUniswapV3Pool(pool_).token0()).symbol(), "/", IERC20Metadata(IUniswapV3Pool(pool_).token1()).symbol(), ")"))) {
        pool = IUniswapV3Pool(pool_);
        token0 = pool.token0();
        token1 = pool.token1();
        factory = msg.sender;
        _distribute();
    }

    function _tokens() internal view virtual returns (address[] memory) {
        address[] memory ret = new address[](2);
        ret[0] = token0;
        ret[1] = token1;
        return ret;
    }

    function _takeBribe(address token, address recipient, uint128 amountMax) internal returns (uint128) {
        if (amountMax == 0) return 0;
        if (token == token0) {
            (uint128 amount,) = IUniswapV3Factory(factory).collectBribe(address(pool), recipient, amountMax, 0);
            return amount;
        } else if (token == token1) {
            (, uint128 amount) = IUniswapV3Factory(factory).collectBribe(address(pool), recipient, 0, amountMax);
            return amount;
        } else {
            return 0;
        }
    }

    function _surplus(address token) internal view virtual returns (uint128) {
        if (token == token0) {
            (uint128 amount,) = pool.protocolFees();
            return amount;
        } else if (token == token1) {
            (, uint128 amount) = pool.protocolFees();
            return amount;
        } else {
            return 0;
        }
    }

    function collectUndistributed(address token, address recipient) external nonReentrant {
        require(msg.sender == Ownable(factory).owner());
        _collectUndistributed(token, recipient);
    }
}
