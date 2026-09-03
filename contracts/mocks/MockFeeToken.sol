// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeToken is ERC20 {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public immutable feeBps;

    error FeeBpsTooHigh();

    constructor(uint256 feeBps_) ERC20("Mock Fee Token", "mFEE") {
        if (feeBps_ > BPS_DENOMINATOR) revert FeeBpsTooHigh();
        feeBps = feeBps_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0 || value == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / BPS_DENOMINATOR;
        uint256 received = value - fee;

        if (fee > 0) {
            super._update(from, address(0), fee);
        }
        if (received > 0) {
            super._update(from, to, received);
        }
    }
}
