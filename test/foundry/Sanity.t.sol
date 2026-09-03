// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FuzzBase} from "./lib/minstd/FuzzBase.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {SinettiEscrowV04} from "../../contracts/SinettiEscrowV04.sol";

/**
 * @title Sanity
 * @notice Proves the Foundry pipeline end to end: the real contracts compile
 *         under foundry.toml's Hardhat-mirroring settings, the OZ remapping
 *         resolves from node_modules, the vendored cheatcode surface works,
 *         and the V04 constructor accepts the same shape Hardhat deploys.
 */
contract SanityTest is FuzzBase {
    function test_realContractsCompileAndDeploy() public {
        MockUSDC token = new MockUSDC();
        token.mint(address(this), 1_000_000);
        assertEq(token.balanceOf(address(this)), 1_000_000, "mint");

        SinettiEscrowV04.TokenPolicy[] memory policies = new SinettiEscrowV04.TokenPolicy[](1);
        policies[0] = SinettiEscrowV04.TokenPolicy({
            token: IERC20(address(token)),
            maxAmount: 1_000_000,
            maxBond: 1_000_000,
            minBondBps: 0,
            minChallengerBondBps: 0
        });
        SinettiEscrowV04 escrow = new SinettiEscrowV04(
            address(this),
            policies,
            new address[](0),
            new address[](0),
            60,
            60
        );
        assertEq(escrow.minChallengeWindow(), 60, "challenge floor");
        assertEq(escrow.minRulingWindow(), 60, "ruling floor");
        assertEq(
            bytes32(bytes(escrow.SIGNING_DOMAIN_VERSION())),
            bytes32(bytes("8")),
            "domain version"
        );
    }

    function testFuzz_cheatcodesWork(uint64 timestamp) public {
        vm.assume(timestamp > 1_000_000);
        vm.warp(timestamp);
        assertEq(block.timestamp, timestamp, "warp");
        address someone = vm.addr(0xA11CE);
        vm.prank(someone);
        assertTrue(someone != address(0), "addr");
    }
}
