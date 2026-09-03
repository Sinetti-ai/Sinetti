// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MaliciousArbitrator} from "../../contracts/mocks/MaliciousArbitrator.sol";
import {MockManualArbitrator} from "../../contracts/mocks/MockManualArbitrator.sol";
import {EscrowFixture} from "./EscrowFixture.sol";

/**
 * @title EscrowArbitratorTest
 * @notice The arbitrator trust boundary (deploy-gating). The escrow trusts
 *         whatever arbitrator a deal names to call `submitRuling`; this suite
 *         drives disputes through a deliberately misbehaving arbitrator and
 *         proves every abuse is rejected with the exact guard error while
 *         conservation holds, plus that the escrow never depends on - or even
 *         calls - the arbitrator.
 * @dev Follows the solidity-fuzzing skill's no-vacuous-pass discipline: each
 *      abuse asserts the exact expected error (a bare expectRevert would pass on
 *      any revert, including a broken setup), and the independence test asserts
 *      the deal actually settled AND the arbitrator flag is false.
 */
contract EscrowArbitratorTest is EscrowFixture {
    MockUSDC internal token;
    MaliciousArbitrator internal evil;
    MockManualArbitrator internal honest;
    SinettiEscrowV04 internal escrow;

    uint256 internal constant SELLER_KEY = 0x5E11;
    uint256 internal constant BUYER_KEY = 0xB0B;
    address internal seller;
    address internal buyer;
    address internal verifier = address(0x5E7);
    uint256 internal saltNonce;

    function setUp() public {
        token = new MockUSDC();
        evil = new MaliciousArbitrator();
        honest = new MockManualArbitrator();
        seller = vm.addr(SELLER_KEY);
        buyer = vm.addr(BUYER_KEY);

        SinettiEscrowV04.TokenPolicy[] memory policies = new SinettiEscrowV04.TokenPolicy[](1);
        policies[0] = SinettiEscrowV04.TokenPolicy({
            token: IERC20(address(token)),
            maxAmount: 1_000_000,
            maxBond: 1_000_000,
            minBondBps: 0,
            minChallengerBondBps: 0
        });
        escrow = new SinettiEscrowV04(
            address(this), policies, new address[](0), new address[](0), 60, 60
        );

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? buyer : seller;
            token.mint(who, 100_000_000);
            vm.prank(who);
            token.approve(address(escrow), type(uint256).max);
        }
    }

    /// @dev Open a deal and drive it to Disputed with `arbitrator`, verdict Fail,
    ///      the seller challenging (the disadvantaged party on a Fail).
    function _openDisputed(address arbitrator) internal returns (uint256 dealId) {
        SinettiEscrowV04.SellerAcceptance memory terms = baseAcceptance(
            buyer, seller, verifier, arbitrator, address(token),
            1000, 0, 1000, keccak256(abi.encode("arb", saltNonce++))
        );
        bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), terms);
        vm.prank(buyer);
        escrow.openDeal(terms, sig);
        dealId = escrow.nextDealId() - 1;

        vm.prank(seller);
        escrow.submitDelivery(dealId, keccak256("delivery"));
        vm.prank(verifier);
        escrow.recordVerification(dealId, 2); // Fail
        vm.prank(seller);
        escrow.challenge(dealId);
        assertEq(uint256(uint8(escrow.getDeal(dealId).state)), 4, "deal should be Disputed");
    }

    function _backed() internal view {
        assertGe(
            token.balanceOf(address(escrow)),
            escrow.tokenLiability(IERC20(address(token))),
            "escrow balance must back its liability"
        );
    }

    /// A ruling on a deal this arbitrator does not arbitrate is rejected.
    function test_rejectsRulingOnADealItDoesNotArbitrate() public {
        uint256 mine = _openDisputed(address(evil));
        uint256 theirs = _openDisputed(address(honest));
        // evil is not `theirs`'s arbitrator.
        vm.expectRevert(SinettiEscrowV04.NotArbitrator.selector);
        evil.rule(address(escrow), theirs, 1);
        // mine is still open and untouched.
        assertEq(uint256(uint8(escrow.getDeal(mine).state)), 4, "untouched deal moved");
        _backed();
    }

    /// Invalid outcomes (None / out-of-range) are rejected.
    function test_rejectsInvalidOutcomes() public {
        uint256 dealId = _openDisputed(address(evil));
        vm.expectRevert(SinettiEscrowV04.InvalidOutcome.selector);
        evil.rule(address(escrow), dealId, 0);
        vm.expectRevert(SinettiEscrowV04.InvalidOutcome.selector);
        evil.rule(address(escrow), dealId, 3);
        assertEq(uint256(uint8(escrow.getDeal(dealId).state)), 4, "invalid outcome moved the deal");
        _backed();
    }

    /// A second ruling after a legitimate one is rejected (double-rule).
    function test_rejectsDoubleRuling() public {
        uint256 dealId = _openDisputed(address(evil));
        // A single legitimate Release settles it.
        evil.rule(address(escrow), dealId, 1);
        assertEq(uint256(uint8(escrow.getDeal(dealId).state)), 5, "deal should be Released");
        // Any further ruling is rejected - the deal is no longer Disputed.
        vm.expectRevert(SinettiEscrowV04.DealNotDisputed.selector);
        evil.rule(address(escrow), dealId, 2);
        _backed();
    }

    /// Two rulings in one transaction: the second reverts and unwinds the whole tx.
    function test_rejectsAtomicDoubleRuling() public {
        uint256 dealId = _openDisputed(address(evil));
        vm.expectRevert(SinettiEscrowV04.DealNotDisputed.selector);
        evil.ruleTwice(address(escrow), dealId, 1, 2);
        // The revert unwound the first ruling too: still Disputed.
        assertEq(uint256(uint8(escrow.getDeal(dealId).state)), 4, "atomic double-rule half-applied");
        _backed();
    }

    /// A ruling after the ruling deadline is rejected.
    function test_rejectsLateRuling() public {
        uint256 dealId = _openDisputed(address(evil));
        (, uint64 deadline) = escrow.disputes(dealId);
        vm.warp(deadline);
        vm.expectRevert(SinettiEscrowV04.RulingDeadlinePassed.selector);
        evil.rule(address(escrow), dealId, 1);
        _backed();
    }

    /// A ruling on a non-disputed deal is rejected.
    function test_rejectsRulingOnNonDisputedDeal() public {
        SinettiEscrowV04.SellerAcceptance memory terms = baseAcceptance(
            buyer, seller, verifier, address(evil), address(token),
            1000, 0, 1000, keccak256(abi.encode("arb", saltNonce++))
        );
        bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), terms);
        vm.prank(buyer);
        escrow.openDeal(terms, sig);
        uint256 dealId = escrow.nextDealId() - 1;
        vm.prank(seller);
        escrow.submitDelivery(dealId, keccak256("delivery"));
        vm.prank(verifier);
        escrow.recordVerification(dealId, 1); // Pass, never challenged -> Verified
        // The arbitrator has no standing on a deal that was never disputed.
        vm.expectRevert(SinettiEscrowV04.DealNotDisputed.selector);
        evil.rule(address(escrow), dealId, 1);
        _backed();
    }

    /// Independence: a silent (or hostile) arbitrator cannot strand a dispute,
    /// and the escrow settles the lapse without ever calling the arbitrator.
    function test_escrowSettlesWithoutCallingTheArbitrator() public {
        uint256 dealId = _openDisputed(address(evil));
        (, uint64 deadline) = escrow.disputes(dealId);
        vm.warp(deadline);
        // The arbitrator never ruled; anyone finalizes the lapse.
        escrow.finalize(dealId);
        // Standing verdict was Fail -> Refunded.
        assertEq(uint256(uint8(escrow.getDeal(dealId).state)), 6, "lapse should refund");
        // The escrow never touched the arbitrator - that independence is what
        // makes a hostile arbitrator harmless beyond its one (rejected) ruling.
        assertTrue(!evil.called(), "escrow must never call the arbitrator");
        // Conservation after settlement: liability is exactly the credited funds.
        uint256 credits = escrow.withdrawable(IERC20(address(token)), buyer)
            + escrow.withdrawable(IERC20(address(token)), seller);
        assertEq(
            escrow.tokenLiability(IERC20(address(token))), credits,
            "settled liability != credits"
        );
        _backed();
    }
}
