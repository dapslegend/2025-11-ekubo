## Title
Attacker can mint unbacked wrappers and drain all TokenWrapper collateral

## Summary
- Every call coming from `Core` skips balance debits inside `TokenWrapper.transfer`, so the contract never checks (or subtracts) the Core’s balance when it “sends” wrapper tokens.
- Inside the wrapper’s forward hook the contract blindly increases its saved balance and clears accountant debt without confirming that any underlying was actually delivered.
- A malicious locker can therefore withdraw arbitrary wrapper balances from the accountant, immediately forge a fake “wrap” update, and later unwrap those fake tokens to steal the real underlying that honest users deposited.

## Root Cause (with code excerpts)
Skipping accounting for Core-originated transfers lets the Core mint wrappers without a backing balance:

```95:114:src/TokenWrapper.sol
function transfer(address to, uint256 amount) external returns (bool) {
    if (msg.sender != address(CORE)) {
        uint256 balance = _balanceOf[msg.sender];
        if (balance < amount) revert InsufficientBalance();
        unchecked { _balanceOf[msg.sender] = balance - amount; }
    }
    if (to == address(CORE)) {
        coreBalance += amount;
    } else if (to != address(0)) {
        _balanceOf[to] += amount;
    }
    emit Transfer(msg.sender, to, amount);
    return true;
}
```

The forward hook then “credits” the saved balance and clears debt even though no underlying moved:

```157:180:src/TokenWrapper.sol
function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory) {
    (int256 amount) = abi.decode(data, (int256));
    if (amount < 0 && block.timestamp < UNLOCK_TIME) revert TooEarly();

    CORE.updateSavedBalances({
        token0: address(UNDERLYING_TOKEN),
        token1: address(type(uint160).max),
        salt: bytes32(0),
        delta0: amount,
        delta1: 0
    });

    CORE.updateDebt(SafeCastLib.toInt128(-amount));
    return bytes("");
}
```

Because any contract can become a locker (`FlashAccountant.lock()` does not restrict callers), an attacker can combine these two behaviors to mint wrappers with zero collateral and later redeem them for real tokens.

## Impact
All honest wrapper holders lose their deposits. A single malicious locker can mint unlimited wrappers, unwrap them, and drain the entire pool of underlying tokens held by `Core`. Afterwards legitimate users are left with wrappers that can never be redeemed (unwrap reverts because the core balance is empty). This is a protocol-wide loss of user funds.

## Recommendation / Fix
- Track `Core`’s balance the same way you track every other account: debit `_balanceOf[address(CORE)]` (or at least the `coreBalance` cache) whenever Core sends tokens, and revert if it is insufficient.
- Only call `CORE.updateSavedBalances` after the accountant verifies that the underlying tokens were actually transferred (e.g., move the accounting into the periphery or require an accountant-provided receipt).
- As a belt-and-suspenders change, gate `handleForwardData` so it cannot be abused to mint wrappers unless the caller’s delta matches an observed payment.

## Proof of Concept (attacker walk-through)
1. Victim wraps `1e18` underlying via the canonical periphery; `Core` now holds the funds and victim receives wrapper tokens.
2. Attacker deploys any contract that implements `locked_6416899205(uint256)` (see `TokenWrapperAttacker` in the PoC test); no permissions are needed to become a locker.
3. The attacker calls `FlashAccountant.lock()` with calldata that first:
   - `withdraw`s wrapper tokens from the accountant to themselves. Because `TokenWrapper.transfer` never checks Core’s balance, this “transfer” succeeds even though the Core never owned those wrappers.
   - Immediately calls `TokenWrapper.handleForwardData` with a positive amount. This tricks the wrapper into believing underlying was deposited, so it zeroes the accountant’s debt and bumps its saved-balance snapshot.
4. The attacker now holds fully liquid wrapper tokens even though no underlying was provided. They call `TokenWrapperPeriphery.unwrap(...)` (or any other forwardee) to convert those wrappers into the real underlying held in `Core`.
5. Honest users can no longer unwrap—their calls revert because `Core`’s balance is empty.

You can reproduce the exploit with Foundry once `solc 0.8.31-pre.1` is installed:

```sh
forge test --match-test testStealUnderlyingByForgingCoreTransfers
```

This test (added in `test/TokenWrapper.t.sol`) wraps funds on behalf of a victim, uses an untrusted attacker locker to mint unbacked wrappers, and then unwraps them to drain all collateral, leaving the victim with irredeemable wrappers.
