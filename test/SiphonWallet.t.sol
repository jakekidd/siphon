// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonWallet} from "../src/wallet/SiphonWallet.sol";
import {SiphonFactory} from "../src/wallet/SiphonFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory sym) ERC20(name, sym) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract SiphonWalletTest is Test {
    SiphonWallet public wallet;
    MockToken public usdc;
    MockToken public weth;

    address public owner = makeAddr("owner");
    address public svc   = makeAddr("service");
    address public alice = makeAddr("alice");

    uint128 constant RATE     = 100 ether;
    uint32  constant CADENCE  = 30;
    uint256 constant DAY      = 86_400;

    function setUp() public {
        vm.warp(1000 * DAY);
        wallet = new SiphonWallet(owner);
        usdc = new MockToken("USD Coin", "USDC");
        weth = new MockToken("Wrapped ETH", "WETH");
    }

    function _advanceDays(uint256 n) internal { vm.warp(block.timestamp + n * DAY); }

    function _fund(uint256 amount) internal {
        usdc.mint(address(wallet), amount);
    }

    function _grant() internal returns (uint256 id) {
        vm.prank(owner);
        id = wallet.grant(svc, address(usdc), RATE, CADENCE, 0);
    }

    // ================================================================
    //  Grant
    // ================================================================

    function test_Wallet__grant_createsMandate() public {
        _grant();
        SiphonWallet.Mandate memory m = wallet.mandateInfo(0);
        assertEq(m.payee, svc);
        assertEq(m.token, address(usdc));
        assertEq(m.rate, RATE);
        assertEq(m.cadence, CADENCE);
        assertEq(m.lastCollected, 1000);
        assertEq(m.maxPeriods, 0);
        assertTrue(m.active);
    }

    function test_Wallet__grant_incrementsId() public {
        _grant();
        vm.prank(owner);
        uint256 id2 = wallet.grant(alice, address(usdc), 50 ether, 7, 0);
        assertEq(id2, 1);
        assertEq(wallet.mandateCount(), 2);
    }

    function test_Wallet__grant_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(SiphonWallet.Unauthorized.selector);
        wallet.grant(svc, address(usdc), RATE, CADENCE, 0);
    }

    function test_Wallet__grant_revertsIfZeroRate() public {
        vm.prank(owner);
        vm.expectRevert(SiphonWallet.InvalidMandate.selector);
        wallet.grant(svc, address(usdc), 0, CADENCE, 0);
    }

    function test_Wallet__grant_revertsIfZeroCadence() public {
        vm.prank(owner);
        vm.expectRevert(SiphonWallet.InvalidMandate.selector);
        wallet.grant(svc, address(usdc), RATE, 0, 0);
    }

    function test_Wallet__grant_revertsIfPayeeZero() public {
        vm.prank(owner);
        vm.expectRevert(SiphonWallet.InvalidMandate.selector);
        wallet.grant(address(0), address(usdc), RATE, CADENCE, 0);
    }

    function test_Wallet__grant_revertsIfPayeeSelf() public {
        vm.prank(owner);
        vm.expectRevert(SiphonWallet.InvalidMandate.selector);
        wallet.grant(address(wallet), address(usdc), RATE, CADENCE, 0);
    }

    function test_Wallet__grant_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SiphonWallet.Granted(0, svc, address(usdc), RATE, CADENCE);
        wallet.grant(svc, address(usdc), RATE, CADENCE, 0);
    }

    // ================================================================
    //  Cancel
    // ================================================================

    function test_Wallet__cancel_deactivatesMandate() public {
        _grant();
        vm.prank(owner);
        wallet.cancel(0);
        assertFalse(wallet.mandateInfo(0).active);
    }

    function test_Wallet__cancel_revertsIfNotOwner() public {
        _grant();
        vm.prank(alice);
        vm.expectRevert(SiphonWallet.Unauthorized.selector);
        wallet.cancel(0);
    }

    function test_Wallet__cancel_revertsIfAlreadyCancelled() public {
        _grant();
        vm.prank(owner);
        wallet.cancel(0);
        vm.prank(owner);
        vm.expectRevert(SiphonWallet.MandateNotActive.selector);
        wallet.cancel(0);
    }

    function test_Wallet__cancel_preventsCollection() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(30);
        vm.prank(owner);
        wallet.cancel(0);
        vm.expectRevert(SiphonWallet.MandateNotActive.selector);
        wallet.collect(0);
    }

    function test_Wallet__cancel_emitsEvent() public {
        _grant();
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit SiphonWallet.Cancelled(0);
        wallet.cancel(0);
    }

    // ================================================================
    //  Collect (core)
    // ================================================================

    function test_Wallet__collect_transfersAfterOnePeriod() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(30);

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE);
    }

    function test_Wallet__collect_transfersAfterMultiplePeriods() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(90); // 3 periods

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 3);
    }

    function test_Wallet__collect_revertsIfNoPeriodElapsed() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(15); // half a period
        vm.expectRevert(SiphonWallet.NothingOwed.selector);
        wallet.collect(0);
    }

    function test_Wallet__collect_advancesLastCollectedByExactPeriods() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(45); // 1.5 periods: should collect 1, carry 15 days

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE); // only 1 period

        // 15 days carried over. After 15 more days, another period completes.
        _advanceDays(15);
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 2);
    }

    function test_Wallet__collect_permissionless() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(30);

        // Random address calls collect; tokens go to payee not caller
        vm.prank(alice);
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_Wallet__collect_emitsEvent() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(30);

        vm.expectEmit(true, true, true, true);
        emit SiphonWallet.Collected(0, svc, address(usdc), RATE, 1);
        wallet.collect(0);
    }

    function test_Wallet__collect_consecutiveCollections() public {
        _fund(RATE * 10);
        _grant();

        _advanceDays(30);
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE);

        _advanceDays(30);
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 2);

        _advanceDays(60);
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 4);
    }

    // ================================================================
    //  Collect (maxPeriods)
    // ================================================================

    function test_Wallet__collect_maxPeriodsCapsDebt() public {
        _fund(RATE * 10);
        vm.prank(owner);
        wallet.grant(svc, address(usdc), RATE, CADENCE, 2); // max 2 periods

        _advanceDays(150); // 5 periods elapsed, capped at 2

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 2);
    }

    function test_Wallet__collect_unlimitedWhenMaxPeriodsZero() public {
        _fund(RATE * 20);
        _grant(); // maxPeriods = 0

        _advanceDays(300); // 10 periods

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 10);
    }

    function test_Wallet__collect_maxPeriodsResetsAfterCollection() public {
        _fund(RATE * 20);
        vm.prank(owner);
        wallet.grant(svc, address(usdc), RATE, CADENCE, 3);

        _advanceDays(150); // 5 periods, capped at 3
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 3);

        _advanceDays(150); // 5 more periods, capped at 3 again
        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 6);
    }

    // ================================================================
    //  Collect (insolvency)
    // ================================================================

    function test_Wallet__collect_partialPaymentOnInsolvency() public {
        _fund(RATE / 2); // half of one period's payment
        _grant();
        _advanceDays(30);

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE / 2); // gets whatever is available
    }

    function test_Wallet__collect_zeroBalanceTransfersNothing() public {
        // no funding
        _grant();
        _advanceDays(30);

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), 0);
        // lastCollected still advances
        assertEq(wallet.mandateInfo(0).lastCollected, 1030);
    }

    function test_Wallet__collect_exactBalance() public {
        _fund(RATE * 3);
        _grant();
        _advanceDays(90); // owes exactly 3 * RATE

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE * 3);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    // ================================================================
    //  Debt view
    // ================================================================

    function test_Wallet__debt_zeroImmediatelyAfterGrant() public {
        _grant();
        assertEq(wallet.debt(0), 0);
    }

    function test_Wallet__debt_accumulatesOverTime() public {
        _grant();
        _advanceDays(60);
        assertEq(wallet.debt(0), RATE * 2);
    }

    function test_Wallet__debt_cappedByMaxPeriods() public {
        vm.prank(owner);
        wallet.grant(svc, address(usdc), RATE, CADENCE, 2);
        _advanceDays(150);
        assertEq(wallet.debt(0), RATE * 2); // capped at 2
    }

    function test_Wallet__debt_zeroAfterCancel() public {
        _grant();
        _advanceDays(30);
        vm.prank(owner);
        wallet.cancel(0);
        assertEq(wallet.debt(0), 0);
    }

    function test_Wallet__debt_resetsAfterCollect() public {
        _fund(RATE * 10);
        _grant();
        _advanceDays(60);
        assertEq(wallet.debt(0), RATE * 2);
        wallet.collect(0);
        assertEq(wallet.debt(0), 0);
    }

    // ================================================================
    //  Execute
    // ================================================================

    function test_Wallet__execute_transfersERC20() public {
        _fund(1000 ether);
        bytes memory data = abi.encodeCall(usdc.transfer, (alice, 500 ether));
        vm.prank(owner);
        wallet.execute(address(usdc), 0, data);
        assertEq(usdc.balanceOf(alice), 500 ether);
    }

    function test_Wallet__execute_sendsETH() public {
        vm.deal(address(wallet), 1 ether);
        vm.prank(owner);
        wallet.execute(alice, 0.5 ether, "");
        assertEq(alice.balance, 0.5 ether);
    }

    function test_Wallet__execute_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(SiphonWallet.Unauthorized.selector);
        wallet.execute(alice, 0, "");
    }

    function test_Wallet__execute_revertsOnFailedCall() public {
        // Transfer more than balance
        _fund(100 ether);
        bytes memory data = abi.encodeCall(usdc.transfer, (alice, 999 ether));
        vm.prank(owner);
        vm.expectRevert(SiphonWallet.CallFailed.selector);
        wallet.execute(address(usdc), 0, data);
    }

    // ================================================================
    //  Multi-mandate
    // ================================================================

    function test_Wallet__multiMandate_independentCollection() public {
        _fund(RATE * 20);
        vm.startPrank(owner);
        wallet.grant(svc, address(usdc), RATE, 30, 0);     // id 0
        wallet.grant(alice, address(usdc), 50 ether, 7, 0); // id 1
        vm.stopPrank();

        _advanceDays(30); // 1 monthly period, 4 weekly periods

        wallet.collect(0);
        assertEq(usdc.balanceOf(svc), RATE);

        wallet.collect(1);
        assertEq(usdc.balanceOf(alice), 50 ether * 4);
    }

    function test_Wallet__multiMandate_insolvencyAffectsLaterCollector() public {
        _fund(RATE + 10 ether); // enough for svc but not both
        vm.startPrank(owner);
        wallet.grant(svc, address(usdc), RATE, 30, 0);    // id 0
        wallet.grant(alice, address(usdc), RATE, 30, 0);   // id 1
        vm.stopPrank();

        _advanceDays(30);

        wallet.collect(0); // svc gets full RATE
        assertEq(usdc.balanceOf(svc), RATE);

        wallet.collect(1); // alice gets remaining 10
        assertEq(usdc.balanceOf(alice), 10 ether);
    }

    // ================================================================
    //  Multi-token
    // ================================================================

    function test_Wallet__multiToken_separateBalances() public {
        usdc.mint(address(wallet), 1000 ether);
        weth.mint(address(wallet), 5 ether);

        vm.startPrank(owner);
        wallet.grant(svc, address(usdc), 100 ether, 30, 0);
        wallet.grant(svc, address(weth), 1 ether, 30, 0);
        vm.stopPrank();

        _advanceDays(30);

        wallet.collect(0); // USDC
        wallet.collect(1); // WETH

        assertEq(usdc.balanceOf(svc), 100 ether);
        assertEq(weth.balanceOf(svc), 1 ether);
        assertEq(usdc.balanceOf(address(wallet)), 900 ether);
        assertEq(weth.balanceOf(address(wallet)), 4 ether);
    }
}

// ================================================================
//  Factory tests
// ================================================================

contract SiphonFactoryTest is Test {
    SiphonFactory public factory;

    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    function setUp() public {
        factory = new SiphonFactory();
    }

    function test_Factory__createWallet_deploysAndRegisters() public {
        vm.prank(alice);
        address wallet = factory.createWallet();
        assertTrue(wallet != address(0));
        assertEq(factory.wallets(alice), wallet);
    }

    function test_Factory__createWallet_ownerIsCorrect() public {
        vm.prank(alice);
        address wallet = factory.createWallet();
        assertEq(SiphonWallet(payable(wallet)).owner(), alice);
    }

    function test_Factory__createWallet_revertsIfAlreadyExists() public {
        vm.prank(alice);
        factory.createWallet();
        vm.prank(alice);
        vm.expectRevert(SiphonFactory.WalletExists.selector);
        factory.createWallet();
    }

    function test_Factory__getWallet_returnsZeroIfNotCreated() public view {
        assertEq(factory.getWallet(bob), address(0));
    }

    function test_Factory__createWallet_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit SiphonFactory.WalletCreated(alice, address(0)); // address won't match exactly
        factory.createWallet();
    }
}
