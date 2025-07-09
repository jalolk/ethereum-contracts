// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract NFTMarketplace is ERC721URIStorage, ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;
    
    Counters.Counter private _tokenIds;
    Counters.Counter private _itemsSold;
    
    uint256 public listingPrice = 0.025 ether;
    
    struct MarketItem {
        uint256 tokenId;
        address payable seller;
        address payable owner;
        uint256 price;
        bool sold;
        uint256 timestamp;
    }
    
    mapping(uint256 => MarketItem) public marketItems;
    
    event MarketItemCreated(
        uint256 indexed tokenId,
        address seller,
        address owner,
        uint256 price,
        bool sold
    );
    
    event MarketItemSold(
        uint256 indexed tokenId,
        address seller,
        address buyer,
        uint256 price
    );
    
    event PriceUpdated(uint256 indexed tokenId, uint256 newPrice);
    
    constructor() ERC721("NFT Marketplace", "NFTM") Ownable(msg.sender) {}
    
    function updateListingPrice(uint256 _listingPrice) public onlyOwner {
        listingPrice = _listingPrice;
    }
    
    function createToken(string memory tokenURI, uint256 price) 
        public 
        payable 
        nonReentrant 
        returns (uint256) 
    {
        require(price > 0, "Price must be greater than 0");
        require(msg.value == listingPrice, "Must pay listing price");
        
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        
        _mint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI);
        
        createMarketItem(newTokenId, price);
        
        return newTokenId;
    }
    
    function createMarketItem(uint256 tokenId, uint256 price) private {
        require(price > 0, "Price must be greater than 0");
        require(msg.value == listingPrice, "Must pay listing price");
        
        marketItems[tokenId] = MarketItem(
            tokenId,
            payable(msg.sender),
            payable(address(0)),
            price,
            false,
            block.timestamp
        );
        
        _transfer(msg.sender, address(this), tokenId);
        
        emit MarketItemCreated(
            tokenId,
            msg.sender,
            address(0),
            price,
            false
        );
    }
    
    function createMarketSale(uint256 tokenId) public payable nonReentrant {
        MarketItem storage item = marketItems[tokenId];
        uint256 price = item.price;
        
        require(msg.value == price, "Must pay asking price");
        require(!item.sold, "Item already sold");
        
        item.seller.transfer(msg.value);
        _transfer(address(this), msg.sender, tokenId);
        
        item.owner = payable(msg.sender);
        item.sold = true;
        
        _itemsSold.increment();
        payable(owner()).transfer(listingPrice);
        
        emit MarketItemSold(tokenId, item.seller, msg.sender, price);
    }
    
    function resellToken(uint256 tokenId, uint256 price) 
        public 
        payable 
        nonReentrant 
    {
        require(ownerOf(tokenId) == msg.sender, "Only owner can resell");
        require(msg.value == listingPrice, "Must pay listing price");
        require(price > 0, "Price must be greater than 0");
        
        marketItems[tokenId] = MarketItem(
            tokenId,
            payable(msg.sender),
            payable(address(0)),
            price,
            false,
            block.timestamp
        );
        
        _transfer(msg.sender, address(this), tokenId);
        
        emit MarketItemCreated(
            tokenId,
            msg.sender,
            address(0),
            price,
            false
        );
    }
    
    function updatePrice(uint256 tokenId, uint256 newPrice) public {
        require(marketItems[tokenId].seller == msg.sender, "Only seller can update price");
        require(!marketItems[tokenId].sold, "Cannot update price of sold item");
        require(newPrice > 0, "Price must be greater than 0");
        
        marketItems[tokenId].price = newPrice;
        emit PriceUpdated(tokenId, newPrice);
    }
    
    function fetchMarketItems() public view returns (MarketItem[] memory) {
        uint itemCount = _tokenIds.current();
        uint unsoldItemCount = _tokenIds.current() - _itemsSold.current();
        uint currentIndex = 0;
        
        MarketItem[] memory items = new MarketItem[](unsoldItemCount);
        
        for (uint i = 0; i < itemCount; i++) {
            if (marketItems[i + 1].owner == address(0)) {
                uint currentId = i + 1;
                MarketItem storage currentItem = marketItems[currentId];
                items[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        
        return items;
    }
    
    function fetchMyNFTs() public view returns (MarketItem[] memory) {
        uint totalItemCount = _tokenIds.current();
        uint itemCount = 0;
        uint currentIndex = 0;
        
        for (uint i = 0; i < totalItemCount; i++) {
            if (marketItems[i + 1].owner == msg.sender) {
                itemCount += 1;
            }
        }
        
        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (marketItems[i + 1].owner == msg.sender) {
                uint currentId = i + 1;
                MarketItem storage currentItem = marketItems[currentId];
                items[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        
        return items;
    }
    
    function fetchItemsCreated() public view returns (MarketItem[] memory) {
        uint totalItemCount = _tokenIds.current();
        uint itemCount = 0;
        uint currentIndex = 0;
        
        for (uint i = 0; i < totalItemCount; i++) {
            if (marketItems[i + 1].seller == msg.sender) {
                itemCount += 1;
            }
        }
        
        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (marketItems[i + 1].seller == msg.sender) {
                uint currentId = i + 1;
                MarketItem storage currentItem = marketItems[currentId];
                items[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        
        return items;
    }
    
    function getMarketStats() public view returns (
        uint256 totalItems,
        uint256 soldItems,
        uint256 availableItems,
        uint256 totalVolume
    ) {
        totalItems = _tokenIds.current();
        soldItems = _itemsSold.current();
        availableItems = totalItems - soldItems;
        
        // Calculate total volume
        uint256 volume = 0;
        for (uint i = 1; i <= totalItems; i++) {
            if (marketItems[i].sold) {
                volume += marketItems[i].price;
            }
        }
        
        return (totalItems, soldItems, availableItems, volume);
    }
    
    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");
    }
}