// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IArbitratorV04} from "../interfaces/IArbitratorV04.sol";

interface IEscrowRuling {
    function submitRuling(uint256 dealId, uint8 rawOutcome) external;
}

/**
 * @title MaliciousArbitrator
 * @notice Test fixture: a real, admitted arbitrator (answers ARBITRATOR_MARKER)
 *         that misbehaves. The escrow trusts whatever arbitrator a deal names to
 *         call `submitRuling`, so this fixture attempts every abuse a compromised
 *         arbitrator could - ruling twice, ruling on a deal it does not
 *         arbitrate, ruling an invalid outcome - and the escrow's guards must
 *         reject each one. `rule` is the legitimate single call.
 * @dev The escrow NEVER calls into an arbitrator. This fixture's
 *      fallback sets a flag (without reverting, so the flag survives) so a test
 *      can prove the escrow drove a full dispute to settlement without ever
 *      touching the arbitrator - the escrow's independence from arbitrator
 *      behaviour, which is what makes a hostile arbitrator harmless beyond its
 *      one ruling.
 */
contract MaliciousArbitrator is IArbitratorV04 {
    bool public called;

    function ARBITRATOR_MARKER() external pure returns (bytes32) {
        return keccak256("sinetti.arbitrator.v04");
    }

    /// @notice The legitimate ruling: a single submitRuling.
    function rule(address escrow, uint256 dealId, uint8 outcome) external {
        IEscrowRuling(escrow).submitRuling(dealId, outcome);
    }

    /// @notice Abuse: rule the same deal twice in one transaction. The escrow's
    ///         state guard must reject the second (the first left Disputed).
    function ruleTwice(address escrow, uint256 dealId, uint8 first, uint8 second) external {
        IEscrowRuling(escrow).submitRuling(dealId, first);
        IEscrowRuling(escrow).submitRuling(dealId, second);
    }

    // The escrow must never call the arbitrator; record it if it ever does,
    // without reverting so the flag persists for the test to observe.
    fallback() external payable {
        called = true;
    }

    receive() external payable {
        called = true;
    }
}
