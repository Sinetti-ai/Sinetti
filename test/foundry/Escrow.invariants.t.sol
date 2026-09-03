// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FuzzBase} from "./lib/minstd/FuzzBase.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockManualArbitrator} from "../../contracts/mocks/MockManualArbitrator.sol";
import {EscrowHandler, IMintableERC20} from "./EscrowHandler.sol";

/**
 * @title EscrowInvariants
 * @notice A Solidity re-implementation of the invariant scan
 *         the TS campaign runs, written by a second author against the same
 *         contract. If the TS harness's checkInvariants has a bug (a wrong
 *         checker passes everything), this catches it, and native fuzzing
 *         reaches call orderings the TS chooser weights away from.
 *
 *         I1 conservation: tokenLiability == sum(credits) + live custody, and
 *                          the real balance covers the liability.
 *         I2 immutability:  a terminal deal never changes (handler-latched).
 *         I3 liveness:      afterInvariant drains every live deal to terminal.
 *         I4 custody:       no credit drops except the owner's own withdrawal
 *                          (handler-latched per step).
 */
contract EscrowInvariantsTest is FuzzBase {
    SinettiEscrowV04 internal escrow;
    MockUSDC internal token;
    MockManualArbitrator internal arbitrator;
    EscrowHandler internal handler;
    address internal verifier;

    function setUp() public {
        token = new MockUSDC();
        arbitrator = new MockManualArbitrator();
        verifier = vm.addr(0x171F1E5);

        SinettiEscrowV04.TokenPolicy[] memory policies = new SinettiEscrowV04.TokenPolicy[](1);
        policies[0] = SinettiEscrowV04.TokenPolicy({
            token: IERC20(address(token)),
            maxAmount: 1_000_000,
            maxBond: 1_000_000,
            // Real floors so the slash and loser-pays branches move real value.
            minBondBps: 500,
            minChallengerBondBps: 200
        });
        escrow = new SinettiEscrowV04(
            address(this),
            policies,
            new address[](0),
            new address[](0),
            60,
            60
        );
        handler = new EscrowHandler(
            escrow,
            IMintableERC20(address(token)),
            arbitrator,
            verifier
        );

        // Only the handler drives the escrow; forge fuzzes its op selectors.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.opOpenDeal.selector;
        selectors[1] = handler.opPostBond.selector;
        selectors[2] = handler.opSubmitDelivery.selector;
        selectors[3] = handler.opRecordVerification.selector;
        selectors[4] = handler.opAccept.selector;
        selectors[5] = handler.opChallenge.selector;
        selectors[6] = handler.opRule.selector;
        selectors[7] = handler.opFinalize.selector;
        selectors[8] = handler.opClaimTimeout.selector;
        selectors[9] = handler.opWithdraw.selector;
        selectors[10] = handler.opWarp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Forge reverts to this post-setUp snapshot between runs, so seeding a
        // few opens here guarantees every run starts from a non-empty world -
        // the afterInvariant drain and its vacuity guard then always have
        // material, instead of depending on a run happening to pick opOpenDeal.
        for (uint256 i = 0; i < 3; i++) {
            handler.opOpenDeal(uint256(keccak256(abi.encode("seed", i))));
        }
    }

    /// @dev I1 + I4: full conservation from live chain state, plus the latched
    ///      per-step custody flag. Recomputed here independently of the handler.
    function invariant_conservationAndCustody() public view {
        assertTrue(!handler.custodyViolated(), "I4: a credit dropped without its owner withdrawing");

        uint256 creditSum;
        uint256 actorCount = handler.actorCount();
        for (uint256 i = 0; i < actorCount; i++) {
            creditSum += escrow.withdrawable(IERC20(address(token)), handler.actorAt(i));
        }

        uint256 escrowed;
        uint256 dealCount = handler.dealCount();
        for (uint256 i = 0; i < dealCount; i++) {
            SinettiEscrowV04.Deal memory deal = escrow.getDeal(handler.dealIds(i));
            uint8 state = uint8(deal.state);
            if (state >= 5) continue;
            escrowed += deal.amount;
            if (deal.bondPosted) escrowed += deal.bond;
            if (state == 4) escrowed += deal.challengerBond;
        }

        uint256 liability = escrow.tokenLiability(IERC20(address(token)));
        assertEq(liability, creditSum + escrowed, "I1: liability != credits + live custody");
        assertGe(token.balanceOf(address(escrow)), liability, "I1: balance under-backs liability");
    }

    /// @dev I2: every deal the handler saw reach a terminal state is unchanged.
    function invariant_terminalImmutability() public view {
        uint256 dealCount = handler.dealCount();
        for (uint256 i = 0; i < dealCount; i++) {
            uint256 dealId = handler.dealIds(i);
            if (!handler.hasTerminalSnapshot(dealId)) continue;
            SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
            assertEq(uint256(uint8(deal.state)), uint256(handler.terminalState(dealId)), "I2: terminal state changed");
            assertEq(uint256(deal.revision), uint256(handler.terminalRevision(dealId)), "I2: terminal revision changed");
        }
    }

    /// @dev I3 liveness: after the run, warp past every clock and drive each
    ///      live deal to terminal; conservation must still hold. A vacuity
    ///      guard fails the run if the handler never actually opened a deal
    ///      (an empty world proves nothing).
    function afterInvariant() public {
        assertTrue(handler.openedTotal() > 0, "vacuity: no deal was ever opened");
        vm.warp(block.timestamp + 500 days);

        uint256 dealCount = handler.dealCount();
        for (uint256 i = 0; i < dealCount; i++) {
            uint256 dealId = handler.dealIds(i);
            SinettiEscrowV04.Deal memory deal = escrow.getDeal(dealId);
            uint8 state = uint8(deal.state);
            if (state >= 5 || state == 0) continue;
            if (state == 1 || state == 2) {
                escrow.claimTimeout(dealId);
            } else {
                escrow.finalize(dealId);
            }
            assertGe(uint256(uint8(escrow.getDeal(dealId).state)), 5, "I3: deal not drainable to terminal");
        }

        // Conservation holds after the drain, with no deal in live custody.
        uint256 creditSum;
        uint256 actorCount = handler.actorCount();
        for (uint256 i = 0; i < actorCount; i++) {
            creditSum += escrow.withdrawable(IERC20(address(token)), handler.actorAt(i));
        }
        assertEq(
            escrow.tokenLiability(IERC20(address(token))),
            creditSum,
            "I3: drained liability != credits"
        );
    }
}
