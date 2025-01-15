// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm-contracts/contracts/token/ERC20/IConfidentialERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SinglePriceAuctionManager is SepoliaZamaFHEVMConfig {
    uint256 public auctionCounter;

    struct Auction {
        address owner;
        uint256 endTime;
        uint256 totalQuantity;
        uint256 settlementPrice;
        bool ended;
        IERC20 assetToken;
        IConfidentialERC20 paymentToken;
        mapping(address => Bid) bids;
        address[] bidders;
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
        auction.paymentToken = IConfidentialERC20(_paymentToken);

        // Transfer the assets from the owner to the contract.
        require(SafeERC20(auction.assetToken).transferFrom(msg.sender, address(this), _totalQuantity), "Asset transfer failed");

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
        auction.bidders.push(msg.sender);

        emit BidPlaced(auctionId, msg.sender, _quantity, _price);
    }

    function endAuction(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(!auction.ended, "Auction already ended");

        // Determine settlement price
        uint256 remainingQuantity = auction.totalQuantity;
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            if (auction.bids[bidder].quantity <= remainingQuantity) {
                remainingQuantity -= auction.bids[bidder].quantity;
            } else {
                auction.settlementPrice = auction.bids[bidder].price;
                break;
            }
        }

        auction.ended = true;
        emit AuctionEnded(auctionId, auction.settlementPrice);
    }

    function claimTokens(uint256 auctionId) external auctionEndedOnly(auctionId) {
        Auction storage auction = auctions[auctionId];
        require(auction.ended, "Auction not yet ended");
        require(auction.bids[msg.sender].exists, "No bid placed");

        uint256 quantity = auction.bids[msg.sender].quantity;
        uint256 price = auction.settlementPrice;
        uint256 totalCost = quantity * price;

        // Transfer payment from bidder to owner
        require(auction.paymentToken.transferFrom(msg.sender, auction.owner, totalCost), "Payment transfer failed");

        // Transfer asset from owner to bidder
        require(auction.assetToken.transfer(msg.sender, quantity), "Asset transfer failed");

        // Remove bid
        delete auction.bids[msg.sender];
    }
}
