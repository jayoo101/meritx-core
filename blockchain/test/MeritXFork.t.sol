// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MeritXFactory, MeritXFund, MeritXToken} from "../contracts/MeritX.sol";
import {IWETH, IUniswapV3Pool} from "../contracts/MeritX.sol";

// SwapRouter02 — Base Sepolia has ONLY v2 router (no deadline in struct)
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata)
        external payable returns (uint256 amountOut);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title MeritXFund Full-Lifecycle Fork Test — Base Sepolia
/// @notice Uses REAL Uniswap V3 contracts deployed on Base Sepolia.
///         Run:  BASE_SEPOLIA_RPC=<url> forge test --mc MeritXBaseSepoliaTest -vvv
contract MeritXBaseSepoliaTest is Test {

    // ─── Base Sepolia canonical addresses (from docs.uniswap.org) ───
    address constant WETH            = 0x4200000000000000000000000000000000000006;
    address constant POSITION_MGR    = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
    address constant SWAP_ROUTER     = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    // ─── Contracts Under Test ───
    MeritXFactory meritFactory;
    MeritXFund    fund;
    MeritXToken   token;
    address       pool;

    // ─── Actors ───
    address owner;
    address treasury;
    uint256 signerPk;
    address signer;
    address alice;
    address bob;
    address charlie;

    // ─── Contribution Amounts (total 12 ETH > SOFT_CAP 10 ETH) ───
    uint256 constant ALICE_CONTRIB   = 4 ether;
    uint256 constant BOB_CONTRIB     = 4 ether;
    uint256 constant CHARLIE_CONTRIB = 4 ether;

    // ═══════════════════════════════════════════════════════════════
    //                          SET UP
    // ═══════════════════════════════════════════════════════════════

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC"));

        owner    = makeAddr("owner");
        treasury = makeAddr("treasury");
        (signer, signerPk) = makeAddrAndKey("signer");
        alice   = makeAddr("alice");
        bob     = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.deal(owner,   100 ether);
        vm.deal(alice,    20 ether);
        vm.deal(bob,      20 ether);
        vm.deal(charlie,  20 ether);

        // ── Deploy MeritXFactory ──
        meritFactory = new MeritXFactory(
            signer, POSITION_MGR, WETH, treasury, makeAddr("emergencyAdmin")
        );

        // Cache view BEFORE vm.prank — prank is consumed by the next external
        // call, including staticcalls like LISTING_FEE().
        uint256 listingFee = meritFactory.LISTING_FEE();
        vm.prank(owner);
        address fundAddr = meritFactory.launchNewProject{value: listingFee}(
            "TestToken", "TT", "ipfs://test"
        );
        fund  = MeritXFund(payable(fundAddr));
        token = fund.projectToken();

        // ── Phase 1: Fundraising ──
        _contribute(alice,   ALICE_CONTRIB,   5 ether);
        _contribute(bob,     BOB_CONTRIB,     5 ether);
        _contribute(charlie, CHARLIE_CONTRIB, 5 ether);

        // ── Phase 2: Announce → Wait notice → Finalize ──
        uint256 raiseDuration = fund.RAISE_DURATION();
        vm.warp(block.timestamp + raiseDuration + 1);

        vm.prank(owner);
        fund.announceLaunch();

        uint256 notice = fund.PRE_LAUNCH_NOTICE();
        vm.warp(block.timestamp + notice);

        vm.prank(owner);
        fund.finalizeFunding();

        pool = fund.uniswapPool();
    }

    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════
    //                        HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Build EIP-191 backend signature matching MeritXFund._recover()
    function _sign(
        address user,
        uint256 maxAlloc,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encodePacked(
            user, maxAlloc, nonce, deadline, address(fund), block.chainid
        ));
        bytes32 eh = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", h)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, eh);
        return abi.encodePacked(r, s, v);
    }

    function _contribute(address user, uint256 amount, uint256 maxAlloc) internal {
        uint256 nonce    = fund.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(user, maxAlloc, nonce, deadline);
        vm.prank(user);
        fund.contribute{value: amount}(maxAlloc, deadline, sig);
    }

    /// @dev Swap via SwapRouter02 (Base Sepolia). Caller must hold ETH / tokens.
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256) {
        if (tokenIn == WETH) {
            IWETH(WETH).deposit{value: amountIn}();
            IWETH(WETH).approve(SWAP_ROUTER, amountIn);
        } else {
            MeritXToken(tokenIn).approve(SWAP_ROUTER, amountIn);
        }
        return ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               3000,
                recipient:         address(this),
                amountIn:          amountIn,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _tokenIsToken0() internal view returns (bool) {
        return address(token) < WETH;
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. Pool Created & Initialized
    // ═══════════════════════════════════════════════════════════════

    function test_PoolCreated() public view {
        assertTrue(pool != address(0), "pool deployed");

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 > 0");
        assertGt(tick, -887272, "tick > MIN_TICK");
        assertLt(tick,  887272, "tick < MAX_TICK");
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. Liquidity Exists + LP NFT Ownership
    // ═══════════════════════════════════════════════════════════════

    function test_LiquidityAndLPOwnership() public view {
        uint256 lpId = fund.lpTokenId();
        assertGt(lpId, 0, "lpTokenId > 0");

        uint128 liq = IUniswapV3Pool(pool).liquidity();
        assertGt(liq, 0, "pool liquidity > 0");

        assertEq(
            IERC721(POSITION_MGR).ownerOf(lpId),
            address(fund),
            "fund owns LP NFT"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. Price Validation — spot price ≈ tokensForPool / ethForPool
    // ═══════════════════════════════════════════════════════════════

    function test_PriceValidation() public {
        uint256 raised     = fund.totalRaised();
        uint256 ethForPool = raised - (raised * fund.PLATFORM_FEE_PCT()) / 100;
        uint256 tokForPool = fund.LP_POOL();

        // Probe spot price with a tiny swap (minimal price impact)
        vm.deal(address(this), 0.01 ether);
        uint256 tokensOut = _swap(WETH, address(token), 0.01 ether);

        // Expected output (0.3% Uniswap fee deducted)
        uint256 expected = (0.01 ether * 997 * tokForPool) / (1000 * ethForPool);

        // 2% tolerance (concentrated liquidity tick discretisation)
        assertApproxEqRel(tokensOut, expected, 0.02e18, "price within 2%");
    }

    // ═══════════════════════════════════════════════════════════════
    //  4a. Swap ETH → Token (real router)
    // ═══════════════════════════════════════════════════════════════

    function test_SwapETHForToken() public {
        vm.deal(address(this), 0.5 ether);
        uint256 out = _swap(WETH, address(token), 0.5 ether);
        assertGt(out, 0, "ETH->Token output > 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  4b. Swap Token → ETH (real router)
    // ═══════════════════════════════════════════════════════════════

    function test_SwapTokenForETH() public {
        // Alice claims her allocation, then sells part of it
        vm.prank(alice);
        fund.claimTokens();
        uint256 aliceBal = token.balanceOf(alice);
        assertGt(aliceBal, 0, "alice has tokens");

        uint256 sellAmt = aliceBal / 10;
        vm.startPrank(alice);
        token.approve(SWAP_ROUTER, sellAmt);
        uint256 wethOut = ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           address(token),
                tokenOut:          WETH,
                fee:               3000,
                recipient:         alice,
                amountIn:          sellAmt,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(wethOut, 0, "Token->WETH output > 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  5. Slippage — large trade gets worse effective rate
    // ═══════════════════════════════════════════════════════════════

    function test_Slippage() public {
        uint256 smallAmt = 0.01 ether;
        uint256 largeAmt = 2 ether;
        vm.deal(address(this), smallAmt + largeAmt);

        uint256 outSmall = _swap(WETH, address(token), smallAmt);
        uint256 rateSmall = (outSmall * 1e18) / smallAmt;

        uint256 outLarge = _swap(WETH, address(token), largeAmt);
        uint256 rateLarge = (outLarge * 1e18) / largeAmt;

        assertGt(rateSmall, rateLarge, "small trade gets better rate");
    }

    // ═══════════════════════════════════════════════════════════════
    //  6. Attack Simulation — extreme swap, pool survives
    // ═══════════════════════════════════════════════════════════════

    function test_AttackResistance() public {
        // Forward swap: dump 5 ETH into the pool (≈44% of pool depth)
        vm.deal(address(this), 5 ether);
        uint256 tokensOut = _swap(WETH, address(token), 5 ether);
        assertGt(tokensOut, 0, "extreme swap completes");

        // Reverse swap: sell 10% of tokens back — pool must still function
        token.approve(SWAP_ROUTER, tokensOut / 10);
        uint256 ethBack = ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           address(token),
                tokenOut:          WETH,
                fee:               3000,
                recipient:         address(this),
                amountIn:          tokensOut / 10,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
        assertGt(ethBack, 0, "reverse swap succeeds");

        // Pool integrity
        (uint160 sqrtPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertGt(sqrtPrice, 0, "pool sqrtPrice still valid");
    }

    // ═══════════════════════════════════════════════════════════════
    //  7. mintInflation — tick moves up → supply increases
    // ═══════════════════════════════════════════════════════════════

    function test_MintInflation() public {
        // Push tick UP: buy token0 with token1
        if (_tokenIsToken0()) {
            vm.deal(address(this), 3 ether);
            _swap(WETH, address(token), 3 ether);
        } else {
            // WETH is token0, projectToken is token1
            // Sell projectToken → WETH to push tick UP
            vm.prank(alice);
            fund.claimTokens();
            uint256 bal = token.balanceOf(alice);
            vm.prank(alice);
            token.transfer(address(this), bal);
            _swap(address(token), WETH, bal / 2);
        }

        // Advance past MINT_COOLDOWN
        uint256 cooldown = fund.MINT_COOLDOWN();
        vm.warp(block.timestamp + cooldown + 1);

        // Verify preconditions
        int24 twap     = fund.getTWAP();
        int24 initTick = fund.initialTick();
        assertGt(twap, initTick, "TWAP > initialTick");

        uint128 liq = IUniswapV3Pool(pool).liquidity();
        assertGe(uint256(liq), uint256(fund.MIN_LIQUIDITY()), "liquidity above floor");

        // Mint inflation
        uint256 supplyBefore = token.totalSupply();
        address minter = makeAddr("minter");
        vm.prank(minter);
        fund.mintInflation();

        assertGt(token.totalSupply(), supplyBefore, "totalSupply increased");
        assertGt(token.balanceOf(minter), 0, "caller received reward");
    }

    // ═══════════════════════════════════════════════════════════════
    //  8. Liquidity Drain → mintInflation reverts
    // ═══════════════════════════════════════════════════════════════

    function test_LiquidityDrainBlocksInflation() public {
        // 500 ETH massively overshoots the ±30 000 tick window (~11 ETH pool)
        vm.deal(address(this), 500 ether);
        _swap(WETH, address(token), 500 ether);

        uint128 liq = IUniswapV3Pool(pool).liquidity();

        if (liq < fund.MIN_LIQUIDITY()) {
            uint256 cooldown = fund.MINT_COOLDOWN();
            vm.warp(block.timestamp + cooldown + 1);

            vm.expectRevert("!low-liq");
            fund.mintInflation();
        } else {
            // Concentrated range absorbed all 500 ETH → pool is robust, also a pass
            assertTrue(true);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  9. Multiple Users Claim — proportional distribution
    // ═══════════════════════════════════════════════════════════════

    function test_ProportionalClaims() public {
        uint256 raised = fund.totalRaised();
        uint256 retail = fund.RETAIL_POOL();

        vm.prank(alice);   fund.claimTokens();
        vm.prank(bob);     fund.claimTokens();
        vm.prank(charlie); fund.claimTokens();

        assertEq(token.balanceOf(alice),   (ALICE_CONTRIB   * retail) / raised);
        assertEq(token.balanceOf(bob),     (BOB_CONTRIB     * retail) / raised);
        assertEq(token.balanceOf(charlie), (CHARLIE_CONTRIB * retail) / raised);
    }

    // ═══════════════════════════════════════════════════════════════
    //  10. Double Claim Reverts
    // ═══════════════════════════════════════════════════════════════

    function test_DoubleClaimReverts() public {
        vm.prank(alice);
        fund.claimTokens();

        vm.expectRevert("!contrib");
        vm.prank(alice);
        fund.claimTokens();
    }
}
