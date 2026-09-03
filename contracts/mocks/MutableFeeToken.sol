// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MutableFeeToken is ERC20 {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public senderFeeBps;
    uint256 public recipientFeeBps;

    error FeeBpsTooHigh();

    constructor() ERC20("Mutable Fee Token", "mMUT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFees(uint256 senderFeeBps_, uint256 recipientFeeBps_) external {
        if (senderFeeBps_ > BPS_DENOMINATOR || recipientFeeBps_ > BPS_DENOMINATOR) {
            revert FeeBpsTooHigh();
        }
        senderFeeBps = senderFeeBps_;
        recipientFeeBps = recipientFeeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 recipientFee = (value * recipientFeeBps) / BPS_DENOMINATOR;
        uint256 senderFee = (value * senderFeeBps) / BPS_DENOMINATOR;
        super._update(from, to, value - recipientFee);
        if (recipientFee + senderFee > 0) {
            super._update(from, address(0), recipientFee + senderFee);
        }
    }
}
