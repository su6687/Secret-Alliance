// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./GameCore.sol";

/**
 * @title VotingSystem
 * @dev 处理游戏中加密投票系统的合约
 */
contract VotingSystem is Ownable, ReentrancyGuard, GatewayCaller {
    using TFHE for euint8;
    using TFHE for euint32;
    using TFHE for ebool;

    // 投票类型枚举
    enum VoteType {
        Elimination,    // 淘汰投票
        Policy,         // 政策投票
        Alliance,       // 联盟投票
        Emergency       // 紧急投票
    }

    // 投票选项结构体
    struct VoteOption {
        euint8 optionId;        // 加密的选项ID
        euint32 voteCount;      // 加密的票数
        string description;      // 选项描述
        bool isActive;          // 是否激活
    }

    // 投票会话结构体
    struct VotingSession {
        uint256 sessionId;
        uint256 roomId;
        VoteType voteType;
        uint256 startTime;
        uint256 endTime;
        euint8 totalVoters;     // 加密的总投票人数
        euint8 votesReceived;   // 加密的已收到票数
        VoteOption[] options;
        mapping(address => ebool) hasVoted;
        mapping(address => euint8) voterChoice; // 加密的投票选择
        bool isActive;
        bool isFinalized;
        euint8 winningOption;   // 加密的获胜选项
    }

    // 投票权重结构体
    struct VoteWeight {
        euint32 baseWeight;     // 基础权重
        euint32 roleBonus;      // 角色加成
        euint32 resourceBonus;  // 资源加成
        euint32 totalWeight;    // 总权重
    }

    GameCore public gameCore;
    
    uint256 public nextSessionId = 1;
    uint256 public constant VOTING_DURATION = 180; // 3分钟投票时间
    uint256 public constant MIN_PARTICIPATION = 50; // 最小参与率50%
    
    mapping(uint256 => VotingSession) public votingSessions;
    mapping(uint256 => mapping(address => VoteWeight)) public voteWeights; // sessionId => voter => weight
    mapping(uint256 => uint256) public roomToActiveSession; // roomId => sessionId
    mapping(address => uint256) public lastVoteTime;
    
    // 投票历史记录
    mapping(uint256 => mapping(address => uint256[])) public voteHistory; // roomId => voter => sessionIds
    
    // 事件
    event VotingSessionCreated(uint256 indexed sessionId, uint256 indexed roomId, VoteType voteType);
    event VoteCast(uint256 indexed sessionId, address indexed voter, uint256 timestamp);
    event VotingSessionFinalized(uint256 indexed sessionId, uint8 winningOption, uint32 totalVotes);
    event VoteWeightCalculated(uint256 indexed sessionId, address indexed voter, uint32 totalWeight);
    event EmergencyVoteTriggered(uint256 indexed roomId, address indexed initiator);
    event VotingSessionCancelled(uint256 indexed sessionId, string reason);

    constructor(address _gameCore) Ownable(msg.sender) {
        gameCore = GameCore(_gameCore);
    }

    /**
     * @dev 创建投票会话
     */
    function createVotingSession(
        uint256 roomId,
        VoteType voteType,
        string[] calldata optionDescriptions,
        uint256 duration
    ) external returns (uint256) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(roomToActiveSession[roomId] == 0, "Active voting session exists");
        require(optionDescriptions.length >= 2, "Need at least 2 options");
        require(optionDescriptions.length <= 10, "Too many options");
        
        // 获取房间信息
        (, uint256 playerCount, GameCore.GamePhase phase,,,) = gameCore.getRoomInfo(roomId);
        require(phase == GameCore.GamePhase.Voting || phase == GameCore.GamePhase.Day, "Invalid phase for voting");
        require(playerCount >= 3, "Not enough players");
        
        uint256 sessionId = nextSessionId++;
        uint256 votingDuration = duration > 0 ? duration : VOTING_DURATION;
        
        VotingSession storage session = votingSessions[sessionId];
        session.sessionId = sessionId;
        session.roomId = roomId;
        session.voteType = voteType;
        session.startTime = block.timestamp;
        session.endTime = block.timestamp + votingDuration;
        session.totalVoters = TFHE.asEuint8(uint8(playerCount));
        session.votesReceived = TFHE.asEuint8(0);
        session.isActive = true;
        session.isFinalized = false;
        
        // 创建投票选项
        for (uint256 i = 0; i < optionDescriptions.length; i++) {
            session.options.push(VoteOption({
                optionId: TFHE.asEuint8(uint8(i)),
                voteCount: TFHE.asEuint32(0),
                description: optionDescriptions[i],
                isActive: true
            }));
        }
        
        roomToActiveSession[roomId] = sessionId;
        
        emit VotingSessionCreated(sessionId, roomId, voteType);
        
        return sessionId;
    }

    /**
     * @dev 投票
     */
    function castVote(
        uint256 sessionId,
        bytes calldata encryptedChoice
    ) external nonReentrant {
        VotingSession storage session = votingSessions[sessionId];
        require(session.isActive, "Voting session not active");
        require(block.timestamp <= session.endTime, "Voting period ended");
        require(gameCore.playerToRoom(msg.sender) == session.roomId, "Player not in room");
        require(!TFHE.decrypt(session.hasVoted[msg.sender]), "Already voted");
        
        // 解密并验证选择
        euint8 choice = TFHE.asEuint8(encryptedChoice);
        require(TFHE.decrypt(TFHE.lt(choice, TFHE.asEuint8(uint8(session.options.length)))), "Invalid choice");
        
        // 计算投票权重
        VoteWeight memory weight = _calculateVoteWeight(sessionId, msg.sender);
        voteWeights[sessionId][msg.sender] = weight;
        
        // 记录投票
        session.hasVoted[msg.sender] = TFHE.asEbool(true);
        session.voterChoice[msg.sender] = choice;
        session.votesReceived = TFHE.add(session.votesReceived, TFHE.asEuint8(1));
        
        // 更新选项票数（使用权重）
        for (uint256 i = 0; i < session.options.length; i++) {
            ebool isChoice = TFHE.eq(choice, TFHE.asEuint8(uint8(i)));
            euint32 weightToAdd = TFHE.select(isChoice, weight.totalWeight, TFHE.asEuint32(0));
            session.options[i].voteCount = TFHE.add(session.options[i].voteCount, weightToAdd);
        }
        
        lastVoteTime[msg.sender] = block.timestamp;
        voteHistory[session.roomId][msg.sender].push(sessionId);
        
        emit VoteCast(sessionId, msg.sender, block.timestamp);
        emit VoteWeightCalculated(sessionId, msg.sender, TFHE.decrypt(weight.totalWeight));
        
        // 检查是否所有人都已投票
        _checkVotingComplete(sessionId);
    }

    /**
     * @dev 计算投票权重
     */
    function _calculateVoteWeight(uint256 sessionId, address voter) internal view returns (VoteWeight memory) {
        VotingSession storage session = votingSessions[sessionId];
        
        // 基础权重
        euint32 baseWeight = TFHE.asEuint32(100);
        
        // 角色加成（需要从GameCore获取角色信息）
        euint32 roleBonus = TFHE.asEuint32(0);
        
        // 资源加成（需要从GameCore获取资源信息）
        euint32 resourceBonus = TFHE.asEuint32(0);
        
        // 计算总权重
        euint32 totalWeight = TFHE.add(TFHE.add(baseWeight, roleBonus), resourceBonus);
        
        return VoteWeight({
            baseWeight: baseWeight,
            roleBonus: roleBonus,
            resourceBonus: resourceBonus,
            totalWeight: totalWeight
        });
    }

    /**
     * @dev 检查投票是否完成
     */
    function _checkVotingComplete(uint256 sessionId) internal {
        VotingSession storage session = votingSessions[sessionId];
        
        // 检查是否所有人都已投票或时间已到
        bool allVoted = TFHE.decrypt(TFHE.eq(session.votesReceived, session.totalVoters));
        bool timeUp = block.timestamp >= session.endTime;
        
        if (allVoted || timeUp) {
            _finalizeVoting(sessionId);
        }
    }

    /**
     * @dev 完成投票并计算结果
     */
    function _finalizeVoting(uint256 sessionId) internal {
        VotingSession storage session = votingSessions[sessionId];
        require(session.isActive, "Session not active");
        require(!session.isFinalized, "Already finalized");
        
        // 找到获胜选项（票数最多的）
        euint8 winningOption = TFHE.asEuint8(0);
        euint32 maxVotes = session.options[0].voteCount;
        
        for (uint256 i = 1; i < session.options.length; i++) {
            ebool hasMoreVotes = TFHE.gt(session.options[i].voteCount, maxVotes);
            winningOption = TFHE.select(hasMoreVotes, TFHE.asEuint8(uint8(i)), winningOption);
            maxVotes = TFHE.select(hasMoreVotes, session.options[i].voteCount, maxVotes);
        }
        
        session.winningOption = winningOption;
        session.isFinalized = true;
        session.isActive = false;
        
        // 清除房间的活跃投票会话
        roomToActiveSession[session.roomId] = 0;
        
        emit VotingSessionFinalized(sessionId, TFHE.decrypt(winningOption), TFHE.decrypt(maxVotes));
        
        // 执行投票结果
        _executeVoteResult(sessionId);
    }

    /**
     * @dev 执行投票结果
     */
    function _executeVoteResult(uint256 sessionId) internal {
        VotingSession storage session = votingSessions[sessionId];
        
        if (session.voteType == VoteType.Elimination) {
            // 处理淘汰投票结果
            _handleEliminationVote(sessionId);
        } else if (session.voteType == VoteType.Policy) {
            // 处理政策投票结果
            _handlePolicyVote(sessionId);
        } else if (session.voteType == VoteType.Alliance) {
            // 处理联盟投票结果
            _handleAllianceVote(sessionId);
        } else if (session.voteType == VoteType.Emergency) {
            // 处理紧急投票结果
            _handleEmergencyVote(sessionId);
        }
    }

    /**
     * @dev 处理淘汰投票结果
     */
    function _handleEliminationVote(uint256 sessionId) internal {
        VotingSession storage session = votingSessions[sessionId];
        uint8 eliminatedPlayerIndex = TFHE.decrypt(session.winningOption);
        
        // 这里需要与GameCore交互来淘汰玩家
        // 由于隐私限制，实际实现会更复杂
    }

    /**
     * @dev 处理政策投票结果
     */
    function _handlePolicyVote(uint256 sessionId) internal {
        // 实现政策投票结果处理
    }

    /**
     * @dev 处理联盟投票结果
     */
    function _handleAllianceVote(uint256 sessionId) internal {
        // 实现联盟投票结果处理
    }

    /**
     * @dev 处理紧急投票结果
     */
    function _handleEmergencyVote(uint256 sessionId) internal {
        // 实现紧急投票结果处理
    }

    /**
     * @dev 手动完成投票（管理员或时间到期）
     */
    function finalizeVoting(uint256 sessionId) external {
        VotingSession storage session = votingSessions[sessionId];
        require(session.isActive, "Session not active");
        require(
            block.timestamp >= session.endTime || 
            msg.sender == owner() ||
            gameCore.playerToRoom(msg.sender) == session.roomId,
            "Not authorized to finalize"
        );
        
        _finalizeVoting(sessionId);
    }

    /**
     * @dev 取消投票会话
     */
    function cancelVotingSession(uint256 sessionId, string calldata reason) external {
        VotingSession storage session = votingSessions[sessionId];
        require(session.isActive, "Session not active");
        require(
            msg.sender == owner() ||
            gameCore.playerToRoom(msg.sender) == session.roomId,
            "Not authorized to cancel"
        );
        
        session.isActive = false;
        roomToActiveSession[session.roomId] = 0;
        
        emit VotingSessionCancelled(sessionId, reason);
    }

    /**
     * @dev 触发紧急投票
     */
    function triggerEmergencyVote(
        uint256 roomId,
        string[] calldata options
    ) external returns (uint256) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(roomToActiveSession[roomId] == 0, "Active voting session exists");
        
        emit EmergencyVoteTriggered(roomId, msg.sender);
        
        return createVotingSession(roomId, VoteType.Emergency, options, VOTING_DURATION / 2);
    }

    /**
     * @dev 获取投票会话信息
     */
    function getVotingSessionInfo(uint256 sessionId) external view returns (
        uint256,
        uint256,
        VoteType,
        uint256,
        uint256,
        uint256,
        bool,
        bool
    ) {
        VotingSession storage session = votingSessions[sessionId];
        return (
            session.sessionId,
            session.roomId,
            session.voteType,
            session.startTime,
            session.endTime,
            session.options.length,
            session.isActive,
            session.isFinalized
        );
    }

    /**
     * @dev 获取投票选项信息
     */
    function getVoteOption(uint256 sessionId, uint256 optionIndex) external view returns (
        string memory,
        bool
    ) {
        VotingSession storage session = votingSessions[sessionId];
        require(optionIndex < session.options.length, "Invalid option index");
        
        VoteOption storage option = session.options[optionIndex];
        return (
            option.description,
            option.isActive
        );
    }

    /**
     * @dev 检查玩家是否已投票
     */
    function hasPlayerVoted(uint256 sessionId, address player) external view returns (bool) {
        return TFHE.decrypt(votingSessions[sessionId].hasVoted[player]);
    }

    /**
     * @dev 获取玩家投票历史
     */
    function getPlayerVoteHistory(uint256 roomId, address player) external view returns (uint256[] memory) {
        return voteHistory[roomId][player];
    }

    /**
     * @dev 获取房间的活跃投票会话
     */
    function getActiveVotingSession(uint256 roomId) external view returns (uint256) {
        return roomToActiveSession[roomId];
    }

    /**
     * @dev 更新GameCore合约地址（仅管理员）
     */
    function updateGameCore(address _gameCore) external onlyOwner {
        gameCore = GameCore(_gameCore);
    }

    /**
     * @dev 设置投票参数（仅管理员）
     */
    function setVotingParameters(
        uint256 _votingDuration,
        uint256 _minParticipation
    ) external onlyOwner {
        // 在实际实现中更新投票参数
    }
}