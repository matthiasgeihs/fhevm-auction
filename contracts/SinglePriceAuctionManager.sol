// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm-contracts/contracts/token/ERC20/IConfidentialERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SinglePriceAuctionManager is SepoliaZamaFHEVMConfig {
    uint256 public auctionCounter;

    struct Auction {
        address owner;
        uint256 endTime;
        uint256 totalQuantity;
        euint64 settlementPrice;
        euint64 refund;
        bool ended;
        IConfidentialERC20 assetToken;
        IConfidentialERC20 paymentToken;
        Bid[] bids;
        Payout[] payouts;
        mapping(address => bool) payoutClaimed;
        bool paymentClaimed;
    }

    struct Bid {
        eaddress bidder;
        euint64 quantity;
        euint64 price;
    }

    struct Payout {
        eaddress bidder;
        euint64 quantity;
    }

    mapping(uint256 => Auction) public auctions;

    event AuctionCreated(
        uint256 auctionId,
        uint256 endTime,
        uint256 quantity,
        address assetToken,
        address paymentToken
    );
    event BidPlaced(uint256 auctionId, address indexed bidder, euint64 quantity, euint64 price);
    event AuctionEnded(uint256 auctionId, euint64 settlementPrice);

    modifier auctionActive(uint256 auctionId) {
        require(block.timestamp < auctions[auctionId].endTime, "Auction already ended");
        _;
    }

    modifier auctionEndedOnly(uint256 auctionId) {
        require(block.timestamp >= auctions[auctionId].endTime, "Auction not yet ended");
        _;
    }

    function createAuction(
        uint256 _auctionDuration,
        uint64 _totalQuantity,
        address _assetToken,
        address _paymentToken
    ) external {
        auctionCounter++;
        uint256 auctionId = auctionCounter;
        Auction storage auction = auctions[auctionId];
        auction.owner = msg.sender;
        auction.endTime = block.timestamp + _auctionDuration;
        auction.totalQuantity = _totalQuantity;
        auction.assetToken = IConfidentialERC20(_assetToken);
        auction.paymentToken = IConfidentialERC20(_paymentToken);

        // Transfer the assets from the owner to the contract.
        euint64 _totalQuantityEncrypted = TFHE.asEuint64(_totalQuantity);
        TFHE.allowTransient(_totalQuantityEncrypted, address(auction.assetToken));
        require(
            auction.assetToken.transferFrom(msg.sender, address(this), _totalQuantityEncrypted),
            "Asset transfer failed"
        );

        emit AuctionCreated(auctionId, auction.endTime, _totalQuantity, _assetToken, _paymentToken);
    }

    function placeBid(
        uint256 _auctionId,
        einput _quantity,
        einput _price,
        bytes calldata _proof
    ) external auctionActive(_auctionId) {
        Auction storage auction = auctions[_auctionId];

        // TODO handle multiple bids from one address

        eaddress bidder = TFHE.asEaddress(msg.sender);
        euint64 quantity = TFHE.asEuint64(_quantity, _proof);
        euint64 price = TFHE.asEuint64(_price, _proof);

        euint64 totalCost = TFHE.mul(quantity, price);

        // Transfer payment from bidder to contract using confidential transfer
        TFHE.allowTransient(totalCost, address(auction.paymentToken));
        require(auction.paymentToken.transferFrom(msg.sender, address(this), totalCost), "Payment transfer failed");

        // Insert bidder in sorted order based on price (descending order)
        euint16 insertIndex = TFHE.asEuint16(auction.bids.length);
        for (uint16 i = 0; i < auction.bids.length; i++) {
            // Find first position where current price is less than new price
            ebool lt = TFHE.lt(auction.bids[i].price, price);
            insertIndex = TFHE.select(lt, TFHE.asEuint16(i), insertIndex);
        }

        // Insert new bid
        auction.bids.push(Bid(bidder, quantity, price));

        // Sort bids by price (descending order)
        if (auction.bids.length > 1) {
            for (uint16 i1 = uint16(auction.bids.length - 1); i1 > 0; i1--) {
                uint16 i = i1 - 1; // Otherwise i-- would go out of bounds

                // Bid i
                eaddress bidderI = auction.bids[i].bidder;
                euint64 quantityI = auction.bids[i].quantity;
                euint64 priceI = auction.bids[i].price;

                // Bid i + 1
                eaddress bidderI1 = auction.bids[i + 1].bidder;
                euint64 quantityI1 = auction.bids[i + 1].quantity;
                euint64 priceI1 = auction.bids[i + 1].price;

                // If i >= insertIndex, swap bidder i and i + 1
                ebool ge = TFHE.ge(TFHE.asEuint16(i), insertIndex);
                auction.bids[i].bidder = TFHE.select(ge, bidderI1, bidderI);
                auction.bids[i].quantity = TFHE.select(ge, quantityI1, quantityI);
                auction.bids[i].price = TFHE.select(ge, priceI1, priceI);
                auction.bids[i + 1].bidder = TFHE.select(ge, bidderI, bidderI1);
                auction.bids[i + 1].quantity = TFHE.select(ge, quantityI, quantityI1);
                auction.bids[i + 1].price = TFHE.select(ge, priceI, priceI1);
            }
        }

        // Persist access to stored values
        for (uint256 i = 0; i < auction.bids.length; i++) {
            Bid memory bid = auction.bids[i];
            TFHE.allowThis(bid.bidder);
            TFHE.allowThis(bid.quantity);
            TFHE.allowThis(bid.price);
        }

        emit BidPlaced(_auctionId, msg.sender, quantity, price);
    }

    function endAuction(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(!auction.ended, "Auction already ended");

        // Determine settlement price.
        //
        // We know that the bidders are already sorted by price, so we can just
        // go down the list.
        euint64 remainingQuantity = TFHE.asEuint64(auction.totalQuantity);
        euint64 settlementPrice = TFHE.asEuint64(0);
        for (uint256 i = 0; i < auction.bids.length; i++) {
            eaddress bidder = auction.bids[i].bidder;
            euint64 bidQuantity = auction.bids[i].quantity;
            euint64 bidPrice = auction.bids[i].price;

            // if (bidQuantity <= remainingQuantity) {
            //     remainingQuantity -= bidQuantity;
            //     auction.payouts[bidder] = bidQuantity;
            //     auction.settlementPrice = auction.bids[bidder].price;
            // } else {
            //     auction.payouts[bidder] = remainingQuantity;
            //     remainingQuantity = 0;
            //     auction.settlementPrice = auction.bids[bidder].price;
            //     break;
            // }

            ebool rEq0 = TFHE.eq(remainingQuantity, TFHE.asEuint64(0));
            ebool bLeR = TFHE.le(bidQuantity, remainingQuantity);

            // Case A: rEq0
            euint64 remainingQuantityCaseA = TFHE.asEuint64(0);
            euint64 auctionPayoutCaseA = TFHE.asEuint64(0);
            euint64 settlementPriceCaseA = settlementPrice;

            // Case BA: !rEq0 && bLeR
            euint64 remainingQuantityCaseBA = TFHE.sub(remainingQuantity, bidQuantity);
            euint64 auctionPayoutCaseBA = bidQuantity;
            euint64 settlementPriceCaseBA = bidPrice;

            // Case BB: !rEq0 && !bLeR
            euint64 auctionPayoutCaseBB = remainingQuantity;
            euint64 remainingQuantityCaseBB = TFHE.asEuint64(0);
            euint64 settlementPriceCaseBB = bidPrice;

            // Reduce cases: BA, BB -> B
            euint64 auctionPayoutCaseB = TFHE.select(bLeR, auctionPayoutCaseBA, auctionPayoutCaseBB);
            euint64 remainingQuantityCaseB = TFHE.select(bLeR, remainingQuantityCaseBA, remainingQuantityCaseBB);
            euint64 settlementPriceCaseB = TFHE.select(bLeR, settlementPriceCaseBA, settlementPriceCaseBB);

            // Reduce cases: A, B -> Result
            remainingQuantity = TFHE.select(rEq0, remainingQuantityCaseA, remainingQuantityCaseB);
            auction.payouts.push(Payout(bidder, TFHE.select(rEq0, auctionPayoutCaseA, auctionPayoutCaseB)));
            settlementPrice = TFHE.select(rEq0, settlementPriceCaseA, settlementPriceCaseB);
        }

        auction.settlementPrice = settlementPrice;
        auction.refund = TFHE.mul(remainingQuantity, auction.settlementPrice);
        auction.ended = true;

        // Persist access to stored values
        TFHE.allowThis(auction.settlementPrice);
        TFHE.allowThis(auction.refund);
        for (uint256 i = 0; i < auction.payouts.length; i++) {
            Payout memory payout = auction.payouts[i];
            TFHE.allowThis(payout.bidder);
            TFHE.allowThis(payout.quantity);
        }

        emit AuctionEnded(auctionId, auction.settlementPrice);
    }

    function claimTokens(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(auction.ended, "Auction not yet ended");

        // If auction owner:

        if (msg.sender == auction.owner) {
            // Check if payment already claimed
            require(!auction.paymentClaimed, "Payment already claimed");

            // Refund remaining assets.
            TFHE.allowTransient(auction.refund, address(auction.assetToken));
            require(auction.assetToken.transfer(msg.sender, auction.refund), "Refund transfer failed");

            // Claim payment.
            euint64 totalPayment = TFHE.asEuint64(0);
            for (uint256 i = 0; i < auction.payouts.length; i++) {
                euint64 quantity = auction.payouts[i].quantity;
                totalPayment = TFHE.add(totalPayment, TFHE.mul(quantity, auction.settlementPrice));
            }
            TFHE.allowTransient(totalPayment, address(auction.paymentToken));
            require(auction.paymentToken.transfer(msg.sender, totalPayment), "Payment transfer failed");

            auction.paymentClaimed = true;
            return;
        }

        // If bidder:

        // Check if payout already claimed
        require(!auction.payoutClaimed[msg.sender], "Payout already claimed");

        // Compute total payout
        euint64 totalPayout = TFHE.asEuint64(0);
        for (uint256 i = 0; i < auction.payouts.length; i++) {
            eaddress bidder = auction.payouts[i].bidder;

            ebool eq = TFHE.eq(bidder, TFHE.asEaddress(msg.sender));
            euint64 quantity = TFHE.select(eq, auction.payouts[i].quantity, TFHE.asEuint64(0));
            totalPayout = TFHE.add(totalPayout, quantity);
        }

        // Compute total cost
        euint64 totalCost = TFHE.asEuint64(0);
        for (uint256 i = 0; i < auction.bids.length; i++) {
            eaddress bidder = auction.bids[i].bidder;
            euint64 bidQuantity = auction.bids[i].quantity;
            euint64 bidPrice = auction.bids[i].price;

            ebool eq = TFHE.eq(bidder, TFHE.asEaddress(msg.sender));
            euint64 bidCost = TFHE.select(eq, TFHE.mul(bidQuantity, bidPrice), TFHE.asEuint64(0));
            totalCost = TFHE.add(totalCost, bidCost);
        }

        // Transfer asset from owner to bidder
        TFHE.allowTransient(totalPayout, address(auction.assetToken));
        require(auction.assetToken.transfer(msg.sender, totalPayout), "Asset transfer failed");

        // Refund difference between actual cost and prepayment.
        euint64 refund = TFHE.sub(totalCost, TFHE.mul(totalPayout, auction.settlementPrice));
        TFHE.allowTransient(refund, address(auction.paymentToken));
        require(auction.paymentToken.transfer(msg.sender, refund), "Refund transfer failed");

        // Mark payout as claimed
        auction.payoutClaimed[msg.sender] = true;
    }
}
