// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FuzzBase} from "./lib/minstd/FuzzBase.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";

/**
 * @title EscrowFixture
 * @notice Shared acceptance-building and signing helpers for the Foundry suites.
 * @dev The typehash and domain below are deliberately re-declared from the
 *      public EIP-712 type rather than read from the contract:
 *      this suite is a second author. If the contract's typehash ever drifts
 *      from the published string, every signature built here dies and the
 *      drift is caught - reading the contract's own constant would make the
 *      check circular.
 */
abstract contract EscrowFixture is FuzzBase {
    bytes32 internal constant SELLER_ACCEPTANCE_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "SellerAcceptance(address buyer,address seller,address verifier,address arbitrator,address token,uint256 amount,uint256 bond,uint256 challengerBond,bytes32 termsHash,bytes32 buyerIdentityRef,bytes32 sellerIdentityRef,bytes32 verifierIdentityRef,bytes32 arbitratorIdentityRef,uint64 duration,uint64 challengeWindow,uint64 rulingWindow,uint64 openBy,bytes32 salt,string metaEvidenceURI)"
    );
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant DOMAIN_NAME_HASH = keccak256(bytes("SinettiEscrow"));
    /// @dev The published signing-domain version for the current acceptance type.
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256(bytes("8"));

    function domainSeparator(address escrow) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                DOMAIN_NAME_HASH,
                DOMAIN_VERSION_HASH,
                block.chainid,
                escrow
            )
        );
    }

    /// @dev Mirrors EIP-712 struct hashing: 20 static words (string pre-hashed),
    ///      encoded in two halves for stack room; concatenation is byte-identical.
    function hashAcceptance(
        SinettiEscrowV04.SellerAcceptance memory terms
    ) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            SELLER_ACCEPTANCE_TYPEHASH,
            terms.buyer,
            terms.seller,
            terms.verifier,
            terms.arbitrator,
            terms.token,
            terms.amount,
            terms.bond,
            terms.challengerBond
        );
        bytes memory tail = abi.encode(
            terms.termsHash,
            terms.buyerIdentityRef,
            terms.sellerIdentityRef,
            terms.verifierIdentityRef,
            terms.arbitratorIdentityRef,
            terms.duration,
            terms.challengeWindow,
            terms.rulingWindow,
            terms.openBy,
            terms.salt,
            keccak256(bytes(terms.metaEvidenceURI))
        );
        return keccak256(bytes.concat(head, tail));
    }

    function acceptanceDigest(
        address escrow,
        SinettiEscrowV04.SellerAcceptance memory terms
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19\x01", domainSeparator(escrow), hashAcceptance(terms))
        );
    }

    function signAcceptance(
        uint256 sellerKey,
        address escrow,
        SinettiEscrowV04.SellerAcceptance memory terms
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, acceptanceDigest(escrow, terms));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A fully legal acceptance skeleton; callers override what they probe.
    function baseAcceptance(
        address buyer,
        address seller,
        address verifier,
        address arbitrator,
        address token,
        uint256 amount,
        uint256 bond,
        uint256 challengerBond,
        bytes32 salt
    ) internal view returns (SinettiEscrowV04.SellerAcceptance memory) {
        return SinettiEscrowV04.SellerAcceptance({
            buyer: buyer,
            seller: seller,
            verifier: verifier,
            arbitrator: arbitrator,
            token: token,
            amount: amount,
            bond: bond,
            challengerBond: challengerBond,
            termsHash: keccak256("forge-terms"),
            buyerIdentityRef: bytes32(0),
            sellerIdentityRef: bytes32(0),
            verifierIdentityRef: bytes32(0),
            arbitratorIdentityRef: bytes32(0),
            duration: 30 days,
            challengeWindow: 3600,
            rulingWindow: 86_400,
            openBy: uint64(block.timestamp + 3600),
            salt: salt,
            metaEvidenceURI: ""
        });
    }

    /// @dev ceil(amount * bps / 10_000), the contract's floor rounding.
    function ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + 9999) / 10_000;
    }
}
