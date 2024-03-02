//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title An interface for NFT Market.
 *
 * @author Garen Woo
 */
interface INFTMarket_V4 {
    /**
     * @dev A custom struct to define the fields of a unique function call which is used in multicall(see the function {aggregate}).
     */
    struct Call {
        address target;
        bytes callData;
    }
    /**
     * @dev Emitted when an NFT is listed successfully.
     */
    event NFTListed(address indexed user, address indexed NFTAddr, uint256 indexed tokenId, uint256 price);

    /**
     * @dev Emitted when an NFT is delisted successfully.
     */
    event NFTDelisted(address user, address NFTAddr, uint256 tokenId);

    /**
     * @dev Emitted when an NFT is bought successfully by a non-owner user.
     */
    event NFTBoughtWithAnyToken(address indexed user, address erc20TokenAddr, address indexed NFTAddr, uint256 indexed tokenId, uint256 tokenPaid);

    /**
     * @dev Emitted when an NFT is bought successfully by a non-owner user.
     */
    event NFTBoughtWithGTST(address indexed user, address indexed NFTAddr, uint256 indexed tokenId, uint256 tokenPaid);

    /**
     * @dev Emitted when an NFT is bought successfully by a non-owner user with an off-chain signed message in the input form of v, r, s.
     */
    event NFTBoughtWithPermit(address indexed user, address erc20TokenAddr, address indexed NFTAddr, uint256 indexed tokenId, uint256 bidValue);

    /**
     * @dev Emitted when the profit of the NFT seller from the seller's balance is withdrawn in the NFTMarket contract.
     */
    event withdrawBalance(address withdrawer, uint256 withdrawnValue);

    /**
     * @dev Emitted when successfully validating the signed message of the ERC2612 token owner desired to buy NFTs.
     */
    event prepay(address tokenOwner, uint256 tokenAmount);

    /**
     * @dev When an address in the whitelist built by an NFT project party claims NFT successfully.
     */
    event NFTClaimed(address NFTAddr, uint256 tokenId, address user);

    /**
     * @dev Indicates a failure when listing an NFT. Used in checking the price set of an NFT.
     */
    error zeroPrice();

    /**
     * @dev Indicates a failure when an NFT is operated by a non-owner user. Used in checking the ownership of the NFT listed in NFTMarket.
     */
    error notOwnerOfNFT();

    /**
     * @dev Indicates a failure when checking `msg.sender` equals the owner of the NFTMarket
     */
    error notOwnerOfNFTMarket();

    /**
     * @dev Indicates a failure when a user attempts to buy or delist an NFT. Used in checking if the NFT has been already listed in the NFTMarket.
     */
    error notOnSale(address tokenAddress, uint256 tokenId);

    /**
     * @dev Indicates a failure when an NFT seller attempts to withdraw an over-balance amount of tokens from its balance.
     */
    error withdrawalExceedBalance(uint256 withdrawAmount, uint256 balanceAmount);

    /**
     * @dev Indicates a failure when a user attempts to buy an NFT by calling a function without inputting a signed message.
     * Used in checking if the user calls the valid function to avoid abuse of the function {buy}.
     */
    error ERC721PermitBoughtByWrongFunction(string calledFunction, string validFunction);

    /**
     * @dev Indicates a failure when calling the function {aggregate}.
     */
    error multiCallFail(uint256 index, bytes callData);

    /**
     * @dev Indicates a failure when detecting a contract does not satisfy the interface {IERC20}
     */
    error notERC20Token(address inputAddress);

    /**
     * @dev Indicates a failure when detecting a contract does not satisfy the interface {IERC20Permit}
     */
    error notERC20PermitToken(address inputAddress);

    /**
     * @dev Indicates a failure when the owner of an NFT attempts to buy the NFT.
     */
    error ownerBuyNFTOfSelf(address NFTAddr, uint256 tokenId, address user);

    /**
     * @dev Indicates a failure when the balance change of the ERC-20 token used for buying NFTs does not fit the returned value of functions for swap in the router contract.
     */
    error tokenSwapFailed(address[] _path, uint256 exactAmountOut, uint256 amountInMax);

    /**
     * @dev Indicates a failure when a wrong slippage is set by a user. 
     */
    error invalidSlippage(uint256 inputLiteral, uint256 inputDecimal);

    /**
     * @dev Indicates a failure when the total supply of KKToken is zero
     */
    error zeroKKToken();

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
    function tokensReceived(address _recipient, address _ERC20TokenAddr, uint256 _tokenAmount, bytes calldata _data) external;
     
    /**
     * @notice List an NFT by its owner with a given price in WETH.
     * Once the NFT is listed:
     * The actual owner of the NFT is the NFT exchange.
     * The previous owner of the NFT(the EOA who lists the NFT) is the current '_tokenApprovals'(at ERC721.sol) of the NFT.
     * The spender which needs to be approved should be set as the buyer.
     */
    function list(address _nftAddr, uint256 _tokenId, uint256 _price) external;

    /**
     * @dev Besides `list`, this function is also used to list NFT on an NFT exchange.
     *  this function verifies off-chain signature of the message signed by the owner of the NFT.
     *  List NFT in this way can have better user experience, because valid signature will lead to automatic approval.
     */
    function listWithPermit(address _nftAddr, uint256 _tokenId, uint256 _price, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) external;

    /**
     * @dev Delist the NFT from an NFT Market.
     */
    function delist(address _nftAddr, uint256 _tokenId) external;
    
    /**
     * @notice Directly Buy NFT using ERC-20 token of this NFTMarket(named "GSTS") without checking ERC721 token permit.
     *
     * @dev Important! If your NFT project supports the function of buying NFT with off-chain signature of messages(i.e.permit), make sure the NFT contract(s) should have realized the functionality of the interface {INFTPermit}.
     * Without the realization of {realized the functionality of the interface {INFTPermit}.}, malevolent EOAs can directly buy NFTs without permit-checking.
     */
    function buyWithGTST(address _nftAddr, uint256 _tokenId, uint256 _tokenAmount) external;

    /**
     * @notice Buy NFT using any ERC-20 token without checking ERC721 token permit.
     *
     * @dev Important! If your NFT project supports the function of buying NFT with off-chain signature of messages(i.e.permit), make sure the NFT contract(s) should have realized the functionality of the interface {INFTPermit}.
     * Without the realization of {realized the functionality of the interface {INFTPermit}.}, malevolent EOAs can directly buy NFTs without permit-checking.
     */
    function buyNFTWithAnyToken(address _ERC20TokenAddr, address _nftAddr, uint256 _tokenId, uint256 _slippageLiteral, uint256 _slippageDecimal) external ;

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
    ) external;

    /**
     * @notice Withdraw a custom amount of ETH from the user's balance which is equivalent to the earned value of selling NFTs.
     */
    function withdrawBalanceByUser(uint256 _value) external;

    /**
     * @notice Modify the price of the NFT of the specific tokenId.
     */
    function modifyPriceForNFT(address _nftAddr, uint256 _tokenId, uint256 _newPrice) external;

    /**
     * @notice  This function supports users to pre-approve `address(this)` with ERC2612(ERC20-Permit) tokens by signing messages off-chain.
     * This function is usually called before calling `claimNFT`.
     */
    function permitPrePay(address _ERC20TokenAddr, address _tokenOwner, uint256 _tokenAmount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) external returns (bool);

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
    function claimNFT(address _recipient, uint256 _promisedTokenId, bytes32[] memory _merkleProof, uint256 _promisedPriceInETH, bytes memory _NFTWhitelistData) external;

    /**
     * @dev Call multiple functions in any target address within one transaction.
     *
     * @param _calls the array of multiple elements in the type of struct `Call`, each element in the array represents a unique call that defines the address called and the encoded data containing ABI and parameters
     */
    function aggregate(Call[] memory _calls) external returns(bytes[] memory returnData);

    /**
     * @dev This function is used to change the owner of this contract by modifying slot.
     */
    function changeOwnerOfNFTMarket(address _newOwner) external;

    /**
     * @notice This function is used for staking WETH. Stake WETH and get minted KKToken(shares).
     *
     * @dev Using the algorithm of ERC4626(a financial model of compound interest and re-invest) to calculate the amount of minted shares(i.e. KKToken).
     * A simple example is presented at "https://solidity-by-example.org/defi/vault/".
     */
    function stakeWETH(uint256 _value) external;

    /**
     * @notice This function is used for unstaking WETH. Burn KKToken(shares) to fetch back staked WETH with the interest of staking.
     *
     * @dev Using the algorithm of ERC4626(a financial model of compound interest and re-invest) to calculate the amount of burnt shares(i.e. KKToken).
     * A simple example is presented at "https://solidity-by-example.org/defi/vault/".
     */
    function unstakeWETH(uint256 _shares) external;

    /**
     * @notice Check if the NFT Market contract has been approved by a specific NFT.
     */
    function checkIfApprovedByNFT(address _nftAddr, uint256 _tokenId) external view returns (bool);

    /**
     * @notice Get the price of a listed NFT.
     */
    function getNFTPrice(address _nftAddr, uint256 _tokenId) external view returns (uint256);

    /**
     * @notice Get the total profit earned by a seller.
     */
    function getUserProfit() external view returns (uint256);

    /**
     * @notice Get the owner of a specific NFT.
     */
    function getNFTOwner(address _nftAddr, uint256 _tokenId) external view returns (address);

    /**
     * @notice Get the owner of this contract by modifying slot.
     */
    function getOwnerOfNFTMarket() external view returns (address ownerAddress);

    /**
     * @notice Get the address of the WETH contract.
     */
    function getWrappedETHAddress() external view returns (address);

    /**
     * @notice Get the address of the router contract.
     */
    function getRouterAddress() external view returns (address);

    /**
     * @notice Get the address of the ERC-20 token contract for this NFTMarket. This token is the default token for the exchange of NFTs.
     */
    function getNFTMarketTokenAddress() external view returns (address);

    /**
     * @notice Get the amount of the token swapped out according to `_path`.
     * 
     * @param _amountIn the exact amount of the token invested into the swap
     * @param _path the path of token swaps whose each element represents a unique swapped token address
     */
    function getAmountsOut(uint _amountIn, address[] memory _path) external view returns (uint[] memory _amountsOut);

    /**
     * @notice Get the amount of the token invested into the swap according `_path`.
     * 
     * @param _amountOut the exact amount of the token swapped out from the swap
     * @param _path the path of token swaps whose each element represents a unique swapped token address
     */
    function getAmountsIn(uint _amountOut, address[] memory _path) external view returns (uint[] memory _amountsIn);

    /**
     * @notice Get the total supply of KKToken(the shares of the staked ETH).
     */
    function getTotalSupplyOfShares() external view returns (uint256);

    /**
     * @notice Get the total amount of staked WETH which comes from the profits of NFT-transactions.
     */
    function getStakeTotalAmount() external view returns (uint256);
}
