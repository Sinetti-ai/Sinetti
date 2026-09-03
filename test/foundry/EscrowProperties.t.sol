// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockManualArbitrator} from "../../contracts/mocks/MockManualArbitrator.sol";
import {EscrowFixture} from "./EscrowFixture.sol";

/**
 * @title EscrowProperties
 * @notice Stateless property fuzzing of the pure validation
 *         math, driven against the LIVE openDeal/constructor so the properties
 *         bind to real behaviour, not a re-derivation. Native fuzzing sweeps
 *         input ranges the scenario harness never enumerates.
 */
contract EscrowPropertiesTest is EscrowFixture {
    MockUSDC internal token;
    MockManualArbitrator internal arbitrator;
    uint256 internal constant SELLER_KEY = 0x5E11E5;
    uint256 internal constant BUYER_KEY = 0xB0B;
    address internal seller;
    address internal buyer;
    address internal verifier = address(0x5E7);
    uint256 internal saltNonce;

    function setUp() public {
        token = new MockUSDC();
        arbitrator = new MockManualArbitrator();
        seller = vm.addr(SELLER_KEY);
        buyer = vm.addr(BUYER_KEY);
    }

    function _deploy(
        uint256 maxAmount,
        uint256 maxBond,
        uint16 minBondBps,
        uint16 minChallengerBondBps
    ) internal returns (SinettiEscrowV04) {
        SinettiEscrowV04.TokenPolicy[] memory policies = new SinettiEscrowV04.TokenPolicy[](1);
        policies[0] = SinettiEscrowV04.TokenPolicy({
            token: IERC20(address(token)),
            maxAmount: maxAmount,
            maxBond: maxBond,
            minBondBps: minBondBps,
            minChallengerBondBps: minChallengerBondBps
        });
        return new SinettiEscrowV04(address(this), policies, new address[](0), new address[](0), 60, 60);
    }

    function _fund(SinettiEscrowV04 escrow) internal {
        token.mint(buyer, type(uint128).max);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _open(
        SinettiEscrowV04 escrow,
        SinettiEscrowV04.SellerAcceptance memory terms
    ) internal {
        bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), terms);
        vm.prank(buyer);
        escrow.openDeal(terms, sig);
    }

    function _terms(
        SinettiEscrowV04 escrow,
        uint256 amount,
        uint256 bond,
        uint256 challengerBond
    ) internal returns (SinettiEscrowV04.SellerAcceptance memory terms) {
        terms = baseAcceptance(
            buyer,
            seller,
            verifier,
            address(arbitrator),
            address(token),
            amount,
            bond,
            challengerBond,
            keccak256(abi.encode("f2", saltNonce++))
        );
        escrow; // silence unused in some paths
    }

    // ------------------------------------------------------------- properties

    /// @dev (1) Seller-bond floor is EXACTLY ceil(amount*bps/10000): the bond at
    ///      the floor opens, one wei under reverts BondBelowMinimum.
    function testFuzz_bondFloorCeilTightness(uint256 amount, uint16 bps) public {
        amount = _bound(amount, 1, 1_000_000);
        bps = uint16(_bound(bps, 1, 5_000));
        SinettiEscrowV04 escrow = _deploy(1_000_000, type(uint128).max, bps, 0);
        _fund(escrow);
        uint256 floor = ceilBps(amount, bps);

        SinettiEscrowV04.SellerAcceptance memory ok = _terms(escrow, amount, floor, amount);
        _open(escrow, ok);

        if (floor > 0) {
            SinettiEscrowV04.SellerAcceptance memory under = _terms(escrow, amount, floor - 1, amount);
            bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), under);
            vm.prank(buyer);
            vm.expectRevert(SinettiEscrowV04.BondBelowMinimum.selector);
            escrow.openDeal(under, sig);
        }
    }

    /// @dev (2a) challengerBond bound is (0, amount]: 0 and amount+1 revert.
    function testFuzz_challengerBondRange(uint256 amount, uint256 challengerBond) public {
        amount = _bound(amount, 1, 1_000_000);
        SinettiEscrowV04 escrow = _deploy(1_000_000, type(uint128).max, 0, 0);
        _fund(escrow);

        SinettiEscrowV04.SellerAcceptance memory zero = _terms(escrow, amount, 0, 0);
        bytes memory zsig = signAcceptance(SELLER_KEY, address(escrow), zero);
        vm.prank(buyer);
        vm.expectRevert(SinettiEscrowV04.ChallengerBondOutOfBounds.selector);
        escrow.openDeal(zero, zsig);

        SinettiEscrowV04.SellerAcceptance memory over = _terms(escrow, amount, 0, amount + 1);
        bytes memory osig = signAcceptance(SELLER_KEY, address(escrow), over);
        vm.prank(buyer);
        vm.expectRevert(SinettiEscrowV04.ChallengerBondOutOfBounds.selector);
        escrow.openDeal(over, osig);

        // A legal value in range opens.
        challengerBond = _bound(challengerBond, 1, amount);
        _open(escrow, _terms(escrow, amount, 0, challengerBond));
    }

    /// @dev (2b) Window/duration bounds: below the floor or above the cap reverts
    ///      with the exact error; the boundary values themselves are admissible.
    function testFuzz_windowBoundsExact(uint64 challengeWindow, uint64 rulingWindow) public {
        SinettiEscrowV04 escrow = _deploy(1_000_000, type(uint128).max, 0, 0);
        _fund(escrow);
        uint64 minC = escrow.minChallengeWindow();
        uint64 maxC = escrow.MAX_CHALLENGE_WINDOW();
        uint64 minR = escrow.minRulingWindow();
        uint64 maxR = escrow.MAX_RULING_WINDOW();

        SinettiEscrowV04.SellerAcceptance memory t = _terms(escrow, 1000, 0, 500);
        t.challengeWindow = uint64(_bound(challengeWindow, 0, minC == 0 ? 0 : minC - 1));
        if (t.challengeWindow < minC) {
            bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), t);
            vm.prank(buyer);
            vm.expectRevert(SinettiEscrowV04.ChallengeWindowTooShort.selector);
            escrow.openDeal(t, sig);
        }

        SinettiEscrowV04.SellerAcceptance memory t2 = _terms(escrow, 1000, 0, 500);
        t2.rulingWindow = uint64(_bound(rulingWindow, uint256(maxR) + 1, type(uint64).max));
        bytes memory sig2 = signAcceptance(SELLER_KEY, address(escrow), t2);
        vm.prank(buyer);
        vm.expectRevert(SinettiEscrowV04.RulingWindowOutOfBounds.selector);
        escrow.openDeal(t2, sig2);

        // Boundary values open cleanly.
        SinettiEscrowV04.SellerAcceptance memory ok = _terms(escrow, 1000, 0, 500);
        ok.challengeWindow = minC;
        ok.rulingWindow = maxR;
        _open(escrow, ok);
        SinettiEscrowV04.SellerAcceptance memory ok2 = _terms(escrow, 1000, 0, 500);
        ok2.challengeWindow = maxC;
        ok2.rulingWindow = minR;
        _open(escrow, ok2);
    }

    /// @dev (3) Constructor accepts a seller-bond policy IFF ceil(maxAmount*bps)
    ///      <= maxBond, and every accepted policy admits a max-amount deal at
    ///      its own bond floor (no policy is a lie).
    function testFuzz_constructorBondPolicyConsistency(
        uint256 maxAmount,
        uint256 maxBond,
        uint16 bps
    ) public {
        maxAmount = _bound(maxAmount, 1, 1_000_000);
        maxBond = _bound(maxBond, 0, 2_000_000);
        bps = uint16(_bound(bps, 0, 20_000));
        uint256 floor = ceilBps(maxAmount, bps);

        if (bps > 0 && floor > maxBond) {
            SinettiEscrowV04.TokenPolicy[] memory p = new SinettiEscrowV04.TokenPolicy[](1);
            p[0] = SinettiEscrowV04.TokenPolicy({
                token: IERC20(address(token)),
                maxAmount: maxAmount,
                maxBond: maxBond,
                minBondBps: bps,
                minChallengerBondBps: 0
            });
            vm.expectRevert(SinettiEscrowV04.UnsatisfiableBondPolicy.selector);
            new SinettiEscrowV04(address(this), p, new address[](0), new address[](0), 60, 60);
            return;
        }

        SinettiEscrowV04 escrow = _deploy(maxAmount, maxBond, bps, 0);
        _fund(escrow);
        // The accepted policy must admit its own worst case: a max-amount deal
        // at the exact bond floor.
        _open(escrow, _terms(escrow, maxAmount, floor, maxAmount));
    }

    /// @dev (4) A challenger-bond policy above 10000 bps is unsatisfiable
    ///      (challengerBond <= amount always), so the constructor rejects it;
    ///      at or below 10000 the floor is enforced exactly on openDeal.
    function testFuzz_challengerBondPolicy(uint256 amount, uint16 bps) public {
        amount = _bound(amount, 1, 1_000_000);
        bps = uint16(_bound(bps, 1, 20_000));

        if (bps > 10_000) {
            SinettiEscrowV04.TokenPolicy[] memory p = new SinettiEscrowV04.TokenPolicy[](1);
            p[0] = SinettiEscrowV04.TokenPolicy({
                token: IERC20(address(token)),
                maxAmount: 1_000_000,
                maxBond: type(uint128).max,
                minBondBps: 0,
                minChallengerBondBps: bps
            });
            vm.expectRevert(SinettiEscrowV04.UnsatisfiableChallengerBondPolicy.selector);
            new SinettiEscrowV04(address(this), p, new address[](0), new address[](0), 60, 60);
            return;
        }

        SinettiEscrowV04 escrow = _deploy(1_000_000, type(uint128).max, 0, bps);
        _fund(escrow);
        uint256 floor = ceilBps(amount, bps);
        if (floor == 0) floor = 1;
        if (floor > amount) {
            // The floor can exceed the principal only when bps rounds a tiny
            // amount up past itself; such a deal is legitimately unopenable.
            SinettiEscrowV04.SellerAcceptance memory imposs = _terms(escrow, amount, 0, amount);
            bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), imposs);
            vm.prank(buyer);
            vm.expectRevert(SinettiEscrowV04.ChallengerBondBelowMinimum.selector);
            escrow.openDeal(imposs, sig);
            return;
        }

        // At the floor opens; one under reverts ChallengerBondBelowMinimum.
        _open(escrow, _terms(escrow, amount, 0, floor));
        if (floor > 1) {
            SinettiEscrowV04.SellerAcceptance memory under = _terms(escrow, amount, 0, floor - 1);
            bytes memory sig = signAcceptance(SELLER_KEY, address(escrow), under);
            vm.prank(buyer);
            vm.expectRevert(SinettiEscrowV04.ChallengerBondBelowMinimum.selector);
            escrow.openDeal(under, sig);
        }
    }

    /// @dev _bound helper mirroring forge-std semantics for the vendored base.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min > max) return min;
        return min + (x % (max - min + 1));
    }
}
