// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title UR ILO — Initial Liquidity Offering (USDT)
 * @notice 为 UR Token 提供 USDT 众筹 + PancakeSwap USDT/UR 流动性共建
 *
 *   资金模型 (80/20)：
 *     - 每笔 USDT 的 20% 立刻转营销钱包
 *     - 80% 留存 + 等值 UR → PancakeSwap USDT/UR 流动性池
 *     - 用户 claimTokens() 领取 120% UR（总量 = 募集 USDT × rate × 2）
 *
 *   流程：
 *   1. 部署 ILO 合约 → URTokenV3 owner 调用 setMinter(iloAddress)
 *   2. 用户先 approve USDT 给 ILO 合约，再调用 contribute(amount)
 *   3. ILO 结束后 finalize()：创建 PancakeSwap USDT/UR 流动性池 + 分配代币
 *   4. 用户 claimTokens() 领取 UR
 *   5. 软顶 = 0，ILO 始终进入结算，无需退款
 *
 *   链：BSC (Chain ID 56)
 *   编译器：Solidity ^0.8.20，优化器 200 runs
 */

// ==================== 抽象合约 ====================

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() { _status = _NOT_ENTERED; }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() { owner = msg.sender; }

    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

// ==================== 接口 ====================

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IURToken {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakeRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function factory() external view returns (address);
}

// ==================== 主合约 ====================

contract URILO is ReentrancyGuard, Ownable {
    // ======== 不可变参数 ========
    IURToken public immutable urToken;
    IERC20  public immutable usdt;
    IPancakeRouter public immutable router;
    uint256 public immutable startTime;
    uint256 public immutable endTime;
    uint256 public immutable hardCap;          // USDT, 最小单位 (18 位小数)
    uint256 public immutable rate;             // UR per USDT（最小单位比，1e18 = 1:1）
    uint256 public immutable minContribution;  // USDT 最小单位
    uint256 public immutable maxContribution;  // USDT 最小单位
    address public immutable marketingWallet;   // 20% 营销 + LP 失败退款接收地址

    // ======== 状态变量 ========
    uint256 public totalRaised;                // 已筹集 USDT 总额（最小单位）
    bool    public finalized;
    bool    public liquidityCreated;
    uint256 public totalTokensForDistribution;
    address public pancakePair;
    address public lpReceiver;

    mapping(address => uint256) public contributions;
    mapping(address => bool)    public claimed;
    address[]                    public contributorList;

    // ======== 事件 ========
    event Contributed(address indexed user, uint256 usdtAmount);
    event Finalized(
        uint256 totalRaised,
        uint256 totalTokens,
        uint256 tokensForLP,
        uint256 tokensForUsers
    );
    event LiquidityCreated(
        address indexed pair,
        uint256 usdtInLP,
        uint256 urInLP,
        uint256 lpTokensReceived,
        address lpReceiver
    );
    event TokensClaimed(address indexed user, uint256 amount);
    event ProjectUSDTWithdrawn(uint256 amount, address to);
    event LPReceiverUpdated(address oldReceiver, address newReceiver);

    // ======== 修饰器 ========
    modifier duringILO() {
        require(block.timestamp >= startTime, "ILO not started");
        require(block.timestamp < endTime, "ILO ended");
        _;
    }

    modifier afterILO() {
        require(block.timestamp >= endTime, "ILO not ended");
        _;
    }

    modifier notFinalized() {
        require(!finalized, "Already finalized");
        _;
    }

    modifier onlyFinalized() {
        require(finalized, "Not finalized");
        _;
    }

    // ======== 构造函数 ========
    /// @param _urToken          UR 代币地址
    /// @param _usdt             USDT 代币地址 (BSC: 0x55d398326f99059fF775485246999027B3197955)
    /// @param _router           PancakeSwap Router (BSC: 0x10ED43C718714eb63d5aA57B78B54704E256024E)
    /// @param _startTime        Unix 时间戳 (秒)
    /// @param _endTime          Unix 时间戳 (秒)
    /// @param _hardCap          USDT 硬顶 (最小单位, USDT 18 位小数)
    /// @param _rate             UR/USDT 兑换率 (最小单位比，1e18 表示 1:1)
    /// @param _minContribution  单笔最低 (USDT 最小单位)
    /// @param _maxContribution  单人最高累计 (USDT 最小单位)
    /// @param _marketingWallet  营销钱包 (20% 即时转入 + LP 失败退款接收)
    constructor(
        address _urToken,
        address _usdt,
        address _router,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _hardCap,
        uint256 _rate,
        uint256 _minContribution,
        uint256 _maxContribution,
        address _marketingWallet
    ) {
        require(_urToken != address(0),         "Zero UR token");
        require(_usdt != address(0),            "Zero USDT");
        require(_router != address(0),          "Zero router");
        require(_startTime > block.timestamp,   "Start in past");
        require(_endTime > _startTime,          "End <= start");
        require(_hardCap > 0,                   "Zero hard cap");
        require(_rate > 0,                      "Zero rate");
        require(_maxContribution > _minContribution, "Max <= min");
        require(_minContribution > 0,           "Zero min contribution");
        require(_marketingWallet != address(0), "Zero marketing wallet");

        urToken         = IURToken(_urToken);
        usdt            = IERC20(_usdt);
        router          = IPancakeRouter(_router);
        startTime       = _startTime;
        endTime         = _endTime;
        hardCap         = _hardCap;
        rate            = _rate;
        minContribution = _minContribution;
        maxContribution = _maxContribution;
        marketingWallet = _marketingWallet;
    }

    // ======== 贡献 ========

    /// @notice 用户贡献 USDT（需先 approve 本合约）
    /// @param amount USDT 数量（最小单位，18 位小数）
    ///         20% 立刻转营销钱包，80% 留存用于 LP
    function contribute(uint256 amount) external duringILO nonReentrant {
        require(amount >= minContribution,            "Below min");
        require(totalRaised + amount <= hardCap,      "Exceeds hard cap");

        uint256 userTotal = contributions[msg.sender] + amount;
        require(userTotal <= maxContribution,         "Exceeds max");

        // 先记录后转币，防止重入
        if (contributions[msg.sender] == 0) {
            contributorList.push(msg.sender);
        }
        contributions[msg.sender] = userTotal;
        totalRaised += amount;

        // 全额转入合约
        require(usdt.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // 20% 即刻转营销钱包
        uint256 fee = amount * 20 / 100;
        if (fee > 0) {
            require(usdt.transfer(marketingWallet, fee), "Marketing fee failed");
        }

        emit Contributed(msg.sender, amount);
    }

    // ======== 查询 ========

    function claimableTokens(address user) public view returns (uint256) {
        if (!finalized || claimed[user] || contributions[user] == 0 || totalRaised == 0)
            return 0;
        return (contributions[user] * totalTokensForDistribution) / totalRaised;
    }

    function isActive() public view returns (bool) {
        return block.timestamp >= startTime && block.timestamp < endTime;
    }

    function sortTokens(address tokenA, address tokenB)
        internal pure returns (address token0, address token1)
    {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice 安全 approve（某些 ERC20 如 USDT 要求先清零再设新值）
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Approve failed");
    }

    /// @notice 从 PancakeSwap Factory 查询交易对地址
    function _getPair(address tokenA, address tokenB) internal view returns (address pair) {
        address factory = router.factory();
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB)
        );
        if (ok && data.length == 32) {
            pair = abi.decode(data, (address));
        }
    }

    // ======== Owner: 执行最终结算 ========

    /// @notice ILO 结束后调用：创建 USDT/UR 流动性 + 铸造代币
    ///         80% USDT + 等值 UR → LP | 20% UR → 用户领取
    /// @param _lpReceiver LP 代币接收地址 (address(0) = 永久销毁)
    /// @param slippageBps 滑点保护 (基点，如 500 = 5%)
    function finalize(address _lpReceiver, uint256 slippageBps)
        external
        onlyOwner
        afterILO
        notFinalized
        nonReentrant
    {
        require(slippageBps <= 1000, "Slippage too high");
        finalized = true;

        // 总 UR = 总 USDT × 兑换率 × 2（200% = 80% LP + 120% 用户）
        uint256 totalTokens = totalRaised * rate * 2 / 1e18;

        // 合约留存 USDT = totalRaised 的 80%（20% 已在 contribute 时转营销钱包）
        // 用 totalRaised × 80% 而非 balanceOf，防止直接转账的 USDT 混入 LP
        uint256 usdtBalance = totalRaised * 80 / 100;

        // UR 进 LP：与留存 USDT 等值配对
        uint256 urForLP = usdtBalance * rate / 1e18;

        if (usdtBalance > 0 && urForLP > 0) {
            uint256 minUR   = urForLP    * (10000 - slippageBps) / 10000;
            uint256 minUSDT = usdtBalance * (10000 - slippageBps) / 10000;

            // 铸造 LP 所需 UR
            urToken.mint(address(this), urForLP);

            // 授权 Router 支配 UR 和 USDT（统一走安全 approve）
            _safeApprove(address(urToken), address(router), urForLP);
            _safeApprove(address(usdt),    address(router), usdtBalance);

            (address token0, address token1) = sortTokens(address(usdt), address(urToken));
            uint256 amount0Desired = token0 == address(usdt) ? usdtBalance : urForLP;
            uint256 amount1Desired = token1 == address(urToken) ? urForLP : usdtBalance;
            uint256 amount0Min     = token0 == address(usdt) ? minUSDT    : minUR;
            uint256 amount1Min     = token1 == address(urToken) ? minUR      : minUSDT;

            // P1-03: _lpReceiver 为 address(0) 时复用 setLPReceiver 已设置的值
            if (_lpReceiver != address(0)) {
                lpReceiver = _lpReceiver;
            }

            try router.addLiquidity(
                token0, token1,
                amount0Desired, amount1Desired,
                amount0Min, amount1Min,
                _lpReceiver,
                block.timestamp + 30 minutes
            ) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
                liquidityCreated = true;
                pancakePair = _getPair(address(usdt), address(urToken));
                emit LiquidityCreated(pancakePair, amountA, amountB, liquidity, _lpReceiver);

                // 清零 Router 授权（防止残留）
                _safeApprove(address(urToken), address(router), 0);
                _safeApprove(address(usdt),    address(router), 0);

                // 扫尾：addLiquidity 返还的 Dust + 直接转账的 USDT → 全转营销钱包
                uint256 remaining = usdt.balanceOf(address(this));
                if (remaining > 0) {
                    require(usdt.transfer(marketingWallet, remaining), "Sweep USDT failed");
                    emit ProjectUSDTWithdrawn(remaining, marketingWallet);
                }

                // P1-01: 清扫 UR 粉尘
                uint256 remainingUR = urToken.balanceOf(address(this));
                if (remainingUR > 0) {
                    require(urToken.transfer(marketingWallet, remainingUR), "Sweep UR failed");
                }
            } catch {
                // LP 创建失败 → 清零授权 + USDT 退营销 + LP 的 UR 退营销
                _safeApprove(address(urToken), address(router), 0);
                _safeApprove(address(usdt),    address(router), 0);

                uint256 remaining = usdt.balanceOf(address(this));
                if (remaining > 0) {
                    require(usdt.transfer(marketingWallet, remaining), "Refund USDT failed");
                    emit ProjectUSDTWithdrawn(remaining, marketingWallet);
                }

                uint256 lockedUR = urToken.balanceOf(address(this));
                if (lockedUR > 0) {
                    require(urToken.transfer(marketingWallet, lockedUR), "Refund UR failed");
                }
            }
        }

        // 铸造用户可领取的 UR（20%）
        uint256 tokensForUsers = totalTokens - urForLP;
        totalTokensForDistribution = tokensForUsers;
        if (tokensForUsers > 0) {
            urToken.mint(address(this), tokensForUsers);
        }

        emit Finalized(totalRaised, totalTokens, urForLP, tokensForUsers);
    }

    // ======== 用户: 领取代币 ========

    function claimTokens() external onlyFinalized nonReentrant {
        require(!claimed[msg.sender],     "Already claimed");
        require(contributions[msg.sender] > 0, "No contribution");

        uint256 amount = claimableTokens(msg.sender);
        require(amount > 0, "Zero claimable");

        claimed[msg.sender] = true;
        require(urToken.transfer(msg.sender, amount), "Transfer failed");

        emit TokensClaimed(msg.sender, amount);
    }

    // ======== Owner: 设置 LP 接收地址 ========

    function setLPReceiver(address _lpReceiver) external onlyOwner {
        require(!liquidityCreated, "LP already created");
        address old = lpReceiver;
        lpReceiver = _lpReceiver;
        emit LPReceiverUpdated(old, _lpReceiver);
    }

    // ======== 视图辅助 ========

    function getContributorCount() external view returns (uint256) {
        return contributorList.length;
    }

    function getContributorList() external view returns (address[] memory) {
        return contributorList;
    }

    function getContractUSDTBalance() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }
}
