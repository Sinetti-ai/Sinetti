// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IArbitratorV04} from "./interfaces/IArbitratorV04.sol";

interface ISinettiEscrowRuling {
    enum State {
        None,
        Funded,
        Delivered,
        Verified,
        Disputed,
        Released,
        Refunded,
        Cancelled
    }

    enum Verdict {
        None,
        Pass,
        Fail,
        Inconclusive
    }

    struct Deal {
        address buyer;
        address seller;
        address verifier;
        address arbitrator;
        address token;
        uint256 amount;
        uint256 bond;
        uint256 challengerBond;
        bytes32 termsHash;
        bytes32 buyerIdentityRef;
        bytes32 sellerIdentityRef;
        bytes32 verifierIdentityRef;
        bytes32 arbitratorIdentityRef;
        bytes32 evidenceHash;
        uint64 deadline;
        uint64 challengeWindow;
        uint64 rulingWindow;
        uint32 revision;
        uint64 verifiedAt;
        State state;
        Verdict verdict;
        bool bondPosted;
    }

    function getDeal(uint256 dealId) external view returns (Deal memory);
    function disputes(uint256 dealId) external view returns (address challenger, uint64 rulingDeadline);
    function submitRuling(uint256 dealId, uint8 rawOutcome) external;
}

/**
 * @title ConsoleArbitrator
 * @notice The day-one arbitrator for SinettiEscrowV04: the operations agent posts a
 *         proposed ruling, a named human officer may overturn it inside a fixed
 *         override window, and after the window anyone may push the standing outcome
 *         to the escrow. This reference offers a human escalation layer, deliberately
 *         living OUTSIDE the immutable escrow so it can be replaced per deal without
 *         a redeploy.
 * @notice A proposal can only start for a live Disputed deal whose signed terms
 *         name this contract as arbitrator; the officer clock cannot run early.
 * @dev A deal's signed rulingWindow must exceed this contract's proposal latency plus
 *      {overrideWindow}, or the escrow's lapse fallback can fire before push().
 */
contract ConsoleArbitrator is IArbitratorV04 {
    /// @dev Outcome values mirror SinettiEscrowV04.Outcome: 1 = Release, 2 = Refund.
    struct Proposal {
        uint8 outcome;
        uint64 proposedAt;
        bool pushed;
    }

    /// @notice Minimum time reserved for human officer review.
    uint64 public constant MIN_OVERRIDE_WINDOW = 1 days;

    /// @notice Minimum time left after human review for a permissionless push.
    uint64 public constant MIN_PUSH_BUFFER = 1 hours;

    /// @notice Upper bound on the officer's veto window.
    /// @dev Two reasons. A window longer than the deal's signed `rulingWindow`
    ///      guarantees the escrow's lapse fallback fires before {push} can land,
    ///      and an unbounded value overflows `proposedAt + overrideWindow`, which
    ///      panics instead of reverting cleanly. Neither risks funds - the escrow
    ///      settles a lapsed dispute on its own - but both are silent traps, so
    ///      the constructor refuses them.
    uint64 public constant MAX_OVERRIDE_WINDOW = 30 days;

    ISinettiEscrowRuling public immutable escrow;
    address public immutable agentKey;
    address public immutable officer;
    uint64 public immutable overrideWindow;

    mapping(uint256 => Proposal) public proposals;

    error ZeroAddress();
    error OverrideWindowTooShort();
    error OverrideWindowTooLong();
    error NotAgent();
    error NotOfficer();
    error InvalidOutcome();
    error AlreadyProposed();
    error DealNotDisputed(uint256 dealId, uint8 actualState);
    error DealUsesDifferentArbitrator(uint256 dealId, address actualArbitrator);
    error InvalidDisputeRecord(uint256 dealId);
    error InsufficientRulingTime(uint256 dealId, uint64 rulingDeadline, uint256 requiredUntil);
    error NothingProposed();
    error OverrideWindowClosed();
    error OverrideWindowOpen();
    error AlreadyPushed();

    event RulingProposed(uint256 indexed dealId, uint8 outcome, uint64 overridableUntil);
    event RulingOverturned(uint256 indexed dealId, uint8 outcome);
    event RulingPushed(uint256 indexed dealId, uint8 outcome);

    constructor(
        ISinettiEscrowRuling escrow_,
        address agentKey_,
        address officer_,
        uint64 overrideWindow_
    ) {
        if (
            address(escrow_) == address(0) ||
            agentKey_ == address(0) ||
            officer_ == address(0)
        ) revert ZeroAddress();
        if (overrideWindow_ < MIN_OVERRIDE_WINDOW) revert OverrideWindowTooShort();
        if (overrideWindow_ > MAX_OVERRIDE_WINDOW) revert OverrideWindowTooLong();
        escrow = escrow_;
        agentKey = agentKey_;
        officer = officer_;
        overrideWindow = overrideWindow_;
    }

    function ARBITRATOR_MARKER() external pure returns (bytes32) {
        return keccak256("sinetti.arbitrator.v04");
    }

    /**
     * @notice The agent's proposed ruling. Starts the officer's override clock.
     */
    // reentrancy-safe: the immutable escrow is queried before any write. getDeal
    // is `external view` (STATICCALL), so even a hostile target cannot re-enter
    // and mutate this proposal mapping.
    function propose(uint256 dealId, uint8 outcome) external {
        if (msg.sender != agentKey) revert NotAgent();
        if (outcome != 1 && outcome != 2) revert InvalidOutcome();
        Proposal storage proposal = proposals[dealId];
        if (proposal.proposedAt != 0) revert AlreadyProposed();

        ISinettiEscrowRuling.Deal memory deal = escrow.getDeal(dealId);
        if (deal.state != ISinettiEscrowRuling.State.Disputed) {
            revert DealNotDisputed(dealId, uint8(deal.state));
        }
        if (deal.arbitrator != address(this)) {
            revert DealUsesDifferentArbitrator(dealId, deal.arbitrator);
        }
        (address challenger, uint64 rulingDeadline) = escrow.disputes(dealId);
        if (challenger == address(0)) revert InvalidDisputeRecord(dealId);
        uint256 requiredUntil = block.timestamp + overrideWindow + MIN_PUSH_BUFFER;
        if (rulingDeadline < requiredUntil) {
            revert InsufficientRulingTime(dealId, rulingDeadline, requiredUntil);
        }

        proposal.outcome = outcome;
        proposal.proposedAt = uint64(block.timestamp);
        emit RulingProposed(dealId, outcome, uint64(block.timestamp) + overrideWindow);
    }

    /**
     * @notice The officer's veto: replace the proposed outcome while the override
     *         window is open. May be exercised more than once; the last stands.
     */
    // reentrancy-safe: no external calls; rewrites the proposal outcome and emits.
    function overturn(uint256 dealId, uint8 outcome) external {
        if (msg.sender != officer) revert NotOfficer();
        if (outcome != 1 && outcome != 2) revert InvalidOutcome();
        Proposal storage proposal = proposals[dealId];
        if (proposal.proposedAt == 0) revert NothingProposed();
        if (block.timestamp >= proposal.proposedAt + overrideWindow) {
            revert OverrideWindowClosed();
        }

        proposal.outcome = outcome;
        emit RulingOverturned(dealId, outcome);
    }

    /**
     * @notice After the override window, anyone relays the standing outcome to the
     *         escrow. Permissionless so a stalled submitter cannot strand a ruling.
     */
    // reentrancy-safe: the pushed flag is set before the only external call, and the
    // escrow target is immutable and itself nonReentrant on submitRuling.
    function push(uint256 dealId) external {
        Proposal storage proposal = proposals[dealId];
        if (proposal.proposedAt == 0) revert NothingProposed();
        if (block.timestamp < proposal.proposedAt + overrideWindow) {
            revert OverrideWindowOpen();
        }
        if (proposal.pushed) revert AlreadyPushed();

        proposal.pushed = true;
        emit RulingPushed(dealId, proposal.outcome);
        escrow.submitRuling(dealId, proposal.outcome);
    }
}
