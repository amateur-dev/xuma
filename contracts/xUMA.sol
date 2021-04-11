pragma solidity 0.6.2;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./helpers/Pausable.sol";

// create the voting interface for UMA
// this will be the batchCommit function

interface IumaVoting {
    /**
     * @notice Commit a vote for a price request for `identifier` at `time`.
     * @dev `identifier`, `time` must correspond to a price request that's currently in the commit phase.
     * Commits can be changed.
     * @dev Since transaction data is public, the salt will be revealed with the vote. While this is the system’s expected behavior,
     * voters should never reuse salts. If someone else is able to guess the voted price and knows that a salt will be reused, then
     * they can determine the vote pre-reveal.
     * @param identifier uniquely identifies the committed vote. EG BTC/USD price pair.
     * @param time unix timestamp of the price being voted on.
     * @param hash keccak256 hash of the `price`, `salt`, voter `address`, `time`, current `roundId`, and `identifier`.
     */
    function commitVote(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData,
        bytes32 hash
    ) public virtual;

    // batchCommit
    function batchCommit(
        CommitmentAncillary[] memory commits
    ) external;
    // batchReveal
    function batchReveal(
        RevealAncillary[] memory reveals
    ) external;
    // claimRewards
    function retrieveRewards(
        address voterAddress,
        uint256 roundId,
        PendingRequestAncillary[] memory toRetrieve
    ) external returns (FixedPoint.Unsigned memory totalRewardToIssue) 

}

interface IKyberNetworkProxy {
    function swapEtherToToken(ERC20 token, uint256 minConversionRate)
        external
        payable
        returns (uint256);

    function swapTokenToToken(
        ERC20 src,
        uint256 srcAmount,
        ERC20 dest,
        uint256 minConversionRate
    ) external returns (uint256);

    function swapTokenToEther(
        ERC20 token,
        uint256 tokenQty,
        uint256 minRate
    ) external payable returns (uint256);
}


contract xUMA is ERC20, Pausable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant DEC_18 = 1e18;
    uint256 private constant MAX_UINT = 2**256 - 1;
//    uint256 private constant uma_BUFFER_TARGET = 20; // 5% target
//    uint256 private constant INITIAL_SUPPLY_MULTIPLIER = 100;
//    uint256 public constant LIQUIDATION_TIME_PERIOD = 4 weeks;

    uint256 public withdrawableumaFees;
    uint256 public adminActiveTimestamp;

    address private manager;

    // IERC20 private uma; // CREATING A VARIABLE OF THE TYPE IERC0 WITH THE NAME uma;
    IERC20 private uma;
    // IERC20 private votinguma; // CREATING ANOTHER TOKEN VOTINGuma;
    // IStakeduma private stakeduma;  // USING FROM THE INTERFACE ABOVE
    IumaProtoGovernance private governance;  // USING FROM THE INTERFACE ABOVE

    IKyberNetworkProxy private kyberProxy;  // USING FROM THE INTERFACE ABOVE

    bool public cooldownActivated;  // RELEVANT TO uma MAYBE

    string public mandate;

    // Captures the necessary data for making a commitment.
    // Used as a parameter when making batch commitments.
    // Not used as a data structure for storage.
    struct CommitmentAncillary {
        bytes32 identifier;
        uint256 time;
        bytes ancillaryData;
        bytes32 hash;
        bytes encryptedVote;
    }
    
    // Captures the necessary data for revealing a vote.
    // Used as a parameter when making batch reveals.
    // Not used as a data structure for storage.
    struct RevealAncillary {
        bytes32 identifier;
        uint256 time;
        int256 price;
        bytes ancillaryData;
        int256 salt;
    }
    
    struct FeeDivisors {
        uint256 mintFee;
        uint256 burnFee;
        uint256 claimFee;
    }

    FeeDivisors public feeDivisors;

    IumaGovernanceV2 private governanceV2;

    address private manager2;

    mapping(address => bool) private whitelist;

    uint256 private constant AFFILIATE_FEE_DIVISOR = 4;


    // CONSTRUCTOR FUNCTION MODIFIED SO THAT IT CAN BE UPGRADED TO WORK ON THIS
    function initialize(
        IERC20 _uma, // ASSIGNING ADDRESS OVER HERE
        IERC20 _votinguma, // ASSIGNING ADDRESS OVER HERE
        // IStakeduma _stakeduma, // FROM THE STATE VARIABLES
        IumaProtoGovernance _governance, // FROM THE STATE VARIABLES
        IKyberNetworkProxy _kyberProxy, // FROM THE STATE VARIABLES
        uint256 _mintFeeDivisor, // A UINT
        uint256 _burnFeeDivisor, // A UINT
        uint256 _claimFeeDivisor, // A UINT
        string memory _symbol,
        string memory _mandate  // THIS IS A STRING // NEED TO CHECK WHAT IS THIS
    ) public initializer {
        __Ownable_init();
        __ERC20_init("xUMA", _symbol);

        uma = _uma;
        votinguma = _votinguma;
        // stakeduma = _stakeduma;
        governance = _governance;
        kyberProxy = _kyberProxy;
        mandate = _mandate;

        // WHY CALLING A FUNCTION?
        _setFeeDivisors(_mintFeeDivisor, _burnFeeDivisor, _claimFeeDivisor);
        _updateAdminActiveTimestamp();
    }

    /* ========================================================================================= */
    /*                                        Investor-Facing                                    */
    /* ========================================================================================= */

    /*
     * @dev Mint xUMA using ETH
     * @param minRate: Kyber min rate ETH=>uma
     */
    function mint(uint256 minRate) public payable whenNotPaused {
        require(msg.value > 0, "Must send ETH");
        // TODO: TO WORK ON THE getFundBalances FX
        (uint256 stakedBalance, uint256 bufferBalance) = getFundBalances();

        uint256 fee = _calculateFee(msg.value, feeDivisors.mintFee);

        uint256 incrementalUma = kyberProxy.swapEtherToToken.value(
            msg.value.sub(fee)
        )(ERC20(address(uma)), minRate);
        return _mintInternal(bufferBalance, stakedBalance, incrementalUma);
    }

    /*
     * @dev Mint xuma using uma
     * @notice Must run ERC20 approval first
     * @param umaAmount: uma to contribute
     * @param affiliate: optional recipient of 25% of fees
     */
    function mintWithUmaToken(uint256 umaAmount, address affiliate)
        public
        whenNotPaused
    {
        require(umaAmount > 0, "Must send uma");
        // TODO: TO WORK ON THE getFundBalances FX
        (uint256 stakedBalance, uint256 bufferBalance) = getFundBalances();

        uma.safeTransferFrom(msg.sender, address(this), umaAmount);

        uint256 fee = _calculateFee(umaAmount, feeDivisors.mintFee);

        if (affiliate != address(0)) {
            require(whitelist[affiliate], "Invalid address");

            uint256 affiliateFee = fee.div(AFFILIATE_FEE_DIVISOR);
            uma.safeTransfer(affiliate, affiliateFee);
            _incrementWithdrawableumaFees(fee.sub(affiliateFee));
        }

        uint256 incrementalUma = umaAmount.sub(fee);
        return _mintInternal(bufferBalance, stakedBalance, incrementalUma);
    }

    function _mintInternal(
        uint256 _bufferBalance,
        uint256 _stakedBalance,
        uint256 _incrementalUma
    ) internal {
        uint256 totalSupply = totalSupply();
        uint256 allocationToStake = _calculateAllocationToStake(
            _bufferBalance,
            _incrementalUma,
            _stakedBalance,
            totalSupply
        );
        _stake(allocationToStake);

        uint256 umaHoldings = _bufferBalance.add(_stakedBalance);
        uint256 mintAmount = calculateMintAmount(
            _incrementalUma,
            umaHoldings,
            totalSupply
        );
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @dev Burn xuma tokens
     * @notice Will fail if redemption value exceeds available liquidity
     * @param redeemAmount: xuma to redeem
     * @param redeemForEth: if true, redeem xuma for ETH
     * @param minRate: Kyber.getExpectedRate uma=>ETH if redeemForEth true (no-op if false)
     */
    function burn(
        uint256 tokenAmount,
        bool redeemForEth,
        uint256 minRate
    ) public {
        require(tokenAmount > 0, "Must send xuma");

        (uint256 stakedBalance, uint256 bufferBalance) = getFundBalances();
        uint256 umaHoldings = bufferBalance.add(stakedBalance);
        uint256 proRatauma = umaHoldings.mul(tokenAmount).div(totalSupply());

        require(proRatauma <= bufferBalance, "Insufficient exit liquidity");
        super._burn(msg.sender, tokenAmount);

        if (redeemForEth) {
            uint256 ethRedemptionValue = kyberProxy.swapTokenToEther(
                ERC20(address(uma)),
                proRatauma,
                minRate
            );
            uint256 fee = _calculateFee(
                ethRedemptionValue,
                feeDivisors.burnFee
            );
            (bool success, ) = msg.sender.call.value(
                ethRedemptionValue.sub(fee)
            )("");
            require(success, "Transfer failed");
        } else {
            uint256 fee = _calculateFee(proRatauma, feeDivisors.burnFee);
            _incrementWithdrawableumaFees(fee);
            uma.safeTransfer(msg.sender, proRatauma.sub(fee));
        }
    }

    /* ========================================================================================= */
    /*                                             NAV                                           */
    /* ========================================================================================= */

    function getFundHoldings() public view returns (uint256) {
        return uma.balanceOf(address(this)).sub(withdrawableumaFees);
    }

    // function getStakedBalance() public view returns (uint256) {
    //     return IERC20(address(stakeduma)).balanceOf(address(this));
    // }

    //TODO: may be not have this function, but have the getFundHoldings;
    //TODO: or considering that all of the xtokens may have 2 separate functions getFundHoldings and getFundBalances, we can and should have boths?
    function getFundBalances() public view returns (uint256) {
        return (getFundHoldings());
    }

    /*
     * @dev Helper function for mint, mintWithUmaToken
     * @param incrementalUma: uma contributed
     * @param umaHoldingsBefore: xuma buffer reserve + staked balance
     * @param totalSupply: xuma.totalSupply()
     */
    function calculateMintAmount(
        uint256 incrementalUma,
        uint256 umaHoldingsBefore,
        uint256 totalSupply
    ) public view returns (uint256 mintAmount) {
        if (totalSupply == 0)
            return incrementalUma.mul(INITIAL_SUPPLY_MULTIPLIER);

        mintAmount = (incrementalUma).mul(totalSupply).div(umaHoldingsBefore);
    }

    /*
     * @dev Helper function for mint, mintWithUmaToken
     * @param _bufferBalanceBefore: xuma uma buffer balance pre-mint
     * @param _incrementalUma: uma contributed
     * @param _totalSupply: xuma.totalSupply()
     */
    function _calculateAllocationToStake(
        uint256 _bufferBalanceBefore,
        uint256 _incrementalUma,
        uint256 _totalSupply
    ) internal view returns (uint256) {
        if (_totalSupply == 0)
            return
                _incrementalUma.sub(_incrementalUma.div(uma_BUFFER_TARGET));

        uint256 bufferBalanceAfter = _bufferBalanceBefore.add(_incrementalUma);
        uint256 umaHoldings = bufferBalanceAfter;

        uint256 targetBufferBalance = umaHoldings.div(uma_BUFFER_TARGET);

        // allocate full incremental uma to buffer balance
        if (bufferBalanceAfter < targetBufferBalance) return 0;

        return bufferBalanceAfter.sub(targetBufferBalance);
    }

    /* ========================================================================================= */
    /*                                   Fund Management - Admin                                 */
    /* ========================================================================================= */

    /*
     * @notice xuma only stakes when cooldown is not active
     * @param _amount: allocation to staked balance
     */
    // function _stake(uint256 _amount) private {
    //     if (_amount > 0 && !cooldownActivated) {
    //         stakeduma.stake(address(this), _amount);
    //     }
    // }

    /*
     * @notice Admin-callable function in case of persistent depletion of buffer reserve
     * or emergency shutdown
     * @notice Incremental uma will only be allocated to buffer reserve
     */
    function cooldown() public onlyOwnerOrManager {
        _updateAdminActiveTimestamp();
        _cooldown();
    }

    /*
     * @notice Admin-callable function disabling cooldown and returning fund to
     * normal course of management
     */
    function disableCooldown() public onlyOwnerOrManager {
        _updateAdminActiveTimestamp();
        cooldownActivated = false;
    }

    /*
     * @notice Admin-callable function available once cooldown has been activated
     * and requisite time elapsed
     * @notice Called when buffer reserve is persistently insufficient to satisfy
     * redemption requirements
     * @param amount: uma to unstake
     */
    function redeem(uint256 amount) public onlyOwnerOrManager {
        _updateAdminActiveTimestamp();
        _redeem(amount);
    }

    /*
     * @notice Admin-callable function claiming staking rewards
     * @notice Called regularly on behalf of pool in normal course of management
     */
    function claim() public onlyOwnerOrManager {
        _updateAdminActiveTimestamp();
        _claim();
    }

    /*
     * @notice Records admin activity
     * @notice Because uma staking "locks" capital in contract and only admin has power
     * to cooldown and redeem in normal course, this function certifies that admin
     * is still active and capital is accessible
     * @notice If not certified for a period exceeding LIQUIDATION_TIME_PERIOD,
     * emergencyCooldown and emergencyRedeem become available to non-admin caller
     */
    function _updateAdminActiveTimestamp() private {
        adminActiveTimestamp = block.timestamp;
    }

    // TODO: this is where Dipesh has to show his magic
    /*
     * @notice Function for participating in uma voting process
     * @notice Called regularly on behalf of pool in normal course of management
     * @param _proposalId:
     * @param _vote:
     */
    function vote(uint256 _proposalId, uint256 _vote)
        public
        onlyOwnerOrManager
    {
        governance.submitVoteByVoter(_proposalId, _vote, votinguma);
    }

    /*
     * @notice Callable in case of fee revenue or extra yield opportunities in non-uma ERC20s
     * @notice Reinvested in uma
     * @param tokens: Addresses of non-uma tokens with balance in xuma
     * @param minReturns: Kyber.getExpectedRate for non-uma tokens
     */
    function convertTokensToTarget(
        address[] calldata tokens,
        uint256[] calldata minReturns
    ) external onlyOwnerOrManager {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 tokenBal = IERC20(tokens[i]).balanceOf(address(this));
            uint256 bufferBalancerBefore = getBufferBalance();

            kyberProxy.swapTokenToToken(
                ERC20(tokens[i]),
                tokenBal,
                ERC20(address(uma)),
                minReturns[i]
            );
            uint256 bufferBalanceAfter = getBufferBalance();

            uint256 fee = _calculateFee(
                bufferBalanceAfter.sub(bufferBalancerBefore),
                feeDivisors.claimFee
            );
            _incrementWithdrawableumaFees(fee);
        }
    }

    /* ========================================================================================= */
    /*                                   Fund Management - Public                                */
    /* ========================================================================================= */

    /*
     * @notice If admin doesn't certify within LIQUIDATION_TIME_PERIOD,
     * admin functions unlock to public
     */
    modifier liquidationTimeElapsed {
        require(
            block.timestamp > adminActiveTimestamp.add(LIQUIDATION_TIME_PERIOD),
            "Liquidation time hasn't elapsed"
        );
        _;
    }

    /*
     * @notice First step in xuma unwind in event of admin failure/incapacitation
     */
    function emergencyCooldown() public liquidationTimeElapsed {
        _cooldown();
    }

    /*
     * @notice Second step in xuma unwind in event of admin failure/incapacitation
     * @notice Called after cooldown period, during unwind period
     */
    function emergencyRedeem(uint256 amount) public liquidationTimeElapsed {
        _redeem(amount);
    }

    /*
     * @notice Public callable function for claiming staking rewards
     */
    function claimExternal() public {
        _claim();
    }

    /* ========================================================================================= */
    /*                                   Fund Management - Private                               */
    /* ========================================================================================= */

    function _cooldown() private {
        cooldownActivated = true;
        // stakeduma.cooldown();
    }

    function _redeem(uint256 _amount) private {
        // stakeduma.redeem(address(this), _amount);
    }

    function _claim() private {
        uint256 bufferBalanceBefore = getBufferBalance();

        // stakeduma.claimRewards(address(this), MAX_UINT);

        uint256 bufferBalanceAfter = getBufferBalance();
        uint256 claimed = bufferBalanceAfter.sub(bufferBalanceBefore);

        uint256 fee = _calculateFee(claimed, feeDivisors.claimFee);
        _incrementWithdrawableumaFees(fee);
    }

    /* ========================================================================================= */
    /*                                         Fee Logic                                         */
    /* ========================================================================================= */

    function _calculateFee(uint256 _value, uint256 _feeDivisor)
        internal
        pure
        returns (uint256 fee)
    {
        if (_feeDivisor > 0) {
            fee = _value.div(_feeDivisor);
        }
    }

    function _incrementWithdrawableumaFees(uint256 _feeAmount) private {
        withdrawableumaFees = withdrawableumaFees.add(_feeAmount);
    }

    /*
     * @notice Inverse of fee i.e., a fee divisor of 100 == 1%
     * @notice Three fee types
     * @dev Mint fee 0 or <= 2%
     * @dev Burn fee 0 or <= 1%
     * @dev Claim fee 0 <= 4%
     */
    function setFeeDivisors(
        uint256 mintFeeDivisor,
        uint256 burnFeeDivisor,
        uint256 claimFeeDivisor
    ) public onlyOwner {
        _setFeeDivisors(mintFeeDivisor, burnFeeDivisor, claimFeeDivisor);
    }

    function _setFeeDivisors(
        uint256 _mintFeeDivisor,
        uint256 _burnFeeDivisor,
        uint256 _claimFeeDivisor
    ) private {
        require(_mintFeeDivisor == 0 || _mintFeeDivisor >= 50, "Invalid fee");
        require(_burnFeeDivisor == 0 || _burnFeeDivisor >= 100, "Invalid fee");
        require(_claimFeeDivisor >= 25, "Invalid fee");
        feeDivisors.mintFee = _mintFeeDivisor;
        feeDivisors.burnFee = _burnFeeDivisor;
        feeDivisors.claimFee = _claimFeeDivisor;
    }

    /*
     * @notice Public callable function for claiming staking rewards
     */
    function withdrawFees() public onlyOwner {
        (bool success, ) = msg.sender.call.value(address(this).balance)("");
        require(success, "Transfer failed");

        uint256 umaFees = withdrawableumaFees;
        withdrawableumaFees = 0;
        uma.safeTransfer(msg.sender, umaFees);
    }

    /* ========================================================================================= */
    /*                                           Utils                                           */
    /* ========================================================================================= */

    function pauseContract() public onlyOwnerOrManager returns (bool) {
        _pause();
        return true;
    }

    function unpauseContract() public onlyOwnerOrManager returns (bool) {
        _unpause();
        return true;
    }

    function approveStakingContract() public onlyOwnerOrManager {
        uma.safeApprove(address(stakeduma), MAX_UINT);
    }

    function approveKyberContract(address _token) public onlyOwnerOrManager {
        IERC20(_token).safeApprove(address(kyberProxy), MAX_UINT);
    }

    /*
     * @notice Callable by admin to ensure LIQUIDATION_TIME_PERIOD won't elapse
     */
    function certifyAdmin() public onlyOwnerOrManager {
        _updateAdminActiveTimestamp();
    }

    /*
     * @notice manager == alternative admin caller to owner
     */
    function setManager(address _manager) public onlyOwner {
        manager = _manager;
    }

    /*
     * @notice manager2 == alternative admin caller to owner
     */
    function setManager2(address _manager2) public onlyOwner {
        manager2 = _manager2;
    }

    /*
     * @notice Emergency function in case of errant transfer of
     * xuma token directly to contract
     */
    function withdrawNativeToken() public onlyOwnerOrManager {
        uint256 tokenBal = balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(address(this)).safeTransfer(msg.sender, tokenBal);
        }
    }

    modifier onlyOwnerOrManager {
        require(
            msg.sender == owner() ||
                msg.sender == manager ||
                msg.sender == manager2,
            "Non-admin caller"
        );
        _;
    }

    receive() external payable {
        require(msg.sender != tx.origin, "Errant ETH deposit");
    }

    // TODO: to check if this function is needed
    // function setVotingumaAddress(IERC20 _votinguma) public onlyOwner {
    //     votinguma = _votinguma;
    // }

    // TODO: to check if this function is needed
    function setGovernanceV2Address(IumaGovernanceV2 _governanceV2)
        public
        onlyOwner
    {
        if (address(governanceV2) == address(0)) {
            governanceV2 = _governanceV2;
        }
    }

    // TODO: to check if this function is needed
    function voteV2(uint256 proposalId, bool support)
        public
        onlyOwnerOrManager
    {
        governanceV2.submitVote(proposalId, support);
    }

    function addToWhitelist(address _address) external onlyOwnerOrManager {
        whitelist[_address] = true;
    }

    function removeFromWhitelist(address _address) external onlyOwnerOrManager {
        whitelist[_address] = false;
    }
}