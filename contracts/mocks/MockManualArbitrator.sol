// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IArbitratorV04} from "../interfaces/IArbitratorV04.sol";

interface IEscrowRuling {
    function submitRuling(uint256 dealId, uint8 rawOutcome) external;
}

/// @notice Test fixture: an arbitrator whose ruling is driven directly by the test.
contract MockManualArbitrator is IArbitratorV04 {
    function ARBITRATOR_MARKER() external pure returns (bytes32) {
        return keccak256("sinetti.arbitrator.v04");
    }

    function rule(address escrow, uint256 dealId, uint8 outcome) external {
        IEscrowRuling(escrow).submitRuling(dealId, outcome);
    }
}
