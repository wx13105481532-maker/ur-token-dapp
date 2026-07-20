// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title UR Token V4 — 拆分部署版
 * @notice
 *   V4 相较 V3 的改动：Oracle 和 Tier 配置抽离为独立库以压缩主合约字节码。
 *   功能与 V3 完全等价。
 *   编译器：Solidity ^0.8.20，Optimizer 200 runs，BSC Chain 56。
 */

import "./URInterfaces.sol";
import "./UROracleLib.sol";
import "./URTierConfigLib.sol";

// ==================== 接口 ====================

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ==================== 主合约 ====================

contract URTokenV4 is IERC20 {
    using UROracleLib for UROracleLib.Storage;

    // ======== 外部库存储 ========
    UROracleLib.Storage public oracle;

    // ======== 基础信息 ========
    string public constant name = "UR Token";
    string public constant symbol = "UR";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 1e18;
    uint256 public constant MIN_SUPPLY = 1_000_000 * 1e18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ======== 权限 ========
    address public owner;
    address public minter;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyMinterOrOwner() {
        require(msg.sender == owner || msg.sender == minter, "Not authorized");
        _;
    }

    // ======== 交易控制 ========
    bool public tradingEnabled;

    // ======== 税率（基点） ========
    uint256 public totalTaxRate = 1000;
    uint256 public nodeDividendRate = 300;
    uint256 public referralRewardRate = 300;
    uint256 public marketingRate = 200;

    address public marketingWallet;

    // ======== 白名单 ========
    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromBurn;

    // ======== 每日销毁 ========
    uint256 public dailyBurnRate = 50;
    uint256 public lastDailyBurnTimestamp;
    uint256 public constant DAILY_BURN_INTERVAL = 1 days;

    // ======== 交易对 ========
    address public pancakePair;

    // ======== 节点系统 ========
    mapping(address => bool) public isNode;
    address[] public nodeList;
    mapping(address => uint256) public nodeIndex;
    uint256 public nodeCount;
    uint256 public accumulatedDividendPerToken;
    mapping(address => uint256) public lastDividendPerTokenCheckpoint;
    mapping(address => uint256) public pendingNodeDividend;

    // ======== 推荐系统 ========
    mapping(address => address) public referrer;
    mapping(address => uint256) public referralDepth;
    mapping(address => address[]) public referrals;
    mapping(address => uint256) public referralCount;
    mapping(address => uint256) public totalReferralVolume;
    mapping(address => uint256) public pendingReferralReward;

    uint256 public constant REF_L1_RATE = 200;
    uint256 public constant REF_L2_RATE = 100;
    uint256 public constant REF_L3_RATE = 50;
    uint256 public constant MAX_REF_DEPTH = 3;

    // ======== V3：伞下持有量追踪 ========
    mapping(address => uint256) public downlineBalance;
    mapping(address => uint256) public v6DownlineCount;

    // ======== V3：八级奖励系统 ========
    mapping(address => uint256) public tierLevel;

    uint256 public currentRewardDay;
    uint256 public constant UTC8_OFFSET = 8 hours;
    uint256 public constant DAY_SECONDS = 86400;

    mapping(address => uint256) public snapshotDay;
    mapping(address => uint256) public downlineSnapshot;

    mapping(address => uint256) public lastClaimedDay;
    mapping(uint256 => mapping(address => uint256)) public dailyRewardPaidToDownline;
    mapping(address => uint256) public cumulativeRewardPaidToDownline;

    // ======== V3：云算力托管集成 ========
    address public custodyContract;
    mapping(address => uint256) public stakedInCustody;

    modifier onlyCustody() {
        require(msg.sender == custodyContract, "Only custody");
        _;
    }

    // ======== 事件 ========
    event DailyBurnExecuted(uint256 burnAmount, uint256 newTotalSupply, uint256 timestamp);
    event NodeStatusChanged(address indexed account, bool isNode);
    event NodeThresholdUpdated(uint256 oldThreshold, uint256 newThreshold, uint256 urPrice);
    event ReferrerBound(address indexed user, address indexed referrer);
    event ReferralRewardPaid(address indexed from, address indexed to, uint256 amount, uint256 level);
    event TaxDistributed(
        address indexed from, address indexed to,
        uint256 totalTax, uint256 nodeDividend, uint256 referralReward,
        uint256 marketing, uint256 contractRetained
    );
    event TradingEnabled();
    event MarketingWalletUpdated(address oldWallet, address newWallet);
    event TaxRateUpdated(uint256 oldRate, uint256 newRate);
    event NodeDividendPaid(address indexed node, uint256 amount);
    event ReferralRewardClaimed(address indexed user, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event NodeDividendRateUpdated(uint256 oldRate, uint256 newRate);
    event ReferralRewardRateUpdated(uint256 oldRate, uint256 newRate);
    event MarketingRateUpdated(uint256 oldRate, uint256 newRate);
    event DailyBurnRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardDayAdvanced(uint256 newDay, uint256 timestamp);
    event TierLevelChanged(address indexed account, uint256 oldTier, uint256 newTier);
    event CustodyContractUpdated(address oldCustody, address newCustody);
    event TaxExemptionChanged(address indexed account, bool excluded);
    event MinterChanged(address oldMinter, address newMinter);
    event DailyTierRewardClaimed(
        address indexed account, uint256 rewardDay, uint256 tier,
        uint256 downlineUSD, uint256 totalNewHoldingUSD, uint256 dailyNewHoldingAvg,
        uint256 rateBps, uint256 coefficient, uint256 rewardAmountPerDay, uint256 totalReward
    );

    // ======== 构造函数 ========
    constructor(
        address _marketingWallet,
        address _pancakeFactory,
        address _WBNB,
        address _USDT
    ) {
        owner = msg.sender;
        marketingWallet = _marketingWallet;

        // 初始化 Oracle 库
        oracle.init(_pancakeFactory, _WBNB, _USDT, 500 * 1e18);
        oracle.initTWAP(address(this));
        _updateOracleWrapper();

        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);

        lastDailyBurnTimestamp = block.timestamp;

        isExcludedFromTax[address(this)] = true;
        isExcludedFromBurn[address(this)] = true;
        isExcludedFromTax[msg.sender] = true;
        isExcludedFromBurn[msg.sender] = true;

        currentRewardDay = _currentRewardDay();
    }

    // ==================== 日推进 ====================

    function _currentRewardDay() internal view returns (uint256) {
        return (block.timestamp + UTC8_OFFSET) / DAY_SECONDS;
    }

    function _advanceRewardDay() internal {
        uint256 day = _currentRewardDay();
        if (day > currentRewardDay) {
            currentRewardDay = day;
            emit RewardDayAdvanced(day, block.timestamp);
        }
    }

    // ==================== 伞下余额追踪 ====================

    function _updateDownlineBalances(
        address from, address to,
        uint256 fromAmount, uint256 toAmount
    ) internal {
        if (from != address(0) && from != address(this) && from != pancakePair) {
            address cursor = referrer[from];
            while (cursor != address(0)) {
                downlineBalance[cursor] -= fromAmount;
                cursor = referrer[cursor];
            }
        }
        if (to != address(0) && to != address(this) && to != pancakePair) {
            address cursor = referrer[to];
            while (cursor != address(0)) {
                downlineBalance[cursor] += toAmount;
                cursor = referrer[cursor];
            }
        }
    }

    // ==================== 等级判定 ====================

    function _effectiveBalance(address account) internal view returns (uint256) {
        return stakedInCustody[account];
    }

    function _computeTier(address account) internal view returns (uint256) {
        uint256 price = oracle.cachedURPrice;
        if (price == 0) return 0;

        uint256 personalUSD = (_effectiveBalance(account) * price) / 1e18;
        uint256 downlineUSD = (downlineBalance[account] * price) / 1e18;
        uint256 v6Count = v6DownlineCount[account];

        for (uint256 t = 8; t >= 1; t--) {
            URTierConfigLib.TierCfg memory cfg = URTierConfigLib.config(t);
            if (personalUSD >= cfg.minPersonalUSD &&
                downlineUSD >= cfg.minDownlineUSD &&
                downlineUSD <= cfg.maxDownlineUSD &&
                v6Count >= cfg.minV6Required)
            {
                return t;
            }
        }
        return 0;
    }

    function _updateTier(address account) internal {
        uint256 oldTier = tierLevel[account];
        uint256 newTier = _computeTier(account);

        if (newTier != oldTier) {
            tierLevel[account] = newTier;

            if (oldTier == 0 && newTier > 0 && lastClaimedDay[account] == 0) {
                lastClaimedDay[account] = currentRewardDay;
            }

            if (oldTier >= 6) {
                _adjustV6Count(account, false);
            }
            if (newTier >= 6) {
                _adjustV6Count(account, true);
            }

            emit TierLevelChanged(account, oldTier, newTier);
        }
    }

    function _adjustV6Count(address account, bool isAdd) internal {
        address cursor = referrer[account];
        while (cursor != address(0)) {
            if (isAdd) {
                v6DownlineCount[cursor] += 1;
            } else {
                require(v6DownlineCount[cursor] > 0, "V6 count underflow");
                v6DownlineCount[cursor] -= 1;
            }
            cursor = referrer[cursor];
        }
    }

    // ==================== 快照管理 ====================

    function _ensureSnapshot(address account) internal {
        uint256 day = currentRewardDay;
        if (snapshotDay[account] < day) {
            snapshotDay[account] = day;
            downlineSnapshot[account] = downlineBalance[account];
        }
    }

    function _ensureSnapshotChain(address account) internal {
        _ensureSnapshot(account);
        address cursor = referrer[account];
        while (cursor != address(0)) {
            _ensureSnapshot(cursor);
            cursor = referrer[cursor];
        }
    }

    // ==================== 每日奖励 ====================

    function claimDailyReward() external {
        _advanceRewardDay();
        _updateTier(msg.sender);

        uint256 startDay = lastClaimedDay[msg.sender];
        uint256 endDay = currentRewardDay;
        require(endDay > startDay, "No new reward day");

        _ensureSnapshotChain(msg.sender);

        uint256 tier = tierLevel[msg.sender];
        require(tier > 0, "No tier");

        uint256 gap = endDay - startDay;
        uint256 downlineUSD;
        uint256 cappedNew;
        uint256 dailyAvgNew;
        uint256 rateBps;
        uint256 coefficient;
        uint256 totalRewardUR;
        {
            uint256 _cfg = URTierConfigLib.packedConfig(tier);

            uint256 price = oracle.cachedURPrice;
            uint256 curBal = downlineBalance[msg.sender];
            uint256 snapBal = downlineSnapshot[msg.sender];

            uint256 snapUSD = (snapBal * price) / 1e18;
            uint256 curUSD  = (curBal * price) / 1e18;
            downlineUSD = snapUSD;

            uint256 totalNew = curUSD > snapUSD ? curUSD - snapUSD : 0;
            uint256 maxNew = (_cfg & 0xFFFFFFFFFFFFFFFFFFFF) * gap;
            cappedNew = totalNew > maxNew ? maxNew : totalNew;
            dailyAvgNew = cappedNew / gap;

            uint256 scale;
            {
                uint256 _nh = _cfg & 0xFFFFFFFFFFFFFFFFFFFF;
                if (_nh > 0 && dailyAvgNew > 0) {
                    scale = (dailyAvgNew * 1e18) / _nh;
                }
                if (scale > 1e18) scale = 1e18;
            }
            {
                uint256 _minR = (_cfg >> 80)  & 0xFF;
                uint256 _maxR = (_cfg >> 88)  & 0xFF;
                rateBps = _minR + ((_maxR - _minR) * scale) / 1e18;
                uint256 _minC = (_cfg >> 96)  & 0xFF;
                uint256 _maxC = (_cfg >> 104) & 0xFF;
                coefficient = _minC + ((_maxC - _minC) * scale) / 1e18;
            }
            {
                uint256 dailyBaseSnap = (snapUSD * rateBps) / 10000;
                uint256 newBonus = (cappedNew * rateBps) / 10000;
                uint256 dailyBase = dailyBaseSnap + (newBonus / gap);

                uint256 _tp = cumulativeRewardPaidToDownline[msg.sender];
                uint256 paidAvg = _tp > 0 ? (_tp * price) / 1e18 / gap : 0;
                uint256 net = dailyBase > paidAvg ? dailyBase - paidAvg : 0;
                totalRewardUR = ((net * coefficient) / 100 * gap * 1e18) / price;
            }
        }

        _propagateRewardToAncestors(msg.sender, endDay, totalRewardUR);

        lastClaimedDay[msg.sender] = endDay;
        _ensureSnapshot(msg.sender);

        if (totalRewardUR > 0) {
            _mintReward(msg.sender, totalRewardUR);
        }

        {
            uint256 dailyRewardBase = totalRewardUR / gap;
            emit DailyTierRewardClaimed(
                msg.sender, endDay, tier,
                downlineUSD, cappedNew, dailyAvgNew,
                rateBps, coefficient, dailyRewardBase, totalRewardUR
            );
        }
    }

    function _propagateRewardToAncestors(address account, uint256 day, uint256 reward) internal {
        if (reward == 0) return;
        address cursor = referrer[account];
        while (cursor != address(0)) {
            dailyRewardPaidToDownline[day][cursor] += reward;
            cumulativeRewardPaidToDownline[cursor] += reward;
            cursor = referrer[cursor];
        }
    }

    function _mintReward(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
        _updateDownlineBalances(address(0), to, 0, amount);
    }

    // ==================== 节点状态 ====================

    function _checkNodeStatusAndTier(address account) internal {
        bool shouldBeNode = stakedInCustody[account] >= oracle.nodeThreshold && oracle.nodeThreshold > 0;
        if (shouldBeNode != isNode[account]) {
            if (shouldBeNode) {
                _addNode(account);
            } else {
                _removeNode(account);
            }
        }
        _updateTier(account);
    }

    function _addNode(address account) internal {
        require(!isNode[account], "Already node");
        isNode[account] = true;
        nodeIndex[account] = nodeList.length + 1;
        nodeList.push(account);
        nodeCount++;
        emit NodeStatusChanged(account, true);
    }

    function _removeNode(address account) internal {
        require(isNode[account], "Not node");
        isNode[account] = false;
        uint256 idx = nodeIndex[account] - 1;
        address lastNode = nodeList[nodeList.length - 1];
        nodeList[idx] = lastNode;
        nodeIndex[lastNode] = idx + 1;
        nodeList.pop();
        nodeCount--;
        delete nodeIndex[account];
        emit NodeStatusChanged(account, false);
    }

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    // ==================== 每日销毁 ====================

    function _maybeDailyBurn() internal {
        uint256 daysElapsed = (block.timestamp - lastDailyBurnTimestamp) / DAILY_BURN_INTERVAL;
        if (daysElapsed == 0) return;

        for (uint256 i = 0; i < daysElapsed && i < 7; i++) {
            if (totalSupply <= MIN_SUPPLY) break;
            uint256 burnAmount = (totalSupply * dailyBurnRate) / 10000;
            if (burnAmount == 0) break;

            uint256 contractBalance = balanceOf[address(this)];
            if (burnAmount > contractBalance) {
                burnAmount = contractBalance;
            }
            if (burnAmount == 0) break;

            if (totalSupply - burnAmount < MIN_SUPPLY) {
                burnAmount = totalSupply - MIN_SUPPLY;
            }
            if (burnAmount == 0) break;

            _transferInternal(address(this), BURN_ADDRESS, burnAmount);
            totalSupply -= burnAmount;

            emit DailyBurnExecuted(burnAmount, totalSupply, block.timestamp);
        }
        lastDailyBurnTimestamp = block.timestamp;
    }

    // ==================== 推荐系统 ====================

    function bindReferrer(address _referrer) external {
        require(_referrer != address(0), "Zero address");
        require(_referrer != msg.sender, "Cannot self-refer");
        require(referrer[msg.sender] == address(0), "Already bound");

        address cursor = _referrer;
        while (cursor != address(0)) {
            require(cursor != msg.sender, "Circular referral");
            cursor = referrer[cursor];
        }

        referrer[msg.sender] = _referrer;
        referrals[_referrer].push(msg.sender);
        referralCount[_referrer]++;
        referralDepth[msg.sender] = referralDepth[_referrer] + 1;

        uint256 totalValue = stakedInCustody[msg.sender] + downlineBalance[msg.sender];
        cursor = _referrer;
        while (cursor != address(0)) {
            downlineBalance[cursor] += totalValue;
            cursor = referrer[cursor];
        }

        emit ReferrerBound(msg.sender, _referrer);

        _advanceRewardDay();
        _ensureSnapshot(msg.sender);
        _updateTier(msg.sender);
        cursor = referrer[msg.sender];
        while (cursor != address(0)) {
            _ensureSnapshot(cursor);
            _updateTier(cursor);
            cursor = referrer[cursor];
        }
    }

    function _distributeReferralRewards(address from, uint256 amount) internal {
        address current = referrer[from];
        uint256 level = 1;
        uint256 totalReward = (amount * referralRewardRate) / 10000;
        if (totalReward == 0) return;

        while (current != address(0) && level <= MAX_REF_DEPTH) {
            uint256 reward;
            if (level == 1) {
                reward = (totalReward * REF_L1_RATE) / (REF_L1_RATE + REF_L2_RATE + REF_L3_RATE);
            } else if (level == 2) {
                reward = (totalReward * REF_L2_RATE) / (REF_L1_RATE + REF_L2_RATE + REF_L3_RATE);
            } else {
                reward = (totalReward * REF_L3_RATE) / (REF_L1_RATE + REF_L2_RATE + REF_L3_RATE);
            }

            pendingReferralReward[current] += reward;
            totalReferralVolume[current] += amount;
            emit ReferralRewardPaid(from, current, reward, level);

            current = referrer[current];
            level++;
        }
    }

    function claimReferralReward() external {
        uint256 reward = pendingReferralReward[msg.sender];
        require(reward > 0, "No reward");
        pendingReferralReward[msg.sender] = 0;
        _transferInternal(address(this), msg.sender, reward);
        emit ReferralRewardClaimed(msg.sender, reward);
    }

    // ==================== 节点分红 ====================

    function _distributeNodeDividend(uint256 amount) internal {
        uint256 dividend = (amount * nodeDividendRate) / 10000;
        if (dividend == 0 || totalSupply == 0) return;
        accumulatedDividendPerToken += (dividend * 1e18) / totalSupply;
    }

    function _earnedNodeDividend(address account) internal view returns (uint256) {
        uint256 acc = accumulatedDividendPerToken;
        uint256 last = lastDividendPerTokenCheckpoint[account];
        if (acc <= last) return pendingNodeDividend[account];
        uint256 stakedBal = stakedInCustody[account];
        uint256 newDividend = (stakedBal * (acc - last)) / 1e18;
        return pendingNodeDividend[account] + newDividend;
    }

    function claimNodeDividend() external {
        require(isNode[msg.sender], "Not a node");
        uint256 acc = accumulatedDividendPerToken;
        uint256 last = lastDividendPerTokenCheckpoint[msg.sender];
        if (acc > last) {
            uint256 stakedBal = stakedInCustody[msg.sender];
            uint256 newDividend = (stakedBal * (acc - last)) / 1e18;
            pendingNodeDividend[msg.sender] += newDividend;
        }
        lastDividendPerTokenCheckpoint[msg.sender] = acc;

        uint256 reward = pendingNodeDividend[msg.sender];
        require(reward > 0, "No dividend");
        pendingNodeDividend[msg.sender] = 0;
        _transferInternal(address(this), msg.sender, reward);
        emit NodeDividendPaid(msg.sender, reward);
    }

    // ==================== 核心转账 ====================

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        allowance[from][msg.sender] = currentAllowance - amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: from zero");
        require(to != address(0), "ERC20: to zero");
        require(from != to, "Self-transfer");
        require(amount > 0, "Zero amount");

        if (!tradingEnabled && from != owner && to != owner) {
            revert("Trading not enabled");
        }

        _advanceRewardDay();
        _ensureSnapshotChain(from);
        _ensureSnapshotChain(to);
        _maybeDailyBurn();
        _maybeUpdateOracleWrapper();

        bool isSwap = (from == pancakePair || to == pancakePair) && pancakePair != address(0);
        bool isTaxExempt = isExcludedFromTax[from] || isExcludedFromTax[to];

        if (isSwap && !isTaxExempt) {
            uint256 taxAmount = (amount * totalTaxRate) / 10000;
            uint256 netAmount = amount - taxAmount;

            uint256 nodeDiv = (taxAmount * nodeDividendRate) / totalTaxRate;
            _transferInternal(from, address(this), nodeDiv);

            uint256 refReward = (taxAmount * referralRewardRate) / totalTaxRate;
            _transferInternal(from, address(this), refReward);

            uint256 marketing = (taxAmount * marketingRate) / totalTaxRate;
            _transferInternal(from, marketingWallet, marketing);

            uint256 retained = taxAmount - nodeDiv - refReward - marketing;
            _transferInternal(from, address(this), retained);

            _transferInternal(from, to, netAmount);

            _distributeNodeDividend(amount);
            _distributeReferralRewards(from, amount);

            _updateDownlineBalances(from, to, netAmount, netAmount);

            emit TaxDistributed(from, to, taxAmount, nodeDiv, refReward, marketing, retained);
        } else {
            _transferInternal(from, to, amount);
            _updateDownlineBalances(from, to, amount, amount);
        }

        _checkNodeStatusAndTier(from);
        _checkNodeStatusAndTier(to);
    }

    function _transferInternal(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    // ==================== Owner 管理 ====================

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        if (pancakePair == address(0)) {
            pancakePair = IPancakeFactory(oracle.pancakeFactory).getPair(address(this), oracle.USDT);
        }
        _updateOracleWrapper();
        emit TradingEnabled();
    }

    function setPancakePair(address _pair) external onlyOwner {
        require(_pair != address(0), "Zero address");
        pancakePair = _pair;
    }

    function setMarketingWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Zero address");
        emit MarketingWalletUpdated(marketingWallet, _wallet);
        marketingWallet = _wallet;
    }

    function setTotalTaxRate(uint256 _rate) external onlyOwner {
        require(_rate <= 2000, "Max 20%");
        require(nodeDividendRate + referralRewardRate + marketingRate <= _rate, "Sub-rates exceed total");
        emit TaxRateUpdated(totalTaxRate, _rate);
        totalTaxRate = _rate;
    }

    function setNodeDividendRate(uint256 _rate) external onlyOwner {
        require(_rate <= totalTaxRate, "Exceeds totalTax");
        require(_rate + referralRewardRate + marketingRate <= totalTaxRate, "Sub-rates exceed total");
        uint256 oldRate = nodeDividendRate;
        nodeDividendRate = _rate;
        emit NodeDividendRateUpdated(oldRate, _rate);
    }

    function setReferralRewardRate(uint256 _rate) external onlyOwner {
        require(_rate <= totalTaxRate, "Exceeds totalTax");
        require(nodeDividendRate + _rate + marketingRate <= totalTaxRate, "Sub-rates exceed total");
        uint256 oldRate = referralRewardRate;
        referralRewardRate = _rate;
        emit ReferralRewardRateUpdated(oldRate, _rate);
    }

    function setMarketingRate(uint256 _rate) external onlyOwner {
        require(_rate <= totalTaxRate, "Exceeds totalTax");
        require(nodeDividendRate + referralRewardRate + _rate <= totalTaxRate, "Sub-rates exceed total");
        uint256 oldRate = marketingRate;
        marketingRate = _rate;
        emit MarketingRateUpdated(oldRate, _rate);
    }

    function setDailyBurnRate(uint256 _rate) external onlyOwner {
        require(_rate <= 30, "Max 0.3%");
        uint256 oldRate = dailyBurnRate;
        dailyBurnRate = _rate;
        emit DailyBurnRateUpdated(oldRate, _rate);
    }

    function setExcludedFromTax(address _account, bool _excluded) external onlyOwner {
        isExcludedFromTax[_account] = _excluded;
        emit TaxExemptionChanged(_account, _excluded);
    }

    function setTargetNodeValueUSD(uint256 _valueUSD) external onlyOwner {
        require(_valueUSD >= 100 * 1e18, "Min $100");
        require(_valueUSD <= 10000 * 1e18, "Max $10000");
        oracle.targetNodeValueUSD = _valueUSD;
        _updateOracleWrapper();
    }

    function getURPriceUSD() public view returns (uint256) {
        return oracle.getURPriceUSD();
    }

    function _updateOracleWrapper() internal {
        uint256 oldThreshold = oracle.nodeThreshold;
        oracle.updateOracle();
        uint256 newThreshold = oracle.nodeThreshold;
        if (newThreshold != oldThreshold) {
            emit NodeThresholdUpdated(oldThreshold, newThreshold, oracle.cachedURPrice);
        }
    }

    function _maybeUpdateOracleWrapper() internal {
        if (block.timestamp >= oracle.lastOracleUpdate + UROracleLib.ORACLE_UPDATE_INTERVAL) {
            _updateOracleWrapper();
        }
    }

    function forceOracleUpdate() external onlyOwner {
        require(
            block.timestamp >= oracle.lastOracleUpdate + UROracleLib.ORACLE_UPDATE_INTERVAL,
            "Oracle update too frequent"
        );
        _updateOracleWrapper();
    }

    function recheckNodeStatusBatch(uint256 startIndex, uint256 batchSize) external onlyOwner {
        uint256 len = nodeList.length;
        uint256 end = startIndex + batchSize;
        if (end > len) end = len;
        for (uint256 i = startIndex; i < end; i++) {
            _checkNodeStatusAndTier(nodeList[i]);
        }
    }

    function mint(address _to, uint256 _amount) external onlyMinterOrOwner {
        totalSupply += _amount;
        balanceOf[_to] += _amount;
        emit Transfer(address(0), _to, _amount);
        _checkNodeStatusAndTier(_to);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    address public pendingOwnerRenounce;
    uint256 public renounceInitiatedAt;

    function initiateRenounceOwnership() external onlyOwner {
        pendingOwnerRenounce = msg.sender;
        renounceInitiatedAt = block.timestamp;
    }

    function confirmRenounceOwnership() external onlyOwner {
        require(pendingOwnerRenounce == msg.sender, "Not initiated");
        require(block.timestamp >= renounceInitiatedAt + 3 days, "Cooldown not passed");
        delete pendingOwnerRenounce;
        delete renounceInitiatedAt;
        owner = address(0);
    }

    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "Zero address");
        address oldMinter = minter;
        minter = _minter;
        emit MinterChanged(oldMinter, _minter);
    }

    // ==================== 云算力托管回调 ====================

    function setCustodyContract(address _custody) external onlyOwner {
        require(_custody != address(0), "Zero address");
        address oldCustody = custodyContract;
        custodyContract = _custody;
        emit CustodyContractUpdated(oldCustody, _custody);
    }

    function updateStakedBalance(address user, uint256 newStaked) external onlyCustody {
        uint256 oldStaked = stakedInCustody[user];
        if (newStaked == oldStaked) return;

        stakedInCustody[user] = newStaked;

        address cursor = referrer[user];
        if (newStaked > oldStaked) {
            uint256 delta = newStaked - oldStaked;
            while (cursor != address(0)) {
                downlineBalance[cursor] += delta;
                cursor = referrer[cursor];
            }
        } else {
            uint256 delta = oldStaked - newStaked;
            while (cursor != address(0)) {
                downlineBalance[cursor] -= delta;
                cursor = referrer[cursor];
            }
        }
    }

    function recheckNodeAndTier(address user) external onlyCustody {
        _checkNodeStatusAndTier(user);
        address cursor = referrer[user];
        while (cursor != address(0)) {
            _checkNodeStatusAndTier(cursor);
            cursor = referrer[cursor];
        }
    }

    function effectiveBalanceOf(address account) external view returns (uint256) {
        return _effectiveBalance(account);
    }

    // ==================== 查询函数 ====================

    function getReferralDepth(address _account) external view returns (uint256) {
        return referralDepth[_account];
    }

    function getReferralsCount(address _account) external view returns (uint256) {
        return referralCount[_account];
    }

    function getReferralList(address _account) external view returns (address[] memory) {
        return referrals[_account];
    }

    function getNodeCount() external view returns (uint256) {
        return nodeCount;
    }

    function getNodeList() external view returns (address[] memory) {
        return nodeList;
    }

    function getNextDailyBurnTime() external view returns (uint256) {
        return lastDailyBurnTimestamp + DAILY_BURN_INTERVAL;
    }

    function getReferralInfo(address _account)
        external view
        returns (address _referrer, uint256 _depth, uint256 _count, uint256 _totalVolume, uint256 _pendingReward)
    {
        return (referrer[_account], referralDepth[_account], referralCount[_account],
                totalReferralVolume[_account], pendingReferralReward[_account]);
    }

    function getNodeInfo(address _account)
        external view
        returns (bool _isNode, uint256 _balance, uint256 _threshold, uint256 _pendingDividend)
    {
        return (isNode[_account], _effectiveBalance(_account), oracle.nodeThreshold, _earnedNodeDividend(_account));
    }

    function getOracleInfo()
        external view
        returns (uint256 _cachedURPrice, uint256 _nodeThreshold, uint256 _targetNodeValueUSD, uint256 _lastOracleUpdate)
    {
        return (oracle.cachedURPrice, oracle.nodeThreshold, oracle.targetNodeValueUSD, oracle.lastOracleUpdate);
    }

    function getTierInfo(address _account)
        external view
        returns (
            uint256 _tierLevel, uint256 _personalBalance, uint256 _downlineBalance,
            uint256 _personalUSD, uint256 _downlineUSD, uint256 _v6Count,
            uint256 _lastClaimedDay, uint256 _rewardDay
        )
    {
        uint256 _pUSD;
        uint256 _dUSD;
        {
            uint256 _price = oracle.cachedURPrice;
            uint256 _effBal = _effectiveBalance(_account);
            _personalBalance = _effBal;
            _downlineBalance = downlineBalance[_account];
            _pUSD = _price > 0 ? (_effBal * _price) / 1e18 : 0;
            _dUSD = _price > 0 ? (_downlineBalance * _price) / 1e18 : 0;
        }
        _tierLevel = tierLevel[_account];
        _personalUSD = _pUSD;
        _downlineUSD = _dUSD;
        _v6Count = v6DownlineCount[_account];
        _lastClaimedDay = lastClaimedDay[_account];
        _rewardDay = currentRewardDay;
    }

    function _previewRewardCalc(
        address _account, uint256 _price, uint256 _tier, uint256 _downlineUSD
    ) internal view returns (
        uint256 _totalNewHoldingUSD, uint256 _dailyAvgNewUSD,
        uint256 _rateBps, uint256 _coefficient, uint256 _estimatedRewardUR
    ) {
        uint256 _cfg = URTierConfigLib.packedConfig(_tier);
        uint256 _nh  = _cfg & 0xFFFFFFFFFFFFFFFFFFFF;

        uint256 gap = currentRewardDay - lastClaimedDay[_account];
        {
            uint256 _su = (downlineSnapshot[_account] * _price) / 1e18;
            uint256 _tn = _downlineUSD > _su ? _downlineUSD - _su : 0;
            uint256 _mn = _nh * gap;
            _totalNewHoldingUSD = _tn > _mn ? _mn : _tn;
        }
        _dailyAvgNewUSD = _totalNewHoldingUSD / gap;
        {
            uint256 scale;
            {
                if (_nh > 0 && _dailyAvgNewUSD > 0) scale = (_dailyAvgNewUSD * 1e18) / _nh;
                if (scale > 1e18) scale = 1e18;
            }
            {
                uint256 _r0 = (_cfg >> 80)  & 0xFF;
                uint256 _r1 = (_cfg >> 88)  & 0xFF;
                _rateBps = _r0 + ((_r1 - _r0) * scale) / 1e18;
                uint256 _c0 = (_cfg >> 96)  & 0xFF;
                uint256 _c1 = (_cfg >> 104) & 0xFF;
                _coefficient = _c0 + ((_c1 - _c0) * scale) / 1e18;
            }
        }
        {
            uint256 _db = (_downlineUSD * _rateBps) / 10000;
            uint256 _tp = cumulativeRewardPaidToDownline[_account];
            uint256 paidAvg = _tp > 0 ? (_tp * _price) / 1e18 / gap : 0;
            uint256 _net = _db > paidAvg ? _db - paidAvg : 0;
            _estimatedRewardUR = ((_net * _coefficient) / 100 * gap * 1e18) / _price;
        }
    }

    function previewDailyReward(address _account)
        external view
        returns (
            uint256 _tier, uint256 _estimatedRewardUR, uint256 _downlineUSD,
            uint256 _totalNewHoldingUSD, uint256 _dailyAvgNewUSD,
            uint256 _rateBps, uint256 _coefficient
        )
    {
        _tier = tierLevel[_account];
        if (_tier == 0 || currentRewardDay <= lastClaimedDay[_account]) {
            return (_tier, 0, 0, 0, 0, 0, 0);
        }

        uint256 price = oracle.cachedURPrice;
        if (price == 0) return (_tier, 0, 0, 0, 0, 0, 0);

        _downlineUSD = (downlineBalance[_account] * price) / 1e18;

        (_totalNewHoldingUSD, _dailyAvgNewUSD, _rateBps, _coefficient, _estimatedRewardUR) =
            _previewRewardCalc(_account, price, _tier, _downlineUSD);

        return (_tier, _estimatedRewardUR, _downlineUSD, _totalNewHoldingUSD, _dailyAvgNewUSD, _rateBps, _coefficient);
    }
}
