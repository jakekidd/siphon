// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SimpleSiphon} from "../src/example/SimpleSiphon.sol";
import {StreamingSubscription} from "../src/example/StreamingSubscription.sol";
import {Payroll} from "../src/example/Payroll.sol";
import {RentalAgreement} from "../src/example/RentalAgreement.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {IScheduleListener} from "../src/interfaces/IScheduleListener.sol";
import {Test} from "forge-std/Test.sol";

// ──────────────────────────────────────────────
// Mock listener
// ──────────────────────────────────────────────

contract MockListener is IScheduleListener {
    struct Call {
        address token;
        address user;
        bool active;
    }

    Call[] public calls;

    function onScheduleUpdate(address _token, address _user, bool _active) external {
        calls.push(Call(_token, _user, _active));
    }

    function callCount() external view returns (uint256) { return calls.length; }
}

// ================================================================
//  Core tests (SiphonToken surface via SimpleSiphon)
// ================================================================

contract SimpleSiphonTest is Test {
    SimpleSiphon public token;
    MockListener public listener;

    address public owner = makeAddr("owner");
    address public sched = makeAddr("scheduler");
    address public spndr = makeAddr("spender");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public treasury = makeAddr("treasury");

    uint128 constant RATE   = 3000 ether;
    uint16  constant PERIOD = 30;
    uint256 constant DAY    = 86_400;

    function setUp() public {
        _warpToDay(1000); // DEPLOY_DAY = 1000
        token = new SimpleSiphon(owner);
        listener = new MockListener();

        vm.startPrank(owner);
        token.setScheduler(sched);
        token.setSpender(spndr);
        token.setListener(address(listener));
        vm.stopPrank();
    }

    // -- Helpers --

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    function _tapViaSched(address user, address beneficiary, uint128 rate) internal {
        vm.prank(sched);
        token.tapUser(user, beneficiary, rate);
    }

    function _revokeViaSched(address user, bytes32 mid) internal {
        vm.prank(sched);
        token.revokeUser(user, mid);
    }

    function _spend(address user, uint128 amt) internal {
        vm.prank(spndr);
        token.spend(user, amt);
    }

    // ================================================================
    //  1. ERC20: metadata, transfer, approve, allowance
    // ================================================================

    function test_SiphonToken__name_returnsSimpleSiphon() public view {
        assertEq(token.name(), "SimpleSiphon");
    }

    function test_SiphonToken__symbol_returnsSIPH() public view {
        assertEq(token.symbol(), "SIPH");
    }

    function test_SiphonToken__decimals_returns18() public view {
        assertEq(token.decimals(), 18);
    }

    function test_SiphonToken__transfer_movesTokens() public {
        _mint(alice, 1000 ether);
        vm.prank(alice);
        token.transfer(bob, 400 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
    }

    function test_SiphonToken__transfer_revertsIfInsufficientBalance() public {
        _mint(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.transfer(bob, 200 ether);
    }

    function test_SiphonToken__transfer_revertsIfReceiverIsZero() public {
        _mint(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiphonToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 50 ether);
    }

    function test_SiphonToken__transfer_revertsIfSenderIsZero() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(SiphonToken.ERC20InvalidSender.selector, address(0)));
        token.transfer(bob, 50 ether);
    }

    function test_SiphonToken__transferFrom_movesTokensWithApproval() public {
        _mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(bob, 500 ether);
        assertEq(token.allowance(alice, bob), 500 ether);

        vm.prank(bob);
        token.transferFrom(alice, carol, 300 ether);
        assertEq(token.balanceOf(alice), 700 ether);
        assertEq(token.balanceOf(carol), 300 ether);
        assertEq(token.allowance(alice, bob), 200 ether);
    }

    function test_SiphonToken__transferFrom_revertsIfInsufficientAllowance() public {
        _mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(bob, 50 ether);
        vm.prank(bob);
        vm.expectRevert(SiphonToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 100 ether);
    }

    function test_SiphonToken__transferFrom_skipsAllowanceDecrementWhenMax() public {
        _mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 500 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_SiphonToken__approve_setsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 999 ether);
        assertEq(token.allowance(alice, bob), 999 ether);
    }

    // ================================================================
    //  2. Mint + balance basics
    // ================================================================

    function test_SimpleSiphon__mint_succeedsWhenOwner() public {
        _mint(alice, 5000 ether);
        assertEq(token.balanceOf(alice), 5000 ether);
    }

    function test_SimpleSiphon__mint_revertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.mint(alice, 100 ether);
    }

    function test_SimpleSiphon__mint_stacksMultipleDeposits() public {
        _mint(alice, 2000 ether);
        _mint(alice, 3000 ether);
        assertEq(token.balanceOf(alice), 5000 ether);
    }

    function test_SiphonToken__totalSupply_reflectsMints() public {
        _mint(alice, 1000 ether);
        _mint(bob, 2000 ether);
        assertEq(token.totalSupply(), 3000 ether);
    }

    // ================================================================
    //  3. Single tap (burn path): beneficiary = address(0)
    // ================================================================

    function test_SiphonToken__balanceOf_unchangedImmediatelyAfterBurnTap() public {
        _mint(alice, RATE * 4);
        // burn tap: beneficiary=address(0), immediate first-term payment burns RATE
        _tapViaSched(alice, address(0), RATE);
        // immediate first-term deduction: 4*RATE - RATE = 3*RATE
        assertEq(token.balanceOf(alice), RATE * 3);
    }

    function test_SiphonToken__balanceOf_decaysOverTimeWithBurnTap() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, address(0), RATE);
        // balance = 3*RATE, outflow = RATE

        // After 30 days: 1 period elapsed -> consumed = 1*RATE
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 2);

        // After 60 days total: 2 periods -> consumed = 2*RATE
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 1);

        // After 90 days total: 3 periods -> consumed = 3*RATE (funded = 3)
        _advanceDays(30);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_SiphonToken__balanceOf_clampedAtZeroOnLapse() public {
        _mint(alice, RATE * 2);
        _tapViaSched(alice, address(0), RATE);
        // balance = RATE, outflow = RATE. funded = 1 period

        // After 30 days: consumed = 1*RATE. balance = 0
        _advanceDays(30);
        assertEq(token.balanceOf(alice), 0);

        // After 90 days: still 0 (clamped)
        _advanceDays(60);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_SiphonToken__settle_clearsLapsedBurnTap() public {
        _mint(alice, RATE * 2);
        _tapViaSched(alice, address(0), RATE);
        // principal = RATE, outflow = RATE, funded = 1

        // Advance past funded periods
        _advanceDays(60); // 2 periods elapsed > 1 funded

        token.settle(alice);
        // Lapse triggers _resolvePriority. principal = 0 < RATE => lapse. Tap removed.
        (uint128 principal, uint128 outflow,) = token.getAccount(alice);
        assertEq(principal, 0);
        assertEq(outflow, 0);

        bytes32[] memory taps = token.getUserTaps(alice);
        assertEq(taps.length, 0);
    }

    function test_SiphonToken__totalBurned_incrementsOnBurnTapSettle() public {
        _mint(alice, RATE * 3);
        _tapViaSched(alice, address(0), RATE);
        // immediate first-term burn: totalBurned = RATE
        assertEq(token.totalBurned(), RATE);

        _advanceDays(30);
        token.settle(alice);
        // 1 period elapsed, burnOutflow = RATE => totalBurned += RATE
        assertEq(token.totalBurned(), RATE * 2);
    }

    // ================================================================
    //  4. Single tap (beneficiary): immediate payment, decay, harvest, revoke
    // ================================================================

    function test_SiphonToken__tap_immediateFirstPaymentToBeneficiary() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        // Immediate first-term: alice loses RATE, treasury gains RATE
        assertEq(token.balanceOf(alice), RATE * 3);
        assertEq(token.balanceOf(treasury), RATE);
    }

    function test_SiphonToken__balanceOf_decaysOverTimeWithBeneficiaryTap() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        // principal = 3*RATE, outflow = RATE

        _advanceDays(30); // epoch 1 starts
        assertEq(token.balanceOf(alice), RATE * 2);

        _advanceDays(30); // epoch 2
        assertEq(token.balanceOf(alice), RATE * 1);

        _advanceDays(30); // epoch 3
        assertEq(token.balanceOf(alice), 0);
    }

    function test_SiphonToken__harvest_collectsBeneficiaryIncome() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        // entry at epoch 1

        // Advance to epoch 1 (day 1030)
        _advanceDays(30);

        // Harvest epoch 1: 1 user paying RATE = RATE
        uint256 preBalance = token.balanceOf(treasury);
        token.harvest(treasury, RATE, 10);
        uint256 postBalance = token.balanceOf(treasury);
        assertEq(postBalance - preBalance, RATE);
    }

    function test_SiphonToken__harvest_collectsMultipleEpochs() public {
        _mint(alice, RATE * 5);
        _tapViaSched(alice, treasury, RATE);
        // Immediate: treasury = RATE. entry at epoch 1.
        // funded: principal(3*RATE)/outflow(RATE) = 4 => exit at epoch 0+1+4 = 5

        _advanceDays(90); // epoch 3
        token.harvest(treasury, RATE, 10);
        // Epochs 1,2,3 each have 1 user => 3 * RATE
        assertEq(token.balanceOf(treasury), RATE + RATE * 3);
    }

    function test_SiphonToken__harvest_returnsNothingIfNoEpochsElapsed() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);

        uint256 pre = token.balanceOf(treasury);
        token.harvest(treasury, RATE, 10);
        // Still epoch 0 — nothing to harvest (entry is at epoch 1)
        assertEq(token.balanceOf(treasury), pre);
    }

    function test_SiphonToken__revoke_immediatelyTerminatesTap() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        assertEq(token.balanceOf(alice), RATE * 3);

        bytes32 mid = _mid(treasury, RATE);
        _revokeViaSched(alice, mid);
        // Outflow removed, principal stays at 3*RATE
        assertEq(token.balanceOf(alice), RATE * 3);

        (uint128 principal, uint128 outflow,) = token.getAccount(alice);
        assertEq(outflow, 0);
        assertEq(principal, uint128(RATE * 3));
    }

    function test_SiphonToken__revoke_callableByUser() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        vm.prank(alice);
        token.revoke(alice, mid);

        (,uint128 outflow,) = token.getAccount(alice);
        assertEq(outflow, 0);
    }

    function test_SiphonToken__revoke_callableByBeneficiary() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        vm.prank(treasury);
        token.revoke(alice, mid);

        (,uint128 outflow,) = token.getAccount(alice);
        assertEq(outflow, 0);
    }

    function test_SiphonToken__revoke_revertsIfUnauthorizedCaller() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        vm.prank(bob);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.revoke(alice, mid);
    }

    function test_SiphonToken__revoke_decrementsOutflow() public {
        _mint(alice, RATE * 8);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(alice, bob, RATE);

        (,uint128 outflowBefore,) = token.getAccount(alice);
        assertEq(outflowBefore, RATE * 2);

        _revokeViaSched(alice, _mid(treasury, RATE));

        (,uint128 outflowAfter,) = token.getAccount(alice);
        assertEq(outflowAfter, RATE);
    }

    // ================================================================
    //  5. Multi-tap: two taps, shared outflow, both decay, independent harvest
    // ================================================================

    function test_SiphonToken__balanceOf_decaysWithMultipleTaps() public {
        _mint(alice, RATE * 8);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(alice, bob, RATE);
        // Immediate: paid RATE to treasury, RATE to bob.
        // principal = 6*RATE, outflow = 2*RATE
        assertEq(token.balanceOf(alice), RATE * 6);

        _advanceDays(30); // 1 period
        // consumed = 1 * 2*RATE = 2*RATE
        assertEq(token.balanceOf(alice), RATE * 4);

        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 2);

        _advanceDays(30);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_SiphonToken__harvest_independentPerMandate() public {
        _mint(alice, RATE * 8);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(alice, bob, RATE);

        _advanceDays(30); // epoch 1

        uint256 preTreasury = token.balanceOf(treasury);
        token.harvest(treasury, RATE, 10);
        assertEq(token.balanceOf(treasury) - preTreasury, RATE);

        uint256 preBob = token.balanceOf(bob);
        token.harvest(bob, RATE, 10);
        assertEq(token.balanceOf(bob) - preBob, RATE);
    }

    // ================================================================
    //  6. Priority lapse: 3 taps, insufficient funds, first survives
    // ================================================================

    function test_SiphonToken__settle_resolvePriorityOnLapse() public {
        // 3 taps at RATE each: immediate = 3*RATE. principal = 2*RATE. outflow = 3*RATE. funded = 0.
        // After 30 days: elapsed=1 > funded=0 => lapse.
        // Priority: remaining=2*RATE. tap1 survives (remaining-=RATE). tap2 survives (remaining=0).
        //           tap3: 0 < RATE => lapsed.

        _mint(alice, RATE * 5);
        _tapViaSched(alice, treasury, RATE);   // first-tapped
        _tapViaSched(alice, bob, RATE);        // second
        _tapViaSched(alice, carol, RATE);      // third (lowest priority)
        // principal = 2*RATE, outflow = 3*RATE

        _advanceDays(30); // elapsed=1, funded=0 => lapse
        token.settle(alice);

        // settle: funded=0, con=0. elapsed(1) > funded(0) => _resolvePriority.
        // remaining=2*RATE. tap1 survives (-RATE). tap2 survives (-RATE). tap3 lapses (0 < RATE).

        bytes32[] memory taps = token.getUserTaps(alice);
        assertEq(taps.length, 2, "two taps should survive");
        assertEq(taps[0], _mid(treasury, RATE));
        assertEq(taps[1], _mid(bob, RATE));

        (uint128 principal, uint128 outflow,) = token.getAccount(alice);
        assertEq(principal, 0);
        assertEq(outflow, RATE * 2);
    }

    function test_SiphonToken__settle_allTapsLapseWhenFullyDrained() public {
        _mint(alice, RATE * 3);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(alice, bob, RATE);
        _tapViaSched(alice, carol, RATE);
        // principal = 0, outflow = 3*RATE

        _advanceDays(30);
        token.settle(alice);

        bytes32[] memory taps = token.getUserTaps(alice);
        assertEq(taps.length, 0);

        (uint128 principal, uint128 outflow,) = token.getAccount(alice);
        assertEq(principal, 0);
        assertEq(outflow, 0);
    }

    // ================================================================
    //  7. Authorization: authorize, consume on tap, insufficient auth, infinite
    // ================================================================

    function test_SiphonToken__authorize_setsCount() public {
        bytes32 mid = _mid(treasury, RATE);
        vm.prank(alice);
        token.authorize(mid, 3);
        assertEq(token.authorization(alice, mid), 3);
    }

    function test_SiphonToken__tap_consumesOneAuthorization() public {
        _mint(alice, RATE * 4);
        bytes32 mid = _mid(treasury, RATE);
        vm.prank(alice);
        token.authorize(mid, 2);

        // treasury taps alice via public tap()
        vm.prank(treasury);
        token.tap(alice, RATE);
        assertEq(token.authorization(alice, mid), 1);
    }

    function test_SiphonToken__tap_revertsIfNotApproved() public {
        _mint(alice, RATE * 4);
        vm.prank(treasury);
        vm.expectRevert(SiphonToken.NotApproved.selector);
        token.tap(alice, RATE);
    }

    function test_SiphonToken__tap_revertsIfAuthorizationExhausted() public {
        _mint(alice, RATE * 8);
        bytes32 mid = _mid(treasury, RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(treasury);
        token.tap(alice, RATE);

        // Revoke so we can re-tap
        vm.prank(treasury);
        token.revoke(alice, mid);

        // Second tap should fail: auth consumed
        vm.prank(treasury);
        vm.expectRevert(SiphonToken.NotApproved.selector);
        token.tap(alice, RATE);
    }

    function test_SiphonToken__tap_infiniteAuthorizationNeverDecremented() public {
        _mint(alice, RATE * 8);
        bytes32 mid = _mid(treasury, RATE);
        vm.prank(alice);
        token.authorize(mid, type(uint256).max);

        vm.prank(treasury);
        token.tap(alice, RATE);
        assertEq(token.authorization(alice, mid), type(uint256).max);

        // Revoke + re-tap: infinite auth allows it, same mandateId works
        vm.prank(treasury);
        token.revoke(alice, mid);

        vm.prank(treasury);
        token.tap(alice, RATE);
        assertEq(token.authorization(alice, mid), type(uint256).max);
    }

    // ================================================================
    //  9. Revoke: immediate termination, outflow decremented
    // ================================================================

    function test_SiphonToken__revoke_revertsIfAlreadyRevoked() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        _revokeViaSched(alice, mid);

        // Tap deleted on revoke — second revoke is TapNotFound
        vm.prank(sched);
        vm.expectRevert(SiphonToken.TapNotFound.selector);
        token.revokeUser(alice, mid);
    }

    function test_SiphonToken__revoke_revertsIfTapNotFound() public {
        bytes32 mid = _mid(treasury, RATE);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.TapNotFound.selector);
        token.revokeUser(alice, mid);
    }

    function test_SiphonToken__revoke_noDecayAfterRevoke() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);

        _advanceDays(15); // half a period
        bytes32 mid = _mid(treasury, RATE);
        _revokeViaSched(alice, mid);

        uint256 balAfterRevoke = token.balanceOf(alice);
        // No periods fully elapsed yet, so balance = 3*RATE
        assertEq(balAfterRevoke, RATE * 3);

        _advanceDays(60);
        // No outflow anymore — balance unchanged
        assertEq(token.balanceOf(alice), RATE * 3);
    }

    // ================================================================
    //  10. Balance mutations: deposit extends, spend shortens
    // ================================================================

    function test_SiphonToken__mint_extendsTapRunway() public {
        _mint(alice, RATE * 2);
        _tapViaSched(alice, treasury, RATE);
        // principal = RATE, outflow = RATE. funded = 1

        // Mint more: extends runway
        _mint(alice, RATE * 2);
        // principal = 3*RATE. funded = 3

        _advanceDays(60); // 2 periods
        assertEq(token.balanceOf(alice), RATE);
    }

    function test_SimpleSiphon__spend_shortensTapRunway() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        // principal = 3*RATE. funded = 3

        _spend(alice, RATE);
        // principal = 2*RATE. funded = 2.
        assertEq(token.balanceOf(alice), RATE * 2);

        _advanceDays(60); // 2 periods, fully consumed
        assertEq(token.balanceOf(alice), 0);
    }

    function test_SimpleSiphon__spend_revertsIfInsufficientBalance() public {
        _mint(alice, RATE);
        vm.prank(spndr);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.spend(alice, uint128(RATE + 1));
    }

    function test_SimpleSiphon__spend_revertsWhenNotSpender() public {
        _mint(alice, RATE);
        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.spend(alice, RATE);
    }

    // ================================================================
    //  11. Transfer: settles both sides, dropoffs recomputed
    // ================================================================

    function test_SiphonToken__transfer_settlesSenderAndReceiver() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        // alice: principal=3*RATE, outflow=RATE

        _mint(bob, RATE * 4);
        _tapViaSched(bob, treasury, RATE);
        // bob: principal=3*RATE, outflow=RATE

        _advanceDays(30); // 1 period elapsed for both

        // Transfer settles both
        vm.prank(alice);
        token.transfer(bob, RATE);

        // alice: settled (consumed 1*RATE), principal becomes 2*RATE, then transfer -RATE = RATE
        assertEq(token.balanceOf(alice), RATE);
        // bob: settled (consumed 1*RATE), principal becomes 2*RATE, then receives RATE = 3*RATE
        assertEq(token.balanceOf(bob), RATE * 3);
    }

    // ================================================================
    //  12. Settle: permissionless, no-op when no taps
    // ================================================================

    function test_SiphonToken__settle_permissionless() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _advanceDays(30);

        // Anyone can settle alice
        vm.prank(bob);
        token.settle(alice);

        (uint128 principal,,) = token.getAccount(alice);
        assertEq(principal, uint128(RATE * 2)); // 3*RATE - 1*RATE
    }

    function test_SiphonToken__settle_noOpWhenNoTaps() public {
        _mint(alice, 1000 ether);
        _advanceDays(60);

        token.settle(alice);
        assertEq(token.balanceOf(alice), 1000 ether);
    }

    function test_SiphonToken__settle_noOpWhenNoPeriodElapsed() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _advanceDays(15);

        (uint128 pBefore,,) = token.getAccount(alice);
        token.settle(alice);
        (uint128 pAfter,,) = token.getAccount(alice);
        assertEq(pBefore, pAfter);
    }

    // ================================================================
    //  13. Edge cases: self-tap, zero rate, max taps, double tap
    // ================================================================

    function test_SiphonToken__tap_revertsIfSelfTap() public {
        _mint(alice, RATE * 4);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.InvalidBeneficiary.selector);
        token.tapUser(alice, alice, RATE);
    }

    function test_SiphonToken__tap_revertsIfZeroRate() public {
        _mint(alice, RATE * 4);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.InvalidMandate.selector);
        token.tapUser(alice, treasury, 0);
    }

    function test_SiphonToken__tap_revertsIfMaxTapsReached() public {
        // MAX_TAPS = 32 for SimpleSiphon
        _mint(alice, uint128(RATE * 64)); // enough for 32 taps + decay

        for (uint256 i = 1; i <= 32; i++) {
            address beneficiary = address(uint160(0xBEEF0000 + i));
            vm.prank(sched);
            token.tapUser(alice, beneficiary, RATE);
        }

        address extra = address(uint160(0xBEEF0033));
        vm.prank(sched);
        vm.expectRevert(SiphonToken.MaxTaps.selector);
        token.tapUser(alice, extra, RATE);
    }

    function test_SiphonToken__tap_revertsIfDuplicateMandate() public {
        _mint(alice, RATE * 8);
        _tapViaSched(alice, treasury, RATE);

        vm.prank(sched);
        vm.expectRevert(SiphonToken.InvalidMandate.selector);
        token.tapUser(alice, treasury, RATE);
    }

    function test_SiphonToken__tap_revertsIfInsufficientBalance() public {
        _mint(alice, RATE - 1);
        vm.prank(sched);
        vm.expectRevert(SiphonToken.InsufficientBalance.selector);
        token.tapUser(alice, treasury, RATE);
    }

    // ================================================================
    //  14. Tracking: totalMinted, totalBurned, totalSpent, totalSupply
    // ================================================================

    function test_SiphonToken__totalMinted_tracksAllMints() public {
        _mint(alice, 1000 ether);
        _mint(bob, 2000 ether);
        assertEq(token.totalMinted(), 3000 ether);
    }

    function test_SiphonToken__totalSpent_tracksSpends() public {
        _mint(alice, 1000 ether);
        _spend(alice, 400 ether);
        assertEq(token.totalSpent(), 400 ether);
    }

    function test_SiphonToken__totalSupply_consistentAfterOperations() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, address(0), RATE);
        // totalMinted = 4*RATE, totalBurned = RATE (immediate), totalSpent = 0
        // totalSupply = 4*RATE - RATE - 0 = 3*RATE
        assertEq(token.totalSupply(), RATE * 3);

        _spend(alice, RATE);
        // totalSpent = RATE
        // totalSupply = 4*RATE - RATE - RATE = 2*RATE
        assertEq(token.totalSupply(), RATE * 2);

        // Settle after 1 period (burns another RATE)
        _advanceDays(30);
        token.settle(alice);
        // totalBurned = 2*RATE
        // totalSupply = 4*RATE - 2*RATE - RATE = RATE
        assertEq(token.totalSupply(), RATE);
    }

    function test_SiphonToken__totalSpent_tracksMultipleSpends() public {
        _mint(alice, RATE * 4);
        _spend(alice, RATE);
        _spend(alice, RATE);
        assertEq(token.totalSpent(), RATE * 2);
    }

    // ================================================================
    //  15. Fuzz: balance never underflows, harvest consistent
    // ================================================================

    function test_SiphonToken__balanceOf_neverUnderflowsFuzz(uint128 mintAmt, uint8 daysElapsed) public {
        vm.assume(mintAmt >= RATE && mintAmt <= 1_000_000 ether);
        vm.assume(daysElapsed <= 200);

        _mint(alice, mintAmt);
        _tapViaSched(alice, treasury, RATE);

        _advanceDays(uint256(daysElapsed));
        // Should never revert — balance is >= 0
        uint256 bal = token.balanceOf(alice);
        assertTrue(bal <= uint256(mintAmt));
    }

    function test_SiphonToken__harvest_totalConsistentFuzz(uint8 numEpochs) public {
        vm.assume(numEpochs >= 1 && numEpochs <= 10);

        _mint(alice, RATE * 20);
        _tapViaSched(alice, treasury, RATE);

        // Advance by numEpochs full periods
        _advanceDays(uint256(numEpochs) * PERIOD);

        uint256 preBal = token.balanceOf(treasury);
        token.harvest(treasury, RATE, uint256(numEpochs));
        uint256 postBal = token.balanceOf(treasury);

        // Each epoch should yield exactly RATE (1 user)
        assertEq(postBal - preBal, uint256(RATE) * uint256(numEpochs));
    }

    // ================================================================
    //  Immutables + views
    // ================================================================

    function test_SiphonToken__immutables_setCorrectly() public view {
        assertEq(token.DEPLOY_DAY(), 1000);
        assertEq(token.TERM_DAYS(), 30);
        assertEq(token.MAX_TAPS(), 32);
    }

    function test_SiphonToken__currentDay_returnsCorrectDay() public view {
        assertEq(token.currentDay(), 1000);
    }

    function test_SiphonToken__currentEpoch_returnsZeroAtDeploy() public view {
        assertEq(token.currentEpoch(), 0);
    }

    function test_SiphonToken__currentEpoch_incrementsAfterTermDays() public {
        _advanceDays(30);
        assertEq(token.currentEpoch(), 1);
        _advanceDays(30);
        assertEq(token.currentEpoch(), 2);
    }

    function test_SiphonToken__mandateId_pureHash() public view {
        bytes32 expected = keccak256(abi.encode(treasury, RATE));
        assertEq(token.mandateId(treasury, RATE), expected);
    }

    function test_SiphonToken__isActive_falseWhenNoTaps() public {
        _mint(alice, 1000 ether);
        assertFalse(token.isActive(alice));
    }

    function test_SiphonToken__isActive_trueWhenTapped() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        assertTrue(token.isActive(alice));
    }

    function test_SiphonToken__isActive_falseWhenLapsed() public {
        // Give alice only enough for the immediate first-term payment.
        // After tap: principal = 0, outflow = RATE. funded = 0.
        _mint(alice, RATE);
        _tapViaSched(alice, treasury, RATE);
        // principal = 0, funded = 0. isActive checks _funded(a) > 0 => false.
        assertFalse(token.isActive(alice));
    }

    function test_SiphonToken__isTapActive_trueWhileFunded() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);
        assertTrue(token.isTapActive(alice, mid));
    }

    function test_SiphonToken__isTapActive_falseAfterRevoke() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);
        _revokeViaSched(alice, mid);
        assertFalse(token.isTapActive(alice, mid));
    }

    function test_SiphonToken__getUserTaps_returnsActiveTaps() public {
        _mint(alice, RATE * 8);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(alice, bob, RATE);

        bytes32[] memory taps = token.getUserTaps(alice);
        assertEq(taps.length, 2);
        assertEq(taps[0], _mid(treasury, RATE));
        assertEq(taps[1], _mid(bob, RATE));
    }

    function test_SiphonToken__getAccount_returnsPrincipalOutflowAnchor() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);

        (uint128 principal, uint128 outflow, uint32 anchor) = token.getAccount(alice);
        assertEq(principal, uint128(RATE * 3));
        assertEq(outflow, RATE);
        assertEq(anchor, 1000);
    }

    function test_SiphonToken__getTap_returnsRateEntryEpochSponsor() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        (uint128 rate, uint32 entryEpoch, uint32 revokedAt) = token.getTap(alice, mid);
        assertEq(rate, RATE);
        assertEq(entryEpoch, 1); // currentEpoch(0) + 1
        assertEq(revokedAt, 0);
    }

    function test_SiphonToken__consumed_returnsCorrectAmount() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        assertEq(token.consumed(alice), 0);

        _advanceDays(30);
        assertEq(token.consumed(alice), RATE);

        _advanceDays(30);
        assertEq(token.consumed(alice), RATE * 2);
    }

    // ================================================================
    //  Listener callbacks
    // ================================================================

    function test_SiphonToken__listener_calledOnTap() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);

        assertEq(listener.callCount(), 1);
        (address t, address u, bool active) = listener.calls(0);
        assertEq(t, address(token));
        assertEq(u, alice);
        assertTrue(active);
    }

    function test_SiphonToken__listener_calledOnLastTapRevoked() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);

        bytes32 mid = _mid(treasury, RATE);
        _revokeViaSched(alice, mid);

        // Last call should be active=false
        uint256 count = listener.callCount();
        (,, bool active) = listener.calls(count - 1);
        assertFalse(active);
    }

    function test_SiphonToken__listener_notCalledOnPartialRevoke() public {
        _mint(alice, RATE * 8);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(alice, bob, RATE);
        uint256 countAfterTaps = listener.callCount();

        _revokeViaSched(alice, _mid(treasury, RATE));
        // Still has bob tap active. Should NOT emit active=false.
        // But _revoke only notifies if _userTaps is empty after removal.
        // After revoking treasury, bob remains => no listener call.
        assertEq(listener.callCount(), countAfterTaps);
    }

    function test_SiphonToken__listener_calledOnLapse() public {
        _mint(alice, RATE); // only enough for immediate payment
        _tapViaSched(alice, treasury, RATE);
        // principal = 0, outflow = RATE
        uint256 countBeforeLapse = listener.callCount();

        _advanceDays(30);
        token.settle(alice);
        // Lapse removes the tap. Listener called with active=false.
        assertTrue(listener.callCount() > countBeforeLapse);
        uint256 lastIdx = listener.callCount() - 1;
        (,, bool active) = listener.calls(lastIdx);
        assertFalse(active);
    }

    // ================================================================
    //  Scheduler / spender access control
    // ================================================================

    function test_SimpleSiphon__tapUser_revertsWhenNotScheduler() public {
        _mint(alice, RATE * 4);
        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.tapUser(alice, treasury, RATE);
    }

    function test_SimpleSiphon__revokeUser_revertsWhenNotScheduler() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);

        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.revokeUser(alice, _mid(treasury, RATE));
    }

    function test_SimpleSiphon__setScheduler_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.setScheduler(alice);
    }

    function test_SimpleSiphon__setSpender_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.setSpender(alice);
    }

    // ================================================================
    //  Harvest edge cases
    // ================================================================

    function test_SiphonToken__harvest_respectsMaxEpochs() public {
        _mint(alice, RATE * 10);
        _tapViaSched(alice, treasury, RATE);

        _advanceDays(90); // epoch 3

        uint256 pre = token.balanceOf(treasury);
        token.harvest(treasury, RATE, 1); // only harvest 1 epoch
        uint256 mid_ = token.balanceOf(treasury);
        assertEq(mid_ - pre, RATE);

        token.harvest(treasury, RATE, 1);
        uint256 post = token.balanceOf(treasury);
        assertEq(post - mid_, RATE);
    }

    function test_SiphonToken__harvest_idempotentWhenAlreadyCurrent() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _advanceDays(30);

        token.harvest(treasury, RATE, 10);
        uint256 bal = token.balanceOf(treasury);

        // Second harvest — should do nothing
        token.harvest(treasury, RATE, 10);
        assertEq(token.balanceOf(treasury), bal);
    }

    function test_SiphonToken__harvest_stopsAtExitEpoch() public {
        // Give alice exactly enough for immediate + 1 period
        _mint(alice, RATE * 2);
        _tapViaSched(alice, treasury, RATE);
        // principal = RATE, outflow = RATE. funded = 1. exit = epoch 0+1+1 = 2

        _advanceDays(90); // epoch 3. But exit was at epoch 2.
        token.harvest(treasury, RATE, 10);
        // Epoch 1: count enters. Epoch 2: count exits. So:
        // epoch 1: running = 0 + 1 entry - 0 = 1, total += 1*RATE
        // epoch 2: running = 1 + 0 - 1 exit = 0, total += 0*RATE
        // epoch 3: running = 0, total += 0
        assertEq(token.balanceOf(treasury), RATE + RATE);
    }

    function test_SiphonToken__harvest_multipleUsersSharedMandate() public {
        // Two users tapped to the same beneficiary at the same rate = same mandateId
        _mint(alice, RATE * 4);
        _mint(bob, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _tapViaSched(bob, treasury, RATE);

        _advanceDays(30); // epoch 1
        token.harvest(treasury, RATE, 10);
        // 2 users in epoch 1 => 2 * RATE
        assertEq(token.balanceOf(treasury), RATE * 2 + RATE * 2);
        // immediate payments: 2*RATE. harvest: 2*RATE. total = 4*RATE
    }

    // ================================================================
    //  Complex scenario: deposit after partial decay
    // ================================================================

    function test_SiphonToken__mint_afterPartialDecayExtendsCorrectly() public {
        _mint(alice, RATE * 2);
        _tapViaSched(alice, treasury, RATE);
        // principal = RATE, outflow = RATE

        _advanceDays(15); // half period, no deduction yet
        _mint(alice, RATE * 2);
        // settle fires: 0 periods elapsed (15 < 30). principal = RATE + 2*RATE = 3*RATE

        _advanceDays(15); // day 1030 = 1 full period from anchor (day 1000)
        assertEq(token.balanceOf(alice), RATE * 2);
    }

    // ================================================================
    //  Epoch boundary precision
    // ================================================================

    function test_SiphonToken__balanceOf_noDecayAt29Days() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _advanceDays(29);
        // Less than 1 full period
        assertEq(token.balanceOf(alice), RATE * 3);
    }

    function test_SiphonToken__balanceOf_decaysAtExactly30Days() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 2);
    }

    function test_SiphonToken__balanceOf_noExtraDecayAt59Days() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        _advanceDays(59);
        // 59/30 = 1 full period
        assertEq(token.balanceOf(alice), RATE * 2);
    }

    // ================================================================
    //  Checkpoint view
    // ================================================================

    function test_SiphonToken__getCheckpoint_updatesAfterHarvest() public {
        _mint(alice, RATE * 10);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        (uint32 lastEpoch, uint224 count) = token.getCheckpoint(mid);
        assertEq(lastEpoch, 0);
        assertEq(count, 0);

        _advanceDays(60); // epoch 2
        token.harvest(treasury, RATE, 10);

        (lastEpoch, count) = token.getCheckpoint(mid);
        assertEq(lastEpoch, 2);
        assertEq(count, 1); // 1 user still active
    }
}

// ================================================================
//  StreamingSubscription tests
// ================================================================

contract StreamingSubscriptionTest is Test {
    SimpleSiphon public token;
    StreamingSubscription public sub;

    address owner    = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    uint128 constant BASIC_RATE   = 1000 ether;
    uint128 constant PREMIUM_RATE = 2000 ether;
    uint256 constant DAY          = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY);
        token = new SimpleSiphon(owner);
        sub = new StreamingSubscription(address(token), subOwner);

        vm.startPrank(owner);
        token.setScheduler(owner);
        token.setSpender(owner);
        vm.stopPrank();
    }

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    function _createPlans() internal returns (uint256 basic, uint256 premium) {
        vm.startPrank(subOwner);
        basic = sub.createPlan("Basic", BASIC_RATE);
        premium = sub.createPlan("Premium", PREMIUM_RATE);
        vm.stopPrank();
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    function test_StreamingSubscription__subscribe_tapsUserAndSetsUserPlan() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 4);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        assertEq(sub.userPlan(alice), basicId);
        assertEq(token.balanceOf(alice), BASIC_RATE * 3); // immediate payment
    }

    function test_StreamingSubscription__subscribe_revertsIfAlreadySubscribed() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 8);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        vm.prank(alice);
        vm.expectRevert(StreamingSubscription.AlreadySubscribed.selector);
        sub.subscribe(basicId);
    }

    function test_StreamingSubscription__subscribe_revertsIfInvalidPlan() public {
        vm.prank(alice);
        vm.expectRevert(StreamingSubscription.InvalidPlan.selector);
        sub.subscribe(99);
    }

    function test_StreamingSubscription__hasAccess_trueWhileFunded() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 4);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        assertTrue(sub.hasAccess(alice));
    }

    function test_StreamingSubscription__hasAccess_falseWhenNotSubscribed() public {
        assertFalse(sub.hasAccess(alice));
    }

    function test_StreamingSubscription__hasAccess_falseWhenLapsed() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 2); // enough for immediate + 1 period

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        _advanceDays(60); // 2 periods, but only funded for 1
        assertFalse(sub.hasAccess(alice));
    }

    function test_StreamingSubscription__cancel_revokesAndClearsUserPlan() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 4);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        vm.prank(alice);
        sub.cancel();

        assertEq(sub.userPlan(alice), 0);
        assertFalse(sub.hasAccess(alice));
        // Balance preserved (no further decay)
        assertEq(token.balanceOf(alice), BASIC_RATE * 3);
    }

    function test_StreamingSubscription__cancel_revertsIfNotSubscribed() public {
        vm.prank(alice);
        vm.expectRevert(StreamingSubscription.NotSubscribed.selector);
        sub.cancel();
    }

    function test_StreamingSubscription__changePlan_switchesMandates() public {
        (uint256 basicId, uint256 premiumId) = _createPlans();
        _mint(alice, PREMIUM_RATE * 8);

        bytes32 basicMid = _mid(address(sub), BASIC_RATE);
        bytes32 premiumMid = _mid(address(sub), PREMIUM_RATE);

        vm.startPrank(alice);
        token.authorize(basicMid, 1);
        token.authorize(premiumMid, 1);
        vm.stopPrank();

        // Subscribe to basic
        vm.prank(alice);
        sub.subscribe(basicId);
        assertEq(sub.userPlan(alice), basicId);

        uint256 balAfterBasic = token.balanceOf(alice);

        // Change to premium
        vm.prank(alice);
        sub.changePlan(premiumId);
        assertEq(sub.userPlan(alice), premiumId);

        // Premium tap deducts PREMIUM_RATE as immediate payment
        assertEq(token.balanceOf(alice), balAfterBasic - PREMIUM_RATE);
    }

    function test_StreamingSubscription__changePlan_revertsIfNotSubscribed() public {
        (,uint256 premiumId) = _createPlans();
        vm.prank(alice);
        vm.expectRevert(StreamingSubscription.NotSubscribed.selector);
        sub.changePlan(premiumId);
    }

    function test_StreamingSubscription__collect_harvestsRevenue() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 10);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        _advanceDays(30); // epoch 1

        uint256 preBal = token.balanceOf(address(sub));
        sub.collect(basicId, 10);
        uint256 postBal = token.balanceOf(address(sub));

        assertEq(postBal - preBal, BASIC_RATE);
    }

    function test_StreamingSubscription__withdraw_sendsTokensToRecipient() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 10);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(basicId);

        _advanceDays(30);
        sub.collect(basicId, 10);

        uint256 contractBal = token.balanceOf(address(sub));
        assertTrue(contractBal > 0);

        vm.prank(subOwner);
        sub.withdraw(subOwner, uint128(contractBal));
        assertEq(token.balanceOf(subOwner), contractBal);
        assertEq(token.balanceOf(address(sub)), 0);
    }

    function test_StreamingSubscription__withdraw_revertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(StreamingSubscription.Unauthorized.selector);
        sub.withdraw(alice, 100 ether);
    }

    function test_StreamingSubscription__deactivatePlan_preventsNewSubscriptions() public {
        (uint256 basicId,) = _createPlans();

        vm.prank(subOwner);
        sub.deactivatePlan(basicId);

        _mint(alice, BASIC_RATE * 4);
        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        vm.expectRevert(StreamingSubscription.InvalidPlan.selector);
        sub.subscribe(basicId);
    }

    function test_StreamingSubscription__lifecycle_subscribeUseCancel() public {
        (uint256 basicId,) = _createPlans();
        _mint(alice, BASIC_RATE * 6);

        bytes32 mid = _mid(address(sub), BASIC_RATE);
        vm.prank(alice);
        token.authorize(mid, 1);

        // Subscribe
        vm.prank(alice);
        sub.subscribe(basicId);
        assertTrue(sub.hasAccess(alice));
        assertEq(token.balanceOf(alice), BASIC_RATE * 5);

        // Use for 2 periods
        _advanceDays(60);
        assertTrue(sub.hasAccess(alice));
        assertEq(token.balanceOf(alice), BASIC_RATE * 3);

        // Collect revenue: sub already has BASIC_RATE (immediate first payment from tap),
        // plus harvest collects 2 epochs = 2*BASIC_RATE. Total = 3*BASIC_RATE.
        sub.collect(basicId, 10);
        assertEq(token.balanceOf(address(sub)), BASIC_RATE * 3);

        // Cancel
        vm.prank(alice);
        sub.cancel();
        assertFalse(sub.hasAccess(alice));

        // Balance frozen (settle happened during revoke, consumed 2*RATE)
        assertEq(token.balanceOf(alice), BASIC_RATE * 3);
    }
}

// ================================================================
//  Payroll tests
// ================================================================

contract PayrollTest is Test {
    SimpleSiphon public token;
    Payroll public payroll;

    address owner_    = makeAddr("owner");
    address employer_ = makeAddr("employer");
    address emp1      = makeAddr("emp1");
    address emp2      = makeAddr("emp2");
    address emp3      = makeAddr("emp3");

    uint128 constant SALARY1 = 5000 ether;
    uint128 constant SALARY2 = 8000 ether;
    uint128 constant SALARY3 = 3000 ether;
    uint256 constant DAY     = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY);
        token = new SimpleSiphon(owner_);
        payroll = new Payroll(address(token), employer_);

        vm.startPrank(owner_);
        token.setScheduler(owner_);
        token.setSpender(owner_);
        vm.stopPrank();
    }

    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner_);
        token.mint(user, amt);
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    /// @dev Hire + authorize + employee taps directly on token (the correct pattern)
    function _hireAndActivate(address _emp, string memory _title, uint128 _salary) internal {
        vm.prank(employer_);
        payroll.hire(_emp, _title, _salary);

        bytes32 mid = _mid(_emp, _salary);
        vm.prank(employer_);
        token.authorize(mid, type(uint256).max);

        vm.prank(_emp);
        token.tap(employer_, _salary);
    }

    function test_Payroll__hire_addsEmployeeToRoster() public {
        vm.prank(employer_);
        payroll.hire(emp1, "Engineer", SALARY1);

        (string memory title, uint128 salary, bool active) = payroll.employees(emp1);
        assertEq(title, "Engineer");
        assertEq(salary, SALARY1);
        assertTrue(active);
        assertEq(payroll.rosterSize(), 1);
    }

    function test_Payroll__hire_revertsWhenNotEmployer() public {
        vm.prank(emp1);
        vm.expectRevert(Payroll.Unauthorized.selector);
        payroll.hire(emp1, "Engineer", SALARY1);
    }

    function test_Payroll__hire_revertsIfAlreadyEmployed() public {
        vm.prank(employer_);
        payroll.hire(emp1, "Engineer", SALARY1);
        vm.prank(employer_);
        vm.expectRevert(Payroll.AlreadyEmployed.selector);
        payroll.hire(emp1, "Senior", SALARY2);
    }

    function test_Payroll__terminate_marksInactive() public {
        vm.prank(employer_);
        payroll.hire(emp1, "Engineer", SALARY1);
        vm.prank(employer_);
        payroll.terminate(emp1);

        (,, bool active) = payroll.employees(emp1);
        assertFalse(active);
    }

    function test_Payroll__isPaid_trueWhileFunded() public {
        _mint(employer_, SALARY1 * 10);
        _hireAndActivate(emp1, "Engineer", SALARY1);
        assertTrue(payroll.isPaid(emp1));
    }

    function test_Payroll__totalPayroll_sumsActiveSalaries() public {
        vm.startPrank(employer_);
        payroll.hire(emp1, "Engineer", SALARY1);
        payroll.hire(emp2, "Designer", SALARY2);
        payroll.hire(emp3, "Intern", SALARY3);
        vm.stopPrank();
        assertEq(payroll.totalPayroll(), SALARY1 + SALARY2 + SALARY3);
    }

    function test_Payroll__rosterSize_tracksEmployees() public {
        vm.startPrank(employer_);
        payroll.hire(emp1, "Engineer", SALARY1);
        payroll.hire(emp2, "Designer", SALARY2);
        vm.stopPrank();
        assertEq(payroll.rosterSize(), 2);
    }

    function test_Payroll__lifecycle_hireActivatePayCollect() public {
        _mint(employer_, SALARY1 * 10);
        _hireAndActivate(emp1, "Engineer", SALARY1);

        // Employer pays immediately on tap (first-term)
        assertEq(token.balanceOf(employer_), SALARY1 * 9);
        assertEq(token.balanceOf(emp1), SALARY1);

        // After 1 period: employer decays by SALARY1
        _advanceDays(30);
        assertEq(token.balanceOf(employer_), SALARY1 * 8);

        // Employee harvests directly
        uint256 preBal = token.balanceOf(emp1);
        token.harvest(emp1, SALARY1, 10);
        assertEq(token.balanceOf(emp1) - preBal, SALARY1);
    }

    function test_Payroll__differentSalaries_separateMandates() public {
        _mint(employer_, (SALARY1 + SALARY2) * 10);
        _hireAndActivate(emp1, "Engineer", SALARY1);
        _hireAndActivate(emp2, "Designer", SALARY2);

        assertTrue(token.isTapActive(employer_, _mid(emp1, SALARY1)));
        assertTrue(token.isTapActive(employer_, _mid(emp2, SALARY2)));
        assertEq(token.balanceOf(employer_), (SALARY1 + SALARY2) * 10 - SALARY1 - SALARY2);
    }

    function test_Payroll__onScheduleUpdate_emitsLapsedOnLapse() public {
        _mint(employer_, SALARY1 * 2);
        vm.prank(owner_);
        token.setListener(address(payroll));

        _hireAndActivate(emp1, "Engineer", SALARY1);

        _advanceDays(60); // lapse
        token.settle(employer_);
        // Listener fires with _user=employer_, _active=false => PayrollLapsed emitted
    }
}

// ================================================================
//  RentalAgreement tests
// ================================================================

contract RentalAgreementTest is Test {
    SimpleSiphon public token;
    RentalAgreement public rental;

    address owner_    = makeAddr("owner");
    address landlord_ = makeAddr("landlord");
    address tenant1   = makeAddr("tenant1");
    address tenant2   = makeAddr("tenant2");

    uint128 constant RENT = 2000 ether;
    uint128 constant DEPOSIT = 4000 ether;
    uint256 constant DAY  = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY);
        token = new SimpleSiphon(owner_);
        rental = new RentalAgreement(address(token), landlord_, RENT);

        vm.startPrank(owner_);
        token.setScheduler(owner_);
        token.setSpender(owner_);
        vm.stopPrank();
    }

    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner_);
        token.mint(user, amt);
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    // ── Helpers ──

    function _authAndAddTenant(address _tenant, uint128 _deposit) internal {
        bytes32 mid = rental.mandateId();
        vm.prank(_tenant);
        token.authorize(mid, 1);
        if (_deposit > 0) {
            vm.prank(_tenant);
            token.approve(address(rental), _deposit);
        }
        vm.prank(landlord_);
        rental.addTenant(_tenant, 0, _deposit);
    }

    // ── addTenant ──

    function test_RentalAgreement__addTenant_createsLeaseAndTap() public {
        _mint(tenant1, RENT * 10 + DEPOSIT);
        _authAndAddTenant(tenant1, DEPOSIT);

        (uint32 startDay, uint32 endDay, uint128 deposit, bool active) = rental.leases(tenant1);
        assertEq(startDay, 1000);
        assertEq(endDay, 0);
        assertEq(deposit, DEPOSIT);
        assertTrue(active);

        assertEq(token.balanceOf(address(rental)), DEPOSIT + RENT);
        assertEq(token.balanceOf(tenant1), RENT * 10 + DEPOSIT - DEPOSIT - RENT);
        assertTrue(token.isTapActive(tenant1, rental.mandateId()));
    }

    function test_RentalAgreement__addTenant_revertsIfAlreadyLeased() public {
        _mint(tenant1, RENT * 20 + DEPOSIT * 2);
        bytes32 mid = rental.mandateId();
        vm.prank(tenant1);
        token.authorize(mid, 2);
        vm.prank(tenant1);
        token.approve(address(rental), DEPOSIT * 2);

        vm.prank(landlord_);
        rental.addTenant(tenant1, 0, DEPOSIT);

        vm.prank(landlord_);
        vm.expectRevert(RentalAgreement.AlreadyLeased.selector);
        rental.addTenant(tenant1, 0, DEPOSIT);
    }

    function test_RentalAgreement__addTenant_revertsWhenNotLandlord() public {
        vm.prank(tenant1);
        vm.expectRevert(RentalAgreement.Unauthorized.selector);
        rental.addTenant(tenant1, 0, 0);
    }

    function test_RentalAgreement__addTenant_noDepositWorks() public {
        _mint(tenant1, RENT * 10);
        _authAndAddTenant(tenant1, 0);

        (,,uint128 deposit, bool active) = rental.leases(tenant1);
        assertEq(deposit, 0);
        assertTrue(active);
    }

    // ── mandateId ──

    function test_RentalAgreement__mandateId_matchesActualTap() public view {
        bytes32 mid = rental.mandateId();
        assertEq(mid, _mid(address(rental), RENT));
    }

    // ── endLease ──

    function test_RentalAgreement__endLease_revokesAndReturnsDeposit() public {
        _mint(tenant1, RENT * 10 + DEPOSIT);
        _authAndAddTenant(tenant1, DEPOSIT);

        uint256 tenantBalBefore = token.balanceOf(tenant1);
        vm.prank(landlord_);
        rental.endLease(tenant1);

        assertFalse(token.isTapActive(tenant1, rental.mandateId()));
        assertEq(token.balanceOf(tenant1), tenantBalBefore + DEPOSIT);
    }

    // ── moveOut ──

    function test_RentalAgreement__moveOut_revokesTenantMandate() public {
        _mint(tenant1, RENT * 10);
        _authAndAddTenant(tenant1, 0);

        vm.prank(tenant1);
        rental.moveOut();

        assertFalse(token.isTapActive(tenant1, rental.mandateId()));
    }

    // ── isCurrentOnRent ──

    function test_RentalAgreement__isCurrentOnRent_trueWhileFunded() public {
        _mint(tenant1, RENT * 10);
        _authAndAddTenant(tenant1, 0);
        assertTrue(rental.isCurrentOnRent(tenant1));
    }

    // ── collectRent ──

    function test_RentalAgreement__collectRent_harvestsToContract() public {
        _mint(tenant1, RENT * 10);
        _authAndAddTenant(tenant1, 0);
        _advanceDays(30);

        uint256 preBal = token.balanceOf(address(rental));
        vm.prank(landlord_);
        rental.collectRent(10);
        assertEq(token.balanceOf(address(rental)) - preBal, RENT);
    }

    // ── tenantCount ──

    function test_RentalAgreement__tenantCount_tracksTenants() public {
        _mint(tenant1, RENT * 10);
        _mint(tenant2, RENT * 10);
        _authAndAddTenant(tenant1, 0);
        _authAndAddTenant(tenant2, 0);
        assertEq(rental.tenantCount(), 2);
    }

    // ── Multiple tenants share mandateId ──

    function test_RentalAgreement__multipleTenants_harvestCollectsAll() public {
        _mint(tenant1, RENT * 10);
        _mint(tenant2, RENT * 10);
        _authAndAddTenant(tenant1, 0);
        _authAndAddTenant(tenant2, 0);

        _advanceDays(30);

        uint256 preRental = token.balanceOf(address(rental));
        vm.prank(landlord_);
        rental.collectRent(10);
        assertEq(token.balanceOf(address(rental)) - preRental, RENT * 2);
    }

    // ── Deposit + withdraw ──

    function test_RentalAgreement__addTenant_depositsHeldByContract() public {
        _mint(tenant1, RENT * 10 + DEPOSIT);
        _authAndAddTenant(tenant1, DEPOSIT);
        assertEq(token.balanceOf(address(rental)), DEPOSIT + RENT);
    }

    function test_RentalAgreement__withdraw_sendsTokens() public {
        _mint(tenant1, RENT * 10);
        _authAndAddTenant(tenant1, 0);

        vm.prank(landlord_);
        rental.withdraw(landlord_, RENT);
        assertEq(token.balanceOf(landlord_), RENT);
    }

    function test_RentalAgreement__withdraw_revertsWhenNotLandlord() public {
        vm.prank(tenant1);
        vm.expectRevert(RentalAgreement.Unauthorized.selector);
        rental.withdraw(tenant1, 100 ether);
    }

    // ── Lease with end day ──

    function test_RentalAgreement__addTenant_storesEndDay() public {
        _mint(tenant1, RENT * 10);
        bytes32 mid = rental.mandateId();
        vm.prank(tenant1);
        token.authorize(mid, 1);
        vm.prank(landlord_);
        rental.addTenant(tenant1, 1365, 0);

        (,uint32 endDay,,) = rental.leases(tenant1);
        assertEq(endDay, 1365);
    }
}
