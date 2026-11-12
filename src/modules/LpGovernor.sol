// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IOFTAdapter} from "../interfaces/IExternal.sol";
import {ILpDesk, IPriceGuard, OpenParams, VenueKind} from "../interfaces/ILpDesk.sol";

/// @notice LpDesk module (SPEC.md section 2a): staking, proposals, votes, the operator veto, execution and the
/// permanent bridge records. Deployed by LpDesk.deployModule; msg.sender is its LpDesk. NOTSTOCK moves only back
/// to its staker.
contract LpGovernor {
    enum Kind {
        OpenPosition,
        AddAsset,
        AddVenue,
        AddBridge,
        BridgeOut
    }

    enum State {
        Voting,
        Failed,
        Passed, // veto window
        Vetoed,
        Executable,
        Executed,
        Expired
    }

    struct Checkpoint {
        uint48 fromBlock;
        uint208 amount;
    }

    struct Proposal {
        Kind kind;
        address author;
        bool byOperator;
        bool executed;
        bool vetoed;
        uint64 createdAt;
        uint48 snapshotBlock;
        uint256 quorumBase;
        uint256 forWeight;
        uint256 againstWeight;
        OpenParams open;
        address target; // AddAsset asset, AddVenue position manager, AddBridge adapter
        VenueKind venueKind;
        uint32 dstEid;
        address dstLpDesk;
        uint256 bridgeId;
        uint256 amount;
    }

    struct BridgeRecord {
        address adapter;
        uint32 dstEid;
        address dstLpDesk;
    }

    address public immutable lpDesk;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant VETO_WINDOW = 2 days;
    uint256 public constant EXECUTION_WINDOW = 259_200; // 3 days
    uint256 public constant QUORUM_BPS = 300; // 3%
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 10; // 0.1%

    mapping(address => uint256) public staked;
    uint256 public totalStaked;
    mapping(address => Checkpoint[]) private _stakeHistory;
    Checkpoint[] private _totalHistory;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev open proposal id + 1 per kind, by author class (false = other stakers, true = operator)
    mapping(Kind => mapping(bool => uint256)) private _openSlot;

    BridgeRecord[] private _bridges;
    mapping(uint256 => uint256) public bridgedOut;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Proposed(uint256 indexed id, Kind kind, address indexed author, bool byOperator);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event Vetoed(uint256 indexed id);
    event Executed(uint256 indexed id);
    event BridgeAdded(uint256 indexed bridgeId, address adapter, uint32 dstEid, address dstLpDesk);

    error ZeroAmount();
    error InsufficientStake();
    error BelowThreshold();
    error KindAlreadyOpen();
    error AboveFreeBalance();
    error WrongState();
    error AlreadyVoted();
    error NoWeight();
    error NotOperator();
    error BadBridge();
    error UnknownBridge();
    error NoValueExpected();

    constructor() {
        lpDesk = msg.sender;
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(ILpDesk(lpDesk).notStock());
        require(token.transferFrom(msg.sender, address(this), amount));
        _write(_stakeHistory[msg.sender], staked[msg.sender] += amount);
        _write(_totalHistory, totalStaked += amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = staked[msg.sender];
        if (bal < amount) revert InsufficientStake();
        _write(_stakeHistory[msg.sender], staked[msg.sender] = bal - amount);
        _write(_totalHistory, totalStaked -= amount);
        require(IERC20(ILpDesk(lpDesk).notStock()).transfer(msg.sender, amount));
        emit Unstaked(msg.sender, amount);
    }

    function stakeAt(address account, uint256 blockNumber) public view returns (uint256) {
        return _lookup(_stakeHistory[account], blockNumber);
    }

    function totalStakedAt(uint256 blockNumber) public view returns (uint256) {
        return _lookup(_totalHistory, blockNumber);
    }

    function stakeCheckpoints(address account) external view returns (Checkpoint[] memory) {
        return _stakeHistory[account];
    }

    function totalCheckpoints() external view returns (Checkpoint[] memory) {
        return _totalHistory;
    }

    // ---------------------------------------------------------------- proposals

    function proposeOpenPosition(OpenParams calldata p) external returns (uint256 id) {
        if (p.amount > ILpDesk(lpDesk).freeBalance(ILpDesk(lpDesk).notStock())) revert AboveFreeBalance();
        id = _create(Kind.OpenPosition);
        _proposals[id].open = p;
        _proposals[id].amount = p.amount;
    }

    function proposeAddAsset(address asset) external returns (uint256 id) {
        IPriceGuard(ILpDesk(lpDesk).priceGuard()).checkAsset(asset);
        id = _create(Kind.AddAsset);
        _proposals[id].target = asset;
    }

    function proposeAddVenue(address positionManager, VenueKind kind) external returns (uint256 id) {
        IPriceGuard(ILpDesk(lpDesk).priceGuard()).checkVenue(positionManager, kind);
        id = _create(Kind.AddVenue);
        _proposals[id].target = positionManager;
        _proposals[id].venueKind = kind;
    }

    function proposeAddBridge(address adapter, uint32 dstEid, address dstLpDesk) external returns (uint256 id) {
        _checkAdapter(adapter, dstLpDesk);
        id = _create(Kind.AddBridge);
        _proposals[id].target = adapter;
        _proposals[id].dstEid = dstEid;
        _proposals[id].dstLpDesk = dstLpDesk;
    }

    function proposeBridgeOut(uint256 bridgeId, uint256 amount) external returns (uint256 id) {
        if (bridgeId >= _bridges.length) revert UnknownBridge();
        if (amount == 0) revert ZeroAmount();
        if (amount > ILpDesk(lpDesk).freeBalance(ILpDesk(lpDesk).notStock())) revert AboveFreeBalance();
        id = _create(Kind.BridgeOut);
        _proposals[id].bridgeId = bridgeId;
        _proposals[id].amount = amount;
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = _proposals[id];
        if (state(id) != State.Voting) revert WrongState();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 weight = stakeAt(msg.sender, p.snapshotBlock);
        if (weight == 0) revert NoWeight();
        hasVoted[id][msg.sender] = true;
        if (support) p.forWeight += weight;
        else p.againstWeight += weight;
        emit Voted(id, msg.sender, support, weight);
    }

    /// @notice Operator only, inside the 2-day window after a pass; cancels permanently.
    function veto(uint256 id) external {
        if (msg.sender != ILpDesk(lpDesk).operator()) revert NotOperator();
        if (state(id) != State.Passed) revert WrongState();
        _proposals[id].vetoed = true;
        emit Vetoed(id);
    }

    /// @notice Anyone, once the veto window ended unvetoed and before expiry. BridgeOut takes the LayerZero fee as value.
    function execute(uint256 id) external payable {
        Proposal storage p = _proposals[id];
        if (state(id) != State.Executable) revert WrongState();
        p.executed = true;
        ILpDesk desk = ILpDesk(lpDesk);
        if (p.kind == Kind.BridgeOut) {
            BridgeRecord memory r = _bridges[p.bridgeId];
            bridgedOut[p.bridgeId] += p.amount;
            desk.bridgeOutFromGovernor{value: msg.value}(r.adapter, r.dstEid, r.dstLpDesk, p.amount, msg.sender);
        } else {
            if (msg.value != 0) revert NoValueExpected();
            if (p.kind == Kind.OpenPosition) {
                desk.openFromGovernor(p.open);
            } else if (p.kind == Kind.AddAsset) {
                desk.addAssetFromGovernor(p.target);
            } else if (p.kind == Kind.AddVenue) {
                desk.addVenueFromGovernor(p.target, p.venueKind);
            } else {
                _checkAdapter(p.target, p.dstLpDesk);
                _bridges.push(BridgeRecord({adapter: p.target, dstEid: p.dstEid, dstLpDesk: p.dstLpDesk}));
                emit BridgeAdded(_bridges.length - 1, p.target, p.dstEid, p.dstLpDesk);
            }
        }
        emit Executed(id);
    }

    // ---------------------------------------------------------------- views

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function bridges() external view returns (BridgeRecord[] memory) {
        return _bridges;
    }

    function bridgeCount() external view returns (uint256) {
        return _bridges.length;
    }

    /// @notice Vote end, veto window end and expiry time of a proposal.
    function deadlines(uint256 id) external view returns (uint256 voteEnd, uint256 vetoEnd, uint256 expiry) {
        uint256 c = _proposals[id].createdAt;
        voteEnd = c + VOTING_PERIOD;
        vetoEnd = voteEnd + VETO_WINDOW;
        expiry = vetoEnd + EXECUTION_WINDOW;
    }

    function state(uint256 id) public view returns (State) {
        Proposal storage p = _proposals[id];
        if (p.executed) return State.Executed;
        if (p.vetoed) return State.Vetoed;
        uint256 voteEnd = p.createdAt + VOTING_PERIOD;
        if (block.timestamp < voteEnd) return State.Voting;
        uint256 cast = p.forWeight + p.againstWeight;
        bool quorum = p.quorumBase > 0 && cast * 10_000 >= p.quorumBase * QUORUM_BPS;
        if (!quorum || p.forWeight <= p.againstWeight) return State.Failed;
        if (block.timestamp < voteEnd + VETO_WINDOW) return State.Passed;
        if (block.timestamp < voteEnd + VETO_WINDOW + EXECUTION_WINDOW) return State.Executable;
        return State.Expired;
    }

    function isOpen(uint256 id) public view returns (bool) {
        State s = state(id);
        return s == State.Voting || s == State.Passed || s == State.Executable;
    }

    // ---------------------------------------------------------------- internals

    function _create(Kind kind) private returns (uint256 id) {
        bool byOperator = msg.sender == ILpDesk(lpDesk).operator();
        uint256 mine = staked[msg.sender];
        if (!byOperator) {
            // A holder with a staked balance of at least 0.1% of all currently staked NOTSTOCK (a zero stake is none).
            if (mine == 0 || mine * 10_000 < totalStaked * PROPOSAL_THRESHOLD_BPS) revert BelowThreshold();
        }
        uint256 slot = _openSlot[kind][byOperator];
        if (slot != 0 && isOpen(slot - 1)) revert KindAlreadyOpen();
        id = _proposals.length;
        _proposals.push();
        Proposal storage p = _proposals[id];
        p.kind = kind;
        p.author = msg.sender;
        p.byOperator = byOperator;
        p.createdAt = uint64(block.timestamp);
        p.snapshotBlock = uint48(block.number - 1);
        p.quorumBase = totalStakedAt(block.number - 1);
        _openSlot[kind][byOperator] = id + 1;
        emit Proposed(id, kind, msg.sender, byOperator);
    }

    function _checkAdapter(address adapter, address dstLpDesk) private view {
        if (adapter.code.length == 0 || dstLpDesk == address(0)) revert BadBridge();
        if (IOFTAdapter(adapter).token() != ILpDesk(lpDesk).notStock()) revert BadBridge();
    }

    function _write(Checkpoint[] storage history, uint256 value) private {
        uint256 n = history.length;
        if (n > 0 && history[n - 1].fromBlock == block.number) {
            history[n - 1].amount = uint208(value);
        } else {
            history.push(Checkpoint({fromBlock: uint48(block.number), amount: uint208(value)}));
        }
    }

    /// @dev Value at the end of `blockNumber`: the last checkpoint with fromBlock <= blockNumber.
    function _lookup(Checkpoint[] storage history, uint256 blockNumber) private view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = history.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (history[mid].fromBlock > blockNumber) hi = mid;
            else lo = mid + 1;
        }
        return lo == 0 ? 0 : history[lo - 1].amount;
    }
}
