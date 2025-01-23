// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm-contracts/contracts/token/ERC20/IConfidentialERC20.sol";

library SafeConfidentialERC20 {
    /**
     * @notice Safe confidential token transfer. Ensures that the full amount is
     * transferred, or otherwise nothing is transferred. Returns an encrypted
     * boolean indicating whether the transfer was successful.
     *
     * Requires TFHE access to the receiver's balances.
     *
     * @param token Token contract.
     * @param from Address to transfer from.
     * @param to Address to transfer to.
     * @param amount Amount to transfer.
     * @return success Whether the transfer was successful.
     */
    function safeTransferFrom(
        IConfidentialERC20 token,
        address from,
        address to,
        euint64 amount
    ) internal returns (ebool success) {
        // Check balance access
        euint64 balBefore = token.balanceOf(to);
        // require(TFHE.isAllowed(balBefore, address(this)), "Access denied");

        // Transfer
        require(token.transferFrom(from, to, amount), "Transfer failed");
        euint64 balAfter = token.balanceOf(to);

        // Refund if transfer failed
        euint64 amountTransferred = TFHE.sub(balAfter, balBefore);
        success = TFHE.eq(amount, amountTransferred);
        euint64 refund = TFHE.select(success, TFHE.asEuint64(0), amountTransferred);
        TFHE.allowTransient(refund, address(token));
        require(token.transfer(from, refund), "Refund transfer failed");

        // Return success
        return TFHE.eq(amount, amountTransferred);
    }
}
