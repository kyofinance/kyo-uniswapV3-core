// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IGauge {
    function rewardTotal() external returns (uint128);
    function claim(uint128 amount, address recipient) external;
}
