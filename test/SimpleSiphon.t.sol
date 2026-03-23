// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SimpleSiphon} from "../src/example/SimpleSiphon.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {IScheduleListener} from "../src/interfaces/IScheduleListener.sol";
import {Test} from "forge-std/Test.sol";

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

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    function _schedule(address user, uint128 rate, uint32 interval, uint16 cap, uint16 grace) internal {
        vm.prank(sched);
        token.setSchedule(user, rate, interval, cap, grace);
    }

    function _terminate(address user) internal { vm.prank(sched); token.terminateSchedule(user); }
    function _clear(address user) internal { vm.prank(sched); token.clearSchedule(user); }
    function _grace(address user, uint16 periods) internal { vm.prank(sched); token.addGracePeriods(user, periods); }
    function _spend(address user, uint128 amt) internal { vm.prank(spndr); token.spend(user, amt); }
    function _auto(address user) internal { _schedule(user, RATE, PERIOD, 0, 0); }
    function _fundAndAuto(address user, uint256 amt) internal { _mint(user, uint128(amt)); _auto(user); }

    // ═══════════════════════════════════════════════════════════════
    // ERC20
    // ═══════════════════════════════════════════════════════════════

    function test_metadata() public {
        assertEq(token.name(), "SimpleSiphon");
        assertEq(token.symbol(), "SIPH");
        assertEq(token.decimals(), 18);
    }

    function test_transfer() public {
        _mint(alice, RATE * 3);
        vm.prank(alice);
        token.transfer(bob, RATE);
        assertEq(token.balanceOf(alice), RATE * 2);
        assertEq(token.balanceOf(bob), RATE);
    }

    function test_transfer_reducesExpiry() public {
        _fundAndAuto(alice, RATE * 3);
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);

        vm.prank(alice);
        token.transfer(bob, RATE); // balance after consumed: 2*RATE, transfer RATE -> 1*RATE left
        // principal was 3*RATE, now 3*RATE - RATE = 2*RATE. funded = 2. But period 1 consuming...
        // Actually _transfer settles first (active schedule, settle is no-op), then reduces principal.
        // principal = 3*RATE - RATE = 2*RATE. funded = 2. expiry = 1000 + 2*30 = 1060.
        assertEq(token.expiry(alice), 1060);
    }

    function test_transfer_insufficientBalance() public {
        _fundAndAuto(alice, RATE * 2);
        // balanceOf = RATE (1 period consumed)
        vm.prank(alice);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.transfer(bob, RATE + 1);
    }

    function test_approve_and_transferFrom() public {
        _mint(alice, RATE * 3);

        vm.prank(alice);
        token.approve(bob, RATE * 2);
        assertEq(token.allowance(alice, bob), RATE * 2);

        vm.prank(bob);
        token.transferFrom(alice, bob, RATE);
        assertEq(token.balanceOf(alice), RATE * 2);
        assertEq(token.balanceOf(bob), RATE);
        assertEq(token.allowance(alice, bob), RATE); // decreased
    }

    function test_transferFrom_insufficientAllowance() public {
        _mint(alice, RATE * 3);
        vm.prank(alice);
        token.approve(bob, RATE - 1);

        vm.prank(bob);
        vm.expectRevert(SiphonToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, RATE);
    }

    function test_transferFrom_maxAllowance() public {
        _mint(alice, RATE * 3);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, RATE);
        assertEq(token.allowance(alice, bob), type(uint256).max); // not decreased
    }

    // ═══════════════════════════════════════════════════════════════
    // MINT + BALANCE
    // ═══════════════════════════════════════════════════════════════

    function test_mint() public {
        _mint(alice, 5000 ether);
        assertEq(token.balanceOf(alice), 5000 ether);
        assertEq(token.totalSupply(), 5000 ether);
    }

    function test_mint_stacks() public {
        _mint(alice, 3000 ether);
        _mint(alice, 2000 ether);
        assertEq(token.balanceOf(alice), 5000 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    // AUTOPAY — BASIC
    // ═══════════════════════════════════════════════════════════════

    function test_autopay_basic() public {
        _fundAndAuto(alice, RATE * 3);
        assertTrue(token.isActive(alice));
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);
    }

    function test_autopay_decay() public {
        _fundAndAuto(alice, RATE * 3);
        assertEq(token.balanceOf(alice), RATE * 2);
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE);
        _advanceDays(30);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_autopay_depositExtends() public {
        _fundAndAuto(alice, RATE);
        assertEq(token.expiry(alice), 1030);
        _mint(alice, RATE * 2);
        assertEq(token.expiry(alice), 1090);
    }

    function test_autopay_lapse() public {
        _fundAndAuto(alice, RATE);
        _advanceDays(31);
        assertTrue(token.isLapsed(alice));
    }

    function test_autopay_terminate() public {
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(5);
        _terminate(alice);
        assertTrue(token.isTerminated(alice));
        assertEq(token.consumed(alice), RATE);
    }

    function test_autopay_settleAfterLapse() public {
        _fundAndAuto(alice, RATE * 2);
        _advanceDays(61);
        _mint(alice, RATE);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(principal, RATE);
        assertEq(rate, 0);
    }

    function test_autopay_settleAfterTerminate() public {
        _fundAndAuto(alice, RATE * 3);
        _terminate(alice);
        _advanceDays(31);
        _mint(alice, RATE);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(principal, RATE * 2 + RATE);
        assertEq(rate, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // PURE PREPAY (grace only)
    // ═══════════════════════════════════════════════════════════════

    function test_prepay_pure() public {
        _mint(alice, 1);
        _schedule(alice, RATE, PERIOD, 0, 3);
        assertTrue(token.isActive(alice));
        assertTrue(token.isGracePeriod(alice));
        assertEq(token.consumed(alice), 0);
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);
        _warpToDay(1091);
        assertTrue(token.isLapsed(alice));
    }

    function test_prepay_thenAutopay() public {
        _mint(alice, RATE * 2);
        _schedule(alice, RATE, PERIOD, 0, 3);
        assertEq(token.expiry(alice), 1000 + 5 * PERIOD);

        _advanceDays(60);
        assertEq(token.balanceOf(alice), RATE * 2);
        assertTrue(token.isGracePeriod(alice));

        _warpToDay(1090);
        assertFalse(token.isGracePeriod(alice));
        assertEq(token.consumed(alice), RATE);

        _warpToDay(1120);
        assertEq(token.consumed(alice), RATE * 2);
        assertEq(token.balanceOf(alice), 0);

        _warpToDay(1150);
        assertTrue(token.isLapsed(alice));
    }

    // ═══════════════════════════════════════════════════════════════
    // MIXED: AUTOPAY + GRACE MID-SCHEDULE
    // ═══════════════════════════════════════════════════════════════

    function test_mixed_addGraceMidAutopay() public {
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(15);
        _grace(alice, 3);

        assertEq(token.consumed(alice), 0);
        assertEq(token.balanceOf(alice), RATE * 2);

        _warpToDay(1030);
        assertTrue(token.isGracePeriod(alice));

        _warpToDay(1090);
        assertTrue(token.isGracePeriod(alice));

        _warpToDay(1105);
        assertFalse(token.isGracePeriod(alice));
        assertEq(token.consumed(alice), RATE);

        _warpToDay(1135);
        assertEq(token.consumed(alice), RATE * 2);
        assertEq(token.balanceOf(alice), 0);

        _warpToDay(1165);
        assertTrue(token.isLapsed(alice));
    }

    function test_mixed_multipleGraceAdditions() public {
        _fundAndAuto(alice, RATE * 4);

        // Day 1010: add 2 grace
        _advanceDays(10);
        _grace(alice, 2);
        // Settled period 1 (RATE consumed), principal=3*RATE, anchor=1010, grace=2

        // Day 1040: add 1 more grace (in grace zone, consumed=0, restart anchor)
        _advanceDays(30);
        _grace(alice, 1);
        // Settled 0 consumed (in grace), principal=3*RATE, anchor=1040, grace=1

        assertEq(token.balanceOf(alice), RATE * 3);
        assertTrue(token.isGracePeriod(alice));

        // From day 1040: grace=1, funded=3. total=4 periods. expiry=1040+120=1160.
        assertEq(token.expiry(alice), 1040 + (1 + 3) * PERIOD);

        _warpToDay(1160);
        assertTrue(token.isLapsed(alice));
    }

    // ═══════════════════════════════════════════════════════════════
    // SPEND + SCHEDULE INTERACTION
    // ═══════════════════════════════════════════════════════════════

    function test_spend_reducesExpiry() public {
        _fundAndAuto(alice, RATE * 3);
        _spend(alice, 1);
        assertEq(token.expiry(alice), 1060);
    }

    function test_spend_duringGraceReducesPostGrace() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        assertEq(token.expiry(alice), 1150);
        _advanceDays(15);
        _spend(alice, RATE);
        assertEq(token.expiry(alice), 1120);
        assertEq(token.balanceOf(alice), RATE * 2);
    }

    function test_spend_cannotExceedAvailable() public {
        _fundAndAuto(alice, RATE * 2);
        vm.prank(spndr);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.spend(alice, RATE + 1);
    }

    function test_spend_settlesStale() public {
        _fundAndAuto(alice, RATE + 500 ether);
        _advanceDays(PERIOD + 1);
        _spend(alice, 200 ether);
        assertEq(token.balanceOf(alice), 300 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    // CAP (maxPeriods)
    // ═══════════════════════════════════════════════════════════════

    function test_cap_total() public {
        _mint(alice, RATE * 10);
        _schedule(alice, RATE, PERIOD, 6, 3);
        assertEq(token.expiry(alice), 1000 + 6 * PERIOD);
    }

    function test_cap_global() public {
        _mint(alice, RATE * 20);
        _schedule(alice, RATE, PERIOD, 0, 3);
        assertEq(token.expiry(alice), 1000 + 12 * PERIOD);
    }

    function test_cap_userSet() public {
        _fundAndAuto(alice, RATE * 6);
        assertEq(token.expiry(alice), 1000 + 6 * PERIOD);
        vm.prank(alice);
        token.setCap(3);
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);
        vm.prank(alice);
        token.setCap(0);
        assertEq(token.expiry(alice), 1000 + 6 * PERIOD);
    }

    function test_cap_spendBelowCap() public {
        _mint(alice, RATE * 6);
        _schedule(alice, RATE, PERIOD, 5, 0);
        assertEq(token.expiry(alice), 1000 + 5 * PERIOD);
        _spend(alice, RATE * 2);
        assertEq(token.expiry(alice), 1000 + 4 * PERIOD);
    }

    // ═══════════════════════════════════════════════════════════════
    // CANCEL DURING GRACE
    // ═══════════════════════════════════════════════════════════════

    function test_terminate_duringGrace() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        _advanceDays(15);
        _terminate(alice);
        assertTrue(token.isTerminated(alice));
        assertEq(token.consumed(alice), 0);
    }

    function test_terminate_duringGrace_settlePreservesBalance() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        _advanceDays(15);
        _terminate(alice);
        _advanceDays(16);
        token.settle(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(principal, RATE * 3);
        assertEq(rate, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // CLEAR SCHEDULE
    // ═══════════════════════════════════════════════════════════════

    function test_clear_immediate() public {
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(5);
        _clear(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
        assertEq(principal, RATE * 2);
    }

    function test_clear_duringGrace() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        _advanceDays(15);
        _clear(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
        assertEq(principal, RATE * 3);
    }

    // ═══════════════════════════════════════════════════════════════
    // LISTENER
    // ═══════════════════════════════════════════════════════════════

    function test_listener_setSchedule() public {
        _mint(alice, RATE);
        _auto(alice);
        assertEq(listener.callCount(), 1);
        (,, bool active) = listener.calls(0);
        assertTrue(active);
    }

    function test_listener_settle() public {
        _fundAndAuto(alice, RATE);
        _advanceDays(31);
        token.settle(alice);
        assertEq(listener.callCount(), 2);
        (,, bool active) = listener.calls(1);
        assertFalse(active);
    }

    function test_listener_addGrace() public {
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(5);
        _grace(alice, 2);
        assertEq(listener.callCount(), 2);
    }

    // ═══════════════════════════════════════════════════════════════
    // SCHEDULE REPLACEMENT
    // ═══════════════════════════════════════════════════════════════

    function test_replace_checkpointsOld() public {
        _fundAndAuto(alice, RATE * 3 + 5000 ether);
        _advanceDays(15);
        _schedule(alice, 5000 ether, PERIOD, 0, 0);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 5000 ether);
        assertEq(principal, RATE * 2 + 5000 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    // FULL LIFECYCLE PATHS
    // ═══════════════════════════════════════════════════════════════

    function test_path_basicRelapse() public {
        _mint(alice, RATE * 2);
        _auto(alice);
        _advanceDays(61);
        assertTrue(token.isLapsed(alice));
        _mint(alice, RATE * 3);
        _auto(alice);
        assertTrue(token.isActive(alice));
    }

    function test_path_terminateAndReturn() public {
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(5);
        _terminate(alice);
        _advanceDays(26);
        _auto(alice);
        assertTrue(token.isActive(alice));
        assertEq(token.balanceOf(alice), RATE);
    }

    function test_path_prepayAutoLapseReturn() public {
        _mint(alice, RATE * 2);
        _schedule(alice, RATE, PERIOD, 0, 3);
        _warpToDay(1080);
        assertTrue(token.isGracePeriod(alice));
        _warpToDay(1095);
        assertFalse(token.isGracePeriod(alice));
        assertEq(token.consumed(alice), RATE);
        _warpToDay(1150);
        assertTrue(token.isLapsed(alice));
        _mint(alice, RATE * 2);
        _auto(alice);
        assertTrue(token.isActive(alice));
    }

    function test_path_repeatedGrace() public {
        _fundAndAuto(alice, RATE * 4);
        _advanceDays(10);
        _grace(alice, 2);
        // principal=3*RATE, anchor=1010, grace=2
        _advanceDays(30);
        _grace(alice, 1);
        // principal=3*RATE, anchor=1040, grace=1
        assertEq(token.expiry(alice), 1040 + (1 + 3) * PERIOD);
        _warpToDay(1160);
        assertTrue(token.isLapsed(alice));
    }

    function test_path_spendThenGrace() public {
        _fundAndAuto(alice, RATE * 4);
        _spend(alice, RATE);
        assertEq(token.expiry(alice), 1000 + 3 * PERIOD);
        _advanceDays(5);
        _grace(alice, 2);
        assertEq(token.expiry(alice), 1005 + (2 + 2) * PERIOD);
    }

    function test_path_terminateDuringGrace() public {
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        _advanceDays(15);
        _terminate(alice);
        _advanceDays(16);
        assertFalse(token.isTerminated(alice));
        token.settle(alice);
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
        assertEq(principal, RATE * 3);
    }

    function test_path_sponsorThenUserAutopay() public {
        _mint(alice, 1);
        _schedule(alice, RATE, PERIOD, 0, 1);
        assertTrue(token.isGracePeriod(alice));
        _advanceDays(15);
        _mint(alice, RATE * 3);
        _advanceDays(15);
        assertFalse(token.isGracePeriod(alice));
        assertEq(token.consumed(alice), RATE);
    }

    // ═══════════════════════════════════════════════════════════════
    // EDGE CASES
    // ═══════════════════════════════════════════════════════════════

    function test_edge_transferToZero() public {
        _mint(alice, RATE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiphonToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), RATE);
    }

    function test_edge_transferFromZero() public {
        // Allowance check fires before zero-address check, but both paths revert
        vm.expectRevert(SiphonToken.InsufficientAllowance.selector);
        token.transferFrom(address(0), alice, RATE);
    }

    function test_edge_insufficientForNonGrace() public {
        _mint(alice, RATE - 1);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.setSchedule(alice, RATE, PERIOD, 0, 0);
    }

    function test_edge_graceWithNoBalance() public {
        _mint(alice, 1);
        _schedule(alice, RATE, PERIOD, 0, 3);
        assertTrue(token.isActive(alice));
    }

    function test_edge_doubleTerminate() public {
        _fundAndAuto(alice, RATE * 3);
        _terminate(alice);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.terminateSchedule(alice);
    }

    function test_edge_addGraceToTerminated() public {
        _fundAndAuto(alice, RATE * 3);
        _terminate(alice);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.addGracePeriods(alice, 2);
    }

    function test_edge_addGraceToLapsed() public {
        _fundAndAuto(alice, RATE);
        _advanceDays(31);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.addGracePeriods(alice, 2);
    }

    function test_edge_capNoSchedule() public {
        vm.prank(alice);
        vm.expectRevert(SiphonToken.NoSchedule.selector);
        token.setCap(3);
    }

    function test_edge_settleNoOp() public {
        _mint(alice, RATE);
        token.settle(alice);
        assertEq(token.balanceOf(alice), RATE);
    }

    function test_edge_publicSettle() public {
        _fundAndAuto(alice, RATE);
        _advanceDays(31);
        vm.prank(bob);
        token.settle(alice);
        (,uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // TRANSFER INTERACTIONS
    // ═══════════════════════════════════════════════════════════════

    function test_transfer_extendsReceiverExpiry() public {
        _fundAndAuto(alice, RATE * 2);
        _fundAndAuto(bob, RATE);
        assertEq(token.expiry(bob), 1000 + PERIOD);

        // Alice transfers RATE to bob — his principal increases, expiry extends
        vm.prank(alice);
        token.transfer(bob, RATE);
        assertEq(token.expiry(bob), 1000 + 2 * PERIOD);
    }

    function test_transfer_settlesStaleReceiver() public {
        _fundAndAuto(bob, RATE);
        _advanceDays(31); // bob lapsed
        assertTrue(token.isLapsed(bob));

        _mint(alice, RATE * 2);
        vm.prank(alice);
        token.transfer(bob, RATE);

        // Bob's lapsed schedule should be settled first, then transfer lands
        (uint128 principal, uint128 rate,,,,,) = token.getSchedule(bob);
        assertEq(rate, 0); // schedule cleared by settle
        assertEq(principal, RATE); // only the transferred amount (consumed deducted by settle)
    }

    function test_transfer_settlesStaleSender() public {
        _fundAndAuto(alice, RATE * 2);
        _advanceDays(61); // lapsed, consumed 2*RATE
        _mint(alice, RATE * 3); // settle fires: principal = 0 + 3*RATE = 3*RATE

        vm.prank(alice);
        token.transfer(bob, RATE);
        assertEq(token.balanceOf(alice), RATE * 2);
        assertEq(token.balanceOf(bob), RATE);
    }

    function test_transfer_zero() public {
        _mint(alice, RATE);
        vm.prank(alice);
        token.transfer(bob, 0); // ERC20 spec: MUST treat as normal
        assertEq(token.balanceOf(alice), RATE);
        assertEq(token.balanceOf(bob), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // TERMINATE — FINAL PERIOD PRESERVED
    // ═══════════════════════════════════════════════════════════════

    function test_terminate_finalPeriodPreserved() public {
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(5);
        _terminate(alice);

        // Terminated but still in final period — schedule should NOT settle yet
        assertTrue(token.isTerminated(alice));
        assertEq(token.consumed(alice), RATE); // frozen at period 1

        // Deposit during final period should NOT clear schedule
        _mint(alice, RATE);
        assertTrue(token.isTerminated(alice)); // still terminated, not settled

        // Past period boundary — now settle can fire
        _advanceDays(26); // day 1031
        assertFalse(token.isTerminated(alice)); // service ended
        token.settle(alice);
        (,uint128 rate,,,,,) = token.getSchedule(alice);
        assertEq(rate, 0); // settled
    }

    function test_terminate_postGrace() public {
        // Grace periods, then autopay, then terminate during autopay
        _mint(alice, RATE * 3);
        _schedule(alice, RATE, PERIOD, 0, 2);
        // 2 grace + 3 funded. expiry = 1000 + 5*30 = 1150.

        // Day 1065: period 3 (first billable, started at day 1060)
        _warpToDay(1065);
        assertFalse(token.isGracePeriod(alice));
        // periodsStarted = ((1065-1000)/30)+1 = 3, billable = 3-2 = 1
        assertEq(token.consumed(alice), RATE);

        _terminate(alice);
        assertTrue(token.isTerminated(alice));

        // Service until period boundary (day 1090)
        _warpToDay(1085);
        assertTrue(token.isTerminated(alice));

        // Past boundary
        _warpToDay(1090);
        assertFalse(token.isTerminated(alice));
        token.settle(alice);
        (uint128 principal,,,,,, ) = token.getSchedule(alice);
        assertEq(principal, RATE * 2); // 3 - 1 consumed
    }

    // ═══════════════════════════════════════════════════════════════
    // TRACKING
    // ═══════════════════════════════════════════════════════════════

    function test_tracking_siphoned() public {
        _fundAndAuto(alice, RATE);
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
        _fundAndAuto(alice, RATE * 3);
        _advanceDays(91);
        token.settle(alice);
        assertEq(token.totalSupply(), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // FUZZ
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_balanceNeverUnderflows(uint256 deposit_, uint256 days_) public {
        deposit_ = bound(deposit_, RATE, RATE * 6);
        days_ = bound(days_, 0, 365);
        _mint(alice, uint128(deposit_));
        _auto(alice);
        _advanceDays(days_);
        assertLe(token.consumed(alice), deposit_);
    }

    function testFuzz_gracePreservesBalance(uint16 grace, uint256 days_) public {
        grace = uint16(bound(grace, 1, 6));
        days_ = bound(days_, 0, uint256(grace) * PERIOD);
        _mint(alice, RATE);
        _schedule(alice, RATE, PERIOD, 0, grace);
        _advanceDays(days_);
        if (days_ < uint256(grace) * PERIOD) {
            assertEq(token.balanceOf(alice), RATE);
        }
    }

    function testFuzz_lifecycle(uint256 deposit_, uint16 grace, uint256 d1, uint256 d2, bool doCancel) public {
        deposit_ = bound(deposit_, RATE, RATE * 6);
        grace = uint16(bound(grace, 0, 4));
        d1 = bound(d1, 0, 180);
        d2 = bound(d2, 1, 180);
        _mint(alice, uint128(deposit_));
        _schedule(alice, RATE, PERIOD, 0, grace);
        _advanceDays(d1);
        if (doCancel && token.isActive(alice)) _terminate(alice); // param name is legacy
        _advanceDays(d2);
        assertLe(token.consumed(alice), deposit_);
    }
}
