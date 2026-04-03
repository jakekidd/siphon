// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SimpleLite} from "../src/token/example/SimpleLite.sol";
import {SiphonLite} from "../src/token/SiphonLite.sol";
import {Test} from "forge-std/Test.sol";

contract SiphonLiteTest is Test {
    SimpleLite public token;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public svc   = makeAddr("service");

    uint128 constant RATE   = 3000 ether;
    uint128 constant RATE_B = 1000 ether;
    uint256 constant DAY    = 86_400;

    function setUp() public {
        _warpToDay(1000);
        token = new SimpleLite(owner);
    }

    function _warpToDay(uint256 d) internal { vm.warp(d * DAY); }
    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _mint(address user, uint128 amt) internal {
        vm.prank(owner);
        token.mint(user, amt);
    }

    function _mid(address beneficiary, uint128 rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, rate));
    }

    // ── ERC20 basics ──

    function test_Lite__balanceOf_reflectsMint() public {
        _mint(alice, 10000 ether);
        assertEq(token.balanceOf(alice), 10000 ether);
    }

    function test_Lite__transfer_movesTokens() public {
        _mint(alice, 1000 ether);
        vm.prank(alice);
        token.transfer(bob, 400 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
    }

    // ── Authorize + Tap ──

    function test_Lite__tap_immediatePaymentAndDecay() public {
        _mint(alice, RATE * 5);

        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);

        vm.prank(svc);
        token.tap(alice, RATE);

        // Immediate first-term payment to service
        assertEq(token.balanceOf(alice), RATE * 4);
        assertEq(token.balanceOf(svc), RATE);

        // After 1 term: balance decays
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 3);

        // After 2 terms
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 2);
    }

    function test_Lite__tap_revertsIfNotAuthorized() public {
        _mint(alice, RATE * 5);
        vm.prank(svc);
        vm.expectRevert(SiphonLite.NotAuthorized.selector);
        token.tap(alice, RATE);
    }

    function test_Lite__tap_revertsIfDuplicate() public {
        _mint(alice, RATE * 10);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        vm.prank(svc);
        vm.expectRevert(SiphonLite.InvalidMandate.selector);
        token.tap(alice, RATE);
    }

    // ── Revoke ──

    function test_Lite__revoke_stopsDecay() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // Revoke after 1 term
        _advanceDays(30);
        uint256 balBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.revoke(alice, mid);

        // Balance frozen
        _advanceDays(30);
        assertEq(token.balanceOf(alice), balBefore);
    }

    function test_Lite__revoke_beneficiaryCanRevoke() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // Service revokes
        vm.prank(svc);
        token.revoke(alice, mid);

        assertFalse(token.isTapActive(alice, mid));
    }

    // ── Claim (replaces harvest) ──

    function test_Lite__claim_beneficiaryCollectsOwed() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // After 2 terms
        _advanceDays(60);

        uint256 svcBefore = token.balanceOf(svc);
        vm.prank(svc);
        token.claim(alice, RATE);
        assertEq(token.balanceOf(svc) - svcBefore, RATE * 2);
    }

    function test_Lite__claim_noopIfNothingOwed() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // Claim immediately: nothing owed (first term was immediate)
        uint256 svcBefore = token.balanceOf(svc);
        vm.prank(svc);
        token.claim(alice, RATE);
        assertEq(token.balanceOf(svc), svcBefore);
    }

    function test_Lite__claim_worksAfterRevoke() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        _advanceDays(60);

        // Revoke
        vm.prank(alice);
        token.revoke(alice, mid);

        // Claim after revoke: still collects owed epochs
        uint256 svcBefore = token.balanceOf(svc);
        vm.prank(svc);
        token.claim(alice, RATE);
        assertEq(token.balanceOf(svc) - svcBefore, RATE * 2);
    }

    function test_Lite__claim_worksAfterLapse() public {
        _mint(alice, RATE * 3); // funded for 2 terms after immediate

        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // Advance past lapse point
        _advanceDays(90); // 3 terms, but only funded for 2

        // Claim: settles (triggers lapse), then claims funded epochs
        uint256 svcBefore = token.balanceOf(svc);
        vm.prank(svc);
        token.claim(alice, RATE);
        assertEq(token.balanceOf(svc) - svcBefore, RATE * 2);
    }

    function test_Lite__batchClaim_multipleUsers() public {
        _mint(alice, RATE * 5);
        _mint(bob, RATE * 5);

        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(bob);
        token.authorize(mid, true);

        vm.prank(svc);
        token.tap(alice, RATE);
        vm.prank(svc);
        token.tap(bob, RATE);

        _advanceDays(30);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256 svcBefore = token.balanceOf(svc);
        vm.prank(svc);
        token.batchClaim(users, RATE);
        // 1 epoch * RATE per user * 2 users
        assertEq(token.balanceOf(svc) - svcBefore, RATE * 2);
    }

    // ── Lapse: all-lapse-together ──

    function test_Lite__lapse_allTapsEnd() public {
        _mint(alice, (RATE + RATE_B) * 3); // funded for 2 terms after immediate

        bytes32 midA = _mid(svc, RATE);
        bytes32 midB = _mid(carol, RATE_B);
        vm.startPrank(alice);
        token.authorize(midA, true);
        token.authorize(midB, true);
        vm.stopPrank();

        vm.prank(svc);
        token.tap(alice, RATE);
        vm.prank(carol);
        token.tap(alice, RATE_B);

        // Both active
        assertTrue(token.isTapActive(alice, midA));
        assertTrue(token.isTapActive(alice, midB));

        // Advance past lapse
        _advanceDays(90);
        token.settle(alice);

        // Both ended
        assertFalse(token.isTapActive(alice, midA));
        assertFalse(token.isTapActive(alice, midB));
        assertEq(token.getUserTaps(alice).length, 0);
    }

    function test_Lite__lapse_bothBeneficiariesCanStillClaim() public {
        _mint(alice, (RATE + RATE_B) * 3);

        bytes32 midA = _mid(svc, RATE);
        bytes32 midB = _mid(carol, RATE_B);
        vm.startPrank(alice);
        token.authorize(midA, true);
        token.authorize(midB, true);
        vm.stopPrank();

        vm.prank(svc);
        token.tap(alice, RATE);
        vm.prank(carol);
        token.tap(alice, RATE_B);

        _advanceDays(90);

        // Both can claim their funded epochs
        vm.prank(svc);
        uint256 owedA = token.claim(alice, RATE);
        vm.prank(carol);
        uint256 owedB = token.claim(alice, RATE_B);

        assertEq(owedA, RATE * 2);
        assertEq(owedB, RATE_B * 2);
    }

    // ── Spend ──

    function test_Lite__spend_deductsFromBalance() public {
        _mint(alice, 10000 ether);
        vm.prank(owner);
        token.spend(alice, 3000 ether);
        assertEq(token.balanceOf(alice), 7000 ether);
    }

    function test_Lite__spend_reduceFundedPeriods() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // funded = 4 terms (5 - 1 immediate)
        assertEq(token.funded(alice), 4);

        // Spend 2 terms worth
        vm.prank(owner);
        token.spend(alice, RATE * 2);

        // funded = 2 terms now
        assertEq(token.funded(alice), 2);
    }

    // ── Views ──

    function test_Lite__isActive_trueWhileFunded() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        assertTrue(token.isActive(alice));
    }

    function test_Lite__expiryDay_correctWithMandate() public {
        _mint(alice, RATE * 5);
        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);

        // anchor = today (1000), funded = 4, term = 30
        assertEq(token.expiryDay(alice), 1000 + 4 * 30);
    }

    // ── Lifecycle ──

    function test_Lite__lifecycle_tapDecayClaimRevokeResubscribe() public {
        _mint(alice, RATE * 10);

        bytes32 mid = _mid(svc, RATE);
        vm.prank(alice);
        token.authorize(mid, true);

        // Subscribe
        vm.prank(svc);
        token.tap(alice, RATE);
        assertTrue(token.isTapActive(alice, mid));
        assertEq(token.balanceOf(svc), RATE); // immediate

        // 3 terms pass, claim
        _advanceDays(90);
        assertEq(token.balanceOf(alice), RATE * 6); // 9 - 3 decayed

        vm.prank(svc);
        token.claim(alice, RATE);
        assertEq(token.balanceOf(svc), RATE + RATE * 3); // immediate + 3 claimed

        // Revoke
        vm.prank(alice);
        token.revoke(alice, mid);
        assertFalse(token.isTapActive(alice, mid));

        // Balance frozen
        uint256 frozenBal = token.balanceOf(alice);
        _advanceDays(30);
        assertEq(token.balanceOf(alice), frozenBal);

        // Re-subscribe (same mandateId, re-authorize)
        vm.prank(alice);
        token.authorize(mid, true);
        vm.prank(svc);
        token.tap(alice, RATE);
        assertTrue(token.isTapActive(alice, mid));
    }

    function test_Lite__lifecycle_multiMandateLapseAndClaim() public {
        uint128 totalOutflow = RATE + RATE_B;
        _mint(alice, totalOutflow * 4); // immediate + 3 funded terms

        bytes32 midA = _mid(svc, RATE);
        bytes32 midB = _mid(carol, RATE_B);

        vm.startPrank(alice);
        token.authorize(midA, true);
        token.authorize(midB, true);
        vm.stopPrank();

        vm.prank(svc);
        token.tap(alice, RATE);
        vm.prank(carol);
        token.tap(alice, RATE_B);

        // Immediate payments
        assertEq(token.balanceOf(svc), RATE);
        assertEq(token.balanceOf(carol), RATE_B);
        assertEq(token.balanceOf(alice), totalOutflow * 3);
        assertEq(token.funded(alice), 3);

        // Advance 5 terms (lapse at 3)
        _advanceDays(150);

        // Both claim post-lapse
        vm.prank(svc);
        uint256 owedA = token.claim(alice, RATE);
        vm.prank(carol);
        uint256 owedB = token.claim(alice, RATE_B);

        assertEq(owedA, RATE * 3);      // 3 funded epochs
        assertEq(owedB, RATE_B * 3);    // 3 funded epochs

        // Alice has dust left (principal - funded * outflow)
        assertEq(token.balanceOf(alice), 0);
    }
}
