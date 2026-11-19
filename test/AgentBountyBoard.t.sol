// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBountyBoard} from "../src/AgentBountyBoard.sol";

contract MockAgentId {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] += 1;
    }
}

contract AgentBountyBoardTest is Test {
    AgentBountyBoard board;
    MockAgentId registry;

    address poster = address(0x1001);
    address worker = address(0x1002);
    address stranger = address(0x1003);

    function setUp() public {
        registry = new MockAgentId();
        board = new AgentBountyBoard(address(registry));
        registry.mint(worker); // worker holds an Agent ID, others do not
        vm.deal(poster, 100 ether);
        vm.deal(worker, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    function _post(uint256 amount, uint64 deadline) internal returns (uint256 id) {
        vm.prank(poster);
        id = board.postBounty{value: amount}("Write a summary", "ipfs://task", deadline);
    }

    function testPostEscrowsFunds() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        AgentBountyBoard.Bounty memory b = board.getBounty(id);
        assertEq(b.amount, 1 ether);
        assertEq(address(board).balance, 1 ether);
        assertEq(uint256(b.status), uint256(AgentBountyBoard.Status.Open));
        assertEq(board.totalPosted(), 1);
    }

    function testPostTooSmallReverts() public {
        vm.prank(poster);
        vm.expectRevert(AgentBountyBoard.BountyTooSmall.selector);
        board.postBounty{value: 0.00001 ether}("x", "ipfs://t", uint64(block.timestamp + 1 days));
    }

    function testClaimRequiresAgentId() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        vm.prank(stranger);
        vm.expectRevert(AgentBountyBoard.NotAgentIdHolder.selector);
        board.claimBounty(id);
    }

    function testFullLifecyclePaysWorker() public {
        uint256 id = _post(2 ether, uint64(block.timestamp + 1 days));
        vm.prank(worker);
        board.claimBounty(id);
        assertEq(board.agentInteractors(), 1);

        vm.prank(worker);
        board.submitWork(id, "ipfs://proof");
        uint256 before = worker.balance;
        vm.prank(poster);
        board.approveAndRelease(id);
        assertEq(worker.balance, before + 2 ether);
        assertEq(board.completedCount(worker), 1);
        assertEq(board.totalEarned(worker), 2 ether);
        assertEq(board.totalReleasedVolume(), 2 ether);
        assertEq(address(board).balance, 0);
    }

    function testRejectAllowsResubmit() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        vm.prank(worker);
        board.claimBounty(id);
        vm.prank(worker);
        board.submitWork(id, "ipfs://v1");
        vm.prank(poster);
        board.rejectWork(id);
        AgentBountyBoard.Bounty memory b = board.getBounty(id);
        assertEq(uint256(b.status), uint256(AgentBountyBoard.Status.Claimed));
        vm.prank(worker);
        board.submitWork(id, "ipfs://v2");
        vm.prank(poster);
        board.approveAndRelease(id);
        assertEq(board.completedCount(worker), 1);
    }

    function testWorkerCannotReleaseBeforeReviewWindow() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 7 days));
        vm.prank(worker);
        board.claimBounty(id);
        vm.prank(worker);
        board.submitWork(id, "ipfs://proof");
        vm.prank(worker);
        vm.expectRevert(AgentBountyBoard.ReviewWindowOpen.selector);
        board.releaseAfterReviewWindow(id);
    }

    function testWorkerReleasesAfterReviewWindow() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 7 days));
        vm.prank(worker);
        board.claimBounty(id);
        vm.prank(worker);
        board.submitWork(id, "ipfs://proof");
        vm.warp(block.timestamp + 3 days + 1);
        uint256 before = worker.balance;
        vm.prank(worker);
        board.releaseAfterReviewWindow(id);
        assertEq(worker.balance, before + 1 ether);
    }

    function testCancelRefundsPoster() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        uint256 before = poster.balance;
        vm.prank(poster);
        board.cancelBounty(id);
        assertEq(poster.balance, before + 1 ether);
        assertEq(address(board).balance, 0);
    }

    function testReclaimExpiredAfterDeadline() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        vm.prank(worker);
        board.claimBounty(id);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = poster.balance;
        vm.prank(poster);
        board.reclaimExpired(id);
        assertEq(poster.balance, before + 1 ether);
    }

    function testReclaimExpiredTooEarlyReverts() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        vm.prank(worker);
        board.claimBounty(id);
        vm.prank(poster);
        vm.expectRevert(AgentBountyBoard.DeadlineNotReached.selector);
        board.reclaimExpired(id);
    }

    function testStrangerCannotApprove() public {
        uint256 id = _post(1 ether, uint64(block.timestamp + 1 days));
        vm.prank(worker);
        board.claimBounty(id);
        vm.prank(worker);
        board.submitWork(id, "ipfs://proof");
        vm.prank(stranger);
        vm.expectRevert(AgentBountyBoard.NotPoster.selector);
        board.approveAndRelease(id);
    }

    function testPagination() public {
        for (uint256 i = 0; i < 5; i++) {
            _post(0.001 ether, uint64(block.timestamp + 1 days));
        }
        AgentBountyBoard.Bounty[] memory page = board.getBounties(1, 2);
        assertEq(page.length, 2);
        assertEq(board.bountyCount(), 5);
    }
}
