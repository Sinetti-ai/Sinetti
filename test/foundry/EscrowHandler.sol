// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";
import {MockManualArbitrator} from "../../contracts/mocks/MockManualArbitrator.sol";
import {EscrowFixture} from "./EscrowFixture.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title EscrowHandler
 * @notice Invariant handler: a second author's random
 *         driver for SinettiEscrowV04. State is re-read from the chain
 *         wherever the chain can answer (withdrawable, tokenLiability,
 *         getDeal, balanceOf); ghosts exist only for what the chain cannot
 *         enumerate - the deal-id list, terminal (state,revision) snapshots
 *         for I2, and the previous-credit table for per-step I4.
 * @dev fail_on_revert is false, so a reverting handler frame (a wrong-state
 *      probe) is data, not failure - and therefore NO CHECK in this contract
 *      may revert. Violations latch flags that the invariant functions
 *      assert; a require here would be silently swallowed.
 */
contract EscrowHandler is EscrowFixture {
    SinettiEscrowV04 public immutable escrow;
    IMintableERC20 public immutable token;
    MockManualArbitrator public immutable arbitrator;
    address public immutable verifier;

    uint256[] internal buyerKeys;
    uint256[] internal sellerKeys;
    address[] internal actorList;

    uint256[] public dealIds;
    mapping(uint256 => bool) public hasTerminalSnapshot;
    mapping(uint256 => uint8) public terminalState;
    mapping(uint256 => uint32) public terminalRevision;
    mapping(address => uint256) public prevCredit;

    /// @notice Latched I4 violation: somebody's credit dropped without their withdrawal.
    bool public custodyViolated;
    /// @notice Successful opens, for the afterInvariant vacuity guard.
    uint256 public openedTotal;
    uint256 internal saltNonce;

    uint256 internal constant MAX_AMOUNT = 1_000_000;

    constructor(
        SinettiEscrowV04 escrow_,
        IMintableERC20 token_,
        MockManualArbitrator arbitrator_,
        address verifier_
    ) {
        escrow = escrow_;
        token = token_;
        arbitrator = arbitrator_;
        verifier = verifier_;

        // Two buyers, two sellers, keys known so acceptances can be signed
        // in-handler through the re-declared typehash.
        for (uint256 i = 0; i < 2; i++) {
            buyerKeys.push(0xB0B0 + i);
            sellerKeys.push(0x5E11 + i);
        }
        for (uint256 i = 0; i < 2; i++) {
            actorList.push(vm.addr(buyerKeys[i]));
            actorList.push(vm.addr(sellerKeys[i]));
        }
        actorList.push(verifier_);
        for (uint256 i = 0; i < actorList.length; i++) {
            token_.mint(actorList[i], MAX_AMOUNT * 1_000);
            vm.prank(actorList[i]);
            token_.approve(address(escrow_), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actorList.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actorList[index];
    }

    function dealCount() external view returns (uint256) {
        return dealIds.length;
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        return min + (x % (max - min + 1));
    }

    function _pickDeal(uint256 seed) internal view returns (uint256) {
        // Returns 0 (never a real id: ids start at 1) when no deal exists;
        // callers then revert on the escrow's own guard, which is fine.
        if (dealIds.length == 0) return 0;
        return dealIds[seed % dealIds.length];
    }

    function _signer(uint256 seed, uint256[] storage keys) internal view returns (uint256) {
        return keys[seed % keys.length];
    }

    /// @dev Post-op bookkeeping: per-step I4 (latched) plus terminal snapshots
    ///      for I2. Runs only when the op itself succeeded.
    function _afterOp(address withdrawer) internal virtual {
        for (uint256 i = 0; i < actorList.length; i++) {
            address actor = actorList[i];
            uint256 credit = escrow.withdrawable(IERC20(escrowToken()), actor);
            if (credit < prevCredit[actor] && actor != withdrawer) {
                custodyViolated = true;
            }
            prevCredit[actor] = credit;
        }
        for (uint256 i = 0; i < dealIds.length; i++) {
            uint256 dealId = dealIds[i];
            if (hasTerminalSnapshot[dealId]) continue;
            SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
            if (uint8(deal.state) >= 5) {
                hasTerminalSnapshot[dealId] = true;
                terminalState[dealId] = uint8(deal.state);
                terminalRevision[dealId] = deal.revision;
            }
        }
    }

    function escrowToken() public view virtual returns (address) {
        return address(token);
    }

    // ------------------------------------------------------------------ ops

    function opOpenDeal(uint256 seed) external virtual {
        uint256 buyerKey = _signer(seed, buyerKeys);
        uint256 sellerKey = _signer(seed >> 8, sellerKeys);
        uint256 amount = _bound(seed >> 16, 1, MAX_AMOUNT);
        uint256 minBond = ceilBps(amount, escrow.minBondBpsOf(IERC20(escrowToken())));
        uint256 bond = (seed >> 48) % 4 == 0 && minBond == 0
            ? 0
            : _bound(seed >> 64, minBond, minBond + MAX_AMOUNT / 4);
        uint256 minChallenger = ceilBps(
            amount,
            escrow.minChallengerBondBpsOf(IERC20(escrowToken()))
        );
        if (minChallenger == 0) minChallenger = 1;
        uint256 challengerBond = _bound(seed >> 96, minChallenger, amount < minChallenger ? minChallenger : amount);

        SinettiEscrowV04.SellerAcceptance memory terms = baseAcceptance(
            vm.addr(buyerKey),
            vm.addr(sellerKey),
            verifier,
            address(arbitrator),
            escrowToken(),
            amount,
            bond,
            challengerBond,
            keccak256(abi.encode("handler-salt", saltNonce++))
        );
        terms.duration = uint64(_bound(seed >> 128, 300, 30 days));
        terms.challengeWindow = uint64(_bound(seed >> 160, 60, 7200));
        terms.rulingWindow = uint64(_bound(seed >> 192, 60, 7200));

        bytes memory signature = signAcceptance(sellerKey, address(escrow), terms);
        vm.prank(terms.buyer);
        escrow.openDeal(terms, signature);
        dealIds.push(escrow.nextDealId() - 1);
        openedTotal++;
        _afterOp(address(0));
    }

    function opPostBond(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
        vm.prank(deal.seller);
        escrow.postBond(dealId);
        _afterOp(address(0));
    }

    function opSubmitDelivery(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
        vm.prank(deal.seller);
        escrow.submitDelivery(dealId, keccak256("delivery"));
        _afterOp(address(0));
    }

    function opRecordVerification(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        uint8 verdict = uint8(_bound(seed >> 8, 1, 3));
        vm.prank(verifier);
        escrow.recordVerification(dealId, verdict);
        _afterOp(address(0));
    }

    function opAccept(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
        vm.prank(deal.buyer);
        escrow.accept(dealId);
        _afterOp(address(0));
    }

    function opChallenge(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
        // Only the disadvantaged party is admissible; anyone else is a probe.
        address challenger = deal.verdict == SinettiEscrowV04.Verdict.Pass
            ? deal.buyer
            : deal.seller;
        vm.prank(challenger);
        escrow.challenge(dealId);
        _afterOp(address(0));
    }

    function opRule(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        uint8 outcome = uint8(_bound(seed >> 8, 1, 2));
        arbitrator.rule(address(escrow), dealId, outcome);
        _afterOp(address(0));
    }

    function opFinalize(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        escrow.finalize(dealId);
        _afterOp(address(0));
    }

    function opClaimTimeout(uint256 seed) external {
        uint256 dealId = _pickDeal(seed);
        escrow.claimTimeout(dealId);
        _afterOp(address(0));
    }

    function opWithdraw(uint256 seed) external {
        address actor = actorList[seed % actorList.length];
        uint256 credit = escrow.withdrawable(IERC20(escrowToken()), actor);
        if ((seed >> 8) % 2 == 0 && credit > 1) {
            uint256 part = _bound(seed >> 16, 1, credit);
            vm.prank(actor);
            escrow.withdraw(IERC20(escrowToken()), part);
        } else {
            vm.prank(actor);
            escrow.withdraw(IERC20(escrowToken()));
        }
        _afterOp(actor);
    }

    function opWarp(uint256 seed) external {
        // Mostly short hops; occasional leaps past ruling deadlines and
        // deal deadlines so lapse and timeout branches stay reachable.
        uint256 jump = seed % 5 == 0
            ? _bound(seed >> 8, 1 hours, 40 days)
            : _bound(seed >> 8, 1, 2 hours);
        vm.warp(block.timestamp + jump);
        _afterOp(address(0));
    }
}
