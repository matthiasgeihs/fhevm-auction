// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
// import "fhevm-contracts/contracts/token/ERC20/IConfidentialERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SinglePriceAuctionManager is SepoliaZamaFHEVMConfig {
    uint256 public auctionCounter;

    struct Auction {
        address owner;
        uint256 endTime;
        uint256 totalQuantity;
        uint256 settlementPrice;
        uint256 refund;
        bool ended;
        IERC20 assetToken;
        IERC20 paymentToken; // TODO make this a confidential erc20
        mapping(address => Bid) bids;
        address[] bidders;
        mapping(address => uint256) payouts;
        bool paymentClaimed;
    }

    struct Bid {
        uint256 quantity;
        uint256 price;
        bool exists;
    }

    mapping(uint256 => Auction) public auctions;

    event AuctionCreated(uint256 auctionId, uint256 endTime, uint256 quantity, address assetToken, address paymentToken);
    event BidPlaced(uint256 auctionId, address indexed bidder, uint256 quantity, uint256 price);
    event AuctionEnded(uint256 auctionId, uint256 settlementPrice);

    modifier auctionActive(uint256 auctionId) {
        require(block.timestamp < auctions[auctionId].endTime, "Auction already ended");
        _;
    }

    modifier auctionEndedOnly(uint256 auctionId) {
        require(block.timestamp >= auctions[auctionId].endTime, "Auction not yet ended");
        _;
    }

    function createAuction(uint256 _auctionDuration, uint256 _totalQuantity, address _assetToken, address _paymentToken) external {
        auctionCounter++;
        uint256 auctionId = auctionCounter;
        Auction storage auction = auctions[auctionId];
        auction.owner = msg.sender;
        auction.endTime = block.timestamp + _auctionDuration;
        auction.totalQuantity = _totalQuantity;
        auction.assetToken = IERC20(_assetToken);
        auction.paymentToken = IERC20(_paymentToken);

        // Transfer the assets from the owner to the contract.
        require(auction.assetToken.transferFrom(msg.sender, address(this), _totalQuantity), "Asset transfer failed");

        emit AuctionCreated(auctionId, auction.endTime, _totalQuantity, _assetToken, _paymentToken);
    }

    function placeBid(uint256 auctionId, uint256 _quantity, uint256 _price) external auctionActive(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(_quantity > 0, "Quantity must be greater than 0");
        require(_price > 0, "Price must be greater than 0");
        // TODO allow replacing bids
        require(!auction.bids[msg.sender].exists, "Bid already placed");

        uint256 totalCost = _quantity * _price;

        // Transfer payment from bidder to contract
        // TODO this needs to be done using ConfidentialERC20
        require(auction.paymentToken.transferFrom(msg.sender, address(this), totalCost), "Payment transfer failed");

        auction.bids[msg.sender] = Bid(_quantity, _price, true);
        
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

        emit BidPlaced(auctionId, msg.sender, _quantity, _price);
    }

    function endAuction(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(!auction.ended, "Auction already ended");

        // Determine settlement price.
        //
        // We know that the bidders are already sorted by price, so we can just
        // go down the list.
        uint256 remainingQuantity = auction.totalQuantity;
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            uint256 bidQuantity = auction.bids[bidder].quantity;
            
            if (bidQuantity <= remainingQuantity) {
                remainingQuantity -= bidQuantity;
                auction.payouts[bidder] = bidQuantity;
                auction.settlementPrice = auction.bids[bidder].price;
            } else {
                remainingQuantity = 0;
                auction.payouts[bidder] = remainingQuantity;
                auction.settlementPrice = auction.bids[bidder].price;
                break;
            }
        }

        auction.refund = remainingQuantity * auction.settlementPrice;
        auction.ended = true;
        emit AuctionEnded(auctionId, auction.settlementPrice);
    }

    function claimTokens(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(auction.ended, "Auction not yet ended");

        // If auction owner:
        if (msg.sender == auction.owner) {
            // Refund remaining assets.
            require(auction.assetToken.transfer(auction.owner, auction.refund), "Refund transfer failed");

            // Claim payment.
            uint256 totalPayment = 0;
            for (uint256 i = 0; i < auction.bidders.length; i++) {
                address bidder = auction.bidders[i];
                totalPayment += auction.payouts[bidder] * auction.settlementPrice;
            }
            require(auction.paymentToken.transfer(auction.owner, totalPayment), "Payment transfer failed");

            auction.paymentClaimed = true;
            return;
        }

        // If bidder:
        Bid storage bid = auction.bids[msg.sender];
        require(bid.exists, "No bid placed");

        // Transfer asset from owner to bidder
        uint256 payout = auction.payouts[msg.sender];
        require(auction.assetToken.transfer(msg.sender, payout), "Asset transfer failed");

        // Refund difference between actual cost and prepayment.
        uint256 refund = bid.quantity * bid.price - payout * auction.settlementPrice;
        require(auction.paymentToken.transfer(msg.sender, refund), "Refund transfer failed");

        // Remove bid
        delete auction.bids[msg.sender];
    }
}
