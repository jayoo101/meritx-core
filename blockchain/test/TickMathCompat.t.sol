// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";

/// @title MeritX sqrtPrice <-> TickMath Compatibility Test
contract TickMathCompatTest is Test {

    uint256 constant LP_POOL = 19_950_000e18;
    uint256 constant PLATFORM_FEE_PCT = 5;

    function _sqrtPrice(uint256 a0, uint256 a1) internal pure returns (uint160) {
        uint256 sqrtA0 = Math.sqrt(a0);
        uint256 sqrtA1 = Math.sqrt(a1);
        require(sqrtA0 > 0, "sqrt(a0) zero");
        return uint160((sqrtA1 << 96) / sqrtA0);
    }

    // -------------------------------------------------------
    //  Deterministic: realistic raise amounts
    // -------------------------------------------------------

    function test_compat_tokenIsToken0() public pure {
        uint256 totalRaised = 15 ether;
        uint256 ethForPool = totalRaised - (totalRaised * PLATFORM_FEE_PCT) / 100;
        uint256 a0 = LP_POOL;      // token0 = projectToken
        uint256 a1 = ethForPool;    // token1 = WETH

        uint160 sqrtPrice = _sqrtPrice(a0, a1);
        _assertRoundtrip(sqrtPrice, "token0");
    }

    function test_compat_tokenIsToken1() public pure {
        uint256 totalRaised = 15 ether;
        uint256 ethForPool = totalRaised - (totalRaised * PLATFORM_FEE_PCT) / 100;
        uint256 a0 = ethForPool;    // token0 = WETH
        uint256 a1 = LP_POOL;      // token1 = projectToken

        uint160 sqrtPrice = _sqrtPrice(a0, a1);
        _assertRoundtrip(sqrtPrice, "token1");
    }

    function test_compat_softCap_token0() public pure {
        uint256 totalRaised = 0.01 ether; // testnet soft cap
        uint256 ethForPool = totalRaised - (totalRaised * PLATFORM_FEE_PCT) / 100;
        uint160 sqrtPrice = _sqrtPrice(LP_POOL, ethForPool);
        _assertRoundtrip(sqrtPrice, "softcap-t0");
    }

    function test_compat_softCap_token1() public pure {
        uint256 totalRaised = 0.01 ether;
        uint256 ethForPool = totalRaised - (totalRaised * PLATFORM_FEE_PCT) / 100;
        uint160 sqrtPrice = _sqrtPrice(ethForPool, LP_POOL);
        _assertRoundtrip(sqrtPrice, "softcap-t1");
    }

    function test_compat_largeRaise() public pure {
        uint256 totalRaised = 1000 ether;
        uint256 ethForPool = totalRaised - (totalRaised * PLATFORM_FEE_PCT) / 100;

        uint160 sp0 = _sqrtPrice(LP_POOL, ethForPool);
        _assertRoundtrip(sp0, "large-t0");

        uint160 sp1 = _sqrtPrice(ethForPool, LP_POOL);
        _assertRoundtrip(sp1, "large-t1");
    }

    // -------------------------------------------------------
    //  Fuzz: random a0, a1 in [1e6, 1e30]
    // -------------------------------------------------------

    function testFuzz_tickMathRoundtrip(uint256 a0, uint256 a1) public pure {
        a0 = bound(a0, 1e6, 1e30);
        a1 = bound(a1, 1e6, 1e30);

        uint256 sqrtA0 = Math.sqrt(a0);
        if (sqrtA0 == 0) return;

        uint256 raw = (Math.sqrt(a1) << 96) / sqrtA0;
        if (raw == 0 || raw > type(uint160).max) return;

        uint160 sqrtPrice = uint160(raw);

        if (sqrtPrice < TickMath.MIN_SQRT_RATIO || sqrtPrice >= TickMath.MAX_SQRT_RATIO) return;

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 sqrtBack = TickMath.getSqrtRatioAtTick(tick);

        // sqrtBack <= sqrtPrice by TickMath spec (greatest tick where ratio <= input)
        assertLe(sqrtBack, sqrtPrice, "fuzz: back <= original");

        // Precision: deviation < 0.01% (100 ppm)
        uint256 diff = uint256(sqrtPrice) - uint256(sqrtBack);
        uint256 ppm = (diff * 1_000_000) / uint256(sqrtPrice);
        assertLt(ppm, 100, "fuzz: roundtrip deviation >= 0.01%");
    }

    // -------------------------------------------------------
    //  Internal roundtrip helper
    // -------------------------------------------------------

    function _assertRoundtrip(uint160 sqrtPrice, string memory label) internal pure {
        console.log("---", label, "---");
        console.log("  sqrtPrice:", sqrtPrice);

        assertGe(sqrtPrice, TickMath.MIN_SQRT_RATIO, string.concat(label, ": >= MIN_SQRT"));
        assertLt(sqrtPrice, TickMath.MAX_SQRT_RATIO, string.concat(label, ": < MAX_SQRT"));

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 sqrtBack = TickMath.getSqrtRatioAtTick(tick);

        console.log("  tick     :", uint24(tick < 0 ? -tick : tick), tick < 0 ? "(neg)" : "(pos)");
        console.log("  sqrtBack :", sqrtBack);

        assertGe(tick, TickMath.MIN_TICK, string.concat(label, ": tick >= MIN"));
        assertLe(tick, TickMath.MAX_TICK, string.concat(label, ": tick <= MAX"));

        assertLe(sqrtBack, sqrtPrice, string.concat(label, ": back <= orig"));

        uint256 diff = uint256(sqrtPrice) - uint256(sqrtBack);
        uint256 ppm = sqrtPrice > 0 ? (diff * 1_000_000) / uint256(sqrtPrice) : 0;
        console.log("  ppm error:", ppm);
        assertLt(ppm, 100, string.concat(label, ": roundtrip > 0.01%"));

        if (tick < TickMath.MAX_TICK) {
            uint160 nextPrice = TickMath.getSqrtRatioAtTick(tick + 1);
            assertGt(nextPrice, sqrtPrice, string.concat(label, ": next tick > orig"));
        }
    }
}
