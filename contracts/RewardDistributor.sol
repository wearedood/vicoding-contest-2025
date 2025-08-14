// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RewardDistributor
 * @dev Smart contract for distributing rewards to Base ecosystem builders
 * @notice This contract manages the distribution of ETH and token rewards
 * based on builder scores and verified contributions
 */
contract RewardDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Events
    event RewardDistributed(address indexed recipient, uint256 amount, string rewardType);
    event BuilderScoreUpdated(address indexed builder, uint256 newScore);
    event RewardPoolUpdated(uint256 newAmount);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // Structs
    struct Builder {
        uint256 score;
        uint256 totalRewardsEarned;
        uint256 lastRewardClaim;
        bool isActive;
        string githubUsername;
    }

    struct RewardTier {
        uint256 minScore;
        uint256 maxScore;
        uint256 rewardMultiplier; // Basis points (10000 = 100%)
    }

    // State variables
    mapping(address => Builder) public builders;
    mapping(string => address) public githubToAddress;
    RewardTier[] public rewardTiers;
    
    uint256 public totalRewardPool;
    uint256 public weeklyRewardAmount;
    uint256 public currentWeek;
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public deploymentTime;
    
    address[] public activeBuilders;
    mapping(address => bool) public isBuilderActive;

    // Modifiers
    modifier onlyActiveBuilder() {
        require(builders[msg.sender].isActive, "Builder not active");
        _;
    }

    modifier validAddress(address _addr) {
        require(_addr != address(0), "Invalid address");
        _;
    }

    constructor(uint256 _weeklyRewardAmount) {
        weeklyRewardAmount = _weeklyRewardAmount;
        deploymentTime = block.timestamp;
        currentWeek = 1;
        
        // Initialize reward tiers
        _initializeRewardTiers();
    }

    /**
     * @dev Initialize reward tiers for different builder score ranges
     */
    function _initializeRewardTiers() private {
        rewardTiers.push(RewardTier(0, 100, 1000));      // 10% for 0-100 score
        rewardTiers.push(RewardTier(101, 500, 2500));    // 25% for 101-500 score
        rewardTiers.push(RewardTier(501, 1000, 5000));   // 50% for 501-1000 score
        rewardTiers.push(RewardTier(1001, 2500, 7500));  // 75% for 1001-2500 score
        rewardTiers.push(RewardTier(2501, type(uint256).max, 10000)); // 100% for 2501+ score
    }

    /**
     * @dev Register a new builder with their GitHub username
     * @param _builderAddress Address of the builder
     * @param _githubUsername GitHub username of the builder
     */
    function registerBuilder(
        address _builderAddress,
        string memory _githubUsername
    ) external onlyOwner validAddress(_builderAddress) {
        require(bytes(_githubUsername).length > 0, "GitHub username required");
        require(githubToAddress[_githubUsername] == address(0), "GitHub username already registered");
        
        builders[_builderAddress] = Builder({
            score: 0,
            totalRewardsEarned: 0,
            lastRewardClaim: block.timestamp,
            isActive: true,
            githubUsername: _githubUsername
        });
        
        githubToAddress[_githubUsername] = _builderAddress;
        
        if (!isBuilderActive[_builderAddress]) {
            activeBuilders.push(_builderAddress);
            isBuilderActive[_builderAddress] = true;
        }
    }

    /**
     * @dev Update builder score based on their contributions
     * @param _builderAddress Address of the builder
     * @param _newScore New score for the builder
     */
    function updateBuilderScore(
        address _builderAddress,
        uint256 _newScore
    ) external onlyOwner validAddress(_builderAddress) {
        require(builders[_builderAddress].isActive, "Builder not registered");
        
        builders[_builderAddress].score = _newScore;
        emit BuilderScoreUpdated(_builderAddress, _newScore);
    }

    /**
     * @dev Calculate reward amount for a builder based on their score
     * @param _builderAddress Address of the builder
     * @return Reward amount in wei
     */
    function calculateReward(address _builderAddress) public view returns (uint256) {
        Builder memory builder = builders[_builderAddress];
        if (!builder.isActive || builder.score == 0) {
            return 0;
        }

        uint256 baseReward = weeklyRewardAmount / activeBuilders.length;
        uint256 multiplier = _getRewardMultiplier(builder.score);
        
        return (baseReward * multiplier) / 10000;
    }

    /**
     * @dev Get reward multiplier based on builder score
     * @param _score Builder's score
     * @return Multiplier in basis points
     */
    function _getRewardMultiplier(uint256 _score) private view returns (uint256) {
        for (uint256 i = 0; i < rewardTiers.length; i++) {
            if (_score >= rewardTiers[i].minScore && _score <= rewardTiers[i].maxScore) {
                return rewardTiers[i].rewardMultiplier;
            }
        }
        return 1000; // Default 10% if no tier matches
    }

    /**
     * @dev Distribute rewards to all active builders
     */
    function distributeWeeklyRewards() external onlyOwner nonReentrant {
        require(address(this).balance >= weeklyRewardAmount, "Insufficient contract balance");
        require(_canDistributeRewards(), "Too early for next distribution");
        
        uint256 totalDistributed = 0;
        
        for (uint256 i = 0; i < activeBuilders.length; i++) {
            address builderAddr = activeBuilders[i];
            if (builders[builderAddr].isActive) {
                uint256 reward = calculateReward(builderAddr);
                
                if (reward > 0) {
                    builders[builderAddr].totalRewardsEarned += reward;
                    builders[builderAddr].lastRewardClaim = block.timestamp;
                    totalDistributed += reward;
                    
                    (bool success, ) = payable(builderAddr).call{value: reward}("");
                    require(success, "Reward transfer failed");
                    
                    emit RewardDistributed(builderAddr, reward, "ETH");
                }
            }
        }
        
        currentWeek++;
        emit RewardPoolUpdated(address(this).balance);
    }

    /**
     * @dev Check if rewards can be distributed (weekly interval)
     */
    function _canDistributeRewards() private view returns (bool) {
        return block.timestamp >= deploymentTime + (currentWeek * WEEK_DURATION);
    }

    /**
     * @dev Claim individual reward (alternative to batch distribution)
     */
    function claimReward() external onlyActiveBuilder nonReentrant {
        require(_canClaimReward(msg.sender), "Cannot claim reward yet");
        
        uint256 reward = calculateReward(msg.sender);
        require(reward > 0, "No reward available");
        require(address(this).balance >= reward, "Insufficient contract balance");
        
        builders[msg.sender].totalRewardsEarned += reward;
        builders[msg.sender].lastRewardClaim = block.timestamp;
        
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "Reward transfer failed");
        
        emit RewardDistributed(msg.sender, reward, "ETH");
    }

    /**
     * @dev Check if builder can claim reward
     */
    function _canClaimReward(address _builder) private view returns (bool) {
        return block.timestamp >= builders[_builder].lastRewardClaim + WEEK_DURATION;
    }

    /**
     * @dev Add funds to the reward pool
     */
    function addToRewardPool() external payable onlyOwner {
        totalRewardPool += msg.value;
        emit RewardPoolUpdated(totalRewardPool);
    }

    /**
     * @dev Update weekly reward amount
     */
    function updateWeeklyRewardAmount(uint256 _newAmount) external onlyOwner {
        weeklyRewardAmount = _newAmount;
    }

    /**
     * @dev Deactivate a builder
     */
    function deactivateBuilder(address _builderAddress) external onlyOwner {
        builders[_builderAddress].isActive = false;
        isBuilderActive[_builderAddress] = false;
        
        // Remove from active builders array
        for (uint256 i = 0; i < activeBuilders.length; i++) {
            if (activeBuilders[i] == _builderAddress) {
                activeBuilders[i] = activeBuilders[activeBuilders.length - 1];
                activeBuilders.pop();
                break;
            }
        }
    }

    /**
     * @dev Emergency withdraw function
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");
        
        emit EmergencyWithdraw(address(0), balance);
    }

    /**
     * @dev Get builder information
     */
    function getBuilderInfo(address _builderAddress) external view returns (
        uint256 score,
        uint256 totalRewardsEarned,
        uint256 lastRewardClaim,
        bool isActive,
        string memory githubUsername
    ) {
        Builder memory builder = builders[_builderAddress];
        return (
            builder.score,
            builder.totalRewardsEarned,
            builder.lastRewardClaim,
            builder.isActive,
            builder.githubUsername
        );
    }

    /**
     * @dev Get total number of active builders
     */
    function getActiveBuilderCount() external view returns (uint256) {
        return activeBuilders.length;
    }

    /**
     * @dev Get contract statistics
     */
    function getContractStats() external view returns (
        uint256 totalPool,
        uint256 weeklyAmount,
        uint256 week,
        uint256 activeCount
    ) {
        return (
            address(this).balance,
            weeklyRewardAmount,
            currentWeek,
            activeBuilders.length
        );
    }

    // Receive function to accept ETH
    receive() external payable {
        totalRewardPool += msg.value;
        emit RewardPoolUpdated(totalRewardPool);
    }
}
