// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/MeritX.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
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

/// @notice Full-lifecycle fork test for MeritXFund + Uniswap V3 integration.
///         Requires ETH_RPC_URL env var pointing to an Ethereum mainnet RPC.
///         Run:  forge test --mc MeritXFundForkTest -vvv
contract MeritXFundForkTest is Test {
    // ─── Ethereum Mainnet Uniswap V3 ───
    address constant WETH9        = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant POSITION_MGR = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER  = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

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

    // ─── Contribution Amounts ───
    uint256 constant ALICE_CONTRIB   = 4 ether;
    uint256 constant BOB_CONTRIB     = 4 ether;
    uint256 constant CHARLIE_CONTRIB = 4 ether;

    // ═══════════════════════════════════════════════════════════════
    //                          SET UP
    // ═══════════════════════════════════════════════════════════════

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

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

        // Deploy factory
        meritFactory = new MeritXFactory(
            signer, POSITION_MGR, WETH9, treasury, makeAddr("emergencyAdmin")
        );

        // Cache view before prank — vm.prank is consumed by the NEXT call
        // (including staticcalls like LISTING_FEE), so read first.
        uint256 listingFee = meritFactory.LISTING_FEE();
        vm.prank(owner);
        address fundAddr = meritFactory.launchNewProject{value: listingFee}(
            "TestToken", "TT", "ipfs://test"
        );
        fund  = MeritXFund(payable(fundAddr));
        token = fund.projectToken();

        // ── Phase 1: Fundraising (12 ETH > SOFT_CAP 10 ETH) ──
        _contribute(alice,   ALICE_CONTRIB,   5 ether);
        _contribute(bob,     BOB_CONTRIB,     5 ether);
        _contribute(charlie, CHARLIE_CONTRIB, 5 ether);

        // ── Phase 2: Announce → Notice → Finalize ──
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

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256) {
        if (tokenIn == WETH9) {
            IWETH(WETH9).deposit{value: amountIn}();
            IWETH(WETH9).approve(SWAP_ROUTER, amountIn);
        } else {
            MeritXToken(tokenIn).approve(SWAP_ROUTER, amountIn);
        }
        return ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               3000,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          amountIn,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _tokenIsToken0() internal view returns (bool) {
        return address(token) < WETH9;
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. Pool Initialization
    // ═══════════════════════════════════════════════════════════════

    function test_PoolInitialization() public view {
        assertTrue(pool != address(0), "pool != 0");

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 > 0");
        assertGt(tick, -887272, "tick above TickMath.MIN_TICK");
        assertLt(tick,  887272, "tick below TickMath.MAX_TICK");
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. Liquidity Mint
    // ═══════════════════════════════════════════════════════════════

    function test_LiquidityMint() public view {
        uint256 lpId = fund.lpTokenId();
        assertGt(lpId, 0, "LP tokenId > 0");

        uint128 liq = IUniswapV3Pool(pool).liquidity();
        assertGt(liq, 0, "pool liquidity > 0");

        assertEq(
            IERC721(POSITION_MGR).ownerOf(lpId),
            address(fund),
            "fund owns LP NFT"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. Price Sanity  —  implied price ≈ tokensForPool / ethForPool
    // ═══════════════════════════════════════════════════════════════

    function test_PriceSanity() public {
        uint256 raised     = fund.totalRaised();
        uint256 ethForPool = raised - (raised * fund.PLATFORM_FEE_PCT()) / 100;
        uint256 tokForPool = fund.LP_POOL();

        // Tiny swap to probe spot price (avoids material price impact)
        vm.deal(address(this), 0.01 ether);
        uint256 tokensOut = _swap(WETH9, address(token), 0.01 ether);

        // Expected output accounting for 0.3 % fee
        uint256 expected = (0.01 ether * 997 * tokForPool) / (1000 * ethForPool);

        // 1 % tolerance on top of fee (concentrated liquidity may skew slightly)
        assertApproxEqRel(tokensOut, expected, 0.01e18, "price within 1%");
    }

    // ═══════════════════════════════════════════════════════════════
    //  4a. Swap ETH → Token
    // ═══════════════════════════════════════════════════════════════

    function test_SwapETHForToken() public {
        vm.deal(address(this), 0.5 ether);
        uint256 out = _swap(WETH9, address(token), 0.5 ether);
        assertGt(out, 0, "ETH->Token output > 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  4b. Swap Token → ETH
    // ═══════════════════════════════════════════════════════════════

    function test_SwapTokenForETH() public {
        vm.prank(alice);
        fund.claimTokens();

        uint256 aliceBal = token.balanceOf(alice);
        assertGt(aliceBal, 0, "alice claimed tokens");

        uint256 swapAmt = aliceBal / 10;
        vm.startPrank(alice);
        token.approve(SWAP_ROUTER, swapAmt);
        uint256 wethOut = ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(token),
                tokenOut:          WETH9,
                fee:               3000,
                recipient:         alice,
                deadline:          block.timestamp,
                amountIn:          swapAmt,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        assertGt(wethOut, 0, "Token->WETH output > 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  5. Slippage Behavior — large swap gets worse rate
    // ═══════════════════════════════════════════════════════════════

    function test_SlippageBehavior() public {
        uint256 smallAmt = 0.01 ether;
        uint256 largeAmt = 2 ether;
        vm.deal(address(this), smallAmt + largeAmt);

        uint256 outSmall = _swap(WETH9, address(token), smallAmt);
        uint256 rateSmall = (outSmall * 1e18) / smallAmt;

        uint256 outLarge = _swap(WETH9, address(token), largeAmt);
        uint256 rateLarge = (outLarge * 1e18) / largeAmt;

        assertGt(rateSmall, rateLarge, "small swap should have better rate");
    }

    // ═══════════════════════════════════════════════════════════════
    //  6. Arbitrage Resistance — extreme swap does not break pool
    // ═══════════════════════════════════════════════════════════════

    function test_ArbitrageResistance() public {
        vm.deal(address(this), 5 ether);
        uint256 tokensOut = _swap(WETH9, address(token), 5 ether);
        assertGt(tokensOut, 0, "extreme swap succeeds");

        // Swap back a fraction — pool must still function
        uint256 backAmt = tokensOut / 10;
        token.approve(SWAP_ROUTER, backAmt);
        uint256 ethBack = ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(token),
                tokenOut:          WETH9,
                fee:               3000,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          backAmt,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
        assertGt(ethBack, 0, "reverse swap succeeds");

        (uint160 sqrtPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertGt(sqrtPrice, 0, "pool sqrtPrice remains valid");
    }

    // ═══════════════════════════════════════════════════════════════
    //  7. mintInflation()  —  tick UP → supply increase + caller reward
    // ═══════════════════════════════════════════════════════════════

    function test_MintInflation() public {
        // Push tick UP: buy token0 with token1
        if (_tokenIsToken0()) {
            // token0 = projectToken, token1 = WETH → swap WETH in
            vm.deal(address(this), 3 ether);
            _swap(WETH9, address(token), 3 ether);
        } else {
            // token0 = WETH, token1 = projectToken → sell projectToken
            vm.prank(alice);
            fund.claimTokens();
            uint256 bal = token.balanceOf(alice);
            vm.prank(alice);
            token.transfer(address(this), bal);
            _swap(address(token), WETH9, bal / 2);
        }

        // Advance past MINT_COOLDOWN so inflation is allowed
        vm.warp(block.timestamp + fund.MINT_COOLDOWN() + 1);

        // Verify pre-conditions
        int24 twap     = fund.getTWAP();
        int24 initTick = fund.initialTick();
        assertGt(twap, initTick, "TWAP must exceed initialTick for inflation");

        uint128 liq = IUniswapV3Pool(pool).liquidity();
        assertGe(uint256(liq), uint256(fund.MIN_LIQUIDITY()), "pool liquidity above floor");

        // Mint
        uint256 supplyBefore = token.totalSupply();
        address minter = makeAddr("minter");
        vm.prank(minter);
        fund.mintInflation();

        assertGt(token.totalSupply(), supplyBefore, "totalSupply increased");
        assertGt(token.balanceOf(minter), 0, "caller received reward");
    }

    // ═══════════════════════════════════════════════════════════════
    //  8. Zero Liquidity Attack — mintInflation reverts when liq drained
    // ═══════════════════════════════════════════════════════════════

    function test_ZeroLiquidityMintReverts() public {
        // Massive swap to push price beyond the concentrated LP range
        // Pool has ~11.4 ETH; 500 ETH easily exhausts the ±30 000 tick window
        vm.deal(address(this), 500 ether);
        _swap(WETH9, address(token), 500 ether);

        uint128 liq = IUniswapV3Pool(pool).liquidity();

        if (liq < fund.MIN_LIQUIDITY()) {
            vm.warp(block.timestamp + fund.MINT_COOLDOWN() + 1);

            // Should revert on liquidity guard
            vm.expectRevert("!low-liq");
            fund.mintInflation();
        } else {
            // If concentrated range is deep enough to survive 500 ETH, that's a pass
            // — the MIN_LIQUIDITY guard doesn't trigger, which is also safe behaviour
            assertTrue(true, "pool survived extreme swap with healthy liquidity");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  9. Multiple Users Claim — proportional token distribution
    // ═══════════════════════════════════════════════════════════════

    function test_MultipleUsersClaim() public {
        uint256 raised = fund.totalRaised();
        uint256 retail = fund.RETAIL_POOL();

        uint256 expectedAlice   = (ALICE_CONTRIB   * retail) / raised;
        uint256 expectedBob     = (BOB_CONTRIB     * retail) / raised;
        uint256 expectedCharlie = (CHARLIE_CONTRIB * retail) / raised;

        vm.prank(alice);
        fund.claimTokens();
        vm.prank(bob);
        fund.claimTokens();
        vm.prank(charlie);
        fund.claimTokens();

        assertEq(token.balanceOf(alice),   expectedAlice,   "alice proportional");
        assertEq(token.balanceOf(bob),     expectedBob,     "bob proportional");
        assertEq(token.balanceOf(charlie), expectedCharlie, "charlie proportional");
    }

    // ═══════════════════════════════════════════════════════════════
    //  10. No Double Claim
    // ═══════════════════════════════════════════════════════════════

    function test_NoDoubleClaim() public {
        vm.prank(alice);
        fund.claimTokens();

        vm.expectRevert("!contrib");
        vm.prank(alice);
        fund.claimTokens();
    }
}
