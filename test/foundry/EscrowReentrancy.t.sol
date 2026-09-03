// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";
import {MaliciousReentrantToken} from "../../contracts/mocks/MaliciousReentrantToken.sol";
import {MockManualArbitrator} from "../../contracts/mocks/MockManualArbitrator.sol";
import {EscrowFixture} from "./EscrowFixture.sol";

/**
 * @title EscrowReentrancy
 * @notice The escrow's own token is hostile, reentering on
 *         every transfer. Cheap in Foundry, awkward in the TS harness. Proves
 *         that under a reentering token every state-mutating reentrant payload
 *         fails (the nonReentrant guard holds) while conservation (I1) and
 *         custody (I4) survive - the outer call is armed to IGNORE the callback
 *         failure, so a missing guard would surface as a moved balance rather
 *         than a revert.
 * @dev Reentry fires inside safeTransfer/safeTransferFrom: the withdraw push
 *      and the openDeal/postBond/challenge pulls. Each test arms a payload,
 *      performs the triggering op, then asserts lastCallbackSucceeded == false.
 */
contract EscrowReentrancyTest is EscrowFixture {
    MaliciousReentrantToken internal token;
    MockManualArbitrator internal arbitrator;
    SinettiEscrowV04 internal escrow;

    uint256 internal constant SELLER_KEY = 0x5E11;
    uint256 internal constant BUYER_KEY = 0xB0B;
    address internal seller;
    address internal buyer;
    address internal verifier = address(0x5E7);
    uint256 internal saltNonce;

    function setUp() public {
        token = new MaliciousReentrantToken();
        arbitrator = new MockManualArbitrator();
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
            address(this),
            policies,
            new address[](0),
            new address[](0),
            60,
            60
        );

        token.mint(buyer, 10_000_000);
        token.mint(seller, 10_000_000);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(seller);
        token.approve(address(escrow), type(uint256).max);
    }

    function _openBasic(uint256 amount, uint256 bond) internal returns (uint256 dealId) {
        SinettiEscrowV04.SellerAcceptance memory terms = baseAcceptance(
            buyer,
            seller,
            verifier,
            address(arbitrator),
            address(token),
            amount,
            bond,
            amount, // challengerBond = amount, always in range
            keccak256(abi.encode("f3", saltNonce++))
        );
        bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), terms);
        vm.prank(buyer);
        escrow.openDeal(terms, sig);
        return escrow.nextDealId() - 1;
    }

    function _conservationHolds() internal view returns (bool) {
        uint256 credits = escrow.withdrawable(IERC20(address(token)), buyer)
            + escrow.withdrawable(IERC20(address(token)), seller);
        // No live deals remain in these single-deal scenarios by assertion time,
        // so liability is exactly the outstanding credits and is fully backed.
        uint256 liability = escrow.tokenLiability(IERC20(address(token)));
        return liability >= credits && token.balanceOf(address(escrow)) >= liability;
    }

    /// @dev A reentrant openDeal during the initial pull: the guard must reject
    ///      it, and (ignoring the failure) the outer open still succeeds with
    ///      exactly one deal minted, not two.
    function test_reentrantOpenDuringPullFails() public {
        SinettiEscrowV04.SellerAcceptance memory terms = baseAcceptance(
            buyer,
            seller,
            verifier,
            address(arbitrator),
            address(token),
            1000,
            0,
            1000,
            keccak256(abi.encode("f3-open", saltNonce++))
        );
        bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), terms);
        // Reenter on the transferFrom pull with a distinct, independently built
        // open (a memory-struct copy would alias terms and corrupt its salt).
        SinettiEscrowV04.SellerAcceptance memory inner = baseAcceptance(
            buyer,
            seller,
            verifier,
            address(arbitrator),
            address(token),
            1000,
            0,
            1000,
            keccak256("f3-inner")
        );
        bytes memory innerSig = signAcceptance(SELLER_KEY, address(escrow), inner);
        token.armIgnoringFailure(
            address(escrow),
            abi.encodeWithSelector(escrow.openDeal.selector, inner, innerSig),
            false, // before super.transfer completes (during the pull)
            true
        );
        uint256 idBefore = escrow.nextDealId();
        vm.prank(buyer);
        escrow.openDeal(terms, sig);
        // Read the latch BEFORE disarm(), which resets callbackDone.
        bool fired = token.callbackDone();
        bool callbackOk = token.lastCallbackSucceeded();
        token.disarm();

        assertTrue(fired, "the reentrant callback must have actually fired");
        assertTrue(!callbackOk, "reentrant openDeal must fail");
        assertEq(escrow.nextDealId(), idBefore + 1, "exactly one deal minted");
        assertTrue(_conservationHolds(), "I1 under reentrant open");
    }

    /// @dev The withdraw push is the classic reentrancy surface. Drive a deal
    ///      to a credited terminal state, then arm each state-mutating payload
    ///      to fire during the seller's withdraw; every one must fail and the
    ///      withdraw must still pay out exactly once.
    function test_reentrantPayloadsDuringWithdrawAllFail() public {
        bytes[] memory payloads = _withdrawPayloadMenu();
        for (uint256 i = 0; i < payloads.length; i++) {
            _runWithdrawReentry(payloads[i], i);
        }
    }

    function _withdrawPayloadMenu() internal view returns (bytes[] memory payloads) {
        payloads = new bytes[](4);
        // A second withdraw (the drain attempt).
        payloads[0] = abi.encodeWithSelector(
            bytes4(keccak256("withdraw(address)")),
            IERC20(address(token))
        );
        // finalize / claimTimeout / accept on an arbitrary id - all state-mutating
        // and all nonReentrant, so all must revert inside the callback.
        payloads[1] = abi.encodeWithSelector(escrow.finalize.selector, uint256(1));
        payloads[2] = abi.encodeWithSelector(escrow.claimTimeout.selector, uint256(1));
        payloads[3] = abi.encodeWithSelector(escrow.accept.selector, uint256(1));
    }

    function _runWithdrawReentry(bytes memory payload, uint256 index) internal {
        // Fresh deal each iteration, driven to timeout so the buyer is credited
        // the principal and the seller nothing (bond 0).
        uint256 amount = 1000 + index;
        uint256 dealId = _openBasic(amount, 0);
        vm.warp(block.timestamp + 31 days);
        escrow.claimTimeout(dealId);

        uint256 buyerCreditBefore = escrow.withdrawable(IERC20(address(token)), buyer);
        assertEq(buyerCreditBefore, amount, "buyer credited principal");
        uint256 walletBefore = token.balanceOf(buyer);

        token.armIgnoringFailure(address(escrow), payload, false, true);
        vm.prank(buyer);
        escrow.withdraw(IERC20(address(token)));
        bool fired = token.callbackDone();
        bool callbackOk = token.lastCallbackSucceeded();
        token.disarm();

        assertTrue(fired, "the reentrant callback must have actually fired");
        assertTrue(!callbackOk, "reentrant payload must fail under the guard");
        assertEq(
            token.balanceOf(buyer) - walletBefore,
            amount,
            "withdraw paid out exactly once"
        );
        assertEq(
            escrow.withdrawable(IERC20(address(token)), buyer),
            0,
            "credit fully cleared, not double-spent"
        );
        assertTrue(_conservationHolds(), "I1 under reentrant withdraw");
    }
}
