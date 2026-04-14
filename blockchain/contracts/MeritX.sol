// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ---------- External Interfaces ----------

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee)
        external view returns (address pool);
}

interface IUniswapV3Pool {
    function observe(uint32[] calldata)
        external view returns (int56[] memory, uint160[] memory);
    function slot0()
        external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function increaseObservationCardinalityNext(uint16) external;
    function initialize(uint160 sqrtPriceX96) external;
}

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId; address recipient;
        uint128 amount0Max; uint128 amount1Max;
    }
    function factory() external view returns (address);
    function createAndInitializePoolIfNecessary(
        address, address, uint24, uint160
    ) external payable returns (address);
    function mint(MintParams calldata)
        external payable returns (uint256, uint128, uint256, uint256);
    function collect(CollectParams calldata)
        external payable returns (uint256, uint256);
}

interface IMeritXFactory {
    function operator() external view returns (address);
    function checkAndRecordCooldown(address user) external;
    function lastContributionTime(address user) external view returns (uint256);
}

// ---------- MeritX Token -- ERC20 + immutable minter ----------
contract MeritXToken {
    address public immutable minter;

    string  public name;
    string  public symbol;
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _supply, address _minter) {
        require(_minter != address(0), "!minter");
        name = _name;
        symbol = _symbol;
        totalSupply = _supply;
        minter = _minter;
        balanceOf[_minter] = _supply;
        emit Transfer(address(0), _minter, _supply);
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "!minter");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "!zero"); 
        require(balanceOf[msg.sender] >= amount, "!bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "!zero"); 
        require(balanceOf[from] >= amount, "!bal");
        require(allowance[from][msg.sender] >= amount, "!allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ---------- MeritX Fund -- Raise + LP Creation/Lock ----------
contract MeritXFund is ReentrancyGuard {
    enum State { Funding, Failed, Success_Isolated, Ready_For_DEX }

    event Contribution(address indexed user, uint256 amount);
    event FundFinalized(address pool, uint256 lpTokenId);
    event PoolGriefDetected();

    MeritXToken public projectToken;
    address public immutable factory; 
    address public immutable projectOwner;
    address public immutable platformTreasury;
    address public immutable backendSigner;
    address public immutable positionManager;
    address public immutable weth;

    // -- LP constants --
    int24   internal constant TICK_RADIUS  = 30000;
    int24   internal constant MIN_TICK     = -887220; 
    int24   internal constant MAX_TICK     =  887220; 

    // -- Raise parameters (MAINNET) --
    uint256 public constant SOFT_CAP           = 5 ether;
    uint256 public constant MAX_ALLOCATION     = 0.15 ether;
    uint256 public constant RAISE_DURATION     = 24 hours;
    uint256 public constant PLATFORM_FEE_PCT   = 5;
    uint256 public constant LAUNCH_WINDOW      = 30 days;
    uint256 public constant PRE_LAUNCH_NOTICE  = 6 hours;
    uint256 public constant LAUNCH_EXPIRATION  = 24 hours;
    uint256 public constant RETAIL_POOL        = 21_000_000e18;
    uint256 public constant INITIAL_SUPPLY     = 40_950_000e18;
    uint256 public constant LP_POOL            = INITIAL_SUPPLY - RETAIL_POOL;

    // -- PoP inflation constants --
    uint256 internal constant LN_1_0001        = 99_995_000_333_300;
    uint256 internal constant EXPONENT_012     = 120_000_000_000_000_000;
    uint256 public constant MAX_MINT_BPS       = 350; // 3.5% daily cap
    uint256 public constant RATE_WINDOW        = 24 hours;
    uint256 public constant CALLER_REWARD_BPS  = 10;
    uint32  public constant TWAP_INTERVAL      = 1800;

    // -- Raise state --
    uint256 public totalRaised;
    uint256 public raiseEndTime;
    bool    public isFinalized;
    bool    public poolGriefed;
    mapping(address => uint256) public contributions;
    mapping(address => uint256) public nonces;

    // -- Anti-stealth launch --
    uint256 public launchAnnouncementTime;

    // -- IPFS metadata --
    string public ipfsURI;

    // -- Inflation revenue routing --
    address public inflationReceiver;

    // -- Post-finalization state --
    uint256 public lpTokenId;
    address public uniswapPool;
    int24   public initialTick;
    uint256 public lastMintTime;
    uint256 public poolCreationTime;
    uint256 public mintedInWindow;

    constructor(
        address _factory, 
        address _owner,
        string memory _name,
        string memory _symbol,
        address _treasury,
        address _backendSigner,
        address _positionManager,
        address _weth,
        string memory _ipfsURI,
        address _inflationReceiver
    ) {
        require(_factory        != address(0), "!factory");
        require(_owner          != address(0), "!owner");
        require(_treasury       != address(0), "!treasury");
        require(_backendSigner  != address(0), "!signer");
        require(_positionManager!= address(0), "!pm");
        require(_weth           != address(0), "!weth");
        factory          = _factory;
        projectOwner     = _owner;
        platformTreasury = _treasury;
        backendSigner    = _backendSigner;
        positionManager  = _positionManager;
        weth             = _weth;
        raiseEndTime     = block.timestamp + RAISE_DURATION;
        ipfsURI          = _ipfsURI;
        inflationReceiver = _inflationReceiver == address(0) ? _owner : _inflationReceiver;
        projectToken     = new MeritXToken(_name, _symbol, INITIAL_SUPPLY, address(this));
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    /// @notice Contribute ETH to this project's funding round.
    /// @dev    Requires a valid ECDSA signature from the platform's backend gateway.
    ///         The backend issues signatures only to wallets that pass off-chain
    ///         Proof-of-Gas (PoG) eligibility checks (historical gas spend across
    ///         multiple chains), effectively filtering out sybils, bots and fresh
    ///         wallets.  The signed hash binds (msg.sender, maxAlloc, nonce,
    ///         deadline, address(this), block.chainid) to prevent cross-chain,
    ///         cross-project and replay attacks.
    /// @param _maxAlloc  Maximum wei the user is permitted to contribute (set by backend).
    /// @param _deadline  Unix timestamp after which the signature is invalid.
    /// @param _sig       65-byte ECDSA signature produced by `backendSigner`.
    function contribute(uint256 _maxAlloc, uint256 _deadline, bytes calldata _sig) external payable nonReentrant {
        require(block.timestamp <= raiseEndTime, "!time");
        require(block.timestamp <= _deadline, "!expired");
        require(msg.value > 0, "!val");
        require(_maxAlloc <= MAX_ALLOCATION, "!ceil");

        bytes32 h = keccak256(abi.encodePacked(
            msg.sender, _maxAlloc, nonces[msg.sender], _deadline, address(this), block.chainid
        ));
        require(_recover(h, _sig) == backendSigner, "!sig");
        nonces[msg.sender]++;

        IMeritXFactory(factory).checkAndRecordCooldown(msg.sender);

        require(contributions[msg.sender] + msg.value <= _maxAlloc, "!alloc");
        contributions[msg.sender] += msg.value;
        totalRaised += msg.value;
        emit Contribution(msg.sender, msg.value); 
    }

    function _recover(bytes32 _h, bytes memory _s) internal pure returns (address) {
        bytes32 eh = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", _h)
        );
        require(_s.length == 65, "!siglen");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(_s, 32))
            s := mload(add(_s, 64))
            v := byte(0, mload(add(_s, 96)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "!v");
        require(
            uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "!s"
        );
        address a = ecrecover(eh, v, r, s);
        require(a != address(0), "!rec");
        return a;
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function currentState() public view returns (State) {
        if (poolGriefed) return State.Failed;
        if (block.timestamp <= raiseEndTime) return State.Funding;
        if (totalRaised < SOFT_CAP) return State.Failed;
        if (!isFinalized) return State.Success_Isolated;
        return State.Ready_For_DEX;
    }

    /**
     * Returns the absolute deadline (unix timestamp) by which finalizeFunding()
     * must be called, or 0 if the project is still in Funding / already finalized.
     *
     * Branch A (announced): announcementTime + PRE_LAUNCH_NOTICE + LAUNCH_EXPIRATION
     * Branch B (passive):   raiseEndTime + LAUNCH_WINDOW
     * The effective deadline is the earlier of the two if Branch A applies.
     */
    function launchDeadline() public view returns (uint256) {
        if (currentState() != State.Success_Isolated) return 0;
        uint256 passiveDeadline = raiseEndTime + LAUNCH_WINDOW;
        if (launchAnnouncementTime == 0) return passiveDeadline;
        uint256 activeDeadline = launchAnnouncementTime + PRE_LAUNCH_NOTICE + LAUNCH_EXPIRATION;
        return activeDeadline < passiveDeadline ? activeDeadline : passiveDeadline;
    }

    function claimTokens() external nonReentrant {
        require(currentState() == State.Ready_For_DEX, "!ready");
        uint256 a = contributions[msg.sender];
        require(a > 0, "!contrib");
        contributions[msg.sender] = 0;                                  
        require(projectToken.transfer(msg.sender, (a * RETAIL_POOL) / totalRaised), "!xfer"); 
    }

    function claimRefund() external nonReentrant {
        State s = currentState();
        require(
            s == State.Failed ||
            (s == State.Success_Isolated &&
             block.timestamp > raiseEndTime + LAUNCH_WINDOW) ||
            (s == State.Success_Isolated &&
             launchAnnouncementTime > 0 &&
             block.timestamp > launchAnnouncementTime + PRE_LAUNCH_NOTICE + LAUNCH_EXPIRATION),
            "!rna"
        );
        uint256 a = contributions[msg.sender];
        require(a > 0, "!funds");
        contributions[msg.sender] = 0;
        totalRaised -= a;
        (bool ok, ) = payable(msg.sender).call{value: a}(""); 
        require(ok, "!refund");
    }

    function announceLaunch() external {
        require(msg.sender == projectOwner, "!owner");
        require(block.timestamp > raiseEndTime, "!raise");
        require(totalRaised >= SOFT_CAP, "!cap");
        require(!isFinalized, "!done");
        require(!poolGriefed, "!griefed");
        require(launchAnnouncementTime == 0, "!ann");
        launchAnnouncementTime = block.timestamp;
    }

    function finalizeFunding() external nonReentrant {
        require(msg.sender == projectOwner, "!owner");
        require(
            launchAnnouncementTime > 0 &&
            block.timestamp >= launchAnnouncementTime + PRE_LAUNCH_NOTICE,
            "!notice"
        );
        require(
            block.timestamp <= launchAnnouncementTime + PRE_LAUNCH_NOTICE + LAUNCH_EXPIRATION,
            "!le"
        );
        require(block.timestamp <= raiseEndTime + LAUNCH_WINDOW, "!window");
        require(totalRaised >= SOFT_CAP, "!cap");
        require(!isFinalized, "!done");
        require(!poolGriefed, "!griefed");

        isFinalized = true;
        poolCreationTime = block.timestamp;
        lastMintTime = block.timestamp;

        // ─────────────────────────
        // 1. Prepare funds
        // ─────────────────────────
        uint256 raised = totalRaised;
        uint256 fee = (raised * PLATFORM_FEE_PCT) / 100;
        uint256 ethForPool = raised - fee;

        IWETH(weth).deposit{value: ethForPool}();

        bool tkn0 = address(projectToken) < weth;
        address t0 = tkn0 ? address(projectToken) : weth;
        address t1 = tkn0 ? weth : address(projectToken);

        uint256 tokensForPool = LP_POOL;

        // ─────────────────────────
        // 2. Compute fair sqrtPrice
        // ─────────────────────────
        uint160 sqrtPrice;
        {
            uint256 r0 = tkn0 ? tokensForPool : ethForPool;
            uint256 r1 = tkn0 ? ethForPool : tokensForPool;

            uint256 sqrtR0 = Math.sqrt(r0);
            uint256 sqrtR1 = Math.sqrt(r1);

            sqrtPrice = uint160((sqrtR1 << 96) / sqrtR0);
        }

        // ─────────────────────────
        // 3. Zero-trust pool selection (C-1)
        // ─────────────────────────
        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        address v3Factory = pm.factory();

        address bestPool;
        uint24  bestFee;

        {
            uint24[4] memory fees = [uint24(3000), 10000, 500, 100];

            for (uint256 i = 0; i < 4; i++) {
                address pool = IUniswapV3Factory(v3Factory).getPool(t0, t1, fees[i]);

                if (pool == address(0)) {
                    bestPool = pm.createAndInitializePoolIfNecessary(t0, t1, fees[i], sqrtPrice);
                    bestFee = fees[i];
                    break;
                }

                (uint160 spot,,,,,,) = IUniswapV3Pool(pool).slot0();

                if (spot == 0) {
                    IUniswapV3Pool(pool).initialize(sqrtPrice);
                    bestPool = pool;
                    bestFee = fees[i];
                    break;
                }
            }
        }

        // Graceful degradation: if all 4 pools griefed, abort and enable immediate refunds
        if (bestPool == address(0)) {
            isFinalized = false;
            poolGriefed = true;
            uint256 griefBal = IWETH(weth).balanceOf(address(this));
            if (griefBal > 0) IWETH(weth).withdraw(griefBal);
            emit PoolGriefDetected();
            return;
        }

        // ─────────────────────────
        // 4. Compute ticks
        // ─────────────────────────
        int24 tickSpacing;
        if (bestFee == 3000)       tickSpacing = 60;
        else if (bestFee == 10000) tickSpacing = 200;
        else if (bestFee == 500)   tickSpacing = 10;
        else                       tickSpacing = 1;

        (, int24 currentTick,,,,,) = IUniswapV3Pool(bestPool).slot0();

        int24 lowerTick = _floorTick(currentTick - TICK_RADIUS, tickSpacing);
        int24 upperTick = _floorTick(currentTick + TICK_RADIUS, tickSpacing);

        int24 minT = (-887272 / tickSpacing) * tickSpacing;
        int24 maxT = ( 887272 / tickSpacing) * tickSpacing;

        if (lowerTick < minT) lowerTick = minT;
        if (upperTick > maxT) upperTick = maxT;

        require(lowerTick < upperTick, "!ticks");

        // ─────────────────────────
        // 5. Approve
        // ─────────────────────────
        uint256 wethBal = IWETH(weth).balanceOf(address(this));

        IWETH(weth).approve(positionManager, wethBal);
        projectToken.approve(positionManager, tokensForPool);

        // ─────────────────────────
        // 6. Mint LP
        // ─────────────────────────
        uint256 a0 = tkn0 ? tokensForPool : wethBal;
        uint256 a1 = tkn0 ? wethBal : tokensForPool;

        uint256 min0 = (a0 * 99) / 100;
        uint256 min1 = (a1 * 99) / 100;

        (uint256 tokenId,,,) = pm.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: bestFee,
                tickLower: lowerTick,
                tickUpper: upperTick,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: min0,
                amount1Min: min1,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        require(tokenId > 0, "!lp");

        lpTokenId = tokenId;
        uniswapPool = bestPool;

        (, int24 tick,,,,,) = IUniswapV3Pool(bestPool).slot0();
        initialTick = tick;

        IUniswapV3Pool(bestPool).increaseObservationCardinalityNext(150);

        // ─────────────────────────
        // 7. Platform fee
        // ─────────────────────────
        (bool ok,) = payable(platformTreasury).call{value: fee}("");
        require(ok, "!fee");

        uint256 dust = IWETH(weth).balanceOf(address(this));
        if (dust > 0) {
            IWETH(weth).transfer(platformTreasury, dust);
        }

        emit FundFinalized(bestPool, tokenId);
    }

    function expandPoolObservation(uint16 nextCardinality) external {
        require(uniswapPool != address(0), "!pool");
        IUniswapV3Pool(uniswapPool).increaseObservationCardinalityNext(nextCardinality);
    }

    function collectTradingFees() external nonReentrant {
        require(
            msg.sender == platformTreasury || msg.sender == IMeritXFactory(factory).operator(),
            "!ac"
        );
        require(lpTokenId != 0, "!lp");
        INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    lpTokenId,
                recipient:  platformTreasury,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function getTWAP() public view returns (int24) {
        require(uniswapPool != address(0), "!pool");
        uint32 timeElapsed = uint32(block.timestamp - poolCreationTime);
        if (timeElapsed == 0) return initialTick;
        uint32 interval = timeElapsed < TWAP_INTERVAL ? timeElapsed : TWAP_INTERVAL;
        if (interval == 0) return initialTick;

        uint32[] memory secs = new uint32[](2);
        secs[0] = interval;
        secs[1] = 0;
        (int56[] memory tc, ) = IUniswapV3Pool(uniswapPool).observe(secs);
        return int24((tc[1] - tc[0]) / int56(int32(interval)));
    }

    function calculateTargetSupply(int24 tick) public view returns (uint256) {
        int256 d = int256(tick) - int256(initialTick);
        if (address(projectToken) > weth) d = -d;
        if (d <= 0) return INITIAL_SUPPLY;
        uint256 du = uint256(d) > 120_000 ? 120_000 : uint256(d);
        uint256 e = (EXPONENT_012 * du * LN_1_0001) / 1e18;
        return ud(INITIAL_SUPPLY).mul(ud(e).exp()).unwrap();
    }

    function mintInflation() external nonReentrant {
        require(isFinalized, "!fin");
        require(uniswapPool != address(0), "!pool");
        require(block.timestamp >= poolCreationTime + TWAP_INTERVAL, "!twap");

        uint256 current = projectToken.totalSupply();
        uint256 cap     = (current * MAX_MINT_BPS) / 10_000;

        uint256 elapsed = block.timestamp - lastMintTime;
        uint256 decayed = (cap * elapsed) / RATE_WINDOW; 
        uint256 bucket  = decayed >= mintedInWindow ? 0 : mintedInWindow - decayed;

        int24   t       = getTWAP();
        uint256 target  = calculateTargetSupply(t);
        require(target > current, "!inf");

        uint256 m         = target - current;
        uint256 available = cap > bucket ? cap - bucket : 0;
        require(available > 0, "!rl");
        if (m > available) m = available;

        mintedInWindow = bucket + m;
        lastMintTime   = block.timestamp;

        uint256 cr = (m * CALLER_REWARD_BPS) / 10_000;
        projectToken.mint(inflationReceiver, m - cr);
        if (cr > 0) projectToken.mint(msg.sender, cr);
    }
}

// ---------- MeritX Factory -- Permissionless Genesis ----------
contract MeritXFactory {
    event ProjectCreated(address indexed fund, address indexed creator);
    event OperatorChanged(address indexed prev, address indexed next);
    event PauseToggled(bool paused);

    address[] public allDeployedProjects;
    address public immutable platformTreasury;
    address public immutable backendSigner;
    address public immutable positionManager;
    address public immutable weth;
    
    address public operator;
    address public emergencyAdmin;
    bool public isPaused;

    uint256 public constant LISTING_FEE     = 0.01 ether;
    uint256 public constant GLOBAL_COOLDOWN = 48 hours;

    mapping(address => bool) public isValidFund;
    mapping(address => uint256) public lastContributionTime;

    constructor(
        address _signer, 
        address _pm, 
        address _weth, 
        address _treasury,
        address _emergencyAdmin
    ) {
        require(_signer   != address(0), "!signer");
        require(_pm       != address(0), "!pm");
        require(_weth     != address(0), "!weth");
        require(_treasury != address(0), "!treasury");
        platformTreasury = _treasury;
        backendSigner    = _signer;
        positionManager  = _pm;
        weth             = _weth;
        emergencyAdmin   = _emergencyAdmin;
    }

    function setProtocolPause(bool _paused) external {
        require(
            msg.sender == platformTreasury || 
            (emergencyAdmin != address(0) && msg.sender == emergencyAdmin), 
            "!auth"
        );
        isPaused = _paused;
        emit PauseToggled(_paused);
    }

    function setEmergencyAdmin(address _newAdmin) external {
        require(msg.sender == platformTreasury, "!t");
        emergencyAdmin = _newAdmin;
    }

    function setOperator(address _newOp) external {
        require(msg.sender == platformTreasury, "!t");
        emit OperatorChanged(operator, _newOp);
        operator = _newOp;
    }

    function launchNewProject(
        string memory _name,
        string memory _symbol,
        string memory _ipfsURI,
        address _inflationReceiver
    ) external payable returns (address) {
        require(!isPaused, "!p");
        require(msg.value == LISTING_FEE, "!fee");

        (bool ok, ) = payable(platformTreasury).call{value: msg.value}("");
        require(ok, "!xfer");
        
        MeritXFund f = new MeritXFund(
            address(this), 
            msg.sender, _name, _symbol,
            platformTreasury, backendSigner, positionManager, weth,
            _ipfsURI,
            _inflationReceiver
        );
        allDeployedProjects.push(address(f));
        isValidFund[address(f)] = true;
        emit ProjectCreated(address(f), msg.sender);
        return address(f);
    }

    function checkAndRecordCooldown(address user) external {
        require(isValidFund[msg.sender], "!fund");
        require(
            block.timestamp >= lastContributionTime[user] + GLOBAL_COOLDOWN,
            "!cd"
        );
        lastContributionTime[user] = block.timestamp;
    }

    function projectCount() external view returns (uint256) {
        return allDeployedProjects.length;
    }
}
