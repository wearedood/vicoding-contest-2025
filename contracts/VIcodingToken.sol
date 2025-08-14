// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title VicodingToken
 * @dev ERC20 token for the Vicoding Contest 2025 - Base Builder Rewards program
 * @notice This token represents achievements and contributions in the Base ecosystem
 */
contract VicodingToken is ERC20, ERC20Burnable, ERC20Pausable, Ownable, ReentrancyGuard {
    
    // Token configuration
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**18; // 100 million tokens
    
    // Minting and reward configuration
    uint256 public mintingRate = 1000 * 10**18; // 1000 tokens per contribution
    uint256 public maxMintPerAddress = 50_000 * 10**18; // 50k tokens max per address
    uint256 public rewardPoolReserve = 500_000_000 * 10**18; // 500M tokens for rewards
    
    // Tracking and governance
    mapping(address => uint256) public contributionScores;
    mapping(address => uint256) public totalMinted;
    mapping(address => bool) public authorizedMinters;
    mapping(string => bool) public processedContributions;
    
    // Events
    event ContributionRewarded(address indexed contributor, uint256 amount, string contributionId);
    event MinterAuthorized(address indexed minter, bool authorized);
    event ContributionScoreUpdated(address indexed contributor, uint256 newScore);
    event RewardParametersUpdated(uint256 newMintingRate, uint256 newMaxMintPerAddress);
    
    // Structs
    struct ContributionReward {
        address contributor;
        uint256 amount;
        string contributionType;
        string githubCommit;
        uint256 timestamp;
    }
    
    ContributionReward[] public rewardHistory;
    
    modifier onlyAuthorizedMinter() {
        require(authorizedMinters[msg.sender] || msg.sender == owner(), "Not authorized to mint");
        _;
    }
    
    modifier validContribution(string memory contributionId) {
        require(!processedContributions[contributionId], "Contribution already processed");
        require(bytes(contributionId).length > 0, "Invalid contribution ID");
        _;
    }

    constructor() ERC20("VicodingToken", "VCOD") {
        // Mint initial supply to contract deployer
        _mint(msg.sender, INITIAL_SUPPLY);
        
        // Set deployer as authorized minter
        authorizedMinters[msg.sender] = true;
        
        emit MinterAuthorized(msg.sender, true);
    }

    /**
     * @dev Mint tokens as reward for contributions
     * @param contributor Address of the contributor
     * @param amount Amount of tokens to mint
     * @param contributionId Unique identifier for the contribution
     * @param contributionType Type of contribution (e.g., "github_commit", "smart_contract", "documentation")
     * @param githubCommit GitHub commit hash or reference
     */
    function rewardContribution(
        address contributor,
        uint256 amount,
        string memory contributionId,
        string memory contributionType,
        string memory githubCommit
    ) external onlyAuthorizedMinter validContribution(contributionId) nonReentrant {
        require(contributor != address(0), "Invalid contributor address");
        require(amount > 0, "Amount must be greater than 0");
        require(totalSupply() + amount <= MAX_SUPPLY, "Would exceed max supply");
        require(totalMinted[contributor] + amount <= maxMintPerAddress, "Would exceed max mint per address");
        
        // Mint tokens to contributor
        _mint(contributor, amount);
        
        // Update tracking
        totalMinted[contributor] += amount;
        contributionScores[contributor] += _calculateScoreIncrease(amount, contributionType);
        processedContributions[contributionId] = true;
        
        // Record in history
        rewardHistory.push(ContributionReward({
            contributor: contributor,
            amount: amount,
            contributionType: contributionType,
            githubCommit: githubCommit,
            timestamp: block.timestamp
        }));
        
        emit ContributionRewarded(contributor, amount, contributionId);
        emit ContributionScoreUpdated(contributor, contributionScores[contributor]);
    }

    /**
     * @dev Calculate score increase based on contribution type and amount
     * @param amount Token amount being rewarded
     * @param contributionType Type of contribution
     * @return Score increase amount
     */
    function _calculateScoreIncrease(uint256 amount, string memory contributionType) private pure returns (uint256) {
        bytes32 typeHash = keccak256(abi.encodePacked(contributionType));
        
        // Different multipliers for different contribution types
        if (typeHash == keccak256(abi.encodePacked("smart_contract"))) {
            return amount / 10**18 * 5; // 5x multiplier for smart contracts
        } else if (typeHash == keccak256(abi.encodePacked("github_commit"))) {
            return amount / 10**18 * 2; // 2x multiplier for commits
        } else if (typeHash == keccak256(abi.encodePacked("documentation"))) {
            return amount / 10**18 * 3; // 3x multiplier for documentation
        } else if (typeHash == keccak256(abi.encodePacked("bug_fix"))) {
            return amount / 10**18 * 4; // 4x multiplier for bug fixes
        } else {
            return amount / 10**18; // 1x multiplier for other contributions
        }
    }

    /**
     * @dev Batch reward multiple contributions
     * @param contributors Array of contributor addresses
     * @param amounts Array of token amounts
     * @param contributionIds Array of contribution IDs
     * @param contributionTypes Array of contribution types
     * @param githubCommits Array of GitHub commit references
     */
    function batchRewardContributions(
        address[] memory contributors,
        uint256[] memory amounts,
        string[] memory contributionIds,
        string[] memory contributionTypes,
        string[] memory githubCommits
    ) external onlyAuthorizedMinter nonReentrant {
        require(contributors.length == amounts.length, "Arrays length mismatch");
        require(contributors.length == contributionIds.length, "Arrays length mismatch");
        require(contributors.length == contributionTypes.length, "Arrays length mismatch");
        require(contributors.length == githubCommits.length, "Arrays length mismatch");
        require(contributors.length <= 50, "Too many contributions in batch");
        
        for (uint256 i = 0; i < contributors.length; i++) {
            if (!processedContributions[contributionIds[i]] && 
                contributors[i] != address(0) && 
                amounts[i] > 0 &&
                totalSupply() + amounts[i] <= MAX_SUPPLY &&
                totalMinted[contributors[i]] + amounts[i] <= maxMintPerAddress) {
                
                _mint(contributors[i], amounts[i]);
                totalMinted[contributors[i]] += amounts[i];
                contributionScores[contributors[i]] += _calculateScoreIncrease(amounts[i], contributionTypes[i]);
                processedContributions[contributionIds[i]] = true;
                
                rewardHistory.push(ContributionReward({
                    contributor: contributors[i],
                    amount: amounts[i],
                    contributionType: contributionTypes[i],
                    githubCommit: githubCommits[i],
                    timestamp: block.timestamp
                }));
                
                emit ContributionRewarded(contributors[i], amounts[i], contributionIds[i]);
                emit ContributionScoreUpdated(contributors[i], contributionScores[contributors[i]]);
            }
        }
    }

    /**
     * @dev Authorize or deauthorize an address to mint tokens
     * @param minter Address to authorize/deauthorize
     * @param authorized Whether the address should be authorized
     */
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        require(minter != address(0), "Invalid minter address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    /**
     * @dev Update reward parameters
     * @param newMintingRate New minting rate per contribution
     * @param newMaxMintPerAddress New maximum mint amount per address
     */
    function updateRewardParameters(uint256 newMintingRate, uint256 newMaxMintPerAddress) external onlyOwner {
        require(newMintingRate > 0, "Minting rate must be greater than 0");
        require(newMaxMintPerAddress > 0, "Max mint per address must be greater than 0");
        require(newMaxMintPerAddress <= MAX_SUPPLY / 10, "Max mint per address too high");
        
        mintingRate = newMintingRate;
        maxMintPerAddress = newMaxMintPerAddress;
        
        emit RewardParametersUpdated(newMintingRate, newMaxMintPerAddress);
    }

    /**
     * @dev Get contribution history for an address
     * @param contributor Address to query
     * @return Array of reward history indices for the contributor
     */
    function getContributionHistory(address contributor) external view returns (uint256[] memory) {
        uint256 count = 0;
        
        // Count contributions for this address
        for (uint256 i = 0; i < rewardHistory.length; i++) {
            if (rewardHistory[i].contributor == contributor) {
                count++;
            }
        }
        
        // Create array of indices
        uint256[] memory indices = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < rewardHistory.length; i++) {
            if (rewardHistory[i].contributor == contributor) {
                indices[index] = i;
                index++;
            }
        }
        
        return indices;
    }

    /**
     * @dev Get total number of reward entries
     */
    function getRewardHistoryLength() external view returns (uint256) {
        return rewardHistory.length;
    }

    /**
     * @dev Get contributor statistics
     * @param contributor Address to query
     * @return score Total contribution score
     * @return minted Total tokens minted to this address
     * @return remaining Remaining tokens that can be minted to this address
     */
    function getContributorStats(address contributor) external view returns (
        uint256 score,
        uint256 minted,
        uint256 remaining
    ) {
        score = contributionScores[contributor];
        minted = totalMinted[contributor];
        remaining = maxMintPerAddress > minted ? maxMintPerAddress - minted : 0;
    }

    /**
     * @dev Get token contract statistics
     */
    function getTokenStats() external view returns (
        uint256 currentSupply,
        uint256 maxSupply,
        uint256 remainingSupply,
        uint256 totalRewards,
        uint256 uniqueContributors
    ) {
        currentSupply = totalSupply();
        maxSupply = MAX_SUPPLY;
        remainingSupply = MAX_SUPPLY - currentSupply;
        totalRewards = rewardHistory.length;
        
        // Count unique contributors
        address[] memory seen = new address[](rewardHistory.length);
        uint256 uniqueCount = 0;
        
        for (uint256 i = 0; i < rewardHistory.length; i++) {
            address contributor = rewardHistory[i].contributor;
            bool isUnique = true;
            
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (seen[j] == contributor) {
                    isUnique = false;
                    break;
                }
            }
            
            if (isUnique) {
                seen[uniqueCount] = contributor;
                uniqueCount++;
            }
        }
        
        uniqueContributors = uniqueCount;
    }

    /**
     * @dev Pause token transfers (emergency function)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable) {
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Emergency function to recover accidentally sent tokens
     * @param token Address of the token to recover
     * @param amount Amount to recover
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot recover own token");
        IERC20(token).transfer(owner(), amount);
    }
}
