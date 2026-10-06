// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title InkRunner
/// @notice Paid arcade runs on Ink. Every run costs a fixed fee in ETH.
///         The whole pot of a round is split between the top 10 scores.
///         Winnings are pull-based: finalizeRound credits balances, players claim.
contract InkRunner {
    // ----------------------------------------------------------------- config

    address public owner;
    uint256 public entryFee;        // wei per run
    uint256 public roundDuration;   // seconds
    bool public paused;

    uint16 public constant MAX_JUMPS = 512;
    uint32 public constant MAX_SCORE = 100_000;
    uint256 public constant SUBMIT_WINDOW = 1 hours;
    uint8 public constant TOP_N = 10;

    /// @dev payout weights in basis points, must sum to 10_000
    uint16[10] public weights = [3000, 2000, 1200, 1000, 800, 600, 500, 400, 300, 200];

    // ------------------------------------------------------------------ state

    uint256 public roundId;
    uint256 public roundEndsAt;
    uint256 public pot;             // ETH held for the current round
    uint256 public totalClaimable;  // ETH already credited to winners
    uint256 public nextRunId = 1;

    struct Run {
        address player;
        uint64 startedAt;
        uint64 round;
        bool submitted;
        bytes32 seed;
    }

    struct Entry {
        address player;
        uint32 score;
        uint256 runId;
    }

    mapping(uint256 => Run) public runs;
    Entry[10] public leaderboard;                 // current round, sorted desc
    mapping(address => uint256) public claimable;

    // ----------------------------------------------------------------- events

    event RunStarted(uint256 indexed runId, address indexed player, uint256 indexed round, bytes32 seed);
    event ScoreSubmitted(uint256 indexed runId, address indexed player, uint256 indexed round, uint32 score, uint16[] jumps);
    event RoundFinalized(uint256 indexed round, uint256 distributed, uint256 rolledOver);
    event Claimed(address indexed player, uint256 amount);
    event EntryFeeChanged(uint256 oldFee, uint256 newFee);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ------------------------------------------------------------------ setup

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(uint256 _entryFee, uint256 _roundDuration) {
        require(_roundDuration >= 1 hours, "round too short");
        owner = msg.sender;
        entryFee = _entryFee;
        roundDuration = _roundDuration;
        roundId = 1;
        roundEndsAt = block.timestamp + _roundDuration;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ----------------------------------------------------------------- playing

    /// @notice Pay the entry fee and open a run. The returned seed drives the level.
    function startRun() external payable returns (uint256 runId, bytes32 seed) {
        require(!paused, "paused");
        require(msg.value == entryFee, "wrong fee");
        require(block.timestamp < roundEndsAt, "round over");

        runId = nextRunId++;
        seed = keccak256(
            abi.encodePacked(blockhash(block.number - 1), msg.sender, runId, block.timestamp)
        );

        runs[runId] = Run({
            player: msg.sender,
            startedAt: uint64(block.timestamp),
            round: uint64(roundId),
            submitted: false,
            seed: seed
        });

        pot += msg.value;
        emit RunStarted(runId, msg.sender, roundId, seed);
    }

    /// @notice Close a run with its score and the full jump timeline.
    /// @param jumps frame index of every jump, recorded onchain in the event log
    function submitScore(uint256 runId, uint32 score, uint16[] calldata jumps) external {
        Run storage r = runs[runId];
        require(r.player == msg.sender, "not your run");
        require(!r.submitted, "already submitted");
        require(block.timestamp <= r.startedAt + SUBMIT_WINDOW, "submit window closed");
        require(r.round == roundId, "round moved on");
        require(score <= MAX_SCORE, "score too high");
        require(jumps.length <= MAX_JUMPS, "too many jumps");

        r.submitted = true;
        _insert(msg.sender, score, runId);

        emit ScoreSubmitted(runId, msg.sender, roundId, score, jumps);
    }

    function _insert(address player, uint32 score, uint256 runId_) internal {
        if (score == 0) return;
        if (score <= leaderboard[TOP_N - 1].score) return;

        uint256 at = TOP_N - 1;
        while (at > 0 && leaderboard[at - 1].score < score) {
            leaderboard[at] = leaderboard[at - 1];
            unchecked { at--; }
        }
        leaderboard[at] = Entry({player: player, score: score, runId: runId_});
    }

    // --------------------------------------------------------------- settlement

    /// @notice Split the pot between the top 10 and open the next round.
    ///         Callable by anyone once the round has ended, so payouts never
    ///         depend on the owner showing up.
    function finalizeRound() external {
        require(block.timestamp >= roundEndsAt, "round still running");

        uint256 available = pot;
        uint256 distributed;

        for (uint256 i = 0; i < TOP_N; i++) {
            Entry memory e = leaderboard[i];
            if (e.player == address(0)) continue;
            uint256 cut = (available * weights[i]) / 10_000;
            if (cut == 0) continue;
            claimable[e.player] += cut;
            distributed += cut;
        }

        uint256 rolledOver = available - distributed;
        pot = rolledOver;
        totalClaimable += distributed;

        emit RoundFinalized(roundId, distributed, rolledOver);

        delete leaderboard;
        roundId += 1;
        roundEndsAt = block.timestamp + roundDuration;
    }

    function claim() external {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "nothing to claim");
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        emit Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- read-only

    function getLeaderboard() external view returns (Entry[10] memory) {
        return leaderboard;
    }

    function timeLeft() external view returns (uint256) {
        return block.timestamp >= roundEndsAt ? 0 : roundEndsAt - block.timestamp;
    }

    // -------------------------------------------------------------------- admin

    function setEntryFee(uint256 newFee) external onlyOwner {
        emit EntryFeeChanged(entryFee, newFee);
        entryFee = newFee;
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setRoundDuration(uint256 d) external onlyOwner {
        require(d >= 1 hours, "round too short");
        roundDuration = d;
    }

    function transferOwnership(address to) external onlyOwner {
        require(to != address(0), "zero address");
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    /// @dev Only ETH that is neither in the pot nor owed to players can be moved.
    function sweepUnaccounted(address to) external onlyOwner {
        uint256 owed = pot + totalClaimable;
        require(address(this).balance > owed, "nothing unaccounted");
        uint256 amount = address(this).balance - owed;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
