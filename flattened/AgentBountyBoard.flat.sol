// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// src/AgentBountyBoard.sol

/// @title AgentBountyBoard
/// @notice A bounty board where work is gated by Binance Agent ID.
/// @dev Anyone can post a bounty by escrowing BNB in this contract.
///      Only holders of an Agent ID (the SPACE ID Agent ID ERC-721 on BNB Chain)
///      can claim and work a bounty. The poster releases the escrow when the work
///      is approved. If the worker never submits by the work deadline, the poster
///      can reclaim the escrow. If the poster does not react within REVIEW_WINDOW
///      after a submission, the worker can release the escrow themselves.
///
///      Permissions disclosure (hackathon safety rules): this contract has NO
///      owner and NO admin functions. Nobody — including the deployer — can move
///      escrowed funds except through the bounty lifecycle below, pause the
///      contract, change fees (there are none), or mint anything. Escrowed BNB
///      leaves the contract only to (a) the worker of that bounty on release, or
///      (b) the poster of that bounty on cancel / reclaim.
interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

contract AgentBountyBoard {
    /// @notice The Agent ID registry (SPACE ID Agent ID, BNB Chain mainnet).
    IAgentIdRegistry public immutable agentIdRegistry;

    /// @notice How long a poster has to react after a submission before the
    ///         worker may release the escrow themselves.
    uint256 public constant REVIEW_WINDOW = 3 days;

    /// @notice Minimum escrow per bounty (spam control, not a fee; fully escrowed).
    uint256 public constant MIN_BOUNTY = 0.0001 ether;

    enum Status {
        Open, // posted, waiting for a worker
        Claimed, // a worker claimed it and is working
        Submitted, // worker submitted, waiting for the poster
        Released, // escrow paid to the worker (terminal)
        Refunded // escrow returned to the poster (terminal)
    }

    struct Bounty {
        address poster;
        address worker;
        uint256 amount; // escrowed BNB in wei
        uint64 workDeadline; // submit-by time (unix seconds)
        uint64 submittedAt; // when the latest submission happened (0 = none)
        Status status;
        string title;
        string detailURI; // off-chain task description (e.g. ipfs:// or https://)
        string proofURI; // off-chain work proof submitted by the worker
    }

    Bounty[] private _bounties;

    /// @notice Lifetime number of bounties ever posted.
    uint256 public totalPosted;
    /// @notice Lifetime escrow volume released to workers, in wei.
    uint256 public totalReleasedVolume;
    /// @notice Number of distinct Agent ID addresses that have claimed or submitted.
    uint256 public agentInteractors;

    mapping(address => bool) private _countedInteractor;
    /// @notice Bounties completed by a worker (escrow released to them).
    mapping(address => uint256) public completedCount;
    /// @notice Total wei ever earned by a worker through this board.
    mapping(address => uint256) public totalEarned;
    /// @notice Bounties posted by an address.
    mapping(address => uint256) public postedCount;

    event BountyPosted(uint256 indexed id, address indexed poster, uint256 amount, uint64 workDeadline, string title);
    event BountyClaimed(uint256 indexed id, address indexed worker);
    event WorkSubmitted(uint256 indexed id, address indexed worker, string proofURI);
    event WorkRejected(uint256 indexed id, address indexed poster);
    event BountyReleased(uint256 indexed id, address indexed worker, uint256 amount, bool byPoster);
    event BountyRefunded(uint256 indexed id, address indexed poster, uint256 amount, string reason);

    error NotAgentIdHolder();
    error BountyTooSmall();
    error DeadlineInPast();
    error BadStatus();
    error NotPoster();
    error NotWorker();
    error DeadlineNotReached();
    error ReviewWindowOpen();
    error TransferFailed();
    error Reentrant();

    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param registry The Agent ID registry contract. On BNB Chain mainnet this
    ///        is 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F.
    constructor(address registry) {
        agentIdRegistry = IAgentIdRegistry(registry);
    }

    /// @notice True if `account` currently holds an Agent ID.
    function isAgent(address account) public view returns (bool) {
        return agentIdRegistry.balanceOf(account) > 0;
    }

    /// @notice Post a bounty, escrowing the attached BNB until release or refund.
    /// @param title Short human-readable task title (stored on-chain).
    /// @param detailURI Off-chain description of the task and acceptance criteria.
    /// @param workDeadline Unix time by which the worker must submit.
    /// @return id The new bounty's id.
    function postBounty(string calldata title, string calldata detailURI, uint64 workDeadline)
        external
        payable
        returns (uint256 id)
    {
        if (msg.value < MIN_BOUNTY) revert BountyTooSmall();
        if (workDeadline <= block.timestamp) revert DeadlineInPast();

        id = _bounties.length;
        _bounties.push(
            Bounty({
                poster: msg.sender,
                worker: address(0),
                amount: msg.value,
                workDeadline: workDeadline,
                submittedAt: 0,
                status: Status.Open,
                title: title,
                detailURI: detailURI,
                proofURI: ""
            })
        );
        totalPosted += 1;
        postedCount[msg.sender] += 1;
        emit BountyPosted(id, msg.sender, msg.value, workDeadline, title);
    }

    /// @notice Claim an open bounty. Only Agent ID holders can work bounties.
    function claimBounty(uint256 id) external {
        Bounty storage b = _get(id);
        if (b.status != Status.Open) revert BadStatus();
        if (!isAgent(msg.sender)) revert NotAgentIdHolder();
        b.worker = msg.sender;
        b.status = Status.Claimed;
        _countInteractor(msg.sender);
        emit BountyClaimed(id, msg.sender);
    }

    /// @notice Submit work for a claimed bounty. Only the claiming worker.
    /// @param proofURI Off-chain proof of the finished work.
    function submitWork(uint256 id, string calldata proofURI) external {
        Bounty storage b = _get(id);
        if (msg.sender != b.worker) revert NotWorker();
        if (b.status != Status.Claimed && b.status != Status.Submitted) revert BadStatus();
        // A fresh submission is allowed while Claimed; re-submission after a
        // rejection returns the bounty to Claimed, so Submitted -> Submitted is
        // not reachable, but accepting both keeps the rule simple: the worker
        // may refine their proof until the poster acts.
        b.proofURI = proofURI;
        b.submittedAt = uint64(block.timestamp);
        b.status = Status.Submitted;
        _countInteractor(msg.sender);
        emit WorkSubmitted(id, msg.sender, proofURI);
    }

    /// @notice Poster rejects a submission; the bounty returns to Claimed so the
    ///         worker can improve and resubmit before the work deadline.
    function rejectWork(uint256 id) external {
        Bounty storage b = _get(id);
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != Status.Submitted) revert BadStatus();
        b.status = Status.Claimed;
        b.submittedAt = 0;
        emit WorkRejected(id, msg.sender);
    }

    /// @notice Poster approves the submission and releases the escrow to the worker.
    function approveAndRelease(uint256 id) external nonReentrant {
        Bounty storage b = _get(id);
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != Status.Submitted) revert BadStatus();
        _release(id, b, true);
    }

    /// @notice Worker releases the escrow themselves when the poster has not
    ///         reacted within REVIEW_WINDOW after the submission.
    function releaseAfterReviewWindow(uint256 id) external nonReentrant {
        Bounty storage b = _get(id);
        if (msg.sender != b.worker) revert NotWorker();
        if (b.status != Status.Submitted) revert BadStatus();
        if (block.timestamp < uint256(b.submittedAt) + REVIEW_WINDOW) revert ReviewWindowOpen();
        _release(id, b, false);
    }

    /// @notice Poster cancels a bounty that nobody has claimed yet.
    function cancelBounty(uint256 id) external nonReentrant {
        Bounty storage b = _get(id);
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != Status.Open) revert BadStatus();
        _refund(id, b, "cancelled");
    }

    /// @notice Poster reclaims the escrow when the work deadline passed without
    ///         any submission (status Claimed, never submitted).
    function reclaimExpired(uint256 id) external nonReentrant {
        Bounty storage b = _get(id);
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != Status.Claimed) revert BadStatus();
        if (block.timestamp <= b.workDeadline) revert DeadlineNotReached();
        _refund(id, b, "expired");
    }

    /// @notice Poster reclaims the escrow of an unclaimed bounty after its deadline.
    function reclaimUnclaimed(uint256 id) external nonReentrant {
        Bounty storage b = _get(id);
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != Status.Open) revert BadStatus();
        if (block.timestamp <= b.workDeadline) revert DeadlineNotReached();
        _refund(id, b, "unclaimed");
    }

    // ----- views -----

    function bountyCount() external view returns (uint256) {
        return _bounties.length;
    }

    function getBounty(uint256 id) external view returns (Bounty memory) {
        return _get(id);
    }

    /// @notice Read a page of bounties (newest last). For the web board.
    function getBounties(uint256 offset, uint256 limit) external view returns (Bounty[] memory page) {
        uint256 n = _bounties.length;
        if (offset >= n || limit == 0) return new Bounty[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        page = new Bounty[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _bounties[i];
        }
    }

    // ----- internals -----

    function _get(uint256 id) internal view returns (Bounty storage) {
        // Out-of-range ids revert here, which is the intended behaviour.
        return _bounties[id];
    }

    function _countInteractor(address account) internal {
        if (!_countedInteractor[account]) {
            _countedInteractor[account] = true;
            agentInteractors += 1;
        }
    }

    function _release(uint256 id, Bounty storage b, bool byPoster) internal {
        uint256 amount = b.amount;
        address worker = b.worker;
        b.status = Status.Released;
        b.amount = 0;
        completedCount[worker] += 1;
        totalEarned[worker] += amount;
        totalReleasedVolume += amount;
        (bool ok,) = worker.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BountyReleased(id, worker, amount, byPoster);
    }

    function _refund(uint256 id, Bounty storage b, string memory reason) internal {
        uint256 amount = b.amount;
        address poster = b.poster;
        b.status = Status.Refunded;
        b.amount = 0;
        (bool ok,) = poster.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BountyRefunded(id, poster, amount, reason);
    }
}

