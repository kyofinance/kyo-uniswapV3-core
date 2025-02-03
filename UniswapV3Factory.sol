// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IERC4626TokenStreamSplitter} from "contracts/reward/interfaces/IERC4626TokenStreamSplitter.sol";
import {Ownable} from "openzeppelin-v5/access/Ownable.sol";

import {UniswapV3PoolDeployer} from "./UniswapV3PoolDeployer.sol";

import {Voter} from "contracts/voting/Voter.sol";
import {IVoter} from "contracts/voting/interfaces/IVoter.sol";

import {UniswapV3Elector} from "./UniswapV3Elector.sol";
import {UniswapV3Pool} from "./UniswapV3Pool.sol";
import {ICodeStorage} from "contracts/lib/ICodeStorage.sol";

/// @title Canonical Uniswap V3 factory
/// @notice Deploys Uniswap V3 pools and manages ownership and control over pool protocol fees
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, Voter {
    struct ProtocolFee {
        uint24 value;
        bool set;
    }

    event ElectorCreated(address indexed pool, address indexed elector);
    event DefaultProtocolFeeUpdated(uint24 protocolFee);
    event ProtocolFeeUpdated(address indexed pool, uint24 protocolFee);
    event ProtocolFeeReset(address indexed pool);
    event FeeExempted(address indexed user, bool value);

    mapping(uint24 => int24) public feeAmountTickSpacing;

    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;
    mapping(address => address) public getElector;

    mapping(address => bool) public feeExempted;
    uint24 public defaultProtocolFee;
    mapping(address => ProtocolFee) private _protocolFees;

    mapping(address => bool) internal _isWhitelisted;

    constructor(address creationCode, address electorCreationCode, IERC4626TokenStreamSplitter rewardSource) UniswapV3PoolDeployer(creationCode, electorCreationCode) Voter(rewardSource) Ownable(msg.sender) {}

    /// @inheritdoc IUniswapV3Factory
    function createPool(address tokenA, address tokenB, uint24 fee) external override returns (address pool) {
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));
        int24 tickSpacing = feeAmountTickSpacing[fee];
        require(tickSpacing != 0);
        require(getPool[token0][token1][fee] == address(0));

        address elector;
        (pool, elector) = deploy(token0, token1, fee, tickSpacing);

        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
        _isWhitelisted[pool] = true;

        getElector[pool] = elector;

        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
        emit ElectorCreated(pool, elector);
    }

    function _whitelisted(address pool) internal view override returns (bool) {
        return _isWhitelisted[pool];
    }

    function collectBribe(address pool, address recipient, uint128 amountMax0, uint128 amountMax1) external returns (uint128, uint128) {
        require(getElector[pool] == msg.sender, "unauthorized");
        return UniswapV3Pool(pool).collectProtocol(recipient, amountMax0, amountMax1);
    }

    function enableFeeAmount(uint24 fee, int24 tickSpacing) public onlyOwner {
        require(fee <= 1e6);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }

    function getProtocolFeeRate(address pool) external view override returns (uint24) {
        ProtocolFee memory pf = _protocolFees[pool];
        if (pf.set) return pf.value;
        return defaultProtocolFee;
    }

    function resetFees(address pool) external onlyOwner {
        delete _protocolFees[pool];
        emit ProtocolFeeReset(pool);
    }

    function setProtocolFee(address pool, uint24 protocolFee) external onlyOwner {
        require(protocolFee <= 1e6);
        _protocolFees[pool] = ProtocolFee({value: protocolFee, set: true});
        emit ProtocolFeeUpdated(pool, protocolFee);
    }

    function setDefaultProtocolFee(uint24 protocolFee) external onlyOwner {
        require(protocolFee <= 1e6);
        defaultProtocolFee = protocolFee;
        emit DefaultProtocolFeeUpdated(protocolFee);
    }

    function exemptFee(address user, bool value) external onlyOwner {
        feeExempted[user] = value;
        emit FeeExempted(user, value);
    }
}
