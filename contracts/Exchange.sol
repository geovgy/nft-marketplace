// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

contract NFTExchange is ReentrancyGuard, Ownable {
  bytes4 private constant ERC721_INTERFACE_ID = 0x80ac58cd;
  bytes4 private constant ERC1155_INTERFACE_ID = 0xd9b67a26;
  bytes4 private constant ERC2981_INTERFACE_ID = 0x2a55205a;

  enum NFT_TYPE {ERC721, ERC1155}

  struct Bid {
    address buyer;
    address nftAddress;
    uint256 tokenId;
    uint256 units;
    NFT_TYPE standard;
    address erc20Address;
    uint256 amount;
    uint256 createdAt;
    uint256 expiresAt;
  }

  struct Ask {
    address seller;
    address nftAddress;
    uint256 tokenId;
    uint256 units;
    NFT_TYPE standard;
    address erc20Address;
    uint256 buyNowAmount;
    uint256 createdAt;
    uint256 expiresAt;
  }

  // Query contract address then tokenId for array of indexes.
  // Indexes are to retrieve Bid from _allBids.
  mapping(address => mapping(uint256 => uint256[])) private _bidsByToken;
  mapping(uint256 => Bid) private _allBids;
  uint256 private _bidCount;

  // Query contract address then tokenId for array of indexes.
  // Indexes are to retrieve Ask from _allAsks.
  mapping(address => mapping(uint256 => uint256[])) private _asksByToken;
  mapping(uint256 => Ask) private _allAsks;
  uint256 private _askCount;
  
  // Commission fee for trades
  // basis points out of 10000
  uint256 private TRADE_FEE;

  constructor(uint256 fee) {
    setTradeFee(fee);
  }

  function setTradeFee(uint256 fee) public onlyOwner {
    TRADE_FEE = fee;
  }

  function calculateFee(uint256 amount) public view returns (uint256) {
    return amount * TRADE_FEE / 10000;
  }

  function placeBid(
    address nftAddress,
    uint256 tokenId,
    uint256 units,
    address erc20Address,
    uint256 amount,
    uint256 expiration
  ) external {
    require(erc20Address != address(0), "Exchange: must include a ERC20 token address");
    require(units > 0, "Exchange: units must be more than zero");
    bool isERC721 = IERC165(nftAddress).supportsInterface(ERC721_INTERFACE_ID);
    bool isERC1155 = IERC165(nftAddress).supportsInterface(ERC1155_INTERFACE_ID);
    uint256 allowance = IERC20(erc20Address).allowance(msg.sender, address(this));
    if (allowance >= amount) {
      if (isERC721) {
        address owner = IERC721(nftAddress).ownerOf(tokenId);
        // bool isApproved = IERC721(nftAddress).getApproved(tokenId) == address(this) || IERC721(nftAddress).isApprovedForAll(owner, address(this));
        if (owner != msg.sender) {
          Bid memory newBid = Bid(msg.sender, nftAddress, tokenId, units, NFT_TYPE.ERC721, erc20Address, amount, block.timestamp, expiration);
          _allBids[_bidCount] = newBid;
          _bidsByToken[nftAddress][tokenId].push(_bidCount);
          _bidCount++;
        }
      } else if (isERC1155) {
        Bid memory newBid = Bid(msg.sender, nftAddress, tokenId, units, NFT_TYPE.ERC1155, erc20Address, amount, block.timestamp, expiration);
        _allBids[_bidCount] = newBid;
        _bidsByToken[nftAddress][tokenId].push(_bidCount);
        _bidCount++;
      }
    }
  }

  function placeAsk(
    address nftAddress,
    uint256 tokenId,
    uint256 units,
    address erc20Address,
    uint256 buyNowAmount,
    uint256 expiration
  ) external {
    bool isERC721 = IERC165(nftAddress).supportsInterface(ERC721_INTERFACE_ID);
    bool isERC1155 = IERC165(nftAddress).supportsInterface(ERC1155_INTERFACE_ID);
    if (isERC721) {
      address owner = IERC721(nftAddress).ownerOf(tokenId);
      require(owner == msg.sender, "Exchange: cannot sell a token you do not own");
      bool isApproved = IERC721(nftAddress).getApproved(tokenId) == address(this) || IERC721(nftAddress).isApprovedForAll(owner, address(this));
      if (isApproved && owner == msg.sender) {
        Ask memory newAsk = Ask(msg.sender, nftAddress, tokenId, units, NFT_TYPE.ERC721, erc20Address, buyNowAmount, block.timestamp, expiration);
        _allAsks[_askCount] = newAsk;
        _asksByToken[nftAddress][tokenId].push(_askCount);
        _askCount++;
      }
    } else if (isERC1155) {
      uint256 balance = IERC1155(nftAddress).balanceOf(msg.sender, tokenId);
      bool isApproved = IERC1155(nftAddress).isApprovedForAll(msg.sender, address(this));
      if (isApproved && balance >= 1) {
        Ask memory newAsk = Ask(msg.sender, nftAddress, tokenId, units, NFT_TYPE.ERC1155, erc20Address, buyNowAmount, block.timestamp, expiration);
        _allAsks[_askCount] = newAsk;
        _asksByToken[nftAddress][tokenId].push(_askCount);
        _askCount++;
      }
    }
  }

  function acceptBid(uint256 index) external {
    require(index <= _askCount, "Exchange: index is above maximum count of asks");
    Bid memory bid = _allBids[index];
    uint256 commission = calculateFee(bid.amount);
    bool isERC2981 = IERC165(bid.nftAddress).supportsInterface(ERC2981_INTERFACE_ID);
    uint256 royalty;
    address royaltyReceiver;
    if (isERC2981) {
      (royaltyReceiver, royalty) = IERC2981(bid.nftAddress).royaltyInfo(bid.tokenId, bid.amount);
    }
    if (bid.standard == NFT_TYPE.ERC721) {
      address owner = IERC721(bid.nftAddress).ownerOf(bid.tokenId);
      bool isApproved = IERC721(bid.nftAddress).getApproved(bid.tokenId) == address(this) || IERC721(bid.nftAddress).isApprovedForAll(owner, address(this));
      if (owner == msg.sender && isApproved) {
        if (royalty > 0) {
          IERC20(bid.erc20Address).transferFrom(bid.buyer, royaltyReceiver, royalty);
          IERC20(bid.erc20Address).transferFrom(bid.buyer, address(this), commission);
          IERC20(bid.erc20Address).transferFrom(bid.buyer, msg.sender, bid.amount - (commission + royalty));
        } else {
          IERC20(bid.erc20Address).transferFrom(bid.buyer, msg.sender, bid.amount - commission);
          IERC20(bid.erc20Address).transferFrom(bid.buyer, address(this), commission);
        }
        IERC721(bid.nftAddress).safeTransferFrom(msg.sender, bid.buyer, bid.tokenId);
      }
    } else if (bid.standard == NFT_TYPE.ERC1155) {
      uint256 balance = IERC1155(bid.nftAddress).balanceOf(msg.sender, bid.tokenId);
      bool isApproved = IERC1155(bid.nftAddress).isApprovedForAll(msg.sender, address(this));
      if (isApproved && balance >= 1) {
        if (royalty > 0) {
          IERC20(bid.erc20Address).transferFrom(bid.buyer, royaltyReceiver, royalty);
          IERC20(bid.erc20Address).transferFrom(bid.buyer, address(this), commission);
          IERC20(bid.erc20Address).transferFrom(bid.buyer, msg.sender, bid.amount - (commission + royalty));
        } else {
          IERC20(bid.erc20Address).transferFrom(bid.buyer, msg.sender, bid.amount - commission);
          IERC20(bid.erc20Address).transferFrom(bid.buyer, address(this), commission);
        }
        IERC1155(bid.nftAddress).safeTransferFrom(msg.sender, bid.buyer, bid.tokenId, bid.units, bytes(""));
      }
    }
  }

  function buyNow(uint256 index, uint256 amount) external {
    require(index <= _askCount, "Exchange: index is above maximum count of asks");
    require(_allAsks[index].buyNowAmount > 0, "Exchange: no buy now amount available");
    require(_allAsks[index].erc20Address != address(0), "Exchange: Asking price is not in native currency");
    require(amount >= _allAsks[index].buyNowAmount, "Exchange: amount is too low");

    bool isERC2981 = IERC165(_allAsks[index].nftAddress).supportsInterface(ERC2981_INTERFACE_ID);
    address royaltyReceiver;
    uint256 royalty;
    if (isERC2981) {
      (royaltyReceiver, royalty) = IERC2981(_allAsks[index].nftAddress).royaltyInfo(_allAsks[index].tokenId, amount);
    }
    uint256 commission = calculateFee(amount);
    if (_allAsks[index].standard == NFT_TYPE.ERC721) {
      address owner = IERC721(_allAsks[index].nftAddress).ownerOf(_allAsks[index].tokenId);
      bool isApproved = IERC721(_allAsks[index].nftAddress).getApproved(_allAsks[index].tokenId) == address(this) || IERC721(_allAsks[index].nftAddress).isApprovedForAll(_allAsks[index].seller, address(this));
      if (owner == address(_allAsks[index].seller) && isApproved) {
        if (royalty > 0) {
          IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, royaltyReceiver, royalty);
          IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, address(this), commission);
          IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, _allAsks[index].seller, amount - (commission + royalty));
        } else {
          IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, address(this), commission);
          IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, _allAsks[index].seller, amount - commission);
        }
        IERC721(_allAsks[index].nftAddress).safeTransferFrom(_allAsks[index].seller, msg.sender, _allAsks[index].tokenId);
      }
    } else if (_allAsks[index].standard == NFT_TYPE.ERC1155) {
      // Add trade equivalent for ERC115 token
      if (royalty > 0) {
        IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, royaltyReceiver, royalty);
        IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, address(this), commission);
        IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, _allAsks[index].seller, amount - (commission + royalty));
      } else {
        IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, address(this), commission);
        IERC20(_allAsks[index].erc20Address).transferFrom(msg.sender, _allAsks[index].seller, amount - commission);
      }
      IERC1155(_allAsks[index].nftAddress).safeTransferFrom(_allAsks[index].seller, msg.sender, _allAsks[index].tokenId, _allAsks[index].units, bytes(""));
    }
  }

  // TO DO: ERC2981 royalty distribution still needs to be implemented in this function
  function buyNow(uint256 index) external payable {
    require(index <= _askCount, "Exchange: index is above maximum count of asks");
    require(_allAsks[index].buyNowAmount > 0, "Exchange: no buy now amount available");
    require(_allAsks[index].erc20Address == address(0), "Exchange: Asking price is not in native currency");
    require(msg.value >= _allAsks[index].buyNowAmount, "Exchange: msg.value is too low");

    uint256 commission = calculateFee(msg.value);
    if (_allAsks[index].standard == NFT_TYPE.ERC721) {
      address owner = IERC721(_allAsks[index].nftAddress).ownerOf(_allAsks[index].tokenId);
      bool isApproved = IERC721(_allAsks[index].nftAddress).getApproved(_allAsks[index].tokenId) == address(this) || IERC721(_allAsks[index].nftAddress).isApprovedForAll(_allAsks[index].seller, address(this));
      if (owner == address(_allAsks[index].seller) && isApproved) {
        payable(_allAsks[index].seller).transfer(msg.value - commission);
        IERC721(_allAsks[index].nftAddress).safeTransferFrom(_allAsks[index].seller, msg.sender, _allAsks[index].tokenId);
      }
    } else if (_allAsks[index].standard == NFT_TYPE.ERC1155) {
      // Add trade equivalent for ERC115 token
      payable(_allAsks[index].seller).transfer(msg.value - commission);
      IERC1155(_allAsks[index].nftAddress).safeTransferFrom(_allAsks[index].seller, msg.sender, _allAsks[index].tokenId, _allAsks[index].units, bytes(""));
    }
  }

  // TO DO
  function _removeOffer(uint256 index) internal {}
}