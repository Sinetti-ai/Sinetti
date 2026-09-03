// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SinettiEscrowV04
 * @notice Escrow and bond flow for agent-to-agent deals with optimistic settlement:
 *         the verifier's verdict is stored on-chain and, if unchallenged inside the
 *         per-deal challenge window, simply executes. Design authority:
 *         the public protocol and security documentation.
 * @notice Pausing blocks only new deals. Every path that advances or resolves an existing
 *         deal remains available so wall-clock deadlines cannot turn a pause into a
 *         settlement advantage.
 */
contract SinettiEscrowV04 is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

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

    enum Outcome {
        None,
        Release,
        Refund
    }

    struct Deal {
        address buyer;
        address seller;
        address verifier;
        address arbitrator;
        IERC20 token;
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

    struct SellerAcceptance {
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
        uint64 duration;
        uint64 challengeWindow;
        uint64 rulingWindow;
        uint64 openBy;
        bytes32 salt;
        string metaEvidenceURI;
    }

    struct Dispute {
        address challenger;
        uint64 rulingDeadline;
    }

    struct CancellationOffer {
        uint256 dealId;
        address signer;
        uint32 revision;
        bytes32 nonce;
        uint64 issuedAt;
        uint64 expiry;
    }

    struct TokenPolicy {
        IERC20 token;
        uint256 maxAmount;
        uint256 maxBond;
        uint16 minBondBps;
        uint16 minChallengerBondBps;
    }

    bytes32 private constant SELLER_ACCEPTANCE_TYPEHASH = keccak256(
        "SellerAcceptance(address buyer,address seller,address verifier,address arbitrator,address token,uint256 amount,uint256 bond,uint256 challengerBond,bytes32 termsHash,bytes32 buyerIdentityRef,bytes32 sellerIdentityRef,bytes32 verifierIdentityRef,bytes32 arbitratorIdentityRef,uint64 duration,uint64 challengeWindow,uint64 rulingWindow,uint64 openBy,bytes32 salt,string metaEvidenceURI)"
    );
    bytes32 private constant CANCELLATION_OFFER_TYPEHASH = keccak256(
        "CancellationOffer(uint256 dealId,address signer,uint32 revision,bytes32 nonce,uint64 issuedAt,uint64 expiry)"
    );

    /// @notice Shortest and longest signable delivery countdown. The deadline is
    ///         computed at open (`block.timestamp + duration`), so the seller always
    ///         receives the full signed countdown regardless of when the buyer opens.
    uint64 public constant MIN_DEAL_DURATION = 300;
    uint64 public constant MAX_DEAL_DURATION = 365 days;
    /// @notice Client default. Every deal still signs its exact challenge window. A
    ///         deployment may set its floor above this default; clients must then read
    ///         {minChallengeWindow} rather than assume the default is signable.
    uint64 public constant DEFAULT_CHALLENGE_WINDOW = 3600;
    /// @dev The lowest challenge-window floor any deployment may choose. It exists
    ///      so local demonstrations can run quickly; it is not a recommended public
    ///      deployment setting. See SECURITY.md.
    uint64 public constant ABSOLUTE_MIN_CHALLENGE_WINDOW = 60;
    uint64 public constant MAX_CHALLENGE_WINDOW = 30 days;
    /// @notice Bounds on the arbitrator's ruling time. The escrow only enforces the
    ///         outer bound; the arbitrator contract sets its own internal pace, and a
    ///         deal's signed rulingWindow must exceed that pace or the lapse fallback
    ///         can fire before the arbitrator finishes.
    uint64 public constant ABSOLUTE_MIN_RULING_WINDOW = 60;
    uint64 public constant MAX_RULING_WINDOW = 90 days;
    /// @notice Per-deployment floors on the signable windows: chosen once in the
    ///         constructor, bounded by the ABSOLUTE_* constants below them and the MAX
    ///         constants above them. One audited contract serves demo (60s floor) and
    ///         higher-floor deployments alike.
    uint64 public immutable minChallengeWindow;
    uint64 public immutable minRulingWindow;
    /// @notice Maximum lifetime of a signed cancellation offer.
    uint64 public constant MAX_CANCELLATION_OFFER_DURATION = 1 hours;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    string public constant SIGNING_DOMAIN_VERSION = "8";

    /**
     * @notice Gas forwarded to ERC-1271 signature checks.
     * @dev Bounds seller-wallet work during opening; combined with the 32-byte
     *      returndata bound in {_isValidSignature} it caps what a hostile wallet
     *      can cost the caller.
     */
    uint256 public constant ERC1271_GAS_LIMIT = 100_000;

    bytes32 public constant REASON_ACCEPTED = "accepted";
    bytes32 public constant REASON_VERDICT_PASS = "verdict_pass";
    bytes32 public constant REASON_VERDICT_FAIL = "verdict_fail";
    bytes32 public constant REASON_VERDICT_INCONCLUSIVE = "verdict_inconclusive";
    bytes32 public constant REASON_RULING_RELEASE = "ruling_release";
    bytes32 public constant REASON_RULING_REFUND = "ruling_refund";
    bytes32 public constant REASON_RULING_LAPSED = "ruling_lapsed";
    bytes32 public constant REASON_TIMEOUT = "timeout";
    bytes32 public constant REASON_CANCELLED = "cancelled";

    uint256 public nextDealId = 1;
    /// @dev Not public: the auto-generated getter would return the 22-field struct as a
    ///      flat tuple, which exceeds the EVM stack in legacy codegen. Use {getDeal}.
    mapping(uint256 => Deal) internal deals;
    mapping(uint256 => Dispute) public disputes;
    mapping(bytes32 => bool) public consumedAcceptance;
    mapping(bytes32 => bool) public consumedCancellationOffer;
    mapping(IERC20 => mapping(address => uint256)) public withdrawable;
    mapping(IERC20 => uint256) public tokenLiability;
    mapping(IERC20 => uint256) public maxAmountOf;
    mapping(IERC20 => uint256) public maxBondOf;
    mapping(IERC20 => uint16) public minBondBpsOf;
    mapping(IERC20 => uint16) public minChallengerBondBpsOf;
    mapping(IERC20 => bool) public listedToken;
    mapping(address => bool) public listedParticipant;
    mapping(address => bool) public listedArbitrator;

    address public pauser;
    address public pendingPauser;
    bool public immutable participantAllowlistEnabled;
    bool public immutable arbitratorAllowlistEnabled;
    bool public paused;

    error ZeroSeller();
    error ZeroVerifier();
    error ZeroArbitrator();
    error ZeroToken();
    error ZeroTermsHash();
    error ZeroPauser();
    error ZeroParticipant();
    error ZeroArbitratorEntry();
    error DuplicateParty();
    error DuplicateToken();
    error ZeroMaxAmount();
    error AmountZero();
    error DurationOutOfBounds();
    error ChallengeWindowTooShort();
    error ChallengeWindowTooLong();
    error RulingWindowOutOfBounds();
    error ChallengerBondOutOfBounds();
    error ChallengerBondBelowMinimum();
    error UnsatisfiableChallengerBondPolicy();
    error ChallengeWindowFloorOutOfBounds();
    error RulingWindowFloorOutOfBounds();
    error AcceptanceExpired();
    error NotSeller();
    error NotBuyer();
    error NotVerifier();
    error NotPauser();
    error NotPendingPauser();
    error ContractIsPaused();
    error DealNotFunded();
    error DealNotDelivered();
    error DealNotVerified();
    error DealNotActive();
    error BondNotRequired();
    error BondAlreadyPosted();
    error BondMissing();
    error DeadlineNotReached();
    error DeadlinePassed();
    error VerdictNotPass();
    error ChallengeWindowClosed();
    error DealNotDisputed();
    error NotArbitrator();
    error RulingDeadlinePassed();
    error InvalidOutcome();
    error NotParty();
    error ChallengerBondMismatch();
    error FinalizationNotReady();
    error InvalidVerdict();
    error AmountMismatch();
    error BondMismatch();
    error ZeroEvidence();
    error AcceptanceAlreadyConsumed();
    error InvalidSellerSignature();
    error CancellationOfferAlreadyConsumed();
    error CancellationOfferExpired();
    error CancellationOfferNotYetValid();
    error CancellationOfferDurationTooLong();
    error InvalidCancellationSigner();
    error InvalidCancellationSignature();
    error CancellationRevisionMismatch();
    error CancelNotAllowed();
    error TokenNotListed();
    error TokenHasNoCode(address token);
    error ArbitratorHasNoCode(address arbitrator);
    error AmountExceedsCap();
    error BondExceedsCap();
    error BondBelowMinimum();
    error UnsatisfiableBondPolicy();
    error ParticipantNotListed(address participant);
    error ArbitratorNotListed(address arbitrator);
    error InsufficientParticipants();
    error NoArbitrators();
    error DuplicateParticipant();
    error DuplicateArbitrator();
    error NoTokenPolicies();
    error NothingToWithdraw();
    error WithdrawalAmountMismatch();

    event DealOpened(
        uint256 indexed dealId,
        address indexed buyer,
        address indexed seller,
        address verifier,
        address arbitrator,
        IERC20 token,
        uint256 amount,
        uint256 bond,
        uint256 challengerBond,
        bytes32 termsHash,
        bytes32 buyerIdentityRef,
        bytes32 sellerIdentityRef,
        bytes32 verifierIdentityRef,
        bytes32 arbitratorIdentityRef,
        uint64 deadline,
        uint64 challengeWindow,
        uint64 rulingWindow
    );
    /**
     * @notice The two deal roles {DealOpened} cannot index, made filterable.
     * @dev Carries no data of its own: verifier and arbitrator are both already in
     *      {DealOpened}, but its three indexed slots are spent on dealId, buyer and
     *      seller, and the EVM allows no more. This event exists solely so a supervisor
     *      can ask "which deals was this verifier assigned" as one filtered log query
     *      instead of re-indexing every DealOpened ever emitted. Filtering it by
     *      verifier and comparing against {VerificationRecorded} filtered by the same
     *      verifier yields that verifier's no-show rate.
     */
    event DealParties(
        uint256 indexed dealId,
        address indexed verifier,
        address indexed arbitrator
    );
    /// @notice ERC-1497-shaped. Emitted at open only when the signed metaEvidenceURI is
    ///         non-empty, so an absent document reads as absent, not as a broken pointer.
    event MetaEvidence(uint256 indexed dealId, string evidence);
    event AcceptanceRevoked(bytes32 indexed digest, address indexed seller);
    event BondPosted(uint256 indexed dealId, uint256 bond);
    event DeliverySubmitted(uint256 indexed dealId, bytes32 evidenceHash);
    /// @notice The verifier is indexed so a supervisor can pull every verdict one
    ///         verifier actually recorded. Set against {DealParties} filtered by the same
    ///         address - the deals they were assigned - the gap is their no-show rate.
    event VerificationRecorded(
        uint256 indexed dealId,
        address indexed verifier,
        Verdict verdict,
        uint64 verifiedAt,
        uint64 challengeEndsAt
    );
    event Challenged(
        uint256 indexed dealId,
        address indexed challenger,
        uint256 challengerBond,
        uint64 rulingDeadline
    );
    /// @notice ERC-1497-shaped party evidence, open while a deal is Disputed.
    event Evidence(
        address indexed arbitrator,
        uint256 indexed dealId,
        address indexed party,
        string evidence
    );
    event RulingSubmitted(uint256 indexed dealId, address indexed arbitrator, Outcome outcome);
    /**
     * @notice Credits are per role address and total; any challenger-bond routing is
     *         inside the winning party's figure. Every settlement path emits exactly one.
     * @dev `reason` is indexed. It is a bytes32, a value type, so the topic holds
     *      the readable string rather than a hash of it, and one filter answers "every
     *      deal that ended in arbitrator silence / a timeout / a slashing ruling" across
     *      the whole contract without decoding anything.
     */
    event Settled(
        uint256 indexed dealId,
        bytes32 indexed reason,
        uint256 sellerCredit,
        uint256 buyerCredit
    );
    event BondSlashed(uint256 indexed dealId, uint256 bond);
    event Withdrawn(IERC20 indexed token, address indexed to, uint256 amount);
    event Paused(address indexed pauser);
    event Unpaused(address indexed pauser);
    event PauserTransferStarted(address indexed from, address indexed to);
    event PauserTransferred(address indexed from, address indexed to);

    modifier whenNotPaused() {
        if (paused) revert ContractIsPaused();
        _;
    }

    constructor(
        address pauser_,
        TokenPolicy[] memory tokens_,
        address[] memory participants_,
        address[] memory arbitrators_,
        uint64 minChallengeWindow_,
        uint64 minRulingWindow_
    ) EIP712("SinettiEscrow", SIGNING_DOMAIN_VERSION) {
        if (pauser_ == address(0)) revert ZeroPauser();
        if (tokens_.length == 0) revert NoTokenPolicies();
        // The deployment chooses its window floors once, inside the hard bounds.
        if (
            minChallengeWindow_ < ABSOLUTE_MIN_CHALLENGE_WINDOW ||
            minChallengeWindow_ > MAX_CHALLENGE_WINDOW
        ) revert ChallengeWindowFloorOutOfBounds();
        if (
            minRulingWindow_ < ABSOLUTE_MIN_RULING_WINDOW ||
            minRulingWindow_ > MAX_RULING_WINDOW
        ) revert RulingWindowFloorOutOfBounds();
        minChallengeWindow = minChallengeWindow_;
        minRulingWindow = minRulingWindow_;

        pauser = pauser_;
        participantAllowlistEnabled = participants_.length > 0;
        arbitratorAllowlistEnabled = arbitrators_.length > 0;

        for (uint256 i = 0; i < tokens_.length; ++i) {
            TokenPolicy memory policy = tokens_[i];
            if (address(policy.token) == address(0)) revert ZeroToken();
            // Code existence rejects EOAs; it does not prove ERC-20 compatibility.
            if (address(policy.token).code.length == 0) {
                revert TokenHasNoCode(address(policy.token));
            }
            if (policy.maxAmount == 0) revert ZeroMaxAmount();
            // The policy is unsatisfiable when the largest openable deal demands a
            // minimum bond above the bond cap. Checked against the real worst case:
            // maxAmount * minBondBps, ceiling-rounded exactly as openDeal rounds.
            if (
                policy.minBondBps > 0 &&
                Math.mulDiv(
                    policy.maxAmount,
                    policy.minBondBps,
                    BPS_DENOMINATOR,
                    Math.Rounding.Ceil
                ) > policy.maxBond
            ) revert UnsatisfiableBondPolicy();
            // Unlike minBondBps (a seller bond above principal is a legal policy), a
            // challenger floor above 10_000 bps can never be satisfied because
            // challengerBond <= amount always holds; reject it at deploy.
            if (policy.minChallengerBondBps > BPS_DENOMINATOR) {
                revert UnsatisfiableChallengerBondPolicy();
            }
            if (listedToken[policy.token]) revert DuplicateToken();
            listedToken[policy.token] = true;
            maxAmountOf[policy.token] = policy.maxAmount;
            maxBondOf[policy.token] = policy.maxBond;
            minBondBpsOf[policy.token] = policy.minBondBps;
            minChallengerBondBpsOf[policy.token] = policy.minChallengerBondBps;
        }

        for (uint256 i = 0; i < participants_.length; ++i) {
            address participant = participants_[i];
            if (participant == address(0)) revert ZeroParticipant();
            if (listedParticipant[participant]) revert DuplicateParticipant();
            listedParticipant[participant] = true;
        }
        // Cardinality only: three EOA roles (buyer, seller, verifier). The arbitrator
        // is a contract and is admitted through the separate arbitrator allowlist.
        if (participantAllowlistEnabled && participants_.length < 3) {
            revert InsufficientParticipants();
        }
        if (participantAllowlistEnabled && arbitrators_.length == 0) {
            revert NoArbitrators();
        }
        for (uint256 i = 0; i < arbitrators_.length; ++i) {
            address arbitrator = arbitrators_[i];
            if (arbitrator == address(0)) revert ZeroArbitratorEntry();
            if (listedArbitrator[arbitrator]) revert DuplicateArbitrator();
            listedArbitrator[arbitrator] = true;
        }
    }

    /**
     * @notice Create and fund a deal using the seller's EIP-712 acceptance of the exact terms.
     * @dev ERC-1271 validation forwards at most {ERC1271_GAS_LIMIT} gas and reads at most
     *      32 bytes of returndata. The deal clock starts now: deadline = now + duration.
     */
    function openDeal(
        SellerAcceptance calldata terms,
        bytes calldata sellerSignature
    ) external nonReentrant whenNotPaused returns (uint256 dealId) {
        if (terms.buyer != msg.sender) revert NotBuyer();
        _validateTerms(terms);

        bytes32 digest = _hashTypedDataV4(_hashSellerAcceptance(terms));
        if (consumedAcceptance[digest]) revert AcceptanceAlreadyConsumed();
        // Consumed before the ERC-1271 staticcall so no state write follows an
        // external call. A rejected signature reverts the whole transaction, so
        // the mark is discarded with it and the acceptance stays spendable.
        consumedAcceptance[digest] = true;
        if (!_isValidSignature(terms.seller, digest, sellerSignature)) {
            revert InvalidSellerSignature();
        }

        dealId = nextDealId++;
        _writeDeal(dealId, terms);

        uint256 received = _pull(IERC20(terms.token), terms.buyer, terms.amount);
        if (received != terms.amount) revert AmountMismatch();

        _emitDealOpened(dealId, deals[dealId]);
        if (bytes(terms.metaEvidenceURI).length > 0) {
            emit MetaEvidence(dealId, terms.metaEvidenceURI);
        }
    }

    function _validateTerms(SellerAcceptance calldata terms) private view {
        if (terms.seller == address(0)) revert ZeroSeller();
        if (terms.verifier == address(0)) revert ZeroVerifier();
        if (terms.arbitrator == address(0)) revert ZeroArbitrator();
        if (terms.token == address(0)) revert ZeroToken();
        // The commitment to the acceptance criteria, checked here for the same
        // reason submitDelivery rejects a zero evidenceHash: a deal that commits
        // to no criteria gives an arbitrator nothing to adjudicate against, which
        // is the whole recourse premise. Consent does not rescue it - the seller
        // signs evidenceHash too, and that one is checked.
        if (terms.termsHash == bytes32(0)) revert ZeroTermsHash();
        if (terms.amount == 0) revert AmountZero();
        if (
            terms.duration < MIN_DEAL_DURATION || terms.duration > MAX_DEAL_DURATION
        ) revert DurationOutOfBounds();
        if (terms.challengeWindow < minChallengeWindow) revert ChallengeWindowTooShort();
        if (terms.challengeWindow > MAX_CHALLENGE_WINDOW) revert ChallengeWindowTooLong();
        if (
            terms.rulingWindow < minRulingWindow || terms.rulingWindow > MAX_RULING_WINDOW
        ) revert RulingWindowOutOfBounds();
        // A challenger bond above the principal would price the loser of a verdict out
        // of recourse entirely, which is the same denial a late verdict would cause.
        if (
            terms.challengerBond == 0 || terms.challengerBond > terms.amount
        ) revert ChallengerBondOutOfBounds();
        if (block.timestamp > terms.openBy) revert AcceptanceExpired();
        if (
            _hasDuplicateParty(terms.buyer, terms.seller, terms.verifier, terms.arbitrator)
        ) revert DuplicateParty();
        if (terms.arbitrator.code.length == 0) {
            revert ArbitratorHasNoCode(terms.arbitrator);
        }

        IERC20 token = IERC20(terms.token);
        if (!listedToken[token]) revert TokenNotListed();
        if (terms.amount > maxAmountOf[token]) revert AmountExceedsCap();
        if (terms.bond > maxBondOf[token]) revert BondExceedsCap();
        uint256 minimumBond = Math.mulDiv(
            terms.amount,
            minBondBpsOf[token],
            BPS_DENOMINATOR,
            Math.Rounding.Ceil
        );
        if (terms.bond < minimumBond) revert BondBelowMinimum();
        // Same ceiling rounding as the seller floor. The policy caps the floor at
        // 10_000 bps (constructor), so it can never contradict challengerBond <= amount.
        uint256 minimumChallengerBond = Math.mulDiv(
            terms.amount,
            minChallengerBondBpsOf[token],
            BPS_DENOMINATOR,
            Math.Rounding.Ceil
        );
        if (terms.challengerBond < minimumChallengerBond) {
            revert ChallengerBondBelowMinimum();
        }
        if (participantAllowlistEnabled) {
            if (!listedParticipant[terms.buyer]) revert ParticipantNotListed(terms.buyer);
            if (!listedParticipant[terms.seller]) revert ParticipantNotListed(terms.seller);
            if (!listedParticipant[terms.verifier]) {
                revert ParticipantNotListed(terms.verifier);
            }
        }
        if (arbitratorAllowlistEnabled) {
            if (!listedArbitrator[terms.arbitrator]) {
                revert ArbitratorNotListed(terms.arbitrator);
            }
        }
    }

    function _writeDeal(uint256 dealId, SellerAcceptance calldata terms) private {
        Deal storage deal = deals[dealId];
        deal.buyer = terms.buyer;
        deal.seller = terms.seller;
        deal.verifier = terms.verifier;
        deal.arbitrator = terms.arbitrator;
        deal.token = IERC20(terms.token);
        deal.amount = terms.amount;
        deal.bond = terms.bond;
        deal.challengerBond = terms.challengerBond;
        deal.termsHash = terms.termsHash;
        deal.buyerIdentityRef = terms.buyerIdentityRef;
        deal.sellerIdentityRef = terms.sellerIdentityRef;
        deal.verifierIdentityRef = terms.verifierIdentityRef;
        deal.arbitratorIdentityRef = terms.arbitratorIdentityRef;
        deal.deadline = uint64(block.timestamp) + terms.duration;
        deal.challengeWindow = terms.challengeWindow;
        deal.rulingWindow = terms.rulingWindow;
        deal.state = State.Funded;
        deal.revision = 1;
        tokenLiability[deal.token] += terms.amount;
    }

    /// @dev keccak256 of the DealOpened signature, pinned so the assembly emit below
    ///      stays byte-identical to the declared event. Any drift makes every ABI
    ///      decode of DealOpened fail, which the lifecycle tests catch immediately.
    bytes32 private constant DEAL_OPENED_TOPIC0 = keccak256(
        "DealOpened(uint256,address,address,address,address,address,uint256,uint256,uint256,bytes32,bytes32,bytes32,bytes32,bytes32,uint64,uint64,uint64)"
    );

    /// @dev Split out of openDeal to keep stack depth inside the EVM limit. At 17
    ///      event parameters even a dedicated helper exceeds legacy codegen's stack,
    ///      so the data payload is abi-encoded in two halves (every field is a static
    ///      32-byte word, so concatenation is byte-identical to one abi.encode) and
    ///      emitted through a raw log4 with the same topics the declared event uses.
    function _emitDealOpened(uint256 dealId, Deal storage deal) private {
        bytes memory head = abi.encode(
            deal.verifier,
            deal.arbitrator,
            deal.token,
            deal.amount,
            deal.bond,
            deal.challengerBond,
            deal.termsHash
        );
        bytes memory tail = abi.encode(
            deal.buyerIdentityRef,
            deal.sellerIdentityRef,
            deal.verifierIdentityRef,
            deal.arbitratorIdentityRef,
            deal.deadline,
            deal.challengeWindow,
            deal.rulingWindow
        );
        bytes memory data = bytes.concat(head, tail);
        bytes32 topic0 = DEAL_OPENED_TOPIC0;
        address buyer = deal.buyer;
        address seller = deal.seller;
        // reentrancy-safe justification not needed (no external call); assembly is the
        // documented stack-depth escape, mirroring the bounded ERC-1271 block below.
        assembly {
            log4(add(data, 32), mload(data), topic0, dealId, buyer, seller)
        }
        // Emitted here rather than in openDeal because this helper already holds the
        // storage pointer and openDeal has no stack left to spare - the same constraint
        // that forced the raw log4 above. Three indexed params and no data, so the
        // high-level emit compiles to its own log4 with an empty data payload.
        emit DealParties(dealId, deal.verifier, deal.arbitrator);
    }

    /**
     * @notice Revoke an unused seller acceptance. Revocation remains available while paused.
     */
    // reentrancy-safe: no external calls; consumes a digest and emits.
    function revokeAcceptance(SellerAcceptance calldata terms) external {
        if (msg.sender != terms.seller) revert NotSeller();
        bytes32 digest = _hashTypedDataV4(_hashSellerAcceptance(terms));
        if (consumedAcceptance[digest]) revert AcceptanceAlreadyConsumed();
        consumedAcceptance[digest] = true;
        emit AcceptanceRevoked(digest, msg.sender);
    }

    function postBond(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Funded) revert DealNotFunded();
        if (msg.sender != deal.seller) revert NotSeller();
        if (deal.bond == 0) revert BondNotRequired();
        if (deal.bondPosted) revert BondAlreadyPosted();
        if (block.timestamp >= deal.deadline) revert DeadlinePassed();

        deal.bondPosted = true;
        deal.revision++;
        tokenLiability[deal.token] += deal.bond;
        uint256 received = _pull(deal.token, msg.sender, deal.bond);
        if (received != deal.bond) revert BondMismatch();

        emit BondPosted(dealId, received);
    }

    function submitDelivery(uint256 dealId, bytes32 evidenceHash) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Funded) revert DealNotFunded();
        if (msg.sender != deal.seller) revert NotSeller();
        if (block.timestamp >= deal.deadline) revert DeadlinePassed();
        if (evidenceHash == bytes32(0)) revert ZeroEvidence();
        if (deal.bond > 0 && !deal.bondPosted) revert BondMissing();

        deal.evidenceHash = evidenceHash;
        deal.state = State.Delivered;
        deal.revision++;

        emit DeliverySubmitted(dealId, evidenceHash);
    }

    /**
     * @notice Record the verifier's verdict. The verdict is stored, and recording moves
     *         the settlement horizon to verifiedAt + challengeWindow, so the losing
     *         side's challenge window always physically exists in full regardless of
     *         when the verdict lands by extending the settlement horizon.
     */
    function recordVerification(uint256 dealId, uint8 rawVerdict) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (msg.sender != deal.verifier) revert NotVerifier();
        if (deal.state != State.Delivered) revert DealNotDelivered();
        if (block.timestamp >= deal.deadline) revert DeadlinePassed();
        if (rawVerdict == uint8(Verdict.None) || rawVerdict > uint8(type(Verdict).max)) {
            revert InvalidVerdict();
        }

        deal.verdict = Verdict(rawVerdict);
        deal.verifiedAt = uint64(block.timestamp);
        deal.state = State.Verified;
        deal.revision++;

        // deal.verifier, not msg.sender: the guard above proves they are equal, and the
        // event should state the deal's assigned verifier rather than whoever called.
        // The slot is already warm from that guard.
        emit VerificationRecorded(
            dealId,
            deal.verifier,
            deal.verdict,
            deal.verifiedAt,
            challengeEndsAt(dealId)
        );
    }

    /**
     * @notice Accept a verifier Pass and settle immediately. Deliberately has no time
     *         bound: inside the window the buyer waives only their own protection, and
     *         after it the call races the permissionless finalize benignly, so a
     *         cooperative buyer can still emit the "accepted" signal slightly late.
     *         Available while paused so pausing cannot block settlement.
     */
    function accept(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Verified) revert DealNotVerified();
        if (msg.sender != deal.buyer) revert NotBuyer();
        if (deal.verdict != Verdict.Pass) revert VerdictNotPass();

        _release(dealId, deal, REASON_ACCEPTED);
    }

    /**
     * @notice Challenge the standing verdict. Only the party the verdict pays against
     *         may challenge (Pass: the buyer; Fail or Inconclusive: the seller), it
     *         costs the signed challenger bond, and it hands the case to the deal's
     *         arbitrator contract. The escrow does NOT call the arbitrator: it emits
     *         {Challenged} and the arbitrator answers via {submitRuling}.
     *         Available while paused.
     */
    function challenge(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Verified) revert DealNotVerified();
        if (_challengeWindowElapsed(dealId)) revert ChallengeWindowClosed();
        if (deal.verdict == Verdict.Pass) {
            if (msg.sender != deal.buyer) revert NotBuyer();
        } else {
            if (msg.sender != deal.seller) revert NotSeller();
        }

        deal.state = State.Disputed;
        deal.revision++;
        disputes[dealId] = Dispute({
            challenger: msg.sender,
            rulingDeadline: uint64(block.timestamp) + deal.rulingWindow
        });
        tokenLiability[deal.token] += deal.challengerBond;
        uint256 received = _pull(deal.token, msg.sender, deal.challengerBond);
        if (received != deal.challengerBond) revert ChallengerBondMismatch();

        emit Challenged(
            dealId,
            msg.sender,
            deal.challengerBond,
            disputes[dealId].rulingDeadline
        );
    }

    /**
     * @notice Put party evidence on the record while the dispute is open. Emits only;
     *         the contract stores nothing (ERC-1497 shape). Available while paused.
     */
    // reentrancy-safe: no external calls and no state writes; emits a single event.
    function submitEvidence(uint256 dealId, string calldata evidence) external {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Disputed) revert DealNotDisputed();
        if (msg.sender != deal.buyer && msg.sender != deal.seller) revert NotParty();
        emit Evidence(deal.arbitrator, dealId, msg.sender, evidence);
    }

    /**
     * @notice The arbitrator's answer. Release pays the seller (plus bond, plus the
     *         challenger bond); Refund pays the buyer, slashes the seller bond, and
     *         routes the challenger bond per loser-pays. This is the ONLY path on
     *         which the seller bond ever slashes.
     */
    function submitRuling(uint256 dealId, uint8 rawOutcome) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Disputed) revert DealNotDisputed();
        if (msg.sender != deal.arbitrator) revert NotArbitrator();
        Dispute storage dispute = disputes[dealId];
        if (block.timestamp >= dispute.rulingDeadline) revert RulingDeadlinePassed();
        if (
            rawOutcome != uint8(Outcome.Release) && rawOutcome != uint8(Outcome.Refund)
        ) revert InvalidOutcome();
        Outcome outcome = Outcome(rawOutcome);

        emit RulingSubmitted(dealId, msg.sender, outcome);

        if (outcome == Outcome.Release) {
            // Either challenger branch: seller receives amount + bond + challenger
            // bond (a losing buyer forfeits it; a winning seller gets their own back).
            deal.state = State.Released;
            deal.revision++;
            uint256 bondReturned = _clearPostedBond(deal);
            uint256 sellerCredit = deal.amount + bondReturned + deal.challengerBond;
            _credit(deal.token, deal.seller, sellerCredit);
            emit Settled(dealId, REASON_RULING_RELEASE, sellerCredit, 0);
        } else {
            // Either challenger branch: buyer receives amount + slashed bond +
            // challenger bond (a losing seller forfeits it; a winning buyer gets
            // their own back).
            deal.state = State.Refunded;
            deal.revision++;
            uint256 slashed = _clearPostedBond(deal);
            uint256 buyerCredit = deal.amount + slashed + deal.challengerBond;
            _credit(deal.token, deal.buyer, buyerCredit);
            if (slashed > 0) {
                emit BondSlashed(dealId, slashed);
            }
            emit Settled(dealId, REASON_RULING_REFUND, 0, buyerCredit);
        }
    }

    /**
     * @notice Permissionlessly settle: an unchallenged verdict after its window, or a
     *         challenged deal whose arbitrator never ruled before the ruling deadline
     *         (the standing verdict executes and the challenger bond is returned -
     *         arbitrator silence is never allowed to strand funds or invent a split).
     */
    function finalize(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state == State.Verified) {
            if (!_challengeWindowElapsed(dealId)) revert FinalizationNotReady();
            _executeVerdict(dealId, deal);
            return;
        }
        if (deal.state == State.Disputed) {
            Dispute storage dispute = disputes[dealId];
            if (block.timestamp < dispute.rulingDeadline) revert FinalizationNotReady();
            _executeLapsedDispute(dealId, deal, dispute);
            return;
        }
        revert FinalizationNotReady();
    }

    /**
     * @notice Refund a deal whose deadline passed before delivery or before any verdict.
     *         The bond, if posted, returns to the seller: timeouts and verifier silence
     *         never slash (SECURITY.md documents the limitation).
     */
    function claimTimeout(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        if (deal.state != State.Funded && deal.state != State.Delivered) {
            revert DealNotActive();
        }
        if (block.timestamp < deal.deadline) revert DeadlineNotReached();

        deal.state = State.Refunded;
        deal.revision++;
        uint256 bondReturned = _clearPostedBond(deal);
        _credit(deal.token, deal.buyer, deal.amount);
        if (bondReturned > 0) {
            _credit(deal.token, deal.seller, bondReturned);
        }

        emit Settled(dealId, REASON_TIMEOUT, bondReturned, deal.amount);
    }

    /**
     * @notice Atomically accept the counterparty's signed cancellation offer and unwind:
     *         principal to the buyer, posted bond to the seller. Available while paused.
     * @dev The offer binds to one deal at one exact revision, so an offer signed in one
     *      context cannot land after the deal has moved.
     */
    function cancelMutually(
        CancellationOffer calldata offer,
        bytes calldata signature
    ) external nonReentrant {
        bytes32 digest = _hashTypedDataV4(_hashCancellationOffer(offer));
        if (consumedCancellationOffer[digest]) revert CancellationOfferAlreadyConsumed();

        Deal storage deal = deals[offer.dealId];
        if (!_isActive(deal.state)) revert CancelNotAllowed();
        if (offer.issuedAt > block.timestamp) revert CancellationOfferNotYetValid();
        if (offer.expiry < block.timestamp) revert CancellationOfferExpired();
        if (
            offer.expiry <= offer.issuedAt ||
            offer.expiry - offer.issuedAt > MAX_CANCELLATION_OFFER_DURATION
        ) {
            revert CancellationOfferDurationTooLong();
        }
        if (offer.revision != deal.revision) revert CancellationRevisionMismatch();

        address counterparty = address(0);
        if (offer.signer == deal.buyer) {
            counterparty = deal.seller;
        } else if (offer.signer == deal.seller) {
            counterparty = deal.buyer;
        } else {
            revert InvalidCancellationSigner();
        }
        if (msg.sender != counterparty) revert InvalidCancellationSigner();
        // Consumed before the ERC-1271 staticcall, as in openDeal.
        consumedCancellationOffer[digest] = true;
        if (!_isValidSignature(offer.signer, digest, signature)) {
            revert InvalidCancellationSignature();
        }

        bool wasDisputed = deal.state == State.Disputed;
        deal.state = State.Cancelled;
        deal.revision++;
        uint256 bondReturned = _clearPostedBond(deal);
        uint256 sellerCredit = bondReturned;
        uint256 buyerCredit = deal.amount;
        if (wasDisputed) {
            // Mutual agreement supersedes the pending arbitration; the challenger
            // bond unwinds to whichever party posted it.
            if (disputes[offer.dealId].challenger == deal.buyer) {
                buyerCredit += deal.challengerBond;
            } else {
                sellerCredit += deal.challengerBond;
            }
        }
        if (sellerCredit > 0) {
            _credit(deal.token, deal.seller, sellerCredit);
        }
        _credit(deal.token, deal.buyer, buyerCredit);

        emit Settled(offer.dealId, REASON_CANCELLED, sellerCredit, buyerCredit);
    }

    /**
     * @notice Withdraw the caller's entire credited balance for a token. Available while paused.
     */
    function withdraw(IERC20 token) external nonReentrant {
        _withdraw(token, withdrawable[token][msg.sender]);
    }

    /**
     * @notice Withdraw part of the caller's credited balance, so a token quirk that
     *         blocks one transfer size can never trap the whole balance.
     */
    function withdraw(IERC20 token, uint256 amount) external nonReentrant {
        _withdraw(token, amount);
    }

    /**
     * @notice Report the escrow's obligations and actual holdings for a token.
     */
    function tokenAccounting(
        IERC20 token
    ) external view returns (uint256 liabilities, uint256 actualBalance) {
        liabilities = tokenLiability[token];
        actualBalance = token.balanceOf(address(this));
    }

    // reentrancy-safe: no external calls; flips a bool and emits.
    function pause() external {
        if (msg.sender != pauser) revert NotPauser();
        paused = true;
        emit Paused(msg.sender);
    }

    // reentrancy-safe: no external calls; flips a bool and emits.
    function unpause() external {
        if (msg.sender != pauser) revert NotPauser();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // reentrancy-safe: no external calls; writes pendingPauser and emits.
    function transferPauser(address newPauser) external {
        if (msg.sender != pauser) revert NotPauser();
        if (newPauser == address(0)) revert ZeroPauser();
        pendingPauser = newPauser;
        emit PauserTransferStarted(msg.sender, newPauser);
    }

    // reentrancy-safe: no external calls; rotates the pauser pair and emits.
    function acceptPauser() external {
        if (msg.sender != pendingPauser) revert NotPendingPauser();
        address previousPauser = pauser;
        pauser = msg.sender;
        pendingPauser = address(0);
        emit PauserTransferred(previousPauser, msg.sender);
    }

    /// @notice The full deal record, ABI-encoded as a struct.
    function getDeal(uint256 dealId) external view returns (Deal memory) {
        return deals[dealId];
    }

    /// @notice End of the standing verdict's challenge window; 0 while no verdict exists.
    function challengeEndsAt(uint256 dealId) public view returns (uint64) {
        Deal storage deal = deals[dealId];
        if (deal.verifiedAt == 0) return 0;
        return deal.verifiedAt + deal.challengeWindow;
    }

    /// @dev Fail-closed: "no verdict recorded" must never read as "window already
    ///      closed", because this predicate is what stands between recorded funds and
    ///      a premature settlement.
    function _challengeWindowElapsed(uint256 dealId) internal view returns (bool) {
        uint64 endsAt = challengeEndsAt(dealId);
        if (endsAt == 0) return false;
        return block.timestamp >= endsAt;
    }

    /// @dev Executes the stored verdict on the optimistic (unchallenged) path.
    function _executeVerdict(uint256 dealId, Deal storage deal) private {
        if (deal.verdict == Verdict.Pass) {
            _release(dealId, deal, REASON_VERDICT_PASS);
        } else if (deal.verdict == Verdict.Fail) {
            _refund(dealId, deal, REASON_VERDICT_FAIL);
        } else {
            _refund(dealId, deal, REASON_VERDICT_INCONCLUSIVE);
        }
    }

    /// @dev Ruling deadline passed with no ruling: the standing verdict executes and
    ///      the challenger bond returns to the challenger. No slash - the seller bond
    ///      only ever slashes on an explicit Refund ruling.
    function _executeLapsedDispute(
        uint256 dealId,
        Deal storage deal,
        Dispute storage dispute
    ) private {
        // The challenger's identity follows the verdict, because challenge() only
        // admits the disadvantaged party: Pass -> buyer challenged, else the seller.
        // dispute.challenger is read anyway so a future challenge-rule change cannot
        // silently desynchronise the routing from the admission rule.
        bool buyerChallenged = dispute.challenger == deal.buyer;
        uint256 bondBack;
        uint256 sellerCredit;
        uint256 buyerCredit;
        if (deal.verdict == Verdict.Pass) {
            deal.state = State.Released;
            bondBack = _clearPostedBond(deal);
            sellerCredit = deal.amount + bondBack;
            buyerCredit = buyerChallenged ? deal.challengerBond : 0;
        } else {
            deal.state = State.Refunded;
            bondBack = _clearPostedBond(deal);
            sellerCredit = bondBack + (buyerChallenged ? 0 : deal.challengerBond);
            buyerCredit = deal.amount;
        }
        deal.revision++;
        if (sellerCredit > 0) {
            _credit(deal.token, deal.seller, sellerCredit);
        }
        if (buyerCredit > 0) {
            _credit(deal.token, deal.buyer, buyerCredit);
        }

        emit Settled(dealId, REASON_RULING_LAPSED, sellerCredit, buyerCredit);
    }

    function _release(uint256 dealId, Deal storage deal, bytes32 reason) private {
        deal.state = State.Released;
        deal.revision++;
        uint256 bondReturned = _clearPostedBond(deal);
        uint256 sellerCredit = deal.amount + bondReturned;
        _credit(deal.token, deal.seller, sellerCredit);

        emit Settled(dealId, reason, sellerCredit, 0);
    }

    /// @dev Unchallenged Fail/Inconclusive refund: bond returns unslashed. The only
    ///      slash path in V04 is an arbitrator ruling of Refund.
    function _refund(uint256 dealId, Deal storage deal, bytes32 reason) private {
        deal.state = State.Refunded;
        deal.revision++;
        uint256 bondReturned = _clearPostedBond(deal);
        _credit(deal.token, deal.buyer, deal.amount);
        if (bondReturned > 0) {
            _credit(deal.token, deal.seller, bondReturned);
        }

        emit Settled(dealId, reason, bondReturned, deal.amount);
    }

    function _withdraw(IERC20 token, uint256 amount) private {
        uint256 credit = withdrawable[token][msg.sender];
        if (amount == 0 || credit < amount) revert NothingToWithdraw();

        uint256 escrowBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(msg.sender);
        withdrawable[token][msg.sender] = credit - amount;
        tokenLiability[token] -= amount;
        token.safeTransfer(msg.sender, amount);
        uint256 escrowBalanceAfter = token.balanceOf(address(this));
        uint256 recipientBalanceAfter = token.balanceOf(msg.sender);
        if (
            escrowBalanceAfter > escrowBalanceBefore ||
            escrowBalanceBefore - escrowBalanceAfter != amount ||
            recipientBalanceAfter < recipientBalanceBefore ||
            recipientBalanceAfter - recipientBalanceBefore != amount
        ) {
            revert WithdrawalAmountMismatch();
        }

        emit Withdrawn(token, msg.sender, amount);
    }

    function _credit(IERC20 token, address party, uint256 amount) private {
        withdrawable[token][party] += amount;
    }

    function _clearPostedBond(Deal storage deal) private returns (uint256 postedBond) {
        if (deal.bondPosted) {
            postedBond = deal.bond;
            deal.bondPosted = false;
        }
    }

    function _pull(
        IERC20 token,
        address from,
        uint256 requested
    ) private returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), requested);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    function _hashSellerAcceptance(
        SellerAcceptance calldata acceptance
    ) private pure returns (bytes32) {
        // Encoded in two halves to stay inside the EVM stack limit. Every field is a
        // static 32-byte word (the string is EIP-712-hashed first), so concatenating
        // the halves is byte-identical to a single abi.encode of all 20 words.
        bytes memory head = abi.encode(
            SELLER_ACCEPTANCE_TYPEHASH,
            acceptance.buyer,
            acceptance.seller,
            acceptance.verifier,
            acceptance.arbitrator,
            acceptance.token,
            acceptance.amount,
            acceptance.bond,
            acceptance.challengerBond
        );
        bytes memory tail = abi.encode(
            acceptance.termsHash,
            acceptance.buyerIdentityRef,
            acceptance.sellerIdentityRef,
            acceptance.verifierIdentityRef,
            acceptance.arbitratorIdentityRef,
            acceptance.duration,
            acceptance.challengeWindow,
            acceptance.rulingWindow,
            acceptance.openBy,
            acceptance.salt,
            keccak256(bytes(acceptance.metaEvidenceURI))
        );
        return keccak256(bytes.concat(head, tail));
    }

    function _hashCancellationOffer(
        CancellationOffer calldata offer
    ) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CANCELLATION_OFFER_TYPEHASH,
                    offer.dealId,
                    offer.signer,
                    offer.revision,
                    offer.nonce,
                    offer.issuedAt,
                    offer.expiry
                )
            );
    }

    /**
     * @dev EOA path: strict ECDSA recovery. Contract path: bounded ERC-1271 check that
     *      forwards at most {ERC1271_GAS_LIMIT} gas and copies at most 32 bytes of
     *      returndata, so a hostile wallet cannot burn the caller's gas with an
     *      oversized reply.
     */
    function _isValidSignature(
        address signer,
        bytes32 digest,
        bytes calldata signature
    ) private view returns (bool) {
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError error, ) = ECDSA.tryRecover(
                digest,
                signature
            );
            return error == ECDSA.RecoverError.NoError && recovered == signer;
        }

        bytes memory callData = abi.encodeCall(
            IERC1271.isValidSignature,
            (digest, signature)
        );
        bool success;
        bytes32 word;
        uint256 returndataSize;
        uint256 gasLimit = ERC1271_GAS_LIMIT;
        assembly ("memory-safe") {
            success := staticcall(
                gasLimit,
                signer,
                add(callData, 0x20),
                mload(callData),
                0x00,
                0x00
            )
            returndataSize := returndatasize()
            // Exactly one word is ever copied, whatever the wallet returned, so
            // an oversized reply cannot charge the caller for memory expansion.
            if iszero(lt(returndataSize, 0x20)) {
                returndatacopy(0x00, 0x00, 0x20)
                word := mload(0x00)
            }
        }
        return
            success &&
            returndataSize >= 32 &&
            bytes4(word) == IERC1271.isValidSignature.selector;
    }

    function _hasDuplicateParty(
        address buyer,
        address seller,
        address verifier,
        address arbitrator
    ) private pure returns (bool) {
        return (buyer == seller ||
            buyer == verifier ||
            buyer == arbitrator ||
            seller == verifier ||
            seller == arbitrator ||
            verifier == arbitrator);
    }

    function _isActive(State state) private pure returns (bool) {
        return
            state == State.Funded ||
            state == State.Delivered ||
            state == State.Verified ||
            state == State.Disputed;
    }
}
