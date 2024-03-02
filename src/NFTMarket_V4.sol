//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/INFTMarket_V4.sol";
import "./interfaces/INFTPermit.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IWETH9.sol";

/**
 * @title This is an NFT exchange contract that can provide trading for ERC721 Tokens. Various ERC721 tokens are able to be traded here.
 * This contract was updated from `NFTMarket_V3`.
 * New features are added into this new version. Now, any ERC-20 token can use to buy NFT in this NFT exchange.
 * Now, listed NFTs are valued in WETH(equivalent to ETH) in the current version.
 *
 * @author Garen Woo
 */
contract NFTMarket_V4 is INFTMarket_V4, IERC721Receiver {
    address private owner;
    address immutable private NFTMarketTokenAddr;
    address public wrappedETHAddr;
    address public routerAddr;
    address public KKToken;
    mapping(address NFTAddr => mapping(uint256 tokenId => uint256 priceInETH)) private price;
    mapping(address user => uint256 balanceInWETH) private userProfit;
    uint256 public stakeWETHPool;
    uint256 public constant txFeeRatio_Figure = 10;
    uint256 public constant txFeeRatio_Decimal = 2;

    using SafeERC20 for IERC20;

    constructor(address _tokenAddr, address _wrappedETHAddr, address _routerAddr, address _KKToken) {
        owner = msg.sender;
        NFTMarketTokenAddr= _tokenAddr;
        wrappedETHAddr = _wrappedETHAddr;
        routerAddr = _routerAddr;
        KKToken = _KKToken;
    }

    modifier onlyNFTMarketOwner() {
        if (msg.sender != owner) {
            revert notOwnerOfNFTMarket();
        }
        _;
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    /**
     * @notice Once this function is called, the 'msg.sender' will try to buy NFT with the token transferred.
     * The NFT address and tokenId of the NFT separately come from `nftAddress` and 'tokenId', which are decoded from the `data` in the input list.
     *
     * @dev Important! If your NFT project supports the function of buying NFT with off-chain signature of messages(i.e.permit), make sure the NFT contract(s) should have realized the functionality of the interface {INFTPermit}.
     * Without the realization of {INFTPermit}, malevolent EOAs can directly buy NFTs without permit-checking.
     *
     * @param _recipient the NFT recipient(also the buyer of the NFT)
     * @param _ERC20TokenAddr the address of the ERC-20 token used for buying the NFT
     * @param _tokenAmount the amount of the ERC-20 token used for buying the NFT
     * @param _data the encoded data containing `nftAddress` and `tokenId`
     */
    function tokensReceived(address _recipient, address _ERC20TokenAddr, uint256 _tokenAmount, bytes calldata _data) external {
        (address nftAddress, uint256 tokenId) = abi.decode(_data, (address, uint256));
        bool checkResult = _beforeNFTPurchase(_recipient, _ERC20TokenAddr, nftAddress, tokenId);

        // To avoid users directly buying NFTs which require checking of whitelist membership, here check the interface existence of {_support_IERC721Permit}.
        bool isERC721PermitSupported = _support_IERC721Permit(nftAddress);
        if (isERC721PermitSupported) {
            revert ERC721PermitBoughtByWrongFunction("tokenReceived", "buyWithPermit");
        }
        
        // If all the checks have passed, here comes the execution of the NFT purchase.
        if (checkResult) {
            uint256 tokenAmountPaid = _handleNFTPurchase(_recipient, _ERC20TokenAddr, nftAddress, tokenId, _tokenAmount);
            emit NFTBoughtWithAnyToken(_recipient, _ERC20TokenAddr, nftAddress, tokenId, tokenAmountPaid);
        }
    }

    /**
     * @notice List an NFT by its owner with a given price in WETH.
     * Once the NFT is listed:
     * The actual owner of the NFT is the NFT exchange.
     * The previous owner of the NFT(the EOA who lists the NFT) is the current '_tokenApprovals'(at ERC721.sol) of the NFT.
     * The spender which needs to be approved should be set as the buyer.
     */
    function list(address _nftAddr, uint256 _tokenId, uint256 _priceInWETH) external {
        if (msg.sender != IERC721(_nftAddr).ownerOf(_tokenId)) {
            revert notOwnerOfNFT();
        }
        if (_priceInWETH == 0) revert zeroPrice();
        require(price[_nftAddr][_tokenId] == 0, "This NFT is already listed");
        _List(_nftAddr, _tokenId, _priceInWETH);
    }

    /**
     * @dev Besides `list`, this function is also used to list NFT on an NFT exchange.
     *  this function verifies off-chain signature of the message signed by the owner of the NFT.
     *  List NFT in this way can have better user experience, because valid signature will lead to automatic approval.
     */
    function listWithPermit(
        address _nftAddr,
        uint256 _tokenId,
        uint256 _priceInWETH,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        if (_priceInWETH == 0) revert zeroPrice();
        require(price[_nftAddr][_tokenId] == 0, "This NFT is already listed");
        bool isPermitVerified = INFTPermit(_nftAddr).NFTPermit_PrepareForList(
            address(this), _tokenId, _priceInWETH, _deadline, _v, _r, _s
        );
        if (isPermitVerified) {
            _List(_nftAddr, _tokenId, _priceInWETH);
        }
    }

    /**
     * @dev Delist the NFT from an NFT Market.
     */
    function delist(address _nftAddr, uint256 _tokenId) external {
        require(IERC721(_nftAddr).getApproved(_tokenId) == msg.sender, "Not seller or Not on sale");
        if (price[_nftAddr][_tokenId] == 0) revert notOnSale(_nftAddr, _tokenId);
        IERC721(_nftAddr).safeTransferFrom(address(this), msg.sender, _tokenId, "Delist successfully");
        delete price[_nftAddr][_tokenId];
        emit NFTDelisted(msg.sender, _nftAddr, _tokenId);
    }

    /**
     * @notice Directly Buy NFT using ERC-20 token of this NFTMarket(named "GSTS") without checking ERC721 token permit.
     *
     * @dev Important! If your NFT project supports the function of buying NFT with off-chain signature of messages(i.e.permit), make sure the NFT contract(s) should have realized the functionality of the interface {INFTPermit}.
     * Without the realization of {realized the functionality of the interface {INFTPermit}.}, malevolent EOAs can directly buy NFTs without permit-checking.
     */
    function buyWithGTST(address _nftAddr, uint256 _tokenId, uint256 _tokenAmount) external {
        bool checkResult = _beforeNFTPurchase(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId);

        // To avoid users directly buying NFTs which require checking of whitelist membership, here check the interface existence of {_support_IERC721Permit}.
        bool isERC721PermitSupported = _support_IERC721Permit(_nftAddr);
        if (isERC721PermitSupported) {
            revert ERC721PermitBoughtByWrongFunction("buy", "buyWithPermit");
        }
        
        // If all the checks have passed, here comes the execution of the NFT purchase.
        if (checkResult) {
            _handleNFTPurchaseUsingGTST(msg.sender, _nftAddr, _tokenId, _tokenAmount);
            emit NFTBoughtWithGTST(msg.sender, _nftAddr, _tokenId, _tokenAmount);
        }
    }

    /**
     * @notice Buy NFT using any ERC-20 token without checking ERC721 token permit.
     *
     * @dev Important! If your NFT project supports the function of buying NFT with off-chain signature of messages(i.e.permit), make sure the NFT contract(s) should have realized the functionality of the interface {INFTPermit}.
     * Without the realization of {realized the functionality of the interface {INFTPermit}.}, malevolent EOAs can directly buy NFTs without permit-checking.
     */
    function buyNFTWithAnyToken(address _ERC20TokenAddr, address _nftAddr, uint256 _tokenId, uint256 _slippageLiteral, uint256 _slippageDecimal) external {
        bool checkResult = _beforeNFTPurchase(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId);

        // To avoid users directly buying NFTs which require checking of whitelist membership, here check the interface existence of {_support_IERC721Permit}.
        bool isERC721PermitSupported = _support_IERC721Permit(_nftAddr);
        if (isERC721PermitSupported) {
            revert ERC721PermitBoughtByWrongFunction("buy", "buyWithPermit");
        }
        
        // If all the checks have passed, here comes the execution of the NFT purchase.
        if (checkResult) {
            uint256 tokenAmountPaid = _handleNFTPurchaseWithSlippage(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId, _slippageLiteral, _slippageDecimal);
            emit NFTBoughtWithAnyToken(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId, tokenAmountPaid);
        }
    }

    /**
     * @notice Buy NFT with validating the given signature to ensure whitelist membership of `msg.sender`.
     */
    function buyWithPermit(
        address _ERC20TokenAddr,
        address _nftAddr,
        uint256 _tokenId,
        uint256 _tokenAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        bool checkResult = _beforeNFTPurchase(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId);
        
        // Validate the signature of the typed message with given inputs.
        bool isPermitVerified = INFTPermit(_nftAddr).NFTPermit_PrepareForBuy(
            msg.sender, _tokenId, _deadline, _v, _r, _s
        );

        // If all the checks have passed, here comes the execution of the NFT purchase.
        if (checkResult && isPermitVerified) {
            uint256 tokenAmountPaid = _handleNFTPurchase(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId, _tokenAmount);
            emit NFTBoughtWithPermit(msg.sender, _ERC20TokenAddr, _nftAddr, _tokenId, tokenAmountPaid);
        }
    }

    /**
     * @notice Withdraw a custom amount of ETH from the user's balance which is equivalent to the earned value of selling NFTs.
     */
    function withdrawBalanceByUser(uint256 _value) external {
        if (_value > userProfit[msg.sender]) {
            revert withdrawalExceedBalance(_value, userProfit[msg.sender]);
        }
        userProfit[msg.sender] -= _value;
        IWETH9(wrappedETHAddr).withdraw(_value);
        (bool _success, ) = payable(msg.sender).call{value: _value}("");
        require(_success, "withdraw ETH failed");
        emit withdrawBalance(msg.sender, _value);
    }

    /**
     * @notice Modify the price of the NFT of the specific tokenId.
     */
    function modifyPriceForNFT(address _nftAddr, uint256 _tokenId, uint256 _newPriceInWETH) public {
        require(IERC721(_nftAddr).getApproved(_tokenId) != msg.sender, "Not seller or Not on sale");
        price[_nftAddr][_tokenId] = _newPriceInWETH;
    }

    /**
     * @notice  This function supports users to pre-approve `address(this)` with ERC2612(ERC20-Permit) tokens by signing messages off-chain.
     * This function is usually called before calling `claimNFT`.
     */
    function permitPrePay(address _ERC20TokenAddr, address _tokenOwner, uint256 _tokenAmount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public returns (bool) {
        bool isIERC20Supported = _support_IERC20(_ERC20TokenAddr);
        bool isIERC20PermitSupported = _support_IERC20Permit(_ERC20TokenAddr);
        if (!isIERC20Supported || !isIERC20PermitSupported) {
            revert notERC20PermitToken(_ERC20TokenAddr);
        }
        IERC20Permit(_ERC20TokenAddr).permit(_tokenOwner, address(this), _tokenAmount, _deadline, _v, _r, _s);
        emit prepay(_tokenOwner, _tokenAmount);
        return true;
    }

    /**
     * @notice Users who are allowed to get NFTs with agreed prices.
     * The membership of the whitelist should be in the form of a Merkle tree.
     * Before calling this function, the user should approve `address(this)` with sufficient allowance.
     * The function `permitPrePay` is recommended for the approval.
     *
     * @param _recipient the address which is the member of whitelist as well as the recipient of the claimed NFT
     * @param _promisedTokenId the tokenId corresponds to the NFT which is specified to a member in the NFT's whitelist
     * @param _merkleProof a dynamic array which contains Merkle proof is used for validating the membership of the caller. This should be offered by the project party
     * @param _promisedPriceInETH the promised price(unit: wei) of the NFT corresponding to `_promisedTokenId`, which is one of the fields of each Merkle tree node
     * @param _NFTWhitelistData a bytes variable offered by the owner of NFT Project. it contains the compressed infomation about the NFT whitelist
     */
    function claimNFT(address _recipient, uint256 _promisedTokenId, bytes32[] memory _merkleProof, uint256 _promisedPriceInETH, bytes memory _NFTWhitelistData)
        public
    {   
        (address whitelistNFTAddr, bytes32 MerkleRoot) = abi.decode(_NFTWhitelistData, (address, bytes32));
        // Verify the membership of whitelist using Merkle tree.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(_recipient, _promisedTokenId, _promisedPriceInETH))));
        _verifyMerkleProof(_merkleProof, MerkleRoot, leaf);
        bool _ok = IWETH9(wrappedETHAddr).transferFrom(_recipient, address(this), _promisedPriceInETH);
        require(_ok, "WETH transfer failed");
        address NFTOwner = IERC721(whitelistNFTAddr).ownerOf(_promisedTokenId);
        IERC721(whitelistNFTAddr).transferFrom(NFTOwner, _recipient, _promisedTokenId);
        userProfit[NFTOwner] += _promisedPriceInETH;
        emit NFTClaimed(whitelistNFTAddr, _promisedTokenId, _recipient);
    }

    /**
     * @dev Call multiple functions in any target address within one transaction.
     *
     * @param _calls the array of multiple elements in the type of struct `Call`, each element in the array represents a unique call that defines the address called and the encoded data containing ABI and parameters
     */
    function aggregate(Call[] memory _calls) public returns(bytes[] memory returnData) {
        returnData = new bytes[](_calls.length);
        for (uint256 i = 0; i < _calls.length; i++) {
            (bool success, bytes memory returnBytes) = (_calls[i].target).call(_calls[i].callData);
            if (!success) {
                revert multiCallFail(i, _calls[i].callData);
            }
            returnData[i] = returnBytes;
        }
    }

    /**
     * @dev This function is used to change the owner of this contract by modifying slot.
     */
    function changeOwnerOfNFTMarket(address _newOwner) public onlyNFTMarketOwner {
        assembly {
            sstore(0, _newOwner)
        }
    }

    /**
     * @notice This function is used for staking WETH. Stake WETH and get minted KKToken(shares).
     *
     * @dev Using the algorithm of ERC4626(a financial model of compound interest and re-invest) to calculate the amount of minted shares(i.e. KKToken).
     * A simple example is presented at "https://solidity-by-example.org/defi/vault/".
     */
    function stakeWETH(uint256 _value) public {
        uint256 shares;
        uint256 totalSupply = IERC20(KKToken).totalSupply();
        if (totalSupply == 0) {
            shares = _value;
        } else {
            shares = (_value * totalSupply) / stakeWETHPool;
        }
        IERC20(KKToken).mint(msg.sender, shares);
        stakeWETHPool += _value;
    }

    /**
     * @notice This function is used for unstaking WETH. Burn KKToken(shares) to fetch back staked WETH with the interest of staking.
     *
     * @dev Using the algorithm of ERC4626(a financial model of compound interest and re-invest) to calculate the amount of burnt shares(i.e. KKToken).
     * A simple example is presented at "https://solidity-by-example.org/defi/vault/".
     */
    function unstakeWETH(uint256 _shares) public {
        uint256 totalSupply = IERC20(KKToken).totalSupply();
        uint amount = (_shares * stakeWETHPool) / totalSupply;
        IERC20(KKToken).burn(msg.sender, _shares);
        stakeWETHPool -= amount;
        userProfit[msg.sender] += amount;
    }

    /**
     * @notice Check if the NFT Market contract has been approved by a specific NFT.
     */
    function checkIfApprovedByNFT(address _nftAddr, uint256 _tokenId) public view returns (bool) {
        bool isApproved = false;
        if (IERC721(_nftAddr).getApproved(_tokenId) == address(this)) {
            isApproved = true;
        }
        return isApproved;
    }

    /**
     * @dev This internal function is called when an NFT is bought(except via {buyWithGTST}).
     * Part of the profit from NFT transactions will be staked.
     * Using the algorithm of ERC4626(a financial model of compound interest and re-invest) to calculate the amount of minted shares(i.e. KKToken).
     */
    function _stakeWETH(address _account, uint256 _value) internal {
        uint256 shares;
        uint256 totalSupply = IERC20(KKToken).totalSupply();
        if (totalSupply == 0) {
            shares = _value;
        } else {
            shares = (_value * totalSupply) / stakeWETHPool;
        }
        IERC20(KKToken).mint(_account, shares);
        stakeWETHPool += _value;
    }

    function _verifyMerkleProof(bytes32[] memory _proof, bytes32 _root, bytes32 _leaf) internal pure {
        require(MerkleProof.verify(_proof, _root, _leaf), "Invalid Merkle proof");
    }

    function _support_IERC721Permit(address _contractAddr) internal view returns (bool) {
        bytes4 INFTPermit_Id = type(INFTPermit).interfaceId;
        IERC165 contractInstance = IERC165(_contractAddr);
        return contractInstance.supportsInterface(INFTPermit_Id);
    }

    function _support_IERC20(address _contractAddr) internal view returns (bool) {
        bytes4 IERC20_Id = type(IERC20).interfaceId;
        IERC165 contractInstance = IERC165(_contractAddr);
        return contractInstance.supportsInterface(IERC20_Id);
    }

    function _support_IERC20Permit(address _contractAddr) internal view returns (bool) {
        bytes4 IERC20Permit_Id = type(IERC20Permit).interfaceId;
        IERC165 contractInstance = IERC165(_contractAddr);
        return contractInstance.supportsInterface(IERC20Permit_Id);
    }

    function _List(address _nftAddr, uint256 _tokenId, uint256 _priceInWETH) internal {
        IERC721(_nftAddr).safeTransferFrom(msg.sender, address(this), _tokenId, "List successfully");
        IERC721(_nftAddr).approve(msg.sender, _tokenId);
        price[_nftAddr][_tokenId] = _priceInWETH;
        emit NFTListed(msg.sender, _nftAddr, _tokenId, _priceInWETH);
    }

    function _beforeNFTPurchase(address _buyer, address _ERC20TokenAddr, address _nftAddr, uint256 _tokenId)
        internal
        view
        returns (bool)
    {   
        // Check if the NFT corresponding to `_nftAddr` is already listed.
        if (price[_nftAddr][_tokenId] == 0) {
            revert notOnSale(_nftAddr, _tokenId);
        }

        // Check if the contract corresponding to `_ERC20TokenAddr` has satisfied the interface {IERC20}.
        bool isIERC20Supported = _support_IERC20(_ERC20TokenAddr);
        if (!isIERC20Supported) {
            revert notERC20Token(_ERC20TokenAddr);
        }

        // Check if the buyer is not the owner of the NFT which is desired to be bought.
        // When NFT listed, the previous owner(EOA, the seller) should be approved. So, this EOA can delist NFT whenever he/she wants.
        // After NFT is listed successfully, getApproved() will return the orginal owner of the listed NFT.
        address previousOwner = IERC721(_nftAddr).getApproved(_tokenId);
        if (_buyer == previousOwner) {
            revert ownerBuyNFTOfSelf(_nftAddr, _tokenId, _buyer);
        }

        // If everything goes well without any reverts, here comes a return boolean value. It indicates that all the checks are passed.
        return true;
    }

    /**
     * @dev This internal function only conducts the 'action' of a single NFT purchase with an exact amount of ERC-20 token used for buying an NFT.
     */
    function _handleNFTPurchase(address _nftBuyer, address _ERC20TokenAddr, address _nftAddr, uint256 _tokenId, uint256 _tokenAmount) internal returns (uint256 result) {
        uint256 NFTPrice = getNFTPrice(_nftAddr, _tokenId);

        // If the ERC-20 token used for buying NFTs is not WETH, execute token-swap.
        // To make the NFT purchase more economical, calculate the necessary(also minimal) amount of token paid based on the current price of the NFT(uint: WETH or ETH).
        if (_ERC20TokenAddr != wrappedETHAddr) {
            bool _success = IERC20(_ERC20TokenAddr).transferFrom(_nftBuyer, address(this), _tokenAmount);
            require(_success, "ERC-20 token transferFrom failed");

            // token swap
            uint256 tokenBalanceBeforeSwap = IERC20(_ERC20TokenAddr).balanceOf(address(this));
            uint256 tokenAmountPaid = _swapTokenForExactWETH(_ERC20TokenAddr, NFTPrice, _tokenAmount);
            uint256 tokenBalanceAfterSwap = IERC20(_ERC20TokenAddr).balanceOf(address(this));
            if (tokenBalanceAfterSwap >= tokenBalanceBeforeSwap || tokenBalanceBeforeSwap - tokenBalanceAfterSwap != tokenAmountPaid) {
                address[] memory _path = new address[](2);
                _path[0] = _ERC20TokenAddr;
                _path[1] = wrappedETHAddr;
                revert tokenSwapFailed(_path, NFTPrice, _tokenAmount);
            }

            // After paying the necessary amount of token, refund excess amount.
            uint256 refundTokenAmount = _tokenAmount - tokenAmountPaid;
            bool _refundTokenSuccess = IERC20(_ERC20TokenAddr).transfer(_nftBuyer, refundTokenAmount);
            require(_refundTokenSuccess, "Fail to refund exceed amount of token");
            result = tokenAmountPaid;
        } else {
            bool _ok = IWETH9(wrappedETHAddr).transferFrom(_nftBuyer, address(this), NFTPrice);
            require(_ok, "WETH transferFrom failed");
            result = NFTPrice;
        }
        // Execute the transfer of the NFT being bought
        IERC721(_nftAddr).transferFrom(address(this), _nftBuyer, _tokenId);
        // add the staked part generated from the NFT profit
        uint256 stakedAmount = NFTPrice * txFeeRatio_Figure / (10 ** txFeeRatio_Decimal);
        address NFTOwner = IERC721(_nftAddr).getApproved(_tokenId);
        _stakeWETH(NFTOwner, stakedAmount);
        // Add the earned amount of WETH(i.e. the price of the sold NFT) to the balance of the NFT seller.
        userProfit[NFTOwner] += NFTPrice - stakedAmount;

        // Reset the price of the sold NFT. This indicates that this NFT is not on sale.
        delete price[_nftAddr][_tokenId];
    }

    /**
     * @dev This internal function only conducts the 'action' of a single NFT purchase with an exact amount of ERC-20 token used for buying an NFT.
     * And User should consider the slippage for token-swap.
     */
    function _handleNFTPurchaseWithSlippage(address _nftBuyer, address _ERC20TokenAddr, address _nftAddr, uint256 _tokenId, uint256 _slippageLiteral, uint256 _slippageDecimal) internal returns (uint256 result) {
        uint256 NFTPrice = getNFTPrice(_nftAddr, _tokenId);
    
        // If the ERC-20 token used for buying NFTs is not WETH, execute token-swap.
        // To make the NFT purchase more economical, calculate the necessary(also minimal) amount of token paid based on the current price of the NFT(uint: WETH or ETH).
        if (_ERC20TokenAddr != wrappedETHAddr) {
            uint256 amountInRequired = _estimateAmountInWithSlipage(_ERC20TokenAddr, NFTPrice, _slippageLiteral, _slippageDecimal);
            bool _success = IERC20(_ERC20TokenAddr).transferFrom(_nftBuyer, address(this), amountInRequired);
            require(_success, "ERC-20 token transferFrom failed");

            // token swap
            uint256 tokenBalanceBeforeSwap = IERC20(_ERC20TokenAddr).balanceOf(address(this));
            uint256 tokenAmountPaid = _swapTokenForExactWETH(_ERC20TokenAddr, NFTPrice, amountInRequired);
            uint256 tokenBalanceAfterSwap = IERC20(_ERC20TokenAddr).balanceOf(address(this));
            if (tokenBalanceAfterSwap >= tokenBalanceBeforeSwap || tokenBalanceBeforeSwap - tokenBalanceAfterSwap != tokenAmountPaid) {
                address[] memory _path = new address[](2);
                _path[0] = _ERC20TokenAddr;
                _path[1] = wrappedETHAddr;
                revert tokenSwapFailed(_path, NFTPrice, amountInRequired);
            }
            result = tokenAmountPaid;
        } else {
            bool _ok = IWETH9(wrappedETHAddr).transferFrom(_nftBuyer, address(this), NFTPrice);
            require(_ok, "WETH transferFrom failed");
            result = NFTPrice;
        }
        // Execute the transfer of the NFT being bought
        IERC721(_nftAddr).transferFrom(address(this), _nftBuyer, _tokenId);
         // add the staked part generated from the NFT profit
        uint256 stakedAmount = NFTPrice * txFeeRatio_Figure / (10 ** txFeeRatio_Decimal);
        address NFTOwner = IERC721(_nftAddr).getApproved(_tokenId);
        _stakeWETH(NFTOwner, stakedAmount);
        // Add the earned amount of WETH(i.e. the price of the sold NFT) to the balance of the NFT seller.
        userProfit[NFTOwner] += NFTPrice - stakedAmount;

        // Reset the price of the sold NFT. This indicates that this NFT is not on sale.
        delete price[_nftAddr][_tokenId];
    }

    /**
     * @dev This internal function only conducts the 'action' of a single NFT purchase using an exact amount of GSTS.
     * And User should consider the slippage for token-swap.
     */
    function _handleNFTPurchaseUsingGTST(address _nftBuyer, address _nftAddr, uint256 _tokenId, uint256 _tokenAmount) internal {
        bool _success = IERC20(NFTMarketTokenAddr).transferFrom(_nftBuyer, address(this), _tokenAmount);
        require(_success, "Fail to buy or Allowance is insufficient");
        // Execute the transfer of the NFT being bought
        IERC721(_nftAddr).transferFrom(address(this), _nftBuyer, _tokenId);
        // Add the earned amount of WETH(i.e. the price of the sold NFT) to the balance of the NFT seller.
        userProfit[IERC721(_nftAddr).getApproved(_tokenId)] += _tokenAmount;
        // Reset the price of the sold NFT. This indicates that this NFT is not on sale.
        delete price[_nftAddr][_tokenId];
    }

    function _swapExactTokenForWETH(address _ERC20TokenAddr, uint256 _amountIn, uint256 _amountOutMin) internal returns (uint256) {
        address[] memory _path = new address[](2);
        _path[0] = _ERC20TokenAddr;
        _path[1] = wrappedETHAddr;
        uint256 _deadline = block.timestamp + 600;
        uint[] memory amountsOut = IUniswapV2Router02(routerAddr).swapExactTokensForTokens(_amountIn, _amountOutMin, _path, address(this), _deadline);
        return amountsOut[_path.length - 1];
    }

    function _swapTokenForExactWETH(address _ERC20TokenAddr, uint256 _amountOut, uint256 _amountInMax) internal returns (uint256) {
        address[] memory _path = new address[](2);
        _path[0] = _ERC20TokenAddr;
        _path[1] = wrappedETHAddr;
        uint256 _deadline = block.timestamp + 600;
        uint[] memory amountsIn = IUniswapV2Router02(routerAddr).swapTokensForExactTokens(_amountOut, _amountInMax, _path, address(this), _deadline);
        return amountsIn[0];
    }

    function _estimateAmountInWithSlipage(address _ERC20TokenAddr, uint256 _amountOut, uint256 _slippageLiteral, uint256 _slippageDecimal) internal returns (uint256) {
        address[] memory _path = new address[](2);
        _path[0] = _ERC20TokenAddr;
        _path[1] = wrappedETHAddr;
        if (_slippageLiteral == 0 ||  _slippageDecimal == 0) {
            revert invalidSlippage(_slippageLiteral, _slippageDecimal);
        }
        uint256 amountInWithoutSlippage = getAmountsIn(_amountOut, _path)[0];
        uint256 amountInWithSlippage = amountInWithoutSlippage * (10 ** _slippageDecimal +  _slippageLiteral) / (10 ** _slippageDecimal);
        return amountInWithSlippage;
    }

    /**
     * @notice Get the price of a listed NFT.
     */
    function getNFTPrice(address _nftAddr, uint256 _tokenId) public view returns (uint256) {
        return price[_nftAddr][_tokenId];
    }

    /**
     * @notice Get the total profit earned by a seller.
     */
    function getUserProfit() public view returns (uint256) {
        return userProfit[msg.sender];
    }

    /**
     * @notice Get the owner of a specific NFT.
     */
    function getNFTOwner(address _nftAddr, uint256 _tokenId) public view returns (address) {
        return IERC721(_nftAddr).ownerOf(_tokenId);
    }

    /**
     * @notice Get the owner of this contract by modifying slot.
     */
    function getOwnerOfNFTMarket() public view returns (address ownerAddress) {
        assembly {
            ownerAddress := sload(0)
        }
    }

    /**
     * @notice Get the address of the WETH contract.
     */
    function getWrappedETHAddress() public view returns (address) {
        return wrappedETHAddr;
    }

    /**
     * @notice Get the address of the router contract.
     */
    function getRouterAddress() public view returns (address) {
        return routerAddr;
    }

    /**
     * @notice Get the address of the ERC-20 token contract for this NFTMarket. This token is the default token for the exchange of NFTs.
     */
    function getNFTMarketTokenAddress() public view returns (address) {
        return NFTMarketTokenAddr;
    }

    /**
     * @notice Get the amount of the token swapped out according to `_path`.
     * 
     * @param _amountIn the exact amount of the token invested into the swap
     * @param _path the path of token swaps whose each element represents a unique swapped token address
     */
    function getAmountsOut(uint _amountIn, address[] memory _path) public view returns (uint[] memory _amountsOut) {
        _amountsOut = IUniswapV2Router02(routerAddr).getAmountsOut(_amountIn, _path);
    }

    /**
     * @notice Get the amount of the token invested into the swap according `_path`.
     * 
     * @param _amountOut the exact amount of the token swapped out from the swap
     * @param _path the path of token swaps whose each element represents a unique swapped token address
     */
    function getAmountsIn(uint _amountOut, address[] memory _path) public view returns (uint[] memory _amountsIn) {
        _amountsIn = IUniswapV2Router02(routerAddr).getAmountsIn(_amountOut, _path);
    }

    /**
     * @notice Get the total supply of KKToken(the shares of the staked ETH).
     */
    function getTotalSupplyOfShares() public view returns (uint256) {
        return IERC20(KKToken).totalSupply();
    }

    /**
     * @notice Get the total amount of staked WETH which comes from the profits of NFT-transactions.
     */
    function getStakeTotalAmount() public view returns (uint256) {
        return stakeWETHPool;
    }
}
