// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {DedicatedSiphonToken} from "../src/token/DedicatedSiphonToken.sol";
import {Test} from "forge-std/Test.sol";

// Minimal concrete token for testing DedicatedSiphonToken
contract TestCredit is DedicatedSiphonToken {
    address public admin;

    constructor(address _admin, address _beneficiary)
        DedicatedSiphonToken(uint32(block.timestamp / 86400), 30, 16)
    {
        admin = _admin;
        _setBeneficiary(_beneficiary);
    }

    function name() external pure returns (string memory) { return "TestCredit"; }
    function symbol() external pure returns (string memory) { return "TC"; }
    function decimals() external pure returns (uint8) { return 18; }

    function mint(address _to, uint128 _amount) external {
        require(msg.sender == admin, "not admin");
        _mint(_to, _amount);
    }

    function spend(address _from, uint128 _amount) external {
        require(msg.sender == admin || msg.sender == beneficiary, "not authorized");
        _spend(_from, _amount);
    }
}

contract DedicatedSiphonTest is Test {
    TestCredit public token;

    address public admin = makeAddr("admin");
    address public cov   = makeAddr("covenant");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    uint128 constant RATE = 5000 ether;
    uint256 constant DAY  = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY); // genesis day = 1000
        token = new TestCredit(admin, cov);
    }

    function _fund(address user, uint128 amount) internal {
        vm.prank(admin);
        token.mint(user, amount);
    }

    function _advanceDays(uint256 d) internal {
        vm.warp(block.timestamp + d * DAY);
    }

    // ── tap (no auth needed) ──

    function test_DedicatedSiphon__tap_succeedsFromBeneficiary() public {
        _fund(alice, RATE * 4);
        vm.prank(cov);
        token.tap(alice, RATE);
        // first-term payment deducted
        assertEq(token.balanceOf(alice), RATE * 3);
    }

    function test_DedicatedSiphon__tap_revertsFromNonBeneficiary() public {
        _fund(alice, RATE * 4);
        vm.prank(bob);
        vm.expectRevert(DedicatedSiphonToken.NotBeneficiary.selector);
        token.tap(alice, RATE);
    }

    function test_DedicatedSiphon__authorize_reverts() public {
        vm.prank(alice);
        vm.expectRevert(DedicatedSiphonToken.AuthorizationDisabled.selector);
        token.authorize(bytes32(0), 1);
    }

    // ── tapFor (fixed-term) ──

    function test_DedicatedSiphon__tapFor_terminatesAfterMaxEpochs() public {
        // fund alice for 10 periods worth
        _fund(alice, RATE * 11); // 10 periods + 1 for first-term
        vm.prank(cov);
        token.tapFor(alice, RATE, 3); // max 3 billing periods

        // first-term payment
        assertEq(token.balanceOf(alice), RATE * 10);

        // after 3 periods (90 days): mandate should terminate
        _advanceDays(90);
        // balance should reflect 3 periods consumed: 10*RATE - 3*RATE = 7*RATE
        // but tap terminates at epoch 3, so no further decay
        assertEq(token.balanceOf(alice), RATE * 7);

        // after 6 periods (180 days): balance should NOT decay further
        _advanceDays(90);
        assertEq(token.balanceOf(alice), RATE * 7);
    }

    function test_DedicatedSiphon__tapFor_zeroMaxEpochsBehavesLikeTap() public {
        _fund(alice, RATE * 4);
        vm.prank(cov);
        token.tapFor(alice, RATE, 0);
        // same as regular tap, no cap
        assertEq(token.balanceOf(alice), RATE * 3);
        // after 3 periods: balance should be 0 (fully drained)
        _advanceDays(90);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_DedicatedSiphon__tapFor_capSurvivesDeposit() public {
        // fund for 2 periods, tapFor 2 epochs
        _fund(alice, RATE * 3);
        vm.prank(cov);
        token.tapFor(alice, RATE, 2);
        // first-term: balance = 2*RATE

        // now deposit more (10 periods worth)
        _fund(alice, RATE * 10);
        // balance = 12*RATE. without cap, exit would be epoch ~12.
        // with cap, exit should still be epoch 2.

        // after 2 periods: mandate terminates
        _advanceDays(60);
        uint256 bal = token.balanceOf(alice);
        // consumed 2 periods via mandate = 2*RATE
        // balance = 12*RATE - 2*RATE = 10*RATE
        assertEq(bal, RATE * 10);

        // after 4 periods: no further decay
        _advanceDays(60);
        assertEq(token.balanceOf(alice), RATE * 10);
    }

    function test_DedicatedSiphon__tapFor_revertsFromNonBeneficiary() public {
        _fund(alice, RATE * 4);
        vm.prank(bob);
        vm.expectRevert(DedicatedSiphonToken.NotBeneficiary.selector);
        token.tapFor(alice, RATE, 3);
    }

    function test_DedicatedSiphon__maxExit_readableView() public {
        _fund(alice, RATE * 4);
        vm.prank(cov);
        token.tapFor(alice, RATE, 3);
        bytes32 mid = token.mandateId(cov, RATE);
        uint32 cap = token.maxExit(alice, mid);
        assertTrue(cap > 0);
    }

    // ── comp ──

    function test_DedicatedSiphon__comp_succeedsFromBeneficiary() public {
        _fund(alice, RATE * 4);
        vm.prank(cov);
        token.tap(alice, RATE);
        vm.prank(cov);
        token.comp(alice, RATE, 2);
        // balance should be frozen for 2 periods
        _advanceDays(30);
        assertEq(token.balanceOf(alice), RATE * 3);
    }
}
