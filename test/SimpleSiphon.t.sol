// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SimpleSiphon} from "../src/example/SimpleSiphon.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {IScheduleListener} from "../src/interfaces/IScheduleListener.sol";
import {Test} from "forge-std/Test.sol";

// ═══════════════════════════════════════════════════════════════════════════════
// Mock listener that records callbacks
// ═══════════════════════════════════════════════════════════════════════════════

contract MockListener is IScheduleListener {
    struct Call {
        address token;
        address user;
        bool active;
    }

    Call[] public calls;

    function onScheduleUpdate(address token, address user, bool active) external {
        calls.push(Call(token, user, active));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SiphonToken Test Suite
//
// Comprehensive tests covering all user paths including prepay/autopay mixed
// scenarios. Organized by: basic ops, schedule lifecycle, skip periods,
// mixed prepay/autopay, spend+schedule interaction, edge cases, fuzz.
//
// STATE LEGEND:
//   EMPTY       = no balance, no schedule
//   FUNDED      = has balance, no schedule
//   ACTIVE      = schedule active, in billable zone
//   ACTIVE_SKIP = schedule active, in skip (prepaid) zone
//   CANCELED    = schedule canceled, in final period
//   LAPSED      = schedule expired (funds ran out)
//   SETTLED     = schedule cleared after lapse/cancel
// ═══════════════════════════════════════════════════════════════════════════════

contract SimpleSiphonTest is Test {
    SimpleSiphon public token;
    MockListener public listener;

    address public owner = makeAddr("owner");
    address public sched = makeAddr("scheduler");
    address public spndr = makeAddr("spender");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint128 public constant RATE = 3000 ether;
    uint32 public constant PERIOD = 30;
    uint256 public constant DAY = 86_400;

    function setUp() public {
        _warpToDay(1000);

        token = new SimpleSiphon(owner);
        listener = new MockListener();

        vm.startPrank(owner);
        token.setScheduler(sched);
        token.setSpender(spndr);
        token.setListener(address(listener));
        vm.stopPrank();
    }

    // ── Helpers ──

    function _warpToDay(uint256 d) internal {
        vm.warp(d * DAY);
    }

    function _advanceDays(uint256 n) internal {
        vm.warp(block.timestamp + n * DAY);
    }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    function _schedule(address user, uint128 rate, uint32 period, uint16 maxP, uint16 skip) internal {
        vm.prank(sched);
        token.setSchedule(user, rate, period, maxP, skip);
    }

    function _cancel(address user) internal {
        vm.prank(sched);
        token.cancelSchedule(user);
    }

    function _clear(address user) internal {
        vm.prank(sched);
        token.clearSchedule(user);
    }

    function _skip(address user, uint16 periods) internal {
        vm.prank(sched);
        token.addSkipPeriods(user, periods);
    }

    function _spend(address user, uint128 amt) internal {
        vm.prank(spndr);
        token.spend(user, amt);
    }

    function _autoSchedule(address user) internal {
        _schedule(user, RATE, PERIOD, 0, 0);
    }

    function _fundAndSchedule(address user, uint256 ubiAmt) internal {
        _mint(user, uint128(ubiAmt));
        _autoSchedule(user);
    }

    // ═══════════════════════════════════════════════════════════════
    // ERC20 BASICS
    // ═══════════════════════════════════════════════════════════════

    function test_metadata() public {
        assertEq(token.name(), "SimpleSiphon");
        assertEq(token.symbol(), "SIPH");
        assertEq(token.decimals(), 18);
    }

    function test_nonTransferable() public {
        _mint(alice, RATE);
        vm.prank(alice);
        vm.expectRevert(SiphonToken.NonTransferable.selector);
        token.transfer(bob, RATE);
    }

    // ═══════════════════════════════════════════════════════════════
    // MINT + BALANCE
    // ═══════════════════════════════════════════════════════════════

    function test_mint_balance() public {
        _mint(alice, 5000 ether);
        assertEq(token.balanceOf(alice), 5000 ether);
        assertEq(token.totalSupply(), 5000 ether);
        assertEq(token.totalMinted(), 5000 ether);
    }

    function test_mint_stacks() public {
        _mint(alice, 3000 ether);
        _mint(alice, 2000 ether);
        assertEq(token.balanceOf(alice), 5000 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    // SCHEDULE — BASIC AUTOPAY
    // ═══════════════════════════════════════════════════════════════

    function test_autopay_basic() public {
        _fundAndSchedule(alice, RATE * 3);
        assertTrue(token.isActive(alice));
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);
    }

    function test_autopay_balanceDecays() public {
        _fundAndSchedule(alice, RATE * 3);
        assertEq(token.balanceOf(alice), RATE * 2); // period 1 consumed

        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE); // period 2

        _advanceDays(30);
        assertEq(token.balanceOf(alice), 0); // period 3
    }

    function test_autopay_depositExtends() public {
        _fundAndSchedule(alice, RATE);
        assertEq(token.expiry(alice), 1030);

        _mint(alice, RATE * 2);
        assertEq(token.expiry(alice), 1090);
    }

    function test_autopay_lapse() public {
        _fundAndSchedule(alice, RATE);
        _advanceDays(31);
        assertTrue(token.isLapsed(alice));
        assertFalse(token.isActive(alice));
    }

    function test_autopay_cancel() public {
        _fundAndSchedule(alice, RATE * 3);
        _advanceDays(5);
        _cancel(alice);

        assertTrue(token.isCanceled(alice));
        assertFalse(token.isActive(alice));
        assertEq(token.consumed(alice), RATE); // frozen at period 1
    }

    function test_autopay_settleAfterLapse() public {
        _fundAndSchedule(alice, RATE * 2);
        _advanceDays(61); // lapsed

        _mint(alice, RATE);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(principal, RATE); // old consumed deducted, new added
        assertEq(rate, 0); // schedule cleared
    }

    function test_autopay_settleAfterCancel() public {
        _fundAndSchedule(alice, RATE * 3);
        _cancel(alice);
        _advanceDays(31);

        _mint(alice, RATE);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(principal, RATE * 2 + RATE); // 3 - 1 consumed + 1 new
        assertEq(rate, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // SCHEDULE — PURE PREPAY (skip only, no autopay funding)
    // ═══════════════════════════════════════════════════════════════

    function test_prepay_pureSkip() public {
        _mint(alice, 1); // minimal balance, schedule with skip
        _schedule(alice, RATE, PERIOD, 0, 3);

        assertTrue(token.isActive(alice));
        assertTrue(token.isInSkipZone(alice));
        assertEq(token.consumed(alice), 0);
        assertEq(token.balanceOf(alice), 1);

        // Expiry: skip(3) + funded(1/3000e18 = 0) = 3 periods
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD); // 1090

        // During skip: still active
        _advanceDays(60);
        assertTrue(token.isActive(alice));
        assertTrue(token.isInSkipZone(alice));

        // After 3 periods: lapsed (no funded periods after skip)
        _warpToDay(1091);
        assertTrue(token.isLapsed(alice));
    }

    function test_prepay_skipThenAutopay() public {
        // 3 months prepaid + 2 months funded
        _mint(alice, RATE * 2);
        _schedule(alice, RATE, PERIOD, 0, 3);

        // Expiry: 3 skip + 2 funded = 5 periods
        assertEq(token.expiry(alice), 1000 + 5 * PERIOD); // 1150
        assertEq(token.consumed(alice), 0);

        // During skip: balance unchanged
        _advanceDays(60); // day 1060
        assertEq(token.balanceOf(alice), RATE * 2);
        assertTrue(token.isInSkipZone(alice));

        // Past skip: autopay kicks in. Period 4 (first billable) starts at day 1090.
        _warpToDay(1090);
        assertFalse(token.isInSkipZone(alice));
        assertEq(token.consumed(alice), RATE);
        assertEq(token.balanceOf(alice), RATE);

        // Period 5 starts at day 1120
        _warpToDay(1120);
        assertEq(token.consumed(alice), RATE * 2);
        assertEq(token.balanceOf(alice), 0);

        // Lapse at expiry (day 1150)
        _warpToDay(1150);
        assertTrue(token.isLapsed(alice));
    }

    // ═══════════════════════════════════════════════════════════════
    // MIXED: AUTOPAY -> ADD PREPAID MID-SCHEDULE
    // ═══════════════════════════════════════════════════════════════

    function test_mixed_addPrepayMidAutopay() public {
        // Alice on autopay with 3 months funded
        _fundAndSchedule(alice, RATE * 3);
        assertEq(token.expiry(alice), 1090);

        // Day 1015: buy 3 months prepaid
        _advanceDays(15);
        _skip(alice, 3);

        // Checkpoint: consumed period 1 (RATE), principal = 3*RATE - RATE = 2*RATE
        // Restart: startedAt=1015, skip=3, funded=2
        assertEq(token.consumed(alice), 0); // in skip zone
        assertEq(token.balanceOf(alice), RATE * 2);

        // Skip zone: 3 periods from day 1015 = days 1015-1105
        _warpToDay(1030);
        assertTrue(token.isInSkipZone(alice));
        assertEq(token.balanceOf(alice), RATE * 2);

        _warpToDay(1090);
        assertTrue(token.isInSkipZone(alice));

        // Day 1105: period 4 from restart, first billable (past 3 skip periods)
        // periodsStarted = ((1105-1015)/30)+1 = 4, skip=3, billable=1
        _warpToDay(1105);
        assertFalse(token.isInSkipZone(alice));
        assertEq(token.consumed(alice), RATE);
        assertEq(token.balanceOf(alice), RATE);

        // Day 1135: period 5, billable=2
        _warpToDay(1135);
        assertEq(token.consumed(alice), RATE * 2);
        assertEq(token.balanceOf(alice), 0);

        // Expiry = 1015 + (3+2)*30 = 1165. Lapse at 1165.
        _warpToDay(1165);
        assertTrue(token.isLapsed(alice));
    }

    function test_mixed_multiplePrepayAdditions() public {
        // Alice on autopay with 6 months funded
        _fundAndSchedule(alice, RATE * 6);

        // Day 1015: add 2 prepaid months
        _advanceDays(15);
        _skip(alice, 2);
        // Checkpoint: consumed=RATE, principal=5*RATE, skip=2, startedAt=1015
        assertEq(token.balanceOf(alice), RATE * 5);

        // Day 1045: add 1 more prepaid month
        _advanceDays(30);
        _skip(alice, 1);
        // Checkpoint: in skip zone, consumed=0, principal stays 5*RATE
        // skip=0+1=1 (old skip cleared by checkpoint, then +1)
        // Wait, checkpoint clears skipPeriods!
        // At day 1045, periodsStarted from 1015 = ((1045-1015)/30)+1 = 2, skip=2, billable=0, consumed=0
        // Checkpoint: consumed=0, principal stays. startedAt=1045. skip reset to 0.
        // Then addSkipPeriods: skip = 0+1 = 1.

        assertEq(token.balanceOf(alice), RATE * 5); // still no consumption
        assertTrue(token.isInSkipZone(alice));

        // Expiry: from day 1045, skip=1, funded=5. total=6 periods. 1045 + 180 = 1225.
        assertEq(token.expiry(alice), 1045 + 6 * PERIOD);
    }

    // ═══════════════════════════════════════════════════════════════
    // SPEND + SCHEDULE INTERACTION
    // ═══════════════════════════════════════════════════════════════

    function test_spend_reducesExpiry() public {
        _fundAndSchedule(alice, RATE * 3);
        assertEq(token.expiry(alice), 1090);

        _spend(alice, 1);
        // principal = 9000e18 - 1. funded = (9000e18-1)/3000e18 = 2. expiry = 1060.
        assertEq(token.expiry(alice), 1060);
    }

    function test_spend_duringSkipReducesPostSkipPeriods() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        // Skip=2, funded=3. Expiry = 1000 + 5*30 = 1150.
        assertEq(token.expiry(alice), 1150);

        // Spend 1 period's worth during skip zone
        _advanceDays(15);
        _spend(alice, RATE);

        // principal = 2*RATE. funded = 2. skip still 2.
        // Expiry = 1000 + (2+2)*30 = 1120. Lost 1 post-skip period.
        assertEq(token.expiry(alice), 1120);
        assertEq(token.balanceOf(alice), RATE * 2); // no siphon consumption yet
    }

    function test_spend_cannotExceedAvailableBalance() public {
        _fundAndSchedule(alice, RATE * 2);
        // balance = RATE (period 1 consumed)
        vm.prank(spndr);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.spend(alice, RATE + 1);
    }

    function test_spend_settlesStaleSchedule() public {
        _fundAndSchedule(alice, RATE + 500 ether);
        _advanceDays(PERIOD + 1); // lapsed

        _spend(alice, 200 ether);
        assertEq(token.balanceOf(alice), 300 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    // MAX PERIODS WITH SKIP
    // ═══════════════════════════════════════════════════════════════

    function test_maxPeriods_capsTotal() public {
        _mint(alice, RATE * 10);
        _schedule(alice, RATE, PERIOD, 6, 3);
        // maxPeriods=6 caps total. skip=3, funded capped at 6-3=3.
        assertEq(token.expiry(alice), 1000 + 6 * PERIOD);
    }

    function test_maxPrepaid_capsTotal() public {
        _mint(alice, RATE * 20);
        _schedule(alice, RATE, PERIOD, 0, 3);
        // MAX_PREPAID=12. skip=3, funded capped at 12-3=9.
        assertEq(token.expiry(alice), 1000 + 12 * PERIOD);
    }

    function test_maxPeriods_setByUser() public {
        _fundAndSchedule(alice, RATE * 6);
        assertEq(token.expiry(alice), 1000 + 6 * PERIOD);

        vm.prank(alice);
        token.setMaxPeriods(3);
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);

        vm.prank(alice);
        token.setMaxPeriods(0);
        assertEq(token.expiry(alice), 1000 + 6 * PERIOD);
    }

    // ═══════════════════════════════════════════════════════════════
    // CANCEL DURING SKIP
    // ═══════════════════════════════════════════════════════════════

    function test_cancel_duringSkip() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);

        _advanceDays(15); // mid skip period 1
        _cancel(alice);

        assertTrue(token.isCanceled(alice));
        assertEq(token.consumed(alice), 0); // in skip, nothing consumed
    }

    function test_cancel_duringSkip_settlePreservesBalance() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);

        _advanceDays(15);
        _cancel(alice);

        // Service end = current period boundary = day 1030
        _advanceDays(16); // day 1031, past service end

        token.settle(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(principal, RATE * 3); // nothing consumed during skip
        assertEq(rate, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // CLEAR SCHEDULE
    // ═══════════════════════════════════════════════════════════════

    function test_clear_immediateWipe() public {
        _fundAndSchedule(alice, RATE * 3);
        _advanceDays(5);

        _clear(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
        assertEq(principal, RATE * 2); // 1 period consumed
    }

    function test_clear_duringSkip() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        _advanceDays(15);

        _clear(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
        assertEq(principal, RATE * 3); // nothing consumed during skip
    }

    // ═══════════════════════════════════════════════════════════════
    // LISTENER CALLBACKS
    // ═══════════════════════════════════════════════════════════════

    function test_listener_setSchedule() public {
        _mint(alice, RATE);
        _autoSchedule(alice);
        assertEq(listener.callCount(), 1);
        (address t, address u, bool active) = listener.calls(0);
        assertEq(t, address(token));
        assertEq(u, alice);
        assertTrue(active);
    }

    function test_listener_settle() public {
        _fundAndSchedule(alice, RATE);
        _advanceDays(31);
        token.settle(alice);
        // setSchedule + settle = 2 calls
        assertEq(listener.callCount(), 2);
        (, , bool active) = listener.calls(1);
        assertFalse(active);
    }

    function test_listener_addSkip() public {
        _fundAndSchedule(alice, RATE * 3);
        _advanceDays(5);
        _skip(alice, 2);
        // setSchedule + addSkipPeriods = 2 calls
        assertEq(listener.callCount(), 2);
        (, , bool active) = listener.calls(1);
        assertTrue(active);
    }

    // ═══════════════════════════════════════════════════════════════
    // SCHEDULE REPLACEMENT (plan switch)
    // ═══════════════════════════════════════════════════════════════

    function test_scheduleReplace_checkpointsOld() public {
        _fundAndSchedule(alice, RATE * 3 + 5000 ether);
        _advanceDays(15);

        // Switch to different rate
        _schedule(alice, 5000 ether, PERIOD, 0, 0);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 5000 ether);
        // Old schedule checkpoint: consumed 1 period (RATE). principal = (RATE*3 + 5000) - RATE = RATE*2 + 5000.
        assertEq(principal, RATE * 2 + 5000 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    // FULL LIFECYCLE PATHS (Markov chains)
    // ═══════════════════════════════════════════════════════════════

    // Path: EMPTY -> FUNDED -> ACTIVE -> LAPSED -> FUNDED -> ACTIVE
    function test_path_basicRelapse() public {
        _mint(alice, RATE * 2);
        _autoSchedule(alice);
        _advanceDays(61);
        assertTrue(token.isLapsed(alice));

        _mint(alice, RATE * 3);
        assertFalse(token.isLapsed(alice));
        _autoSchedule(alice);
        assertTrue(token.isActive(alice));
    }

    // Path: FUNDED -> ACTIVE -> CANCELED -> SETTLED -> FUNDED -> ACTIVE
    function test_path_cancelAndReturn() public {
        _fundAndSchedule(alice, RATE * 3);
        _advanceDays(5);
        _cancel(alice);
        _advanceDays(26); // past period end

        _autoSchedule(alice); // settle + new schedule
        assertTrue(token.isActive(alice));
        assertEq(token.balanceOf(alice), RATE); // 3 - 1 settled - 1 new period = 1
    }

    // Path: FUNDED -> ACTIVE_SKIP -> ACTIVE_POST_SKIP -> LAPSED -> FUNDED -> ACTIVE
    function test_path_prepayThenAutoThenLapseReturn() public {
        _mint(alice, RATE * 2);
        _schedule(alice, RATE, PERIOD, 0, 3); // 3 skip + 2 funded
        // Expiry = 1000 + 5*30 = 1150

        // Skip zone
        _warpToDay(1080);
        assertTrue(token.isInSkipZone(alice));
        assertEq(token.balanceOf(alice), RATE * 2);

        // Post-skip: period 4 = first billable (day 1090)
        _warpToDay(1095);
        assertFalse(token.isInSkipZone(alice));
        assertEq(token.consumed(alice), RATE);

        // Lapse at expiry (day 1150)
        _warpToDay(1150);
        assertTrue(token.isLapsed(alice));

        // Return
        _mint(alice, RATE * 2);
        _autoSchedule(alice);
        assertTrue(token.isActive(alice));
    }

    // Path: ACTIVE -> addSkip -> ACTIVE_SKIP -> addSkip -> ACTIVE_SKIP -> POST_SKIP -> LAPSE
    function test_path_repeatedPrepay() public {
        _fundAndSchedule(alice, RATE * 4);
        assertEq(token.expiry(alice), 1000 + 4 * PERIOD);

        // Day 10: first prepay
        _advanceDays(10);
        _skip(alice, 2); // checkpoint @ day 1010, consumed RATE, principal=3*RATE, skip=2

        // Day 40: second prepay (still in skip zone from first)
        _advanceDays(30);
        _skip(alice, 1); // checkpoint @ day 1040, consumed=0 (in skip), skip cleared then +1

        // From day 1040: skip=1, principal=3*RATE, funded=3
        // Expiry = 1040 + (1+3)*30 = 1040 + 120 = 1160
        assertEq(token.expiry(alice), 1160);

        // Lapse check
        _warpToDay(1161);
        assertTrue(token.isLapsed(alice));
    }

    // Path: ACTIVE -> spend -> reduced expiry -> addSkip -> ACTIVE_SKIP
    function test_path_spendThenPrepay() public {
        _fundAndSchedule(alice, RATE * 4);
        assertEq(token.expiry(alice), 1000 + 4 * PERIOD);

        // Spend 1 period worth
        _spend(alice, RATE);
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD); // lost 1 period

        // Add 2 prepaid months
        _advanceDays(5);
        _skip(alice, 2);
        // Checkpoint: consumed=RATE, principal=3*RATE-RATE=2*RATE, skip=2
        assertEq(token.expiry(alice), 1005 + (2 + 2) * PERIOD);
    }

    // Path: ACTIVE_SKIP -> cancel -> CANCELED -> settle -> FUNDED
    function test_path_cancelDuringSkip() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);

        _advanceDays(15);
        _cancel(alice);

        // Past period end
        _advanceDays(16);
        assertFalse(token.isCanceled(alice));

        token.settle(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
        assertEq(principal, RATE * 3); // full balance preserved (skip = no consumption)
    }

    // Path: sponsor prepay 1 month -> user deposits + starts autopay mid-month
    function test_path_sponsorThenUserAutopay() public {
        // Sponsor gives alice 1 month prepaid (no UBI balance, just skip)
        _mint(alice, 1); // minimal
        _schedule(alice, RATE, PERIOD, 0, 1);

        assertTrue(token.isActive(alice));
        assertTrue(token.isInSkipZone(alice));

        // Day 1015: alice deposits and wants autopay after prepaid month
        _advanceDays(15);
        _mint(alice, RATE * 3); // now has 3 months worth + 1 wei

        // After skip month ends (day 1030), autopay should consume
        _advanceDays(15); // day 1030, period 2 starts (first billable)
        assertFalse(token.isInSkipZone(alice));
        assertEq(token.consumed(alice), RATE);
    }

    // ═══════════════════════════════════════════════════════════════
    // EDGE CASES
    // ═══════════════════════════════════════════════════════════════

    function test_edge_setScheduleInsufficientForNonSkip() public {
        _mint(alice, RATE - 1);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.setSchedule(alice, RATE, PERIOD, 0, 0);
    }

    function test_edge_setScheduleWithSkipNoBalance() public {
        // With skip > 0, we allow zero funded periods (pure prepay)
        _mint(alice, 1);
        _schedule(alice, RATE, PERIOD, 0, 3);
        assertTrue(token.isActive(alice));
    }

    function test_edge_cancelAlreadyCanceled() public {
        _fundAndSchedule(alice, RATE * 3);
        _cancel(alice);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.cancelSchedule(alice);
    }

    function test_edge_addSkipToCanceled() public {
        _fundAndSchedule(alice, RATE * 3);
        _cancel(alice);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.addSkipPeriods(alice, 2);
    }

    function test_edge_setMaxPeriodsNoSchedule() public {
        vm.prank(alice);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.setMaxPeriods(3);
    }

    function test_edge_settleNoOp() public {
        _mint(alice, RATE);
        token.settle(alice); // no schedule, should be no-op
        assertEq(token.balanceOf(alice), RATE);
    }

    function test_edge_publicSettle() public {
        _fundAndSchedule(alice, RATE);
        _advanceDays(31);

        // Anyone can call settle
        vm.prank(bob);
        token.settle(alice);

        (,uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // TRACKING
    // ═══════════════════════════════════════════════════════════════

    function test_tracking_siphoned() public {
        _fundAndSchedule(alice, RATE);
        _advanceDays(31);
        token.settle(alice);

        assertEq(token.totalSiphoned(), RATE);
        assertEq(token.totalSpent(), 0);
    }

    function test_tracking_spent() public {
        _mint(alice, RATE * 3);
        _spend(alice, RATE);
        assertEq(token.totalSpent(), RATE);
        assertEq(token.totalSiphoned(), 0);
    }

    function test_tracking_totalSupply() public {
        _mint(alice, RATE * 3);
        _autoSchedule(alice);
        _advanceDays(91);

        token.settle(alice);
        assertEq(token.totalSupply(), 0);
        assertEq(token.totalMinted(), RATE * 3);
        assertEq(token.totalSiphoned(), RATE * 3);
    }

    // ═══════════════════════════════════════════════════════════════
    // FUZZ
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_balanceNeverNegative(uint256 deposit_, uint256 days_) public {
        deposit_ = bound(deposit_, RATE, RATE * 6);
        days_ = bound(days_, 0, 365);

        _mint(alice, uint128(deposit_));
        _autoSchedule(alice);
        _advanceDays(days_);

        assertLe(token.consumed(alice), deposit_);
    }

    function testFuzz_skipPreservesBalance(uint16 skipP, uint256 days_) public {
        skipP = uint16(bound(skipP, 1, 6));
        days_ = bound(days_, 0, uint256(skipP) * PERIOD);

        _mint(alice, RATE);
        _schedule(alice, RATE, PERIOD, 0, skipP);
        _advanceDays(days_);

        // During skip zone, balance should be unchanged
        if (days_ < uint256(skipP) * PERIOD) {
            assertEq(token.balanceOf(alice), RATE);
        }
    }

    function testFuzz_lifecycle(
        uint256 deposit_,
        uint16 skipP,
        uint256 days1,
        uint256 days2,
        bool doCancel
    ) public {
        deposit_ = bound(deposit_, RATE, RATE * 6);
        skipP = uint16(bound(skipP, 0, 4));
        days1 = bound(days1, 0, 180);
        days2 = bound(days2, 1, 180);

        _mint(alice, uint128(deposit_));
        _schedule(alice, RATE, PERIOD, 0, skipP);

        _advanceDays(days1);

        if (doCancel && token.isActive(alice)) {
            _cancel(alice);
        }

        _advanceDays(days2);

        // Invariant: consumed <= deposit
        assertLe(token.consumed(alice), deposit_);
    }
}
