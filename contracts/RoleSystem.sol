// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./GameCore.sol";

/**
 * @title RoleSystem
 * @dev 处理游戏中角色系统的合约，包括角色能力和特殊行动
 */
contract RoleSystem is Ownable {
    using TFHE for euint8;
    using TFHE for euint32;
    using TFHE for ebool;

    // 角色能力枚举
    enum AbilityType {
        None,           // 无特殊能力
        Investigate,    // 调查（侦探）
        Eliminate,      // 消除（渗透者）
        Protect,        // 保护（守护者）
        Trade,          // 交易（商人）
        Hack,           // 黑客攻击（黑客）
        Heal,           // 治疗
        Scan            // 扫描
    }

    // 角色能力结构体
    struct RoleAbility {
        AbilityType abilityType;
        euint8 cooldown;        // 冷却时间
        euint8 usesRemaining;   // 剩余使用次数
        euint32 power;          // 能力强度
        ebool isActive;         // 是否激活
    }

    // 行动结果结构体
    struct ActionResult {
        bool success;
        euint32 value;          // 结果值（如伤害、治疗量等）
        euint8 targetAffected;  // 受影响的目标数量
        string message;         // 结果描述
    }

    GameCore public gameCore;
    
    // 角色ID到能力的映射
    mapping(uint8 => RoleAbility) public roleAbilities;
    
    // 玩家到角色能力使用记录的映射
    mapping(address => mapping(uint256 => uint256)) public lastAbilityUse; // player => abilityType => timestamp
    
    // 角色配置
    mapping(uint8 => uint8) public roleCooldowns;     // 角色冷却时间
    mapping(uint8 => uint8) public roleMaxUses;       // 角色最大使用次数
    mapping(uint8 => uint32) public rolePowers;       // 角色能力强度

    // 事件
    event AbilityUsed(address indexed player, uint8 indexed roleType, AbilityType abilityType, bool success);
    event RoleAbilityUpdated(uint8 indexed roleType, AbilityType abilityType, uint8 cooldown, uint8 maxUses);
    event PlayerInvestigated(address indexed investigator, address indexed target, bool result);
    event PlayerEliminated(address indexed eliminator, address indexed target);
    event PlayerProtected(address indexed protector, address indexed target);
    event ResourcesTraded(address indexed trader, address indexed target, uint32 amount);
    event SystemHacked(address indexed hacker, uint8 effectType);

    constructor(address _gameCore) Ownable(msg.sender) {
        gameCore = GameCore(_gameCore);
        _initializeRoleAbilities();
    }

    /**
     * @dev 初始化角色能力配置
     */
    function _initializeRoleAbilities() internal {
        // 守护者 (Guardian) - 保护能力
        _setRoleAbility(uint8(GameCore.RoleType.Guardian), AbilityType.Protect, 2, 3, 50);
        
        // 渗透者 (Infiltrator) - 消除能力
        _setRoleAbility(uint8(GameCore.RoleType.Infiltrator), AbilityType.Eliminate, 1, 2, 100);
        
        // 侦探 (Detective) - 调查能力
        _setRoleAbility(uint8(GameCore.RoleType.Detective), AbilityType.Investigate, 1, 3, 80);
        
        // 商人 (Merchant) - 交易能力
        _setRoleAbility(uint8(GameCore.RoleType.Merchant), AbilityType.Trade, 0, 5, 25);
        
        // 黑客 (Hacker) - 黑客攻击能力
        _setRoleAbility(uint8(GameCore.RoleType.Hacker), AbilityType.Hack, 3, 2, 75);
    }

    /**
     * @dev 设置角色能力
     */
    function _setRoleAbility(
        uint8 roleType,
        AbilityType abilityType,
        uint8 cooldown,
        uint8 maxUses,
        uint32 power
    ) internal {
        roleAbilities[roleType] = RoleAbility({
            abilityType: abilityType,
            cooldown: TFHE.asEuint8(cooldown),
            usesRemaining: TFHE.asEuint8(maxUses),
            power: TFHE.asEuint32(power),
            isActive: TFHE.asEbool(true)
        });
        
        roleCooldowns[roleType] = cooldown;
        roleMaxUses[roleType] = maxUses;
        rolePowers[roleType] = power;
        
        emit RoleAbilityUpdated(roleType, abilityType, cooldown, maxUses);
    }

    /**
     * @dev 使用角色能力
     */
    function useAbility(
        uint256 roomId,
        bytes calldata encryptedTarget,
        bytes calldata encryptedParameters
    ) external returns (bool) {
        // 验证玩家在房间中且游戏进行中
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        
        // 获取玩家角色（这里需要从GameCore获取加密的角色信息）
        // 由于隐私限制，我们需要通过特殊方式验证角色
        
        // 解密目标和参数
        euint8 target = TFHE.asEuint8(encryptedTarget);
        euint32 parameters = TFHE.asEuint32(encryptedParameters);
        
        // 执行能力逻辑
        ActionResult memory result = _executeAbility(msg.sender, target, parameters);
        
        emit AbilityUsed(msg.sender, 0, AbilityType.None, result.success); // 简化的事件
        
        return result.success;
    }

    /**
     * @dev 执行能力逻辑
     */
    function _executeAbility(
        address player,
        euint8 target,
        euint32 parameters
    ) internal returns (ActionResult memory) {
        // 这里需要复杂的FHE逻辑来处理不同角色的能力
        // 由于篇幅限制，这里提供简化版本
        
        return ActionResult({
            success: true,
            value: TFHE.asEuint32(50),
            targetAffected: TFHE.asEuint8(1),
            message: "Ability executed successfully"
        });
    }

    /**
     * @dev 守护者保护能力
     */
    function guardianProtect(
        uint256 roomId,
        bytes calldata encryptedTarget
    ) external returns (bool) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(_canUseAbility(msg.sender, AbilityType.Protect), "Cannot use ability");
        
        euint8 target = TFHE.asEuint8(encryptedTarget);
        
        // 实施保护逻辑
        // 在实际实现中，这里会设置目标玩家的保护状态
        
        _recordAbilityUse(msg.sender, AbilityType.Protect);
        
        emit PlayerProtected(msg.sender, address(0)); // 简化的事件
        
        return true;
    }

    /**
     * @dev 侦探调查能力
     */
    function detectiveInvestigate(
        uint256 roomId,
        bytes calldata encryptedTarget
    ) external returns (bytes memory) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(_canUseAbility(msg.sender, AbilityType.Investigate), "Cannot use ability");
        
        euint8 target = TFHE.asEuint8(encryptedTarget);
        
        // 调查逻辑 - 返回加密的角色信息
        // 在实际实现中，这里会返回目标玩家的部分角色信息
        
        _recordAbilityUse(msg.sender, AbilityType.Investigate);
        
        emit PlayerInvestigated(msg.sender, address(0), true); // 简化的事件
        
        // 返回加密的调查结果
        return TFHE.encrypt(true);
    }

    /**
     * @dev 渗透者消除能力
     */
    function infiltratorEliminate(
        uint256 roomId,
        bytes calldata encryptedTarget
    ) external returns (bool) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(_canUseAbility(msg.sender, AbilityType.Eliminate), "Cannot use ability");
        
        euint8 target = TFHE.asEuint8(encryptedTarget);
        
        // 消除逻辑
        // 在实际实现中，这里会尝试消除目标玩家
        
        _recordAbilityUse(msg.sender, AbilityType.Eliminate);
        
        emit PlayerEliminated(msg.sender, address(0)); // 简化的事件
        
        return true;
    }

    /**
     * @dev 商人交易能力
     */
    function merchantTrade(
        uint256 roomId,
        bytes calldata encryptedTarget,
        bytes calldata encryptedAmount
    ) external returns (bool) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(_canUseAbility(msg.sender, AbilityType.Trade), "Cannot use ability");
        
        euint8 target = TFHE.asEuint8(encryptedTarget);
        euint32 amount = TFHE.asEuint32(encryptedAmount);
        
        // 交易逻辑
        // 在实际实现中，这里会转移资源
        
        _recordAbilityUse(msg.sender, AbilityType.Trade);
        
        emit ResourcesTraded(msg.sender, address(0), 0); // 简化的事件
        
        return true;
    }

    /**
     * @dev 黑客攻击能力
     */
    function hackerAttack(
        uint256 roomId,
        bytes calldata encryptedEffect
    ) external returns (bool) {
        require(gameCore.playerToRoom(msg.sender) == roomId, "Player not in room");
        require(_canUseAbility(msg.sender, AbilityType.Hack), "Cannot use ability");
        
        euint8 effect = TFHE.asEuint8(encryptedEffect);
        
        // 黑客攻击逻辑
        // 在实际实现中，这里会干扰游戏系统或其他玩家
        
        _recordAbilityUse(msg.sender, AbilityType.Hack);
        
        emit SystemHacked(msg.sender, 0); // 简化的事件
        
        return true;
    }

    /**
     * @dev 检查是否可以使用能力
     */
    function _canUseAbility(address player, AbilityType abilityType) internal view returns (bool) {
        uint256 lastUse = lastAbilityUse[player][uint256(abilityType)];
        uint256 cooldownPeriod = 300; // 5分钟冷却时间
        
        return block.timestamp >= lastUse + cooldownPeriod;
    }

    /**
     * @dev 记录能力使用
     */
    function _recordAbilityUse(address player, AbilityType abilityType) internal {
        lastAbilityUse[player][uint256(abilityType)] = block.timestamp;
    }

    /**
     * @dev 获取角色能力信息（公开信息）
     */
    function getRoleAbilityInfo(uint8 roleType) external view returns (
        AbilityType,
        uint8,
        uint8,
        uint32
    ) {
        RoleAbility storage ability = roleAbilities[roleType];
        return (
            ability.abilityType,
            roleCooldowns[roleType],
            roleMaxUses[roleType],
            rolePowers[roleType]
        );
    }

    /**
     * @dev 获取玩家能力冷却状态
     */
    function getAbilityCooldown(address player, AbilityType abilityType) external view returns (uint256) {
        uint256 lastUse = lastAbilityUse[player][uint256(abilityType)];
        uint256 cooldownPeriod = 300;
        
        if (block.timestamp >= lastUse + cooldownPeriod) {
            return 0;
        } else {
            return (lastUse + cooldownPeriod) - block.timestamp;
        }
    }

    /**
     * @dev 更新角色能力配置（仅管理员）
     */
    function updateRoleAbility(
        uint8 roleType,
        AbilityType abilityType,
        uint8 cooldown,
        uint8 maxUses,
        uint32 power
    ) external onlyOwner {
        _setRoleAbility(roleType, abilityType, cooldown, maxUses, power);
    }

    /**
     * @dev 重置玩家能力使用记录（仅管理员）
     */
    function resetPlayerAbilities(address player) external onlyOwner {
        for (uint256 i = 0; i <= uint256(AbilityType.Scan); i++) {
            lastAbilityUse[player][i] = 0;
        }
    }

    /**
     * @dev 更新GameCore合约地址（仅管理员）
     */
    function updateGameCore(address _gameCore) external onlyOwner {
        gameCore = GameCore(_gameCore);
    }
}