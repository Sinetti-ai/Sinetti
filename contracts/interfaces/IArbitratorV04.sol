// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title IArbitratorV04
 * @notice Marker interface for SinettiEscrowV04 arbitrator contracts.
 * @dev The escrow NEVER calls into an arbitrator (an arbitrator that
 *      could revert inside challenge() would be a griefing lever). Arbitrators learn
 *      of disputes from the escrow's `Challenged` event and answer through the
 *      escrow's one inbound `submitRuling` function. This marker exists for the
 *      deploy script's off-chain admission check and for tooling.
 */
interface IArbitratorV04 {
    /// @return The constant keccak256("sinetti.arbitrator.v04").
    function ARBITRATOR_MARKER() external view returns (bytes32);
}
