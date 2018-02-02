pragma solidity 0.4.18;

import "zeppelin-solidity/contracts/crowdsale/FinalizableCrowdsale.sol";
import "zeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "./TeamAndAdvisorsAllocation.sol";
import "./ODEMToken.sol";
import "./Whitelist.sol";

/**
 * @title ODEM Crowdsale contract - crowdsale contract for the ODEM tokens.
 * @author Gustavo Guimaraes - <gustavo@odem.io>
 */

contract ODEMCrowdsale is FinalizableCrowdsale, Pausable {
    uint256 constant public BOUNTY_REWARD_SHARE = 43666667e18;
    uint256 constant public VESTED_TEAM_ADVISORS_SHARE = 38763636e18;
    uint256 constant public NON_VESTED_TEAM_ADVISORS_SHARE = 5039200e18;
    uint256 constant public COMPANY_SHARE = 71300194e18;

    uint256 constant public PRE_CROWDSALE_CAP = 58200000e18;
    uint256 constant public PUBLIC_CROWDSALE_CAP = 180000000e18;
    uint256 constant public TOTAL_TOKENS_FOR_CROWDSALE = PRE_CROWDSALE_CAP + PUBLIC_CROWDSALE_CAP;
    uint256 constant public TOTAL_TOKENS_SUPPLY = 396969697e18;
    uint256 constant public PERSONAL_FIRST_HOUR_CAP = 2000000e18;

    address public rewardWallet;
    uint256 public oneHourAfterStartTime;

    // remainderPurchaser and remainderTokens info saved in the contract
    // used for reference for contract owner to send refund if any to last purchaser after end of crowdsale
    address public remainderPurchaser;
    uint256 public remainderAmount;

    mapping (address => uint256) public trackBuyersPurchases;

    // external contracts
    Whitelist public whitelist;
    TeamAndAdvisorsAllocation public teamAndAdvisorsAllocation;

    event PrivateInvestorTokenPurchase(address indexed investor, uint256 tokensPurchased);
    event TokenRateChanged(uint256 previousRate, uint256 newRate);

    /**
     * @dev Contract constructor function
     * @param _startTime The timestamp of the beginning of the crowdsale
     * @param _endTime Timestamp when the crowdsale will finish
     * @param _whitelist contract containing the whitelisted addresses
     * @param _rate The token rate per ETH
     * @param _wallet Multisig wallet that will hold the crowdsale funds.
     * @param _rewardWallet wallet that will hold tokens bounty and rewards campaign
     */
    function ODEMCrowdsale
        (
            uint256 _startTime,
            uint256 _endTime,
            address _whitelist,
            uint256 _rate,
            address _wallet,
            address _rewardWallet
        )
        public
        FinalizableCrowdsale()
        Crowdsale(_startTime, _endTime, _rate, _wallet)
    {

        require(_whitelist != address(0) && _wallet != address(0) && _rewardWallet != address(0));
        whitelist = Whitelist(_whitelist);
        rewardWallet = _rewardWallet;
        oneHourAfterStartTime = startTime.add(60*60);

        ODEMToken(token).pause();
    }

    modifier whitelisted(address beneficiary) {
        require(whitelist.isWhitelisted(beneficiary));
        _;
    }

    /**
     * @dev change crowdsale rate
     * @param newRate Figure that corresponds to the new rate per token
     */
    function setRate(uint256 newRate) external onlyOwner {
        require(newRate != 0);

        TokenRateChanged(rate, newRate);
        rate = newRate;
    }

    /**
     * @dev Mint tokens for pre crowdsale putchases before crowdsale starts
     * @param investorsAddress Purchaser's address
     * @param tokensPurchased Tokens purchased during pre crowdsale
     */
    function mintTokenForPreCrowdsale(address investorsAddress, uint256 tokensPurchased)
        external
        onlyOwner
    {
        require(now < startTime && investorsAddress != address(0));
        require(token.totalSupply().add(tokensPurchased) <= PRE_CROWDSALE_CAP);

        token.mint(investorsAddress, tokensPurchased);
        PrivateInvestorTokenPurchase(investorsAddress, tokensPurchased);
    }

    /**
     * @dev payable function that allow token purchases
     * @param beneficiary Address of the purchaser
     */
    function buyTokens(address beneficiary)
        public
        whenNotPaused
        whitelisted(beneficiary)
        payable
    {
        require(beneficiary != address(0));
        require(msg.sender == beneficiary);
        require(validPurchase() && token.totalSupply() < TOTAL_TOKENS_FOR_CROWDSALE);

        uint256 weiAmount = msg.value;

        // calculate token amount to be created
        uint256 tokens = weiAmount.mul(rate);

        checkWithinFirstHourRestriction(tokens);

        trackBuyersPurchases[beneficiary] = trackBuyersPurchases[beneficiary].add(tokens);

        // update state
        weiRaised = weiRaised.add(weiAmount);

        //remainder logic
        if (token.totalSupply().add(tokens) > TOTAL_TOKENS_FOR_CROWDSALE) {
            uint256 tokenDifference = token.totalSupply().add(tokens).sub(TOTAL_TOKENS_FOR_CROWDSALE);
            uint256 maxPossibleInvestment = tokenDifference.div(rate);
            uint256 weiAmountToReturn = weiAmount.sub(maxPossibleInvestment);

            tokens = TOTAL_TOKENS_FOR_CROWDSALE.sub(token.totalSupply());

            weiRaised = weiRaised.sub(weiAmountToReturn);
            weiAmount = maxPossibleInvestment;

            // save info so as to refund purchaser after crowdsale's end
            remainderPurchaser = msg.sender;
            remainderAmount = weiAmountToReturn;
        }

        token.mint(beneficiary, tokens);

        TokenPurchase(msg.sender, beneficiary, weiAmount, tokens);

        forwardFunds();
    }

    // overriding Crowdsale#hasEnded to add cap logic
    // @return true if crowdsale event has ended
    function hasEnded() public view returns (bool) {
        if (token.totalSupply() == TOTAL_TOKENS_FOR_CROWDSALE) {
            return true;
        }

        return super.hasEnded();
    }

    /**
     * @dev Creates ODEM token contract. This is called on the constructor function of the Crowdsale contract
     */
    function createTokenContract() internal returns (MintableToken) {
        return new ODEMToken();
    }

    /**
     * @dev checks whether personal token purchase cap has been reached within crowdsale first hour
     * @param tokens calculated total tokens buyer would have from purchase
     */
    function checkWithinFirstHourRestriction(uint256 tokens) internal view {
        if (now < oneHourAfterStartTime && trackBuyersPurchases[msg.sender].add(tokens) > PERSONAL_FIRST_HOUR_CAP) {
            revert();
        }
    }

    /**
     * @dev finalizes crowdsale
     */
    function finalization() internal {
        teamAndAdvisorsAllocation = new TeamAndAdvisorsAllocation(owner, token);

        // final minting
        token.mint(teamAndAdvisorsAllocation, VESTED_TEAM_ADVISORS_SHARE);
        token.mint(wallet, NON_VESTED_TEAM_ADVISORS_SHARE);
        token.mint(wallet, COMPANY_SHARE);
        token.mint(rewardWallet, BOUNTY_REWARD_SHARE);

        if (TOTAL_TOKENS_SUPPLY > token.totalSupply()) {
            uint256 remainingTokens = TOTAL_TOKENS_SUPPLY.sub(token.totalSupply());

            token.mint(wallet, remainingTokens);
        }

        token.finishMinting();
        ODEMToken(token).unpause();
        super.finalization();
    }
}
