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
        mapping(address => Bid) bids;
        address[] bidders;
        mapping(address => euint64) payouts;
        bool paymentClaimed;
    }

    struct Bid {
        euint64 quantity;
        euint64 price;
        bool exists;
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

        // TODO allow replacing bids
        require(!auction.bids[msg.sender].exists, "Bid already placed");

        euint64 quantity = TFHE.asEuint64(_quantity, _proof);
        euint64 price = TFHE.asEuint64(_price, _proof);

        euint64 totalCost = TFHE.mul(quantity, price);

        // Transfer payment from bidder to contract using confidential transfer
        require(auction.paymentToken.transferFrom(msg.sender, address(this), totalCost), "Payment transfer failed");

        auction.bids[msg.sender] = Bid(quantity, price, true);

        // Insert bidder in sorted order based on price
        // TODO use linked list to make this insertion operation more efficient
        bool inserted = false;
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            if (_price > auction.bids[auction.bidders[i]].price) {
                auction.bidders.push(auction.bidders[auction.bidders.length - 1]);
                for (uint256 j = auction.bidders.length - 1; j > i; j--) {
                    auction.bidders[j] = auction.bidders[j - 1];
                }
                auction.bidders[i] = msg.sender;
                inserted = true;
                break;
            }
        }
        if (!inserted) {
            auction.bidders.push(msg.sender);
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
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            euint64 bidQuantity = auction.bids[bidder].quantity;

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

            ebool rEq0 = TFHE.eq(remainingQuantity, 0);
            ebool bLeR = TFHE.le(bidQuantity, remainingQuantity);

            // Case A: rEq0
            euint64 remainingQuantityCaseA = TFHE.asEuint64(0);
            euint64 auctionPayoutCaseA = TFHE.asEuint64(0);
            euint64 settlementPriceCaseA = settlementPrice;

            // Case BA: !rEq0 && bLeR
            euint64 remainingQuantityCaseBA = TFHE.sub(remainingQuantity, bidQuantity);
            euint64 auctionPayoutCaseBA = bidQuantity;
            euint64 settlementPriceCaseBA = auction.bids[bidder].price;

            // Case BB: !rEq0 && !bLeR
            euint64 auctionPayoutCaseBB = remainingQuantity;
            euint64 remainingQuantityCaseBB = TFHE.asEuint64(0);
            euint64 settlementPriceCaseBB = auction.bids[bidder].price;

            // Reduce cases: BA, BB -> B
            euint64 auctionPayoutCaseB = TFHE.select(bLeR, auctionPayoutCaseBA, auctionPayoutCaseBB);
            euint64 remainingQuantityCaseB = TFHE.select(bLeR, remainingQuantityCaseBA, remainingQuantityCaseBB);
            euint64 settlementPriceCaseB = TFHE.select(bLeR, settlementPriceCaseBA, settlementPriceCaseBB);

            // Reduce cases: A, B -> Result
            remainingQuantity = TFHE.select(rEq0, remainingQuantityCaseA, remainingQuantityCaseB);
            auction.payouts[bidder] = TFHE.select(rEq0, auctionPayoutCaseA, auctionPayoutCaseB);
            settlementPrice = TFHE.select(rEq0, settlementPriceCaseA, settlementPriceCaseB);
        }

        auction.settlementPrice = settlementPrice;
        auction.refund = TFHE.mul(remainingQuantity, auction.settlementPrice);
        auction.ended = true;
        emit AuctionEnded(auctionId, auction.settlementPrice);
    }

    function claimTokens(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(auction.ended, "Auction not yet ended");

        // If auction owner:
        if (msg.sender == auction.owner) {
            // Refund remaining assets.
            require(auction.assetToken.transfer(msg.sender, auction.refund), "Refund transfer failed");

            // Claim payment.
            euint64 totalPayment = TFHE.asEuint64(0);
            for (uint256 i = 0; i < auction.bidders.length; i++) {
                address bidder = auction.bidders[i];
                totalPayment = TFHE.add(totalPayment, TFHE.mul(auction.payouts[bidder], auction.settlementPrice));
            }
            require(auction.paymentToken.transfer(msg.sender, totalPayment), "Payment transfer failed");

            auction.paymentClaimed = true;
            return;
        }

        // If bidder:
        Bid storage bid = auction.bids[msg.sender];
        require(bid.exists, "No bid placed");

        // Transfer asset from owner to bidder
        euint64 payout = auction.payouts[msg.sender];
        require(auction.assetToken.transfer(msg.sender, payout), "Asset transfer failed");

        // Refund difference between actual cost and prepayment.
        euint64 refund = TFHE.sub(TFHE.mul(bid.quantity, bid.price), TFHE.mul(payout, auction.settlementPrice));
        require(auction.paymentToken.transfer(msg.sender, refund), "Refund transfer failed");

        // Remove bid
        delete auction.bids[msg.sender];
    }
}
