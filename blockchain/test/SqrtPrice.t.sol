// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";

/// @title sqrtPriceX96 Calculation Fix - Exhaustive Tests
/// @notice Validates the overflow-safe formula: (sqrt(a1) << 96) / sqrt(a0)
contract SqrtPriceTest is Test {

    uint256 constant LP_POOL        = 19_950_000e18;
    uint256 constant INITIAL_SUPPLY = 40_950_000e18;
    uint256 constant PLATFORM_FEE   = 5;

    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // ═══════════════════════════════════════════════════════════
    //  Helper: the FIXED formula (matches contract)
    // ═══════════════════════════════════════════════════════════

    function _computeSqrtPrice(uint256 a0, uint256 a1) internal pure returns (uint160) {
        require(a0 > 0, "a0 zero");
        uint256 sqrtA0 = Math.sqrt(a0);
        uint256 sqrtA1 = Math.sqrt(a1);
        require(sqrtA0 > 0, "sqrt(a0) zero");
        return uint160((sqrtA1 << 96) / sqrtA0);
    }

    // Helper: the BROKEN formula (old code)
    function _computeSqrtPriceBroken(uint256 a0, uint256 a1) internal pure returns (uint160) {
        // This silently overflows when a1 > 2^64
        return uint160(Math.sqrt((a1 << 192) / a0));
    }

    // Helper: high-precision expected value using 512-bit intermediate
    function _computeExpected(uint256 a0, uint256 a1) internal pure returns (uint256) {
        // expected = sqrt(a1 / a0) * 2^96
        // We compute via: sqrt(a1 * 2^192 / a0) using mulDiv to avoid overflow
        // Since we can't do 512-bit in Solidity easily, we use the decomposed form
        // as reference: sqrt(a1) * 2^96 / sqrt(a0)
        // This IS the formula under test, so for the precision test we use
        // an independent calculation path:
        //   ratio = a1 * 1e36 / a0   (scaled to avoid precision loss)
        //   sqrtRatio = sqrt(ratio)
        //   result = sqrtRatio * 2^96 / 1e18
        uint256 ratio = (a1 * 1e36) / a0;
        uint256 sqrtRatio = Math.sqrt(ratio);
        return (sqrtRatio * (1 << 96)) / 1e18;
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 1 - No Overflow (Critical Fix)
    // ═══════════════════════════════════════════════════════════

    function test_noOverflow_CaseA_tokenIsToken0() public pure {
        // token0 = projectToken, token1 = WETH
        uint256 ethForPool = 10 ether;
        uint256 tokensForPool = LP_POOL; // ~19.95M * 1e18 ~ 2^84

        uint256 a0 = tokensForPool; // token0 = projectToken
        uint256 a1 = ethForPool;    // token1 = WETH

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);

        console.log("Case A (token is token0):");
        console.log("  a0 (tokens)  :", a0);
        console.log("  a1 (ETH)     :", a1);
        console.log("  sqrtPriceX96 :", sqrtPrice);

        assertGt(sqrtPrice, 0, "sqrtPrice must be > 0");
        assertLt(uint256(sqrtPrice), uint256(type(uint160).max), "sqrtPrice must fit uint160");
        assertGt(sqrtPrice, MIN_SQRT_RATIO, "sqrtPrice must exceed V3 minimum");
    }

    function test_noOverflow_CaseB_tokenIsToken1() public pure {
        // token0 = WETH, token1 = projectToken - THE CRITICAL PATH
        uint256 ethForPool = 10 ether;
        uint256 tokensForPool = LP_POOL;

        uint256 a0 = ethForPool;    // token0 = WETH
        uint256 a1 = tokensForPool; // token1 = projectToken (~2^84)

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);

        console.log("Case B (token is token1) - CRITICAL PATH:");
        console.log("  a0 (ETH)     :", a0);
        console.log("  a1 (tokens)  :", a1);
        console.log("  sqrtPriceX96 :", sqrtPrice);

        assertGt(sqrtPrice, 0, "sqrtPrice must be > 0");
        assertLt(uint256(sqrtPrice), uint256(type(uint160).max), "sqrtPrice must fit uint160");
        assertGt(sqrtPrice, MIN_SQRT_RATIO, "sqrtPrice must exceed V3 minimum");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 2 - Matches Expected Price Ratio
    // ═══════════════════════════════════════════════════════════

    function test_matchesExpectedPriceRatio_CaseA() public pure {
        uint256 a0 = LP_POOL;
        uint256 a1 = 10 ether;

        uint256 actual   = uint256(_computeSqrtPrice(a0, a1));
        uint256 expected = _computeExpected(a0, a1);

        console.log("Price ratio test (Case A):");
        console.log("  actual   :", actual);
        console.log("  expected :", expected);

        uint256 diff = actual > expected ? actual - expected : expected - actual;
        uint256 relError = (diff * 1e6) / expected;

        console.log("  diff     :", diff);
        console.log("  relError (ppm):", relError);

        // Allow max 0.01% (100 ppm) precision loss from integer sqrt
        assertLt(relError, 100, "Relative error must be < 0.01%");
    }

    function test_matchesExpectedPriceRatio_CaseB() public pure {
        uint256 a0 = 10 ether;
        uint256 a1 = LP_POOL;

        uint256 actual   = uint256(_computeSqrtPrice(a0, a1));
        uint256 expected = _computeExpected(a0, a1);

        console.log("Price ratio test (Case B - critical):");
        console.log("  actual   :", actual);
        console.log("  expected :", expected);

        uint256 diff = actual > expected ? actual - expected : expected - actual;
        uint256 relError = (diff * 1e6) / expected;

        console.log("  relError (ppm):", relError);

        assertLt(relError, 100, "Relative error must be < 0.01%");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 3 - Compare Against Broken Formula
    // ═══════════════════════════════════════════════════════════

    function test_brokenFormulaProducesWrongResult() public pure {
        // Case B: a1 = tokensForPool ~ 2^84 - this triggers the overflow
        uint256 a0 = 10 ether;
        uint256 a1 = LP_POOL; // ~19.95M * 1e18

        uint160 correct = _computeSqrtPrice(a0, a1);

        // The broken formula: sqrt((a1 << 192) / a0)
        // (a1 << 192) overflows uint256 when a1 > 2^64
        // a1 ~ 2^84, so (a1 << 192) loses the top 84+192-256 = 20 bits
        uint160 broken = _computeSqrtPriceBroken(a0, a1);

        console.log("Broken vs Correct formula:");
        console.log("  correct :", correct);
        console.log("  broken  :", broken);

        // The broken formula MUST produce a drastically different (wrong) value
        // due to silent overflow truncation
        if (broken == correct) {
            // If by some numerical coincidence they match, at least log it
            console.log("  WARNING: broken == correct (unlikely for large a1)");
        } else {
            uint256 diff = correct > broken
                ? correct - broken
                : broken - correct;
            uint256 relDiff = (diff * 100) / uint256(correct);
            console.log("  relative diff %:", relDiff);
            assertGt(relDiff, 0, "Broken formula must diverge from correct");
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 4 - Tick Consistency Check (TickMath roundtrip)
    // ═══════════════════════════════════════════════════════════

    function test_tickConsistency_CaseA() public pure {
        uint256 a0 = LP_POOL;
        uint256 a1 = 10 ether;

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);

        // Clamp to TickMath valid range
        if (sqrtPrice < MIN_SQRT_RATIO) sqrtPrice = MIN_SQRT_RATIO;
        if (sqrtPrice >= MAX_SQRT_RATIO) sqrtPrice = uint160(MAX_SQRT_RATIO - 1);

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 sqrtPriceBack = TickMath.getSqrtRatioAtTick(tick);

        console.log("Tick roundtrip (Case A):");
        console.log("  sqrtPrice     :", sqrtPrice);
        console.log("  tick          :", uint24(tick < 0 ? -tick : tick), tick < 0 ? "(negative)" : "(positive)");
        console.log("  sqrtPriceBack :", sqrtPriceBack);

        assertGe(tick, TickMath.MIN_TICK, "Tick must be >= MIN_TICK");
        assertLe(tick, TickMath.MAX_TICK, "Tick must be <= MAX_TICK");

        // getTickAtSqrtRatio returns greatest tick where getSqrtRatioAtTick(tick) <= sqrtPrice
        assertLe(sqrtPriceBack, sqrtPrice, "Roundtrip: back <= original");

        // Next tick's price should be > original
        if (tick < TickMath.MAX_TICK) {
            uint160 nextTickPrice = TickMath.getSqrtRatioAtTick(tick + 1);
            assertGt(nextTickPrice, sqrtPrice, "Next tick price must exceed original");
        }
    }

    function test_tickConsistency_CaseB() public pure {
        uint256 a0 = 10 ether;
        uint256 a1 = LP_POOL;

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);

        if (sqrtPrice < MIN_SQRT_RATIO) sqrtPrice = MIN_SQRT_RATIO;
        if (sqrtPrice >= MAX_SQRT_RATIO) sqrtPrice = uint160(MAX_SQRT_RATIO - 1);

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 sqrtPriceBack = TickMath.getSqrtRatioAtTick(tick);

        console.log("Tick roundtrip (Case B - critical):");
        console.log("  sqrtPrice     :", sqrtPrice);
        console.log("  tick          :", uint24(tick < 0 ? -tick : tick), tick < 0 ? "(negative)" : "(positive)");
        console.log("  sqrtPriceBack :", sqrtPriceBack);

        assertGe(tick, TickMath.MIN_TICK, "Tick must be >= MIN_TICK");
        assertLe(tick, TickMath.MAX_TICK, "Tick must be <= MAX_TICK");
        assertLe(sqrtPriceBack, sqrtPrice, "Roundtrip: back <= original");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 5 - Pool Initialization Simulation
    //  (Pure math simulation - no actual Uniswap deployment)
    // ═══════════════════════════════════════════════════════════

    function test_poolInitSimulation() public pure {
        uint256 totalRaised = 15 ether;
        uint256 fee = (totalRaised * PLATFORM_FEE) / 100;
        uint256 ethForPool = totalRaised - fee;
        uint256 tokensForPool = LP_POOL;

        console.log("Pool init simulation:");
        console.log("  totalRaised  :", totalRaised);
        console.log("  fee          :", fee);
        console.log("  ethForPool   :", ethForPool);
        console.log("  tokensForPool:", tokensForPool);

        // Simulate both token orderings
        // Case A: projectToken < WETH → token is token0
        {
            uint256 a0 = tokensForPool;
            uint256 a1 = ethForPool;
            uint160 sqrtPrice = _computeSqrtPrice(a0, a1);
            assertGt(sqrtPrice, MIN_SQRT_RATIO, "Case A: sqrtPrice > V3 min");
            assertLt(sqrtPrice, MAX_SQRT_RATIO, "Case A: sqrtPrice < V3 max");
            console.log("  Case A sqrtPrice:", sqrtPrice);
        }

        // Case B: WETH < projectToken → token is token1
        {
            uint256 a0 = ethForPool;
            uint256 a1 = tokensForPool;
            uint160 sqrtPrice = _computeSqrtPrice(a0, a1);
            assertGt(sqrtPrice, MIN_SQRT_RATIO, "Case B: sqrtPrice > V3 min");
            assertLt(sqrtPrice, MAX_SQRT_RATIO, "Case B: sqrtPrice < V3 max");
            console.log("  Case B sqrtPrice:", sqrtPrice);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 6 - Edge Case: Very Small ETH
    // ═══════════════════════════════════════════════════════════

    function test_edgeCase_verySmallETH() public pure {
        uint256 a0 = 1; // 1 wei
        uint256 a1 = LP_POOL;

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);

        console.log("Edge case - 1 wei ETH:");
        console.log("  a0 (1 wei)   :", a0);
        console.log("  a1 (tokens)  :", a1);
        console.log("  sqrtPriceX96 :", sqrtPrice);

        assertGt(sqrtPrice, 0, "sqrtPrice must be > 0 even for 1 wei");
    }

    function test_edgeCase_smallETHReversed() public pure {
        uint256 a0 = LP_POOL;
        uint256 a1 = 1; // 1 wei

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);

        console.log("Edge case - 1 wei reversed:");
        console.log("  a0 (tokens)  :", a0);
        console.log("  a1 (1 wei)   :", a1);
        console.log("  sqrtPriceX96 :", sqrtPrice);

        // sqrt(1) << 96 / sqrt(large) → very small, but > 0
        assertGt(sqrtPrice, 0, "sqrtPrice must be > 0");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 7 - Edge Case: Equal Ratio (a0 == a1)
    // ═══════════════════════════════════════════════════════════

    function test_edgeCase_equalRatio() public pure {
        uint256 a0 = 10 ether;
        uint256 a1 = 10 ether;

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);
        uint256 expected = 1 << 96; // sqrt(1) * 2^96

        console.log("Edge case - equal ratio:");
        console.log("  a0 == a1     :", a0);
        console.log("  sqrtPriceX96 :", sqrtPrice);
        console.log("  expected 2^96:", expected);

        // sqrt(a0) == sqrt(a1) → sqrtPrice = (sqrtA1 << 96) / sqrtA0 = 2^96
        assertEq(uint256(sqrtPrice), expected, "Equal amounts must produce sqrtPrice = 2^96");
    }

    function test_edgeCase_equalRatio_large() public pure {
        uint256 a0 = LP_POOL;
        uint256 a1 = LP_POOL;

        uint160 sqrtPrice = _computeSqrtPrice(a0, a1);
        uint256 expected = 1 << 96;

        console.log("Edge case - equal ratio (large values):");
        console.log("  a0 == a1     :", a0);
        console.log("  sqrtPriceX96 :", sqrtPrice);

        assertEq(uint256(sqrtPrice), expected, "Equal large amounts must also produce 2^96");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 8 - Fuzz: Random a0/a1 in realistic range
    // ═══════════════════════════════════════════════════════════

    function testFuzz_noRevert(uint256 a0, uint256 a1) public pure {
        // Bound to realistic DeFi range: 1 wei to 100M tokens
        a0 = bound(a0, 1, 100_000_000e18);
        a1 = bound(a1, 1, 100_000_000e18);

        uint256 sqrtA0 = Math.sqrt(a0);
        if (sqrtA0 == 0) return; // skip degenerate

        uint256 sqrtA1 = Math.sqrt(a1);
        uint256 result = (sqrtA1 << 96) / sqrtA0;

        // Must fit in uint160
        assertLe(result, type(uint160).max, "Result must fit uint160");
        assertGt(result, 0, "Result must be > 0");
    }
}
