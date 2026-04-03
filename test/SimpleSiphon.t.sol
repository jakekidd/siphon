// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SimpleSiphon} from "../src/token/example/SimpleSiphon.sol";
import {StreamingSubscription} from "../src/token/example/StreamingSubscription.sol";
import {Payroll} from "../src/token/example/Payroll.sol";
import {RentalAgreement} from "../src/token/example/RentalAgreement.sol";
import {Timeshare} from "../src/token/example/Timeshare.sol";
import {TimeshareEscrow} from "../src/token/example/TimeshareEscrow.sol";
import {DecayToken} from "../src/token/example/DecayToken.sol";
import {Vesting} from "../src/token/example/Vesting.sol";
import {ServiceCredit} from "../src/token/example/ServiceCredit.sol";
import {SiphonToken} from "../src/token/SiphonToken.sol";
import {IMandateListener} from "../src/token/interfaces/IMandateListener.sol";
import {Test} from "forge-std/Test.sol";

// ──────────────────────────────────────────────
// Mock listener
// ──────────────────────────────────────────────

contract MockListener is IMandateListener {
    struct Call {
        address token;
        address user;
        bool active;
    }

    Call[] public calls;

    function onMandateUpdate(address _token, address _user, bool _active) external {
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
        // Priority: budget=2*RATE. tap1 survives (2*RATE >= RATE). tap2 survives (2*RATE >= 2*RATE).
        //           tap3: 2*RATE < 3*RATE => lapsed.

        _mint(alice, RATE * 5);
        _tapViaSched(alice, treasury, RATE);   // first-tapped
        _tapViaSched(alice, bob, RATE);        // second
        _tapViaSched(alice, carol, RATE);      // third (lowest priority)
        // principal = 2*RATE, outflow = 3*RATE

        _advanceDays(30); // elapsed=1, funded=0 => lapse
        token.settle(alice);

        // settle: funded=0, con=0. elapsed(1) > funded(0) => _resolvePriority.
        // Principal preserved (no leak). tap3 lapsed. outflow reduced to 2*RATE.
        // funded = 2*RATE / 2*RATE = 1. Surviving taps get 1 funded period.

        bytes32[] memory taps = token.getUserTaps(alice);
        assertEq(taps.length, 2, "two taps should survive");
        assertEq(taps[0], _mid(treasury, RATE));
        assertEq(taps[1], _mid(bob, RATE));

        (uint128 principal, uint128 outflow,) = token.getAccount(alice);
        assertEq(principal, RATE * 2); // preserved, not drained
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
        assertEq(token.GENESIS_DAY(), 1000);
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

    function test_SiphonToken__getTap_returnsFields() public {
        _mint(alice, RATE * 4);
        _tapViaSched(alice, treasury, RATE);
        bytes32 mid = _mid(treasury, RATE);

        (uint128 rate, uint32 entryEpoch, uint32 exitEpoch) = token.getTap(alice, mid);
        assertEq(rate, RATE);
        assertEq(entryEpoch, 1); // currentEpoch(0) + 1
        assertTrue(exitEpoch > 0); // exit computed by _recomputeAllExits
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

// ================================================================
//  Timeshare tests
// ================================================================

contract TimeshareTest is Test {
    SimpleSiphon public token;
    Timeshare public ts;

    address owner_  = makeAddr("owner");
    address tsOwner = makeAddr("tsOwner");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address dave    = makeAddr("dave");

    uint128 constant RATE             = 3000 ether;
    uint16  constant TERMS_PER_SEASON = 12;
    uint16  constant DEADLINE_DAYS    = 30;
    uint256 constant DAY              = 86_400;
    // share = 3000 * 12 / 4 = 9000
    uint128 constant SHARE            = 9000 ether;

    function setUp() public {
        vm.warp(1000 * DAY);
        token = new SimpleSiphon(owner_);
        ts = new Timeshare(address(token), tsOwner);

        vm.startPrank(owner_);
        token.setScheduler(owner_);
        token.setSpender(owner_);
        vm.stopPrank();
    }

    // -- Helpers --

    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner_);
        token.mint(user, amt);
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    function _defaultMembers() internal view returns (address[] memory) {
        address[] memory m = new address[](4);
        m[0] = alice; m[1] = bob; m[2] = carol; m[3] = dave;
        return m;
    }

    function _createDefault() internal returns (uint256 agreementId) {
        vm.prank(tsOwner);
        agreementId = ts.create(RATE, TERMS_PER_SEASON, DEADLINE_DAYS, _defaultMembers());
    }

    function _fundMember(uint256 agreementId, address member) internal {
        vm.prank(member);
        token.approve(address(ts), SHARE);
        vm.prank(member);
        ts.fund(agreementId);
    }

    function _fundAll(uint256 agreementId) internal {
        address[] memory m = _defaultMembers();
        for (uint256 i; i < m.length; i++) {
            _mint(m[i], SHARE);
            _fundMember(agreementId, m[i]);
        }
    }

    // ================================================================
    //  1. Create
    // ================================================================

    function test_Timeshare__create_deploysEscrowAndStoresAgreement() public {
        uint256 id = _createDefault();
        assertEq(id, 1);

        (
            address escrow, uint128 rate, uint16 termsPerSeason,
            uint8 memberCount, uint8 fundedCount, uint32 activatedDay,
            uint32 fundingStartDay, uint16 fundingDeadlineDays,
            uint8 season, bool active
        ) = ts.agreements(id);

        assertTrue(escrow != address(0));
        assertEq(rate, RATE);
        assertEq(termsPerSeason, TERMS_PER_SEASON);
        assertEq(memberCount, 4);
        assertEq(fundedCount, 0);
        assertEq(activatedDay, 0);
        assertEq(fundingStartDay, 1000);
        assertEq(fundingDeadlineDays, DEADLINE_DAYS);
        assertEq(season, 0);
        assertFalse(active);

        // Escrow metadata
        TimeshareEscrow escrowContract = TimeshareEscrow(escrow);
        assertEq(escrowContract.rate(), RATE);
        assertEq(escrowContract.termsPerSeason(), TERMS_PER_SEASON);
        assertEq(escrowContract.memberCount(), 4);
        assertTrue(escrowContract.initialized());
        assertEq(escrowContract.totalRequired(), RATE * TERMS_PER_SEASON);
        assertEq(escrowContract.sharePerMember(), SHARE);
    }

    function test_Timeshare__create_storesMembers() public {
        uint256 id = _createDefault();
        address[] memory m = ts.getMembers(id);
        assertEq(m.length, 4);
        assertEq(m[0], alice);
        assertEq(m[1], bob);
        assertEq(m[2], carol);
        assertEq(m[3], dave);
    }

    function test_Timeshare__create_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Timeshare.Unauthorized.selector);
        ts.create(RATE, TERMS_PER_SEASON, DEADLINE_DAYS, _defaultMembers());
    }

    function test_Timeshare__create_revertsIfNotDivisible() public {
        // 3000 * 12 = 36000. 36000 % 7 != 0
        address[] memory m = new address[](7);
        for (uint256 i; i < 7; i++) m[i] = address(uint160(0xAA00 + i));

        vm.prank(tsOwner);
        vm.expectRevert(Timeshare.DivisibilityRequired.selector);
        ts.create(RATE, TERMS_PER_SEASON, DEADLINE_DAYS, m);
    }

    function test_Timeshare__create_revertsIfTooFewMembers() public {
        address[] memory m = new address[](1);
        m[0] = alice;

        vm.prank(tsOwner);
        vm.expectRevert(Timeshare.InvalidParams.selector);
        ts.create(RATE, TERMS_PER_SEASON, DEADLINE_DAYS, m);
    }

    // ================================================================
    //  2. Fund + Activate
    // ================================================================

    function test_Timeshare__fund_allMembersFundAndActivates() public {
        uint256 id = _createDefault();
        _fundAll(id);

        (address escrow,,,,,,,,uint8 season, bool active) = ts.agreements(id);
        assertTrue(active);
        assertEq(season, 1);

        // Escrow was tapped: immediate payment of RATE to Timeshare
        assertEq(token.balanceOf(address(ts)), RATE);
        // Escrow balance: total deposited - immediate = RATE * (TERMS_PER_SEASON - 1)
        assertEq(token.balanceOf(escrow), uint256(RATE) * (TERMS_PER_SEASON - 1));

        // Tap is active
        bytes32 mid = _mid(address(ts), RATE);
        assertTrue(token.isTapActive(escrow, mid));
    }

    function test_Timeshare__fund_revertsIfNonMember() public {
        uint256 id = _createDefault();
        address outsider = makeAddr("outsider");
        _mint(outsider, SHARE);

        vm.prank(outsider);
        vm.expectRevert(Timeshare.NotMember.selector);
        ts.fund(id);
    }

    function test_Timeshare__fund_revertsIfAlreadyFunded() public {
        uint256 id = _createDefault();
        _mint(alice, SHARE * 2);
        _fundMember(id, alice);

        vm.prank(alice);
        token.approve(address(ts), SHARE);
        vm.prank(alice);
        vm.expectRevert(Timeshare.AlreadyFunded.selector);
        ts.fund(id);
    }

    function test_Timeshare__fund_partialDoesNotActivate() public {
        uint256 id = _createDefault();
        _mint(alice, SHARE);
        _fundMember(id, alice);

        (,,,,uint8 fundedCount,,,,,bool active) = ts.agreements(id);
        assertEq(fundedCount, 1);
        assertFalse(active);
    }

    // ================================================================
    //  3. Escrow balance drains
    // ================================================================

    function test_Timeshare__escrowBalance_drainsCorrectlyOverTime() public {
        uint256 id = _createDefault();
        _fundAll(id);

        (address escrow,,,,,,,,,) = ts.agreements(id);

        // After 1 term
        _advanceDays(30);
        assertEq(token.balanceOf(escrow), uint256(RATE) * (TERMS_PER_SEASON - 2));

        // After full season (12 terms from anchor)
        _advanceDays(30 * (TERMS_PER_SEASON - 2)); // 10 more terms
        assertEq(token.balanceOf(escrow), 0);
    }

    // ================================================================
    //  4. Harvest
    // ================================================================

    function test_Timeshare__harvest_collectsCorrectRevenue() public {
        uint256 id = _createDefault();
        _fundAll(id);

        _advanceDays(90); // 3 terms

        uint256 preBal = token.balanceOf(address(ts));
        ts.harvest(RATE, 10);
        uint256 postBal = token.balanceOf(address(ts));

        // Immediate payment already gave RATE. Harvest collects 3 more epochs.
        assertEq(postBal - preBal, uint256(RATE) * 3);
    }

    // ================================================================
    //  5. Access rotation
    // ================================================================

    function test_Timeshare__hasAccess_roundRobinRotation() public {
        uint256 id = _createDefault();
        _fundAll(id);

        // Term 0: alice
        (bool active0, address m0) = ts.hasAccess(id);
        assertTrue(active0);
        assertEq(m0, alice);

        // Term 1: bob
        _advanceDays(30);
        (, address m1) = ts.hasAccess(id);
        assertEq(m1, bob);

        // Term 2: carol
        _advanceDays(30);
        (, address m2) = ts.hasAccess(id);
        assertEq(m2, carol);

        // Term 3: dave
        _advanceDays(30);
        (, address m3) = ts.hasAccess(id);
        assertEq(m3, dave);

        // Term 4: alice again
        _advanceDays(30);
        (, address m4) = ts.hasAccess(id);
        assertEq(m4, alice);
    }

    function test_Timeshare__hasAccess_falseWhenNotActive() public {
        uint256 id = _createDefault();
        (bool active,) = ts.hasAccess(id);
        assertFalse(active);
    }

    function test_Timeshare__memberHasAccess_correctForSpecificMember() public {
        uint256 id = _createDefault();
        _fundAll(id);

        assertTrue(ts.memberHasAccess(id, alice));
        assertFalse(ts.memberHasAccess(id, bob));

        _advanceDays(30);
        assertFalse(ts.memberHasAccess(id, alice));
        assertTrue(ts.memberHasAccess(id, bob));
    }

    // ================================================================
    //  6. Renew
    // ================================================================

    function test_Timeshare__renew_seasonEndsAndMembersReFund() public {
        uint256 id = _createDefault();
        _fundAll(id);

        // Advance full season + 1 term to trigger lapse
        _advanceDays(30 * (TERMS_PER_SEASON + 1));

        // Settle to finalize lapse
        (address escrow,,,,,,,,,) = ts.agreements(id);
        token.settle(escrow);

        ts.renew(id);

        (,,,,uint8 fundedCount,,,,uint8 season, bool active) = ts.agreements(id);
        assertEq(fundedCount, 0);
        assertFalse(active);
        assertEq(season, 1); // still 1 from first activation; renew doesn't increment

        // Fund again
        _fundAll(id);

        (,,,,,,,,uint8 newSeason, bool newActive) = ts.agreements(id);
        assertTrue(newActive);
        assertEq(newSeason, 2);
    }

    function test_Timeshare__renew_revertsIfStillActive() public {
        uint256 id = _createDefault();
        _fundAll(id);

        vm.expectRevert(Timeshare.StillActive.selector);
        ts.renew(id);
    }

    function test_Timeshare__renew_revertsIfNoSeason() public {
        uint256 id = _createDefault();
        vm.expectRevert(Timeshare.NoSeason.selector);
        ts.renew(id);
    }

    // ================================================================
    //  7. Reclaim funding
    // ================================================================

    function test_Timeshare__reclaimFunding_partialFundingDeadlinePassed() public {
        uint256 id = _createDefault();

        // Only alice and bob fund
        _mint(alice, SHARE);
        _fundMember(id, alice);
        _mint(bob, SHARE);
        _fundMember(id, bob);

        // Advance past deadline
        _advanceDays(DEADLINE_DAYS);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        ts.reclaimFunding(id);
        assertEq(token.balanceOf(alice) - aliceBefore, SHARE);

        assertTrue(ts.isFunded(id, bob));
        assertFalse(ts.isFunded(id, alice));
    }

    function test_Timeshare__reclaimFunding_revertsIfDeadlineNotPassed() public {
        uint256 id = _createDefault();
        _mint(alice, SHARE);
        _fundMember(id, alice);

        _advanceDays(DEADLINE_DAYS - 1);

        vm.prank(alice);
        vm.expectRevert(Timeshare.FundingOpen.selector);
        ts.reclaimFunding(id);
    }

    function test_Timeshare__reclaimFunding_revertsIfNotFunded() public {
        uint256 id = _createDefault();
        _advanceDays(DEADLINE_DAYS);

        vm.prank(alice);
        vm.expectRevert(Timeshare.NothingToReclaim.selector);
        ts.reclaimFunding(id);
    }

    // ================================================================
    //  8. Comp
    // ================================================================

    function test_Timeshare__comp_pausesBillingAndAccess() public {
        uint256 id = _createDefault();
        _fundAll(id);

        vm.prank(tsOwner);
        ts.comp(id, 1);

        // During comp: no access
        (bool active,) = ts.hasAccess(id);
        assertFalse(active);

        (address escrow,,,,,,,,,) = ts.agreements(id);
        assertTrue(token.isComped(escrow));

        // After comp ends: access resumes. termIndex = (1030-1000)/30 = 1 => bob
        _advanceDays(30);
        (bool activeAfter, address memberAfter) = ts.hasAccess(id);
        assertTrue(activeAfter);
        assertEq(memberAfter, bob); // term 1 (comp shifted billing, not rotation)
    }

    function test_Timeshare__comp_revertsIfNotOwner() public {
        uint256 id = _createDefault();
        _fundAll(id);

        vm.prank(alice);
        vm.expectRevert(Timeshare.Unauthorized.selector);
        ts.comp(id, 1);
    }

    // ================================================================
    //  9. Multiple agreements, same rate
    // ================================================================

    function test_Timeshare__multipleAgreementsSameRate_sharedHarvest() public {
        // Two agreements at the same rate
        uint256 id1 = _createDefault();
        _fundAll(id1);

        address[] memory m2 = new address[](2);
        m2[0] = makeAddr("e1"); m2[1] = makeAddr("e2");
        vm.prank(tsOwner);
        // rate * termsPerSeason must be divisible by 2: 3000 * 12 / 2 = 18000. OK.
        uint256 id2 = ts.create(RATE, TERMS_PER_SEASON, DEADLINE_DAYS, m2);

        uint128 share2 = uint128(uint256(RATE) * TERMS_PER_SEASON / 2);
        _mint(m2[0], share2);
        vm.prank(m2[0]); token.approve(address(ts), share2);
        vm.prank(m2[0]); ts.fund(id2);
        _mint(m2[1], share2);
        vm.prank(m2[1]); token.approve(address(ts), share2);
        vm.prank(m2[1]); ts.fund(id2);

        // Both active now. Immediate payments: 2 * RATE
        assertEq(token.balanceOf(address(ts)), RATE * 2);

        _advanceDays(30); // 1 term
        ts.harvest(RATE, 10);
        // Harvest from 2 escrows at epoch 1: 2 * RATE
        assertEq(token.balanceOf(address(ts)), RATE * 2 + RATE * 2);
    }

    // ================================================================
    //  10. Revoke mid-season
    // ================================================================

    function test_Timeshare__revokeAgreement_stopsBillingMidSeason() public {
        uint256 id = _createDefault();
        _fundAll(id);

        _advanceDays(90); // 3 terms

        (address escrow,,,,,,,,,) = ts.agreements(id);

        vm.prank(tsOwner);
        ts.revokeAgreement(id);

        (,,,,,,,,,bool active) = ts.agreements(id);
        assertFalse(active);

        // Balance frozen (settle happened during revoke, 3 periods consumed)
        uint256 balAfter = token.balanceOf(escrow);
        // After settle: principal - 3*RATE consumed. Then revoke stops drain.
        // Original: RATE * 11 (after immediate). After 3 periods: RATE * 8.
        assertEq(balAfter, uint256(RATE) * 8);

        // No further decay
        _advanceDays(30);
        assertEq(token.balanceOf(escrow), uint256(RATE) * 8);
    }

    function test_Timeshare__revokeAgreement_revertsIfNotOwner() public {
        uint256 id = _createDefault();
        _fundAll(id);

        vm.prank(alice);
        vm.expectRevert(Timeshare.Unauthorized.selector);
        ts.revokeAgreement(id);
    }

    function test_Timeshare__revokeAgreement_revertsIfNotActive() public {
        uint256 id = _createDefault();

        vm.prank(tsOwner);
        vm.expectRevert(Timeshare.NotActive.selector);
        ts.revokeAgreement(id);
    }

    // ================================================================
    //  11. Escrow access control
    // ================================================================

    function test_Timeshare__escrow_refundRevertsIfNotTimeshare() public {
        uint256 id = _createDefault();
        (address escrow,,,,,,,,,) = ts.agreements(id);

        vm.prank(alice);
        vm.expectRevert(TimeshareEscrow.Unauthorized.selector);
        TimeshareEscrow(escrow).refund(alice, 100 ether);
    }

    function test_Timeshare__escrow_setupRevertsIfNotTimeshare() public {
        uint256 id = _createDefault();
        (address escrow,,,,,,,,,) = ts.agreements(id);

        vm.prank(alice);
        vm.expectRevert(TimeshareEscrow.Unauthorized.selector);
        TimeshareEscrow(escrow).setup(1);
    }

    function test_Timeshare__escrow_initializeRevertsIfAlreadyInitialized() public {
        uint256 id = _createDefault();
        (address escrow,,,,,,,,,) = ts.agreements(id);

        // Even the timeshare can't re-initialize
        vm.prank(address(ts));
        vm.expectRevert(TimeshareEscrow.AlreadyInitialized.selector);
        TimeshareEscrow(escrow).initialize(1000, 6, 2);
    }

    // ================================================================
    //  12. Withdraw
    // ================================================================

    function test_Timeshare__withdraw_sendsTokensToRecipient() public {
        uint256 id = _createDefault();
        _fundAll(id);
        // Timeshare has RATE from immediate payment

        vm.prank(tsOwner);
        ts.withdraw(tsOwner, RATE);
        assertEq(token.balanceOf(tsOwner), RATE);
        assertEq(token.balanceOf(address(ts)), 0);
    }

    function test_Timeshare__withdraw_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Timeshare.Unauthorized.selector);
        ts.withdraw(alice, 100 ether);
    }

    // ================================================================
    //  13. MandateId consistency (avoid RentalAgreement bug)
    // ================================================================

    function test_Timeshare__mandateId_matchesBetweenTimeshareAndEscrow() public {
        uint256 id = _createDefault();
        (address escrow,,,,,,,,,) = ts.agreements(id);

        // The escrow's mandateId view should match what Timeshare uses
        bytes32 escrowMid = TimeshareEscrow(escrow).mandateId();
        bytes32 expected = _mid(address(ts), RATE);
        assertEq(escrowMid, expected);

        // After activation, the tap should be at this mandateId
        _fundAll(id);
        assertTrue(token.isTapActive(escrow, expected));
    }

    // ================================================================
    //  14. Full lifecycle: create, fund, drain, renew, re-fund
    // ================================================================

    function test_Timeshare__lifecycle_createFundDrainRenew() public {
        uint256 id = _createDefault();

        // Season 1: fund and activate
        _fundAll(id);
        assertTrue(ts.memberHasAccess(id, alice));

        (address escrow,,,,,,,,,) = ts.agreements(id);

        // Drain full season
        _advanceDays(30 * TERMS_PER_SEASON);
        assertEq(token.balanceOf(escrow), 0);

        // Harvest all revenue
        ts.harvest(RATE, 20);
        // Total: RATE (immediate) + 11 epochs harvested (entry at epoch 1, exit at epoch 12)
        assertEq(token.balanceOf(address(ts)), uint256(RATE) * TERMS_PER_SEASON);

        // Lapse: advance 1 more term past funded
        _advanceDays(30);
        token.settle(escrow);

        // Season 2: renew and re-fund
        ts.renew(id);
        _fundAll(id);

        (,,,,,,,,uint8 season, bool active) = ts.agreements(id);
        assertEq(season, 2);
        assertTrue(active);

        // Access resumes
        assertTrue(ts.memberHasAccess(id, alice));
    }

    // ================================================================
    //  15. Renew refunds leftover after mid-season revoke
    // ================================================================

    function test_Timeshare__renew_refundsLeftoverAfterRevoke() public {
        uint256 id = _createDefault();
        _fundAll(id);

        // Revoke after 3 terms
        _advanceDays(90);
        vm.prank(tsOwner);
        ts.revokeAgreement(id);

        (address escrow,,,,,,,,,) = ts.agreements(id);
        uint256 leftover = token.balanceOf(escrow);
        assertTrue(leftover > 0);

        // Track member balances before renew
        uint256 aliceBefore = token.balanceOf(alice);

        ts.renew(id);

        // Each member gets leftover / 4
        uint256 perMember = leftover / 4;
        assertEq(token.balanceOf(alice) - aliceBefore, perMember);
    }

    // ================================================================
    //  16. hasAccess returns false after season ends
    // ================================================================

    function test_Timeshare__hasAccess_falseAfterSeasonEnds() public {
        uint256 id = _createDefault();
        _fundAll(id);

        // Advance past termsPerSeason
        _advanceDays(30 * TERMS_PER_SEASON);

        (bool active,) = ts.hasAccess(id);
        assertFalse(active);
    }
}

// ================================================================
//  DecayToken tests
// ================================================================

contract DecayTokenTest is Test {
    DecayToken public token;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    uint128 constant DECAY_RATE = 100 ether;
    uint256 constant DAY        = 86_400;

    function setUp() public {
        _warpToDay(1000);
        // Deploy as owner so msg.sender == owner and token.owner() == owner
        vm.prank(owner);
        token = new DecayToken(30, DECAY_RATE);
    }

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    // ── mint applies burn tap and starts decay ──

    function test_DecayToken__mint_appliesBurnTapOnFirstMint() public {
        _mint(alice, DECAY_RATE * 5);

        // Burn mandate exists: mandateId(address(0), DECAY_RATE)
        bytes32 mid = keccak256(abi.encode(address(0), DECAY_RATE));
        assertTrue(token.isTapActive(alice, mid));
    }

    function test_DecayToken__mint_deductsFirstTermImmediately() public {
        _mint(alice, DECAY_RATE * 5);
        // First-term burn deducted on tap
        assertEq(token.balanceOf(alice), DECAY_RATE * 4);
    }

    // ── mint tops up existing holder (no new tap) ──

    function test_DecayToken__mint_topsUpExistingHolderWithoutNewTap() public {
        _mint(alice, DECAY_RATE * 3);
        uint256 balAfterFirst = token.balanceOf(alice);

        // Top up: should not revert (no duplicate tap), balance increases
        _mint(alice, DECAY_RATE * 2);
        assertEq(token.balanceOf(alice), balAfterFirst + DECAY_RATE * 2);
    }

    function test_DecayToken__mint_topUpExtendsRunway() public {
        _mint(alice, DECAY_RATE * 2);
        uint256 runwayBefore = token.runway(alice);

        _mint(alice, DECAY_RATE * 3);
        uint256 runwayAfter = token.runway(alice);

        assertTrue(runwayAfter > runwayBefore);
    }

    // ── runway returns correct terms ──

    function test_DecayToken__runway_returnsCorrectTerms() public {
        // Mint 5 terms worth; first term deducted immediately, so 4 remain
        _mint(alice, DECAY_RATE * 5);
        assertEq(token.runway(alice), 4);
    }

    function test_DecayToken__runway_returnsZeroWhenNoTap() public {
        assertEq(token.runway(alice), 0);
    }

    // ── balance decays over time ──

    function test_DecayToken__balanceOf_decaysOverTime() public {
        _mint(alice, DECAY_RATE * 5);
        uint256 balAfterMint = token.balanceOf(alice); // 4 terms remaining

        _advanceDays(30); // 1 term passes
        assertEq(token.balanceOf(alice), balAfterMint - DECAY_RATE);

        _advanceDays(30); // 2nd term
        assertEq(token.balanceOf(alice), balAfterMint - DECAY_RATE * 2);
    }

    function test_DecayToken__balanceOf_zeroWhenFullyDecayed() public {
        _mint(alice, DECAY_RATE * 2); // 1 term remaining after first deduction
        _advanceDays(30);
        assertEq(token.balanceOf(alice), 0);
    }

    // ── exempt removes burn mandate ──

    function test_DecayToken__exempt_removesBurnMandate() public {
        _mint(alice, DECAY_RATE * 5);

        vm.prank(owner);
        token.exempt(alice);

        bytes32 mid = keccak256(abi.encode(address(0), DECAY_RATE));
        assertFalse(token.isTapActive(alice, mid));
    }

    function test_DecayToken__exempt_freezesBalanceAfterRemoval() public {
        _mint(alice, DECAY_RATE * 5);
        uint256 balBeforeExempt = token.balanceOf(alice);

        vm.prank(owner);
        token.exempt(alice);

        _advanceDays(60); // 2 terms pass
        assertEq(token.balanceOf(alice), balBeforeExempt);
    }

    function test_DecayToken__exempt_revertsWhenNotOwner() public {
        _mint(alice, DECAY_RATE * 5);
        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.exempt(alice);
    }

    // ── full lifecycle: mint, decay, top up, exempt ──

    function test_DecayToken__lifecycle_mintDecayTopUpExempt() public {
        // Mint 4 terms worth; 3 remain after immediate deduction
        _mint(alice, DECAY_RATE * 4);
        assertEq(token.balanceOf(alice), DECAY_RATE * 3);

        // 1 term passes
        _advanceDays(30);
        assertEq(token.balanceOf(alice), DECAY_RATE * 2);
        // runway() reads stored principal (not yet settled) / outflow = 3 terms
        assertEq(token.runway(alice), 3);

        // Top up 2 more terms; runway extends
        _mint(alice, DECAY_RATE * 2);
        assertEq(token.runway(alice), 4);

        // 1 more term passes
        _advanceDays(30);
        assertEq(token.balanceOf(alice), DECAY_RATE * 3);

        // Owner exempts alice: balance freezes
        vm.prank(owner);
        token.exempt(alice);
        uint256 frozenBal = token.balanceOf(alice);

        _advanceDays(90);
        assertEq(token.balanceOf(alice), frozenBal);
        assertEq(token.runway(alice), 0);
    }
}

// ================================================================
//  Vesting tests
// ================================================================

// Note on Vesting contract design: activate() calls token.tap(grantor, rate)
// from inside the Vesting contract, making address(vesting) the beneficiary.
// The grantor must therefore authorize mandateId(address(vesting), rate).
// isVesting and collect use mandateId(recipient, rate), so they check a
// separate bucket. The full lifecycle test covers the correct integration path.

contract VestingTest is Test {
    SimpleSiphon public token;
    Vesting public vesting;

    address public owner    = makeAddr("owner");
    address public admin    = makeAddr("admin");
    address public grantor  = makeAddr("grantor");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");

    uint128 constant RATE  = 500 ether;
    uint32  constant TERMS = 6;
    uint256 constant DAY   = 86_400;

    function setUp() public {
        _warpToDay(1000);
        token   = new SimpleSiphon(owner);
        vesting = new Vesting(address(token), admin, grantor);

        vm.startPrank(owner);
        token.setScheduler(owner);
        token.setSpender(owner);
        vm.stopPrank();
    }

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mintGrantor(uint128 amt) internal {
        vm.prank(owner);
        token.mint(grantor, amt);
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    /// @dev Authorization the grantor needs to give before alice calls activate().
    ///      token.tap() inside activate() uses msg.sender (= vesting contract) as beneficiary.
    function _authVestingMid(uint256 count) internal {
        bytes32 mid = _mid(address(vesting), RATE);
        vm.prank(grantor);
        token.authorize(mid, count);
    }

    // ── createGrant stores grant ──

    function test_Vesting__createGrant_storesGrant() public {
        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        (address recipient, uint128 rate, uint32 terms, bool created) = vesting.grants(id);
        assertEq(recipient, alice);
        assertEq(rate, RATE);
        assertEq(terms, TERMS);
        assertTrue(created);
        assertEq(vesting.grantCount(), 1);
    }

    function test_Vesting__createGrant_revertsWhenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(Vesting.Unauthorized.selector);
        vesting.createGrant(alice, RATE, TERMS);
    }

    function test_Vesting__createGrant_revertsOnZeroRate() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidGrant.selector);
        vesting.createGrant(alice, 0, TERMS);
    }

    function test_Vesting__createGrant_revertsOnZeroTerms() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidGrant.selector);
        vesting.createGrant(alice, RATE, 0);
    }

    function test_Vesting__createGrant_revertsOnZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidGrant.selector);
        vesting.createGrant(address(0), RATE, TERMS);
    }

    // ── activate taps grantor and starts vesting ──

    function test_Vesting__activate_tapsGrantorAndMarksActivated() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        // Grantor must authorize mandateId(vesting, rate) since vesting is the tap caller
        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        assertTrue(vesting.activated(id));
        // Tap active for vesting-beneficiary mandate
        assertTrue(token.isTapActive(grantor, _mid(address(vesting), RATE)));
        // First term went to vesting contract immediately
        assertEq(token.balanceOf(address(vesting)), RATE);
    }

    function test_Vesting__activate_revertsWhenNotRecipient() public {
        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        vm.prank(bob);
        vm.expectRevert(Vesting.NotRecipient.selector);
        vesting.activate(id);
    }

    function test_Vesting__activate_revertsWhenAlreadyActivated() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        vm.prank(alice);
        vm.expectRevert(Vesting.AlreadyActivated.selector);
        vesting.activate(id);
    }

    function test_Vesting__activate_revertsWhenGrantorNotAuthorized() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        // No authorization given: should revert NotApproved
        vm.prank(alice);
        vm.expectRevert(SiphonToken.NotApproved.selector);
        vesting.activate(id);
    }

    // ── collect harvests and forwards to recipient ──

    function test_Vesting__collect_harvestsAndForwardsToRecipient() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        _advanceDays(30); // 1 epoch

        uint256 aliceBalBefore = token.balanceOf(alice);
        vesting.collect(id, 5);
        // Harvested 1 epoch of RATE, forwarded to alice
        assertEq(token.balanceOf(alice) - aliceBalBefore, RATE);
        // Vesting contract should have 0 (immediate payment from tap was already there,
        // but collect forwards everything harvested to recipient)
    }

    function test_Vesting__collect_noopWhenNothingToHarvest() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        // No time passed since activation, nothing to harvest
        uint256 aliceBalBefore = token.balanceOf(alice);
        vesting.collect(id, 5);
        assertEq(token.balanceOf(alice), aliceBalBefore);
    }

    // ── revokeGrant stops future vesting ──

    function test_Vesting__revokeGrant_stopsFutureVesting() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        bytes32 activeMid = _mid(address(vesting), RATE);
        assertTrue(token.isTapActive(grantor, activeMid));

        vm.prank(admin);
        vesting.revokeGrant(id);

        // Tap is now revoked
        assertFalse(token.isTapActive(grantor, activeMid));

        // Grantor balance frozen after revoke
        uint256 grantorBal = token.balanceOf(grantor);
        _advanceDays(30);
        assertEq(token.balanceOf(grantor), grantorBal);
    }

    function test_Vesting__revokeGrant_revertsWhenNotAdmin() public {
        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        vm.prank(alice);
        vm.expectRevert(Vesting.Unauthorized.selector);
        vesting.revokeGrant(id);
    }

    function test_Vesting__revokeGrant_revertsWhenNotActivated() public {
        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        vm.prank(admin);
        vm.expectRevert(Vesting.NotActivated.selector);
        vesting.revokeGrant(id);
    }

    // ── isVesting returns correct state ──

    function test_Vesting__isVesting_falseBeforeActivation() public {
        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);
        assertFalse(vesting.isVesting(id));
    }

    function test_Vesting__isVesting_trueAfterActivate() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        assertTrue(vesting.isVesting(id));
    }

    function test_Vesting__isVesting_falseAfterRevoke() public {
        _mintGrantor(RATE * (TERMS + 1));

        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);

        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);

        vm.prank(admin);
        vesting.revokeGrant(id);

        assertFalse(vesting.isVesting(id));
    }

    // ── multiple grants with priority ──

    function test_Vesting__multipleGrants_bothActivateSuccessfully() public {
        uint128 rateA = 300 ether;
        uint128 rateB = 200 ether;

        // Mint enough for both first-term payments plus several future terms
        _mintGrantor(rateA + rateB + (rateA + rateB) * 3);

        vm.startPrank(admin);
        uint256 idA = vesting.createGrant(alice, rateA, 3);
        uint256 idB = vesting.createGrant(bob, rateB, 3);
        vm.stopPrank();

        // Both streams use the vesting contract as beneficiary, so they need
        // separate authorizations using mandateId(vesting, rateA) and (vesting, rateB)
        bytes32 midA = _mid(address(vesting), rateA);
        bytes32 midB = _mid(address(vesting), rateB);

        vm.startPrank(grantor);
        token.authorize(midA, 1);
        token.authorize(midB, 1);
        vm.stopPrank();

        vm.prank(alice);
        vesting.activate(idA);

        vm.prank(bob);
        vesting.activate(idB);

        assertTrue(vesting.activated(idA));
        assertTrue(vesting.activated(idB));

        // Both taps active on grantor; balance drains from both
        assertTrue(token.isTapActive(grantor, midA));
        assertTrue(token.isTapActive(grantor, midB));
        assertTrue(vesting.fundedTerms() > 0);
    }

    // ── full lifecycle: create, activate, collect, revoke ──

    function test_Vesting__lifecycle_createActivateCollectRevoke() public {
        _mintGrantor(RATE * (TERMS + 1));

        // Create grant
        vm.prank(admin);
        uint256 id = vesting.createGrant(alice, RATE, TERMS);
        assertFalse(vesting.activated(id));
        assertFalse(vesting.isVesting(id));

        // Activate: grantor authorizes mandateId(vesting, RATE)
        _authVestingMid(1);

        vm.prank(alice);
        vesting.activate(id);
        assertTrue(vesting.activated(id));
        assertTrue(vesting.isVesting(id));

        // Immediate first payment goes to vesting contract
        assertEq(token.balanceOf(address(vesting)), RATE);

        // Collect 2 terms of vested tokens (harvest + forward to alice)
        _advanceDays(60);
        uint256 aliceBefore = token.balanceOf(alice);
        vesting.collect(id, 10);
        assertEq(token.balanceOf(alice) - aliceBefore, RATE * 2);

        // Revoke via admin
        vm.prank(admin);
        vesting.revokeGrant(id);
        assertFalse(vesting.isVesting(id));

        // Grantor's balance freezes after revoke
        uint256 grantorBal = token.balanceOf(grantor);
        _advanceDays(30);
        assertEq(token.balanceOf(grantor), grantorBal);
    }
}

// ================================================================
//  ServiceCredit tests
// ================================================================

contract ServiceCreditTest is Test {
    ServiceCredit public token;

    address public owner    = makeAddr("owner");
    address public operator = makeAddr("operator");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");

    uint128 constant BASE_FEE    = 200 ether;
    uint128 constant USAGE_RATE  = 10 ether;   // per unit
    uint256 constant DAY         = 86_400;

    function setUp() public {
        _warpToDay(1000);
        token = new ServiceCredit(owner, operator);
    }

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    function _createTier() internal returns (uint256 tierId) {
        vm.prank(owner);
        tierId = token.createTier("Basic", BASE_FEE, USAGE_RATE);
    }

    function _enroll(address user, uint256 tierId) internal {
        bytes32 mid = keccak256(abi.encode(address(token), BASE_FEE));
        vm.prank(user);
        token.authorize(mid, 1);
        vm.prank(user);
        token.enroll(tierId);
    }

    // ── createTier and enroll ──

    function test_ServiceCredit__createTier_storesTier() public {
        uint256 tierId = _createTier();

        (string memory name, uint128 baseFee, uint128 usageRate, bool active) = token.tiers(tierId);
        assertEq(name, "Basic");
        assertEq(baseFee, BASE_FEE);
        assertEq(usageRate, USAGE_RATE);
        assertTrue(active);
        assertEq(token.tierCount(), 1);
    }

    function test_ServiceCredit__enroll_startsBaseFeeMandate() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);

        _enroll(alice, tierId);

        assertTrue(token.isEnrolled(alice));
        assertEq(token.userTier(alice), tierId);
        // First term deducted immediately
        assertEq(token.balanceOf(alice), BASE_FEE * 4);
    }

    function test_ServiceCredit__enroll_revertsWhenAlreadyEnrolled() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 10);

        bytes32 mid = keccak256(abi.encode(address(token), BASE_FEE));
        vm.prank(alice);
        token.authorize(mid, 2);

        vm.prank(alice);
        token.enroll(tierId);

        vm.prank(alice);
        vm.expectRevert(ServiceCredit.AlreadyEnrolled.selector);
        token.enroll(tierId);
    }

    // ── chargeUsage deducts from balance ──

    function test_ServiceCredit__chargeUsage_deductsFromBalance() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        uint256 balBefore = token.balanceOf(alice);
        uint256 units = 3;
        vm.prank(operator);
        token.chargeUsage(alice, units);

        uint128 expected = uint128(units) * USAGE_RATE;
        assertEq(token.balanceOf(alice), balBefore - expected);
    }

    function test_ServiceCredit__chargeUsage_revertsWhenNotEnrolled() public {
        vm.prank(operator);
        vm.expectRevert(ServiceCredit.NotEnrolled.selector);
        token.chargeUsage(alice, 1);
    }

    function test_ServiceCredit__chargeUsage_revertsWhenNotOperator() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        vm.prank(alice);
        vm.expectRevert(SiphonToken.Unauthorized.selector);
        token.chargeUsage(alice, 1);
    }

    // ── unenroll stops base fee ──

    function test_ServiceCredit__unenroll_stopsMandateAndClearsTier() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        vm.prank(alice);
        token.unenroll();

        assertFalse(token.isEnrolled(alice));
        assertEq(token.userTier(alice), 0);
    }

    function test_ServiceCredit__unenroll_freezesBalanceAfterRevoke() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        vm.prank(alice);
        token.unenroll();

        uint256 balAfterUnenroll = token.balanceOf(alice);
        _advanceDays(60);
        assertEq(token.balanceOf(alice), balAfterUnenroll);
    }

    function test_ServiceCredit__unenroll_revertsWhenNotEnrolled() public {
        vm.prank(alice);
        vm.expectRevert(ServiceCredit.NotEnrolled.selector);
        token.unenroll();
    }

    // ── base fee decays over time; usage charges are instant ──

    function test_ServiceCredit__baseFee_decaysEachTerm() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        uint256 balAfterEnroll = token.balanceOf(alice); // 4 terms remaining

        _advanceDays(30);
        assertEq(token.balanceOf(alice), balAfterEnroll - BASE_FEE);

        _advanceDays(30);
        assertEq(token.balanceOf(alice), balAfterEnroll - BASE_FEE * 2);
    }

    function test_ServiceCredit__chargeUsage_instantDeductionIndependentOfTerm() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        // Mid-term usage charge: deducted immediately (spend, not mandate)
        _advanceDays(15);
        uint256 balMidTerm = token.balanceOf(alice);

        vm.prank(operator);
        token.chargeUsage(alice, 5);

        assertEq(token.balanceOf(alice), balMidTerm - 5 * USAGE_RATE);
    }

    // ── enroll after lapse works (no deadlock) ──

    function test_ServiceCredit__enroll_worksAfterPreviousLapse() public {
        uint256 tierId = _createTier();
        // Only enough for 2 terms total (1 immediate + 1 period)
        _mint(alice, BASE_FEE * 2);

        bytes32 mid = keccak256(abi.encode(address(token), BASE_FEE));
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        token.enroll(tierId);

        // Advance past the funded period so the mandate lapses
        _advanceDays(60);
        assertFalse(token.isEnrolled(alice));

        // Top up and re-enroll
        _mint(alice, BASE_FEE * 4);

        vm.prank(alice);
        token.authorize(mid, 1);

        // enroll() detects lapsed mandate and allows re-enrollment
        vm.prank(alice);
        token.enroll(tierId);

        assertTrue(token.isEnrolled(alice));
    }

    // ── collect (harvest base fee revenue) ──

    function test_ServiceCredit__collect_harvestsBaseFeeRevenue() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 5);
        _enroll(alice, tierId);

        _advanceDays(30);

        uint256 preBal = token.balanceOf(address(token));
        token.collect(tierId, 10);
        uint256 postBal = token.balanceOf(address(token));

        assertEq(postBal - preBal, BASE_FEE);
    }

    // ── full lifecycle: mint, enroll, use, charge, collect, unenroll ──

    function test_ServiceCredit__lifecycle_mintEnrollUseCollectUnenroll() public {
        uint256 tierId = _createTier();
        _mint(alice, BASE_FEE * 6);

        // Enroll
        _enroll(alice, tierId);
        assertTrue(token.isEnrolled(alice));
        assertEq(token.balanceOf(alice), BASE_FEE * 5); // first term deducted

        // Use 4 units mid-term
        vm.prank(operator);
        token.chargeUsage(alice, 4);
        assertEq(token.balanceOf(alice), BASE_FEE * 5 - USAGE_RATE * 4);

        // 1 term passes: base fee drains another period
        _advanceDays(30);
        assertEq(token.balanceOf(alice), BASE_FEE * 4 - USAGE_RATE * 4);

        // Collect 1 epoch of base fee revenue
        uint256 contractBalBefore = token.balanceOf(address(token));
        token.collect(tierId, 5);
        assertEq(token.balanceOf(address(token)) - contractBalBefore, BASE_FEE);

        // Unenroll
        vm.prank(alice);
        token.unenroll();
        assertFalse(token.isEnrolled(alice));

        // Balance freezes
        uint256 balAfterUnenroll = token.balanceOf(alice);
        _advanceDays(30);
        assertEq(token.balanceOf(alice), balAfterUnenroll);

        // Owner withdraws revenue (base fee immediate payment + usage charges are in token's balance)
        uint256 contractBal = token.balanceOf(address(token));
        vm.prank(owner);
        token.withdraw(owner, uint128(contractBal));
        assertEq(token.balanceOf(owner), contractBal);
    }
}

// ================================================================
//  StreamingSubscription lapse tests
// ================================================================

contract StreamingSubscriptionLapseTest is Test {
    SimpleSiphon public token;
    StreamingSubscription public sub;

    address owner_   = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address alice    = makeAddr("alice");

    uint128 constant BASIC_RATE   = 1000 ether;
    uint128 constant PREMIUM_RATE = 2000 ether;
    uint256 constant DAY          = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY);
        token = new SimpleSiphon(owner_);
        sub   = new StreamingSubscription(address(token), subOwner);

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

    function _createBasicPlan() internal returns (uint256 planId) {
        vm.prank(subOwner);
        planId = sub.createPlan("Basic", BASIC_RATE);
    }

    function _createPremiumPlan() internal returns (uint256 planId) {
        vm.prank(subOwner);
        planId = sub.createPlan("Premium", PREMIUM_RATE);
    }

    function _subscribeWithFunds(address user, uint256 planId, uint128 rate, uint128 fundTerms) internal {
        _mint(user, rate * fundTerms);
        bytes32 mid = keccak256(abi.encode(address(sub), rate));
        vm.prank(user);
        token.authorize(mid, 1);
        vm.prank(user);
        sub.subscribe(planId);
    }

    // ── cancel works after mandate lapsed ──

    function test_StreamingSubscription__cancel_worksAfterMandateLapsed() public {
        uint256 planId = _createBasicPlan();
        // Fund exactly 1 immediate + 1 period = 2 terms total; lapses after 30 days
        _subscribeWithFunds(alice, planId, BASIC_RATE, 2);

        _advanceDays(60); // mandate lapses

        assertFalse(sub.hasAccess(alice));

        // cancel() should not revert even though mandate has lapsed
        vm.prank(alice);
        sub.cancel();

        assertEq(sub.userPlan(alice), 0);
    }

    // ── subscribe works after previous subscription lapsed (re-subscribe) ──

    function test_StreamingSubscription__subscribe_worksAfterPreviousLapse() public {
        uint256 planId = _createBasicPlan();
        // 2 terms: lapses after 1 period
        _subscribeWithFunds(alice, planId, BASIC_RATE, 2);

        _advanceDays(60); // mandate lapses

        assertFalse(sub.hasAccess(alice));
        assertEq(sub.userPlan(alice), planId); // still recorded, just lapsed

        // Re-subscribe: subscribe() clears lapsed entry and taps fresh
        _mint(alice, BASIC_RATE * 4);
        bytes32 mid = keccak256(abi.encode(address(sub), BASIC_RATE));
        vm.prank(alice);
        token.authorize(mid, 1);

        vm.prank(alice);
        sub.subscribe(planId);

        assertTrue(sub.hasAccess(alice));
        assertEq(sub.userPlan(alice), planId);
    }

    // ── changePlan works after old plan lapsed ──

    function test_StreamingSubscription__changePlan_worksAfterOldPlanLapsed() public {
        uint256 basicId   = _createBasicPlan();
        uint256 premiumId = _createPremiumPlan();

        // Subscribe to basic with just 2 terms so it lapses
        _subscribeWithFunds(alice, basicId, BASIC_RATE, 2);

        _advanceDays(60); // basic mandate lapses

        assertFalse(sub.hasAccess(alice));

        // Fund alice for premium plan and authorize
        _mint(alice, PREMIUM_RATE * 4);
        bytes32 premiumMid = keccak256(abi.encode(address(sub), PREMIUM_RATE));
        vm.prank(alice);
        token.authorize(premiumMid, 1);

        // changePlan skips revoke on lapsed mandate, taps premium
        vm.prank(alice);
        sub.changePlan(premiumId);

        assertEq(sub.userPlan(alice), premiumId);
        assertTrue(sub.hasAccess(alice));
    }
}

// ================================================================
//  RentalAgreement lapse tests
// ================================================================

contract RentalAgreementLapseTest is Test {
    SimpleSiphon public token;
    RentalAgreement public rental;

    address owner_   = makeAddr("owner");
    address landlord = makeAddr("landlord");
    address tenant1  = makeAddr("tenant1");

    uint128 constant RENT    = 1000 ether;
    uint128 constant DEPOSIT = 2000 ether;
    uint256 constant DAY     = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY);
        token  = new SimpleSiphon(owner_);
        rental = new RentalAgreement(address(token), landlord, RENT);

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

    function _addTenantWithDeposit(address tenant, uint128 deposit, uint128 fundTerms) internal {
        _mint(tenant, RENT * fundTerms + deposit);
        bytes32 mid = rental.mandateId();
        vm.prank(tenant);
        token.authorize(mid, 1);
        if (deposit > 0) {
            vm.prank(tenant);
            token.approve(address(rental), deposit);
        }
        vm.prank(landlord);
        rental.addTenant(tenant, 0, deposit);
    }

    // ── moveOut works after mandate lapsed ──

    function test_RentalAgreement__moveOut_worksAfterMandateLapsed() public {
        // 2 terms: lapses after 1 period
        _addTenantWithDeposit(tenant1, 0, 2);

        _advanceDays(60); // mandate lapses

        assertFalse(rental.isCurrentOnRent(tenant1));

        // moveOut should not revert even though mandate already lapsed
        vm.prank(tenant1);
        rental.moveOut();

        // Mandate was already lapsed so isTapActive is false
        assertFalse(token.isTapActive(tenant1, rental.mandateId()));
    }

    // ── endLease works after moveOut (deposit returned) ──

    function test_RentalAgreement__endLease_returnsDepositAfterMoveOut() public {
        _addTenantWithDeposit(tenant1, DEPOSIT, 5);

        // Tenant moves out voluntarily
        vm.prank(tenant1);
        rental.moveOut();

        uint256 balBefore = token.balanceOf(tenant1);

        vm.prank(landlord);
        rental.endLease(tenant1);

        assertEq(token.balanceOf(tenant1) - balBefore, DEPOSIT);
        (,,, bool active) = rental.leases(tenant1);
        assertFalse(active);
    }

    // ── endLease works after mandate lapsed (deposit returned) ──

    function test_RentalAgreement__endLease_returnsDepositAfterLapse() public {
        // 2 terms: lapses after 1 period
        _addTenantWithDeposit(tenant1, DEPOSIT, 2);

        _advanceDays(60); // mandate lapses naturally

        assertFalse(rental.isCurrentOnRent(tenant1));

        uint256 balBefore = token.balanceOf(tenant1);

        // endLease skips revoke (mandate already gone) and returns deposit
        vm.prank(landlord);
        rental.endLease(tenant1);

        assertEq(token.balanceOf(tenant1) - balBefore, DEPOSIT);
        (,,, bool active) = rental.leases(tenant1);
        assertFalse(active);
    }
}
