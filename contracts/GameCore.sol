// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title GameCore
 * @dev 隐秘联盟游戏的核心合约，使用FHEVM实现隐私保护
 */
contract GameCore is Ownable, ReentrancyGuard, Pausable, GatewayCaller {
    using TFHE for euint8;
    using TFHE for euint32;
    using TFHE for euint64;
    using TFHE for ebool;

    // 游戏状态枚举
    enum GamePhase {
        Waiting,    // 等待玩家
        Day,        // 白天讨论阶段
        Night,      // 夜晚行动阶段
        Voting,     // 投票阶段
        Ended       // 游戏结束
    }

    // 角色类型枚举
    enum RoleType {
        Guardian,     // 守护者
        Infiltrator,  // 渗透者
        Detective,    // 侦探
        Merchant,     // 商人
        Hacker        // 黑客
    }

    // 玩家结构体
    struct Player {
        address playerAddress;
        euint8 role;           // 加密的角色
        euint32 health;        // 加密的生命值
        euint32 resources;     // 加密的资源
        ebool isAlive;         // 加密的存活状态
        ebool hasVoted;        // 是否已投票
        uint256 joinTime;      // 加入时间
    }

    // 游戏房间结构体
    struct GameRoom {
        uint256 roomId;
        address[] players;
        mapping(address => Player) playerData;
        GamePhase currentPhase;
        uint256 phaseStartTime;
        uint256 dayCount;
        euint8 aliveCount;     // 加密的存活玩家数
        bool isActive;
        address winner;
    }

    // 投票结构体
    struct Vote {
        euint8 targetIndex;    // 加密的目标玩家索引
        uint256 timestamp;
    }

    // 状态变量
    uint256 public nextRoomId = 1;
    uint256 public constant MAX_PLAYERS = 10;
    uint256 public constant MIN_PLAYERS = 4;
    uint256 public constant PHASE_DURATION = 300; // 5分钟
    
    mapping(uint256 => GameRoom) public gameRooms;
    mapping(address => uint256) public playerToRoom;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(uint256 => mapping(uint256 => euint8)) public phaseActions; // 夜晚行动

    // 事件
    event RoomCreated(uint256 indexed roomId, address indexed creator);
    event PlayerJoined(uint256 indexed roomId, address indexed player);
    event GameStarted(uint256 indexed roomId);
    event PhaseChanged(uint256 indexed roomId, GamePhase newPhase);
    event PlayerEliminated(uint256 indexed roomId, address indexed player);
    event GameEnded(uint256 indexed roomId, address indexed winner, RoleType winningTeam);
    event VoteCast(uint256 indexed roomId, address indexed voter);
    event ActionPerformed(uint256 indexed roomId, address indexed player, uint8 actionType);

    constructor() Ownable(msg.sender) {}

    /**
     * @dev 创建新的游戏房间
     */
    function createRoom() external whenNotPaused returns (uint256) {
        require(playerToRoom[msg.sender] == 0, "Player already in a room");
        
        uint256 roomId = nextRoomId++;
        GameRoom storage room = gameRooms[roomId];
        
        room.roomId = roomId;
        room.currentPhase = GamePhase.Waiting;
        room.phaseStartTime = block.timestamp;
        room.dayCount = 0;
        room.isActive = true;
        
        // 创建者自动加入房间
        _joinRoom(roomId, msg.sender);
        
        emit RoomCreated(roomId, msg.sender);
        return roomId;
    }

    /**
     * @dev 加入游戏房间
     */
    function joinRoom(uint256 roomId) external whenNotPaused {
        require(playerToRoom[msg.sender] == 0, "Player already in a room");
        require(gameRooms[roomId].isActive, "Room not active");
        require(gameRooms[roomId].currentPhase == GamePhase.Waiting, "Game already started");
        require(gameRooms[roomId].players.length < MAX_PLAYERS, "Room is full");
        
        _joinRoom(roomId, msg.sender);
    }

    /**
     * @dev 内部函数：玩家加入房间
     */
    function _joinRoom(uint256 roomId, address player) internal {
        GameRoom storage room = gameRooms[roomId];
        
        room.players.push(player);
        playerToRoom[player] = roomId;
        
        // 初始化玩家数据（角色将在游戏开始时分配）
        Player storage playerData = room.playerData[player];
        playerData.playerAddress = player;
        playerData.health = TFHE.asEuint32(100); // 初始生命值100
        playerData.resources = TFHE.asEuint32(50); // 初始资源50
        playerData.isAlive = TFHE.asEbool(true);
        playerData.hasVoted = TFHE.asEbool(false);
        playerData.joinTime = block.timestamp;
        
        emit PlayerJoined(roomId, player);
        
        // 如果达到最小玩家数，可以开始游戏
        if (room.players.length >= MIN_PLAYERS) {
            // 自动开始游戏或等待手动开始
        }
    }

    /**
     * @dev 开始游戏
     */
    function startGame(uint256 roomId) external whenNotPaused {
        GameRoom storage room = gameRooms[roomId];
        require(room.isActive, "Room not active");
        require(room.currentPhase == GamePhase.Waiting, "Game already started");
        require(room.players.length >= MIN_PLAYERS, "Not enough players");
        require(playerToRoom[msg.sender] == roomId, "Not in this room");
        
        // 分配角色
        _assignRoles(roomId);
        
        // 设置游戏状态
        room.currentPhase = GamePhase.Day;
        room.phaseStartTime = block.timestamp;
        room.dayCount = 1;
        room.aliveCount = TFHE.asEuint8(uint8(room.players.length));
        
        emit GameStarted(roomId);
        emit PhaseChanged(roomId, GamePhase.Day);
    }

    /**
     * @dev 内部函数：分配角色
     */
    function _assignRoles(uint256 roomId) internal {
        GameRoom storage room = gameRooms[roomId];
        uint256 playerCount = room.players.length;
        
        // 简化的角色分配逻辑
        // 实际实现中应该使用更复杂的随机数生成
        for (uint256 i = 0; i < playerCount; i++) {
            address player = room.players[i];
            uint8 roleValue;
            
            if (i == 0) {
                roleValue = uint8(RoleType.Infiltrator); // 第一个玩家是渗透者
            } else if (i == 1 && playerCount > 5) {
                roleValue = uint8(RoleType.Detective); // 侦探
            } else if (i == 2 && playerCount > 7) {
                roleValue = uint8(RoleType.Hacker); // 黑客
            } else {
                roleValue = uint8(RoleType.Guardian); // 其他都是守护者
            }
            
            room.playerData[player].role = TFHE.asEuint8(roleValue);
        }
    }

    /**
     * @dev 投票淘汰玩家
     */
    function vote(uint256 roomId, bytes calldata encryptedTargetIndex) external whenNotPaused {
        GameRoom storage room = gameRooms[roomId];
        require(room.isActive, "Room not active");
        require(room.currentPhase == GamePhase.Voting, "Not voting phase");
        require(playerToRoom[msg.sender] == roomId, "Not in this room");
        require(TFHE.decrypt(room.playerData[msg.sender].isAlive), "Player is dead");
        require(!TFHE.decrypt(room.playerData[msg.sender].hasVoted), "Already voted");
        
        // 解密并验证目标索引
        euint8 targetIndex = TFHE.asEuint8(encryptedTargetIndex);
        
        // 记录投票
        votes[roomId][msg.sender] = Vote({
            targetIndex: targetIndex,
            timestamp: block.timestamp
        });
        
        room.playerData[msg.sender].hasVoted = TFHE.asEbool(true);
        
        emit VoteCast(roomId, msg.sender);
        
        // 检查是否所有存活玩家都已投票
        _checkVotingComplete(roomId);
    }

    /**
     * @dev 检查投票是否完成
     */
    function _checkVotingComplete(uint256 roomId) internal {
        GameRoom storage room = gameRooms[roomId];
        
        // 简化的投票检查逻辑
        // 实际实现中需要更复杂的FHE计算来统计投票
        
        // 进入夜晚阶段
        room.currentPhase = GamePhase.Night;
        room.phaseStartTime = block.timestamp;
        
        emit PhaseChanged(roomId, GamePhase.Night);
    }

    /**
     * @dev 执行夜晚行动
     */
    function performNightAction(uint256 roomId, bytes calldata encryptedAction) external whenNotPaused {
        GameRoom storage room = gameRooms[roomId];
        require(room.isActive, "Room not active");
        require(room.currentPhase == GamePhase.Night, "Not night phase");
        require(playerToRoom[msg.sender] == roomId, "Not in this room");
        require(TFHE.decrypt(room.playerData[msg.sender].isAlive), "Player is dead");
        
        euint8 action = TFHE.asEuint8(encryptedAction);
        
        // 根据角色执行不同的行动
        // 这里需要复杂的FHE逻辑来处理不同角色的能力
        
        emit ActionPerformed(roomId, msg.sender, 1); // 简化的事件
    }

    /**
     * @dev 推进游戏阶段（管理员或自动调用）
     */
    function advancePhase(uint256 roomId) external {
        GameRoom storage room = gameRooms[roomId];
        require(room.isActive, "Room not active");
        require(
            block.timestamp >= room.phaseStartTime + PHASE_DURATION || 
            msg.sender == owner(),
            "Phase not ready to advance"
        );
        
        if (room.currentPhase == GamePhase.Day) {
            room.currentPhase = GamePhase.Voting;
        } else if (room.currentPhase == GamePhase.Voting) {
            room.currentPhase = GamePhase.Night;
        } else if (room.currentPhase == GamePhase.Night) {
            room.currentPhase = GamePhase.Day;
            room.dayCount++;
        }
        
        room.phaseStartTime = block.timestamp;
        
        // 重置投票状态
        if (room.currentPhase == GamePhase.Day) {
            for (uint256 i = 0; i < room.players.length; i++) {
                room.playerData[room.players[i]].hasVoted = TFHE.asEbool(false);
            }
        }
        
        emit PhaseChanged(roomId, room.currentPhase);
        
        // 检查游戏结束条件
        _checkGameEnd(roomId);
    }

    /**
     * @dev 检查游戏结束条件
     */
    function _checkGameEnd(uint256 roomId) internal {
        GameRoom storage room = gameRooms[roomId];
        
        // 简化的游戏结束逻辑
        // 实际实现需要复杂的FHE计算来确定获胜条件
        
        if (room.dayCount >= 10) { // 简单的时间限制
            room.currentPhase = GamePhase.Ended;
            room.isActive = false;
            emit GameEnded(roomId, address(0), RoleType.Guardian);
        }
    }

    /**
     * @dev 离开房间
     */
    function leaveRoom() external {
        uint256 roomId = playerToRoom[msg.sender];
        require(roomId != 0, "Not in any room");
        
        GameRoom storage room = gameRooms[roomId];
        require(room.currentPhase == GamePhase.Waiting, "Cannot leave during game");
        
        // 从玩家列表中移除
        for (uint256 i = 0; i < room.players.length; i++) {
            if (room.players[i] == msg.sender) {
                room.players[i] = room.players[room.players.length - 1];
                room.players.pop();
                break;
            }
        }
        
        delete room.playerData[msg.sender];
        delete playerToRoom[msg.sender];
        
        // 如果房间空了，标记为非活跃
        if (room.players.length == 0) {
            room.isActive = false;
        }
    }

    /**
     * @dev 获取房间信息
     */
    function getRoomInfo(uint256 roomId) external view returns (
        uint256,
        uint256,
        GamePhase,
        uint256,
        uint256,
        bool
    ) {
        GameRoom storage room = gameRooms[roomId];
        return (
            room.roomId,
            room.players.length,
            room.currentPhase,
            room.phaseStartTime,
            room.dayCount,
            room.isActive
        );
    }

    /**
     * @dev 获取玩家在房间中的公开信息
     */
    function getPlayerPublicInfo(uint256 roomId, address player) external view returns (
        address,
        uint256,
        bool
    ) {
        GameRoom storage room = gameRooms[roomId];
        Player storage playerData = room.playerData[player];
        
        return (
            playerData.playerAddress,
            playerData.joinTime,
            playerToRoom[player] == roomId
        );
    }

    /**
     * @dev 紧急停止游戏（仅管理员）
     */
    function emergencyStop(uint256 roomId) external onlyOwner {
        GameRoom storage room = gameRooms[roomId];
        room.currentPhase = GamePhase.Ended;
        room.isActive = false;
        
        // 清理玩家房间映射
        for (uint256 i = 0; i < room.players.length; i++) {
            delete playerToRoom[room.players[i]];
        }
        
        emit GameEnded(roomId, address(0), RoleType.Guardian);
    }

    /**
     * @dev 暂停/恢复合约（仅管理员）
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}