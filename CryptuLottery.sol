//Author: C.W from Cryptu.io
//fork of PancakeSwap Lottery contract with ChainLink's VRF2 and Cryptu's Promotion Manager
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;//gas opt
import "./OldDependencies.sol";//gas opt -less gas usage
import "./ICryptuPromotionManager.sol";//importing the Promotion Manager  Contract Interface
import "./ICryptuLottery.sol";//importing the CrypyuLottery interface
import "./IRandomNumberGenerator.sol";




pragma abicoder v2;

/** @title Cryptu Lottery.
 * @notice It is a contract for a lottery system using
 * randomness provided externally.
 */
contract CryptuLottery is ReentrancyGuard, ICryptuLottery, Ownable {
    using SafeERC20 for IERC20;

    address public injectorAddress;
    address public operatorAddress;
    address public treasuryAddress;

    uint32 public currentLotteryId;
    uint64 public currentTicketId;

    uint256 public maxNumberTicketsPerBuyOrClaim = 100;

    uint256 public maxPriceTicketInCake = 50 ether;
    uint256 public minPriceTicketInCake =0.0000000001 ether;//  0.005 ether;

    uint256 public pendingInjectionNextLottery;

    uint256 public constant MIN_DISCOUNT_DIVISOR = 300;
    uint256 public constant MIN_LENGTH_LOTTERY = 4 hours - 5 minutes; // 4 hours
    
   //************************************************************** */
   //  as test 
   //10 seconds;
   // uint256 public constant MIN_LENGTH_LOTTERY = 1 minutes; //4 hours;
   //******************************************************************** */
   
    uint256 public constant MAX_LENGTH_LOTTERY =7 days+ 5 minutes;// 4 days + 5 minutes; // 4 days
    uint256 public constant MAX_TREASURY_FEE = 3000; // 30%

    IERC20 public cakeToken;
    IRandomNumberGenerator public randomGenerator;

    enum Status {
        Pending,
        Open,
        Close,
        Claimable
    }

    struct Lottery {
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 priceTicketInCake;
        uint256 discountDivisor;
        uint256 amountCollectedInCake;
        uint256 treasuryFee; // 500: 5% // 200: 2% // 50: 0.5%
        uint256[6] cakePerBracket;
        
        uint64 firstTicketIdNextLottery;//gas opt 
        uint64 firstTicketId;//gas opt
          
        uint32 finalNumber;
        uint32 numberOfPlayers;//@dev: new feature added by Cryptu//gas opt

        uint16[6] rewardsBreakdown;//gas opt // 0: 1 matching number // 5: 6 matching numbers
       
      
        uint32[6] countWinningsPerBracket;//gas opt
      
    }

    //added by cyrus
    struct WinningTicket{//gas opt
        bool claimed;
        uint8 bracket;
        uint32 number;
        uint64 id;
        uint256 prize;


    }

   

    
    //************************************************
    struct Ticket {
        uint32 number;
        address owner;
    }

    // Mapping are cheaper than arrays
    mapping(uint32 => Lottery) private _lotteries;
    mapping(uint64 => Ticket) private _tickets;

    // Bracket calculator is used for verifying claims for ticket prizes
    mapping(uint32 => uint32) private _bracketCalculator;

    // Keeps track of number of ticket per unique combination for each lotteryId
    mapping(uint32 => mapping(uint32 => uint32)) private _numberTicketsPerLotteryId;

    // Keep track of user ticket ids for a given lotteryId
    mapping(address => mapping(uint32 => uint64[])) private _userTicketIdsPerLotteryId;

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    modifier onlyOwnerOrInjector() {
        require((msg.sender == owner()) || (msg.sender == injectorAddress), "Not owner or injector");
        _;
    }

    event AdminTokenRecovery(address token, uint256 amount);
    event LotteryClose(uint32 indexed lotteryId, uint64 firstTicketIdNextLottery);
    event LotteryInjection(uint32 indexed lotteryId, uint256 injectedAmount);
    event LotteryOpen(
        uint32 indexed lotteryId,
        uint256 startTime,
        uint256 endTime,
        uint256 priceTicketInCake,
        uint64 firstTicketId,
        uint256 injectedAmount
    );
    event LotteryNumberDrawn(uint32 indexed lotteryId, uint32 finalNumber, uint32 countWinningTickets);
    event NewOperatorAndTreasuryAndInjectorAddresses(address operator, address treasury, address injector);
    event NewRandomGenerator(address indexed randomGenerator);
    event TicketsPurchase(address indexed buyer, uint32 indexed lotteryId, uint32 numberTickets);
    event TicketsClaim(address indexed claimer, uint256 amount, uint32 indexed lotteryId, uint32 numberTickets);


    //******** @ dev additives for Promotion Manager support 
     event  OnCommisionTransfered(uint256 amount,bytes10 refCode);//optional event that shows the commission transfer
     ICryptuPromotionManager public promotionManager; //promotion manager contract instance

    //*****************************************************
    /**
     * @notice Constructor
     * @dev RandomNumberGenerator must be deployed prior to this contract
     * @param _cakeTokenAddress: address of the CAKE token
     * @param _randomGeneratorAddress: address of the RandomGenerator contract used to work with ChainLink VRF
     */
     /*@dev new parameters added due to PM
       @param  _promotionManager promotion manager contract address
      
     */


    constructor(address _cakeTokenAddress, address _randomGeneratorAddress,address _promotionManager) {
        cakeToken = IERC20(_cakeTokenAddress);
        
        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);

        //@dev attaching the PM contract******************************************
        promotionManager=ICryptuPromotionManager(_promotionManager);
        //*************************************************************************  
        // Initializes a mapping
        _bracketCalculator[0] = 1;
        _bracketCalculator[1] = 11;
        _bracketCalculator[2] = 111;
        _bracketCalculator[3] = 1111;
        _bracketCalculator[4] = 11111;
        _bracketCalculator[5] = 111111;
    }

    /**
     * @notice Buy tickets for the current lottery
     * @param _lotteryId: lotteryId
     * @param _ticketNumbers: array of ticket numbers between 1,000,000 and 1,999,999
     * @param  _refCode referral code;Promotion Manager Support
     * @dev Callable by users
     */
    function buyTickets(uint32 _lotteryId, uint32[] calldata _ticketNumbers,bytes10 _refCode/*Promotion Manager Support*/)
        external
        override
        notContract
        nonReentrant
    {
        require(_ticketNumbers.length != 0, "No ticket specified");
        require(_ticketNumbers.length <= maxNumberTicketsPerBuyOrClaim, "Too many tickets");

        require(_lotteries[_lotteryId].status == Status.Open, "Lottery is not open");
        require(block.timestamp < _lotteries[_lotteryId].endTime, "Lottery is over");

        // Calculate number of CAKE to this contract
        uint256 amountCakeToTransfer = _calculateTotalPriceForBulkTickets(
            _lotteries[_lotteryId].discountDivisor,
            _lotteries[_lotteryId].priceTicketInCake,
            _ticketNumbers.length,_refCode
        );

        // Transfer cake tokens to this contract
        cakeToken.safeTransferFrom(address(msg.sender), address(this), amountCakeToTransfer);
        
        //Promotion Manager Support***********************************************************
        if(_refCode!=0)
        {
            //a ref code is supplied
            (uint256 _promoterPercent, uint256 _feePercent)=promotionManager.getCodeComission(_refCode);//getting commision percentage from te PM
            uint256 _promoterCommission=(_promoterPercent*amountCakeToTransfer)/10000;

            uint256 _fee=(_feePercent*amountCakeToTransfer)/10000;//the PM service fee if sale percentage is selected


            uint256 _PM_amount=_promoterCommission+_fee;
            //transfering the promoter commission and fee to PM
            cakeToken.safeTransfer(address(promotionManager), _PM_amount);
            
             //using the referral code
            promotionManager.useCode(_refCode,(uint32)(_ticketNumbers.length),_promoterCommission,_fee);

            // emit OnCommisionTransfered(_promoterCommission, _refCode);//gas opt omitted!
             // Increment the total amount collected for the lottery round minus promoters commission and service fee
            //  _lotteries[_lotteryId].amountCollectedInCake += amountCakeToTransfer-_PM_amount;
             _lotteries[_lotteryId].amountCollectedInCake= _lowgas_add_256( _lotteries[_lotteryId].amountCollectedInCake,amountCakeToTransfer-_PM_amount);//gas opt
        }else 
        {
            //no refcode supplied

            
             _lotteries[_lotteryId].amountCollectedInCake =_lowgas_add_256(_lotteries[_lotteryId].amountCollectedInCake, amountCakeToTransfer);//gas opt
        }
        
        
        //************************************************************************************

       

        for (uint32 i; i < _ticketNumbers.length;) {//gas opt
            uint32 thisTicketNumber = _ticketNumbers[i];

            require((thisTicketNumber >= 1000000) && (thisTicketNumber <= 1999999), "Outside range");

            // _numberTicketsPerLotteryId[_lotteryId][1 + (thisTicketNumber % 10)]++;
            // _numberTicketsPerLotteryId[_lotteryId][11 + (thisTicketNumber % 100)]++;
            // _numberTicketsPerLotteryId[_lotteryId][111 + (thisTicketNumber % 1000)]++;
            // _numberTicketsPerLotteryId[_lotteryId][1111 + (thisTicketNumber % 10000)]++;
            // _numberTicketsPerLotteryId[_lotteryId][11111 + (thisTicketNumber % 100000)]++;
            // _numberTicketsPerLotteryId[_lotteryId][111111 + (thisTicketNumber % 1000000)]++;

            //gas opt-more efficient
            uint32  _p1=(uint32)(uint32(1)+thisTicketNumber % uint32(10));
            uint32  _p2=(uint32)(uint32(11)+thisTicketNumber % uint32(100));
            uint32  _p3=(uint32)(uint32(111) + thisTicketNumber % uint32(1000));
            uint32  _p4=(uint32)(uint32(1111)+thisTicketNumber % uint32(10000));
            uint32  _p5=(uint32)(uint32(11111)+thisTicketNumber % uint32(100000));
            uint32  _p6=(uint32)(uint32(111111)+thisTicketNumber % uint32(1000000));
            // uint32  _p1=(1)+thisTicketNumber % (10);
            // uint32  _p2=(11)+thisTicketNumber % (100);
            // uint32  _p3=(111) + thisTicketNumber % (1000);
            // uint32  _p4=(1111)+thisTicketNumber % (10000);
            // uint32  _p5=(11111)+thisTicketNumber % (100000);
            // uint32  _p6=(111111)+thisTicketNumber % (1000000);
            _numberTicketsPerLotteryId[_lotteryId][_p1]=_lowgas_inc_32( _numberTicketsPerLotteryId[_lotteryId][_p1]);
            _numberTicketsPerLotteryId[_lotteryId][_p2]=_lowgas_inc_32(_numberTicketsPerLotteryId[_lotteryId][_p2]);
            _numberTicketsPerLotteryId[_lotteryId][_p3]=_lowgas_inc_32(_numberTicketsPerLotteryId[_lotteryId][_p3]);
            _numberTicketsPerLotteryId[_lotteryId][_p4]=_lowgas_inc_32(_numberTicketsPerLotteryId[_lotteryId][_p4]);
            _numberTicketsPerLotteryId[_lotteryId][_p5]=_lowgas_inc_32(_numberTicketsPerLotteryId[_lotteryId][_p5]);
            _numberTicketsPerLotteryId[_lotteryId][_p6]=_lowgas_inc_32(_numberTicketsPerLotteryId[_lotteryId][_p6]);

            _userTicketIdsPerLotteryId[msg.sender][_lotteryId].push(currentTicketId);

            _tickets[currentTicketId] = Ticket({number: thisTicketNumber, owner: msg.sender});

            // Increase lottery ticket number
          currentTicketId= _lowgas_inc_64(currentTicketId);//gas opt  // currentTicketId++;

            unchecked{++i;}//gas opt
        }


        //********************************************************************* */
        //added by Cyrus
        //_lotteries[_lotteryId].numberOfPlayers+=uint32(_ticketNumbers.length);
       _lotteries[_lotteryId].numberOfPlayers=_lowgas_add_32(_lotteries[_lotteryId].numberOfPlayers, uint32(_ticketNumbers.length));//gas opt
        //********************************************************************* */
        emit TicketsPurchase(msg.sender, _lotteryId,uint32( _ticketNumbers.length));
    }

    /**
     * @notice Claim a set of winning tickets for a lottery
     * @param _lotteryId: lottery id
     * @param _ticketIds: array of ticket ids
     * @param _brackets: array of brackets for the ticket ids
     * @dev Callable by users only, not contract!
     */
    function claimTickets(
        uint32 _lotteryId,
        uint64[] calldata _ticketIds,
        uint32[] calldata _brackets
    ) external override notContract nonReentrant {
        require(_ticketIds.length == _brackets.length, "Not same length");
        require(_ticketIds.length != 0, "Length must be >0");
        require(_ticketIds.length <= maxNumberTicketsPerBuyOrClaim, "Too many tickets");
        require(_lotteries[_lotteryId].status == Status.Claimable, "Lottery not claimable");

        // Initializes the rewardInCakeToTransfer
        uint256 rewardInCakeToTransfer;

        for (uint256 i ; i < _ticketIds.length; ) {
            require(_brackets[i] < 6, "Bracket out of range"); // Must be between 0 and 5

            uint64 thisTicketId = _ticketIds[i];

            require(_lotteries[_lotteryId].firstTicketIdNextLottery > thisTicketId, "TicketId too high");
            require(_lotteries[_lotteryId].firstTicketId <= thisTicketId, "TicketId too low");
            require(msg.sender == _tickets[thisTicketId].owner, "Not the owner");

            // Update the lottery ticket owner to 0x address
            _tickets[thisTicketId].owner = address(0);

            uint256 rewardForTicketId = _calculateRewardsForTicketId(_lotteryId, thisTicketId, _brackets[i]);

            // Check user is claiming the correct bracket
            require(rewardForTicketId != 0, "No prize for this bracket");

            if (_brackets[i] != 5) {
                require(
                    _calculateRewardsForTicketId(_lotteryId, thisTicketId, _brackets[i] + 1) == 0,
                    "Bracket must be higher"
                );
            }

            // Increment the reward to transfer
            rewardInCakeToTransfer += rewardForTicketId;

            unchecked{++i;}//gas opt
        }

        // Transfer money to msg.sender
        cakeToken.safeTransfer(msg.sender, rewardInCakeToTransfer);

        emit TicketsClaim(msg.sender, rewardInCakeToTransfer, _lotteryId,uint32( _ticketIds.length));
    }

    /**
     * @notice Close lottery
     * @param _lotteryId: lottery id
     * @dev Callable by operator
     */
    function closeLottery(uint32 _lotteryId) external override onlyOperator nonReentrant {
        require(_lotteries[_lotteryId].status == Status.Open, "Lottery not open");
        require(block.timestamp > _lotteries[_lotteryId].endTime, "Lottery not over");
        
      

         require(block.timestamp > _lotteries[_lotteryId].endTime,uint2str(block.timestamp) );
        _lotteries[_lotteryId].firstTicketIdNextLottery = currentTicketId;

        
       
        //*************************************************************
        //new call using ChainLink VRF2
        randomGenerator.getRandomNumber();

        //*************************************************************

        _lotteries[_lotteryId].status = Status.Close;

        emit LotteryClose(_lotteryId, currentTicketId);
    }

    /**
     * @notice Draw the final number, calculate reward in CAKE per group, and make lottery claimable
     * @param _lotteryId: lottery id
     * @param _autoInjection: reinjects funds into next lottery (vs. withdrawing all)
     * @dev Callable by operator
     */
    function drawFinalNumberAndMakeLotteryClaimable(uint32 _lotteryId, bool _autoInjection)
        external
        override
        onlyOperator
        nonReentrant
    {

      
        // Calculate the finalNumber based on the randomResult generated by ChainLink's fallback
        uint32 finalNumber =  randomGenerator.viewRandomResult();

        //******************************************************************************************
        //@dev: preventing number duplication due to lack of Link balance of random generator    
        if(currentLotteryId!=0)
        {
            if(_lotteries[currentLotteryId-1].finalNumber==finalNumber)//previous round number
                revert("Wrong final number!");
        }
        //*******************************************************************************************

        // Initialize a number to count addresses in the previous bracket
        uint32 numberAddressesInPreviousBracket;
        _lotteryId=_lotteryId;
        _autoInjection=true;
      
        
        // Calculate the amount to share post-treasury fee
        uint256 amountToShareToWinnings = (
            ((_lotteries[_lotteryId].amountCollectedInCake) * (10000 - _lotteries[_lotteryId].treasuryFee))
        ) / 10000;

        // Initializes the amount to withdraw to treasury
        uint256 amountToWithdrawToTreasury;

        // Calculate prizes in CAKE for each bracket by starting from the highest one
        for (uint32 i; i < 6;) {
            uint32 j = 5 - i;
            uint32 transformedWinningNumber = _bracketCalculator[j] + (finalNumber % (uint32(10)**(j + 1)));

            _lotteries[_lotteryId].countWinningsPerBracket[j] =
                _numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber] -
                numberAddressesInPreviousBracket;

            // A. If number of users for this _bracket number is superior to 0
            if (
                (_numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber] - numberAddressesInPreviousBracket) !=
                0
            ) {
                // B. If rewards at this bracket are > 0, calculate, else, report the numberAddresses from previous bracket
                if (_lotteries[_lotteryId].rewardsBreakdown[j] != 0) {
                    _lotteries[_lotteryId].cakePerBracket[j] =
                        ((_lotteries[_lotteryId].rewardsBreakdown[j] * amountToShareToWinnings) /
                            (_numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber] -
                                numberAddressesInPreviousBracket)) /
                        10000;

                    // Update numberAddressesInPreviousBracket
                    numberAddressesInPreviousBracket = _numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber];
                }
                // A. No CAKE to distribute, they are added to the amount to withdraw to treasury address
            } else {
                _lotteries[_lotteryId].cakePerBracket[j] = 0;

                amountToWithdrawToTreasury +=
                    (_lotteries[_lotteryId].rewardsBreakdown[j] * amountToShareToWinnings) /
                    10000;
            }
              unchecked{++i;}//gas opt
        }

        // Update internal statuses for lottery
        _lotteries[_lotteryId].finalNumber = finalNumber;
        _lotteries[_lotteryId].status = Status.Claimable;

        if (_autoInjection) {
            pendingInjectionNextLottery = amountToWithdrawToTreasury;
            amountToWithdrawToTreasury = 0;
        }

        amountToWithdrawToTreasury += (_lotteries[_lotteryId].amountCollectedInCake - amountToShareToWinnings);

        // Transfer CAKE to treasury address
        if(amountToWithdrawToTreasury!=0)//@dev
            cakeToken.safeTransfer(treasuryAddress, amountToWithdrawToTreasury);

        emit LotteryNumberDrawn(currentLotteryId, finalNumber, numberAddressesInPreviousBracket);
        
    }

    /**
     * @notice Change the random generator
     * @dev The calls to functions are used to verify the new generator implements them properly.
     * It is necessary to wait for the VRF response before starting a round.
     * Callable only by the contract owner
     * @param _randomGeneratorAddress: address of the random generator
     */
    function changeRandomGenerator(address _randomGeneratorAddress) external onlyOwner {
        require(_lotteries[currentLotteryId].status == Status.Claimable, "Lottery not in claimable");

       

        //********************************************************************
        //@dev: using ChainLink VRF V2
        IRandomNumberGenerator(_randomGeneratorAddress).getRandomNumber();

        //********************************************************************

        // Calculate the finalNumber based on the randomResult generated by ChainLink's fallback
        IRandomNumberGenerator(_randomGeneratorAddress).viewRandomResult();

        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);

        emit NewRandomGenerator(_randomGeneratorAddress);
    }

    /**
     * @notice Inject funds
     * @param _lotteryId: lottery id
     * @param _amount: amount to inject in CAKE token
     * @dev Callable by owner or injector address
     */
    function injectFunds(uint32 _lotteryId, uint256 _amount) external override onlyOwnerOrInjector {
        require(_lotteries[_lotteryId].status == Status.Open, "Lottery not open");

        cakeToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        _lotteries[_lotteryId].amountCollectedInCake += _amount;

        emit LotteryInjection(_lotteryId, _amount);
    }
function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len;
        while (_i != 0) {
            k = k-1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }


    /**
     * @notice Start the lottery
     * @dev Callable by operator
     * @param _endTime: endTime of the lottery
     * @param _priceTicketInCake: price of a ticket in CAKE
     * @param _discountDivisor: the divisor to calculate the discount magnitude for bulks
     * @param _rewardsBreakdown: breakdown of rewards per bracket (must sum to 10,000)
     * @param _treasuryFee: treasury fee (10,000 = 100%, 100 = 1%)
     */
    function startLottery(
        uint256 _endTime,
        uint256 _priceTicketInCake,
        uint256 _discountDivisor,
        uint16[6] calldata _rewardsBreakdown,
        uint256 _treasuryFee
    ) external override onlyOperator {
        require(
            (currentLotteryId == 0) || (_lotteries[currentLotteryId].status == Status.Claimable),
            "Not time to start lottery"
        );

        require(
            ((_endTime - block.timestamp) > MIN_LENGTH_LOTTERY) && ((_endTime - block.timestamp) < MAX_LENGTH_LOTTERY),
            "Lottery length outside of range" );

        require(
            (_priceTicketInCake >= minPriceTicketInCake) && (_priceTicketInCake <= maxPriceTicketInCake),
            "Outside of limits"
        );

        require(_discountDivisor >= MIN_DISCOUNT_DIVISOR, "Discount divisor too low");
        require(_treasuryFee <= MAX_TREASURY_FEE, "Treasury fee too high");

        require(
            (_rewardsBreakdown[0] +
                _rewardsBreakdown[1] +
                _rewardsBreakdown[2] +
                _rewardsBreakdown[3] +
                _rewardsBreakdown[4] +
                _rewardsBreakdown[5]) == 10000,
            "Rewards must equal 10000"
        );

   
        currentLotteryId= _lowgas_inc_32(currentLotteryId);//gas opt /
   

        _lotteries[currentLotteryId] = Lottery({
            status: Status.Open,
            startTime: block.timestamp,
            endTime: _endTime,
            priceTicketInCake: _priceTicketInCake,
            discountDivisor: _discountDivisor,
            rewardsBreakdown: _rewardsBreakdown,
            treasuryFee: _treasuryFee,
            cakePerBracket: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            countWinningsPerBracket: [uint32(0), uint32(0), uint32(0), uint32(0), uint32(0), uint32(0)],
            firstTicketId: currentTicketId,
            firstTicketIdNextLottery: currentTicketId,
            amountCollectedInCake: pendingInjectionNextLottery,
            finalNumber: 0,
            numberOfPlayers:0
        });

        emit LotteryOpen(
            currentLotteryId,
            block.timestamp,
            _endTime,
            _priceTicketInCake,
            currentTicketId,
            pendingInjectionNextLottery
        );

        pendingInjectionNextLottery = 0;
    }

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of token amount to withdraw
     * @dev Only callable by owner.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(cakeToken), "Cannot be CAKE token");

        IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /**
     * @notice Set CAKE price ticket upper/lower limit
     * @dev Only callable by owner
     * @param _minPriceTicketInCake: minimum price of a ticket in CAKE
     * @param _maxPriceTicketInCake: maximum price of a ticket in CAKE
     */
    function setMinAndMaxTicketPriceInCake(uint256 _minPriceTicketInCake, uint256 _maxPriceTicketInCake)
        external
        onlyOwner
    {
        require(_minPriceTicketInCake <= _maxPriceTicketInCake, "minPrice must be < maxPrice");

        minPriceTicketInCake = _minPriceTicketInCake;
        maxPriceTicketInCake = _maxPriceTicketInCake;
    }

    /**
     * @notice Set max number of tickets
     * @dev Only callable by owner
     */
    function setMaxNumberTicketsPerBuy(uint256 _maxNumberTicketsPerBuy) external onlyOwner {
        require(_maxNumberTicketsPerBuy != 0, "Must be > 0");
        maxNumberTicketsPerBuyOrClaim = _maxNumberTicketsPerBuy;
    }

    /**
     * @notice Set operator, treasury, and injector addresses
     * @dev Only callable by owner
     * @param _operatorAddress: address of the operator
     * @param _treasuryAddress: address of the treasury
     * @param _injectorAddress: address of the injector
     */
    function setOperatorAndTreasuryAndInjectorAddresses(
        address _operatorAddress,
        address _treasuryAddress,
        address _injectorAddress
    ) external onlyOwner {
        require(_operatorAddress != address(0), "Cannot be zero address");
        require(_treasuryAddress != address(0), "Cannot be zero address");
        require(_injectorAddress != address(0), "Cannot be zero address");

        operatorAddress = _operatorAddress;
        treasuryAddress = _treasuryAddress;
        injectorAddress = _injectorAddress;

        emit NewOperatorAndTreasuryAndInjectorAddresses(_operatorAddress, _treasuryAddress, _injectorAddress);
    }

    /**
     * @notice Calculate price of a set of tickets
     * @param _discountDivisor: divisor for the discount
     * @param _priceTicket price of a ticket (in CAKE)
     * @param _numberTickets number of tickets to buy
     * @dev _refCode aaded due to promotion manager, the referral code
     */

    function calculateTotalPriceForBulkTickets(
        uint256 _discountDivisor,
        uint256 _priceTicket,
        uint256 _numberTickets,
        bytes10 _refCode
    ) external view returns (uint256) {
        require(_discountDivisor >= MIN_DISCOUNT_DIVISOR, "Must be >= MIN_DISCOUNT_DIVISOR");
        require(_numberTickets != 0, "Number of tickets must be > 0");

        return _calculateTotalPriceForBulkTickets(_discountDivisor, _priceTicket, _numberTickets,_refCode);
    }

    /**
     * @notice View current lottery id
     */
    function viewCurrentLotteryId() external view override returns (uint256) {
        return currentLotteryId;
    }

    /**
     * @notice View lottery information
     * @param _lotteryId: lottery id
     */
    function viewLottery(uint32 _lotteryId) external view returns (Lottery memory) {
        return _lotteries[_lotteryId];
    }

    /**
     * @notice View ticker statuses and numbers for an array of ticket ids
     * @param _ticketIds: array of _ticketId
     */
    function viewNumbersAndStatusesForTicketIds(uint64[] calldata _ticketIds)
        external
        view
        returns (uint32[] memory, bool[] memory)
    {
        uint256 length = _ticketIds.length;
        uint32[] memory ticketNumbers = new uint32[](length);
        bool[] memory ticketStatuses = new bool[](length);

        for (uint i ; i < length;) {
            ticketNumbers[i] = _tickets[_ticketIds[i]].number;
            if (_tickets[_ticketIds[i]].owner == address(0)) {
                ticketStatuses[i] = true;
            } else {
                ticketStatuses[i] = false;
            }
              unchecked{++i;}//gas opt
        }

        return (ticketNumbers, ticketStatuses);
    }

    /**
     * @notice View rewards for a given ticket, providing a bracket, and lottery id
     * @dev Computations are mostly offchain. This is used to verify a ticket!
     * @param _lotteryId: lottery id
     * @param _ticketId: ticket id
     * @param _bracket: bracket for the ticketId to verify the claim and calculate rewards
     */
    function viewRewardsForTicketId(
        uint32 _lotteryId,
        uint32 _ticketId,
        uint32 _bracket
    ) external view returns (uint256) {
        // Check lottery is in claimable status
        if (_lotteries[_lotteryId].status != Status.Claimable) {
            return 0;
        }

        // Check ticketId is within range
        if (
            (_lotteries[_lotteryId].firstTicketIdNextLottery < _ticketId) &&
            (_lotteries[_lotteryId].firstTicketId >= _ticketId)
        ) {
            return 0;
        }

        return _calculateRewardsForTicketId(_lotteryId, _ticketId, _bracket);
    }




    /**
     * @notice View user ticket ids, numbers, and statuses of user for a given lottery
     * @param _user: user address
     * @param _lotteryId: lottery id
     * @param _cursor: cursor to start where to retrieve the tickets
     * @param _size: the number of tickets to retrieve
     */
    function viewUserInfoForLotteryId(
        address _user,
        uint32 _lotteryId,
        uint32 _cursor,
        uint32 _size
    )
        external
        view
        returns (
            uint64[] memory,
            uint32[] memory,
            bool[] memory,
            uint256
        )
    {
        uint256 length = _size;
        uint256 numberTicketsBoughtAtLotteryId = _userTicketIdsPerLotteryId[_user][_lotteryId].length;

        if (length > (numberTicketsBoughtAtLotteryId - _cursor)) {
            length = numberTicketsBoughtAtLotteryId - _cursor;
        }

        uint64[] memory lotteryTicketIds = new uint64[](length);
        uint32[] memory ticketNumbers = new uint32[](length);
        bool[] memory ticketStatuses = new bool[](length);

        for (uint256 i; i < length; ) {
            lotteryTicketIds[i] = _userTicketIdsPerLotteryId[_user][_lotteryId][i + _cursor];
            ticketNumbers[i] = _tickets[lotteryTicketIds[i]].number;

            // True = ticket claimed
            if (_tickets[lotteryTicketIds[i]].owner == address(0)) {
                ticketStatuses[i] = true;
            } else {
                // ticket not claimed (includes the ones that cannot be claimed)
                ticketStatuses[i] = false;
            }
            unchecked{++i;} //gas opt   
        }

        return (lotteryTicketIds, ticketNumbers, ticketStatuses, _cursor + length);
    }

    /**
     * @notice Calculate rewards for a given ticket
     * @param _lotteryId: lottery id
     * @param _ticketId: ticket id
     * @param _bracket: bracket for the ticketId to verify the claim and calculate rewards
     */
    function _calculateRewardsForTicketId(
        uint32 _lotteryId,
        uint64 _ticketId,
        uint32 _bracket
    ) internal view returns (uint256) {
        // Retrieve the winning number combination
        uint32 userNumber = _lotteries[_lotteryId].finalNumber;

        // Retrieve the user number combination from the ticketId
        uint32 winningTicketNumber = _tickets[_ticketId].number;

        // Apply transformation to verify the claim provided by the user is true
        uint32 transformedWinningNumber = _bracketCalculator[_bracket] +
            (winningTicketNumber % (uint32(10)**(_bracket + 1)));

        uint32 transformedUserNumber = _bracketCalculator[_bracket] + (userNumber % (uint32(10)**(_bracket + 1)));

        // Confirm that the two transformed numbers are the same, if not throw
        if (transformedWinningNumber == transformedUserNumber) {
            return _lotteries[_lotteryId].cakePerBracket[_bracket];
        } else {
            return 0;
        }
    }

    /**
     * @notice Calculate final price for bulk of tickets
     * @param _discountDivisor: divisor for the discount (the smaller it is, the greater the discount is)
     * @param _priceTicket: price of a ticket
     * @param _numberTickets: number of tickets purchase
     * @param _refCode promotion manager support
     */
     function _calculateTotalPriceForBulkTickets(
        uint256 _discountDivisor,
        uint256 _priceTicket,
        uint256 _numberTickets,
        bytes10 _refCode//promotion manager support
    ) internal view returns (uint256) {
        uint256 _totalPrice=_priceTicket * _numberTickets;
        //@dev*****************************************************************************************
        //promotion manager support
        //gas opt- revised 
        if(_refCode!=0)
        {
            //a refcode supplied
            uint256 _codeDiscount=promotionManager.getCodeDiscount(_refCode);
            return ((_totalPrice * (_discountDivisor + 1 - _numberTickets)) / _discountDivisor)-(_totalPrice*_codeDiscount)/10000 ;
        }
        else 
        {
            //no code
            return ((_totalPrice * (_discountDivisor + 1 - _numberTickets)) / _discountDivisor) ;
        }
        
     
        //*********************************************************************************************
       
    }
    /**
     * @notice Check if an address is a contract
     */
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /********************************************************************* */





function viewUserWinningTickets(address _user,
            uint32 _lotteryId
            ) external view returns(uint256 , WinningTicket[] memory )
   {
        //added by Cyrus
        require(_lotteries[_lotteryId].status == Status.Claimable,"Lottery is not claimable!");
        

         uint256 numberTicketsBoughtAtLotteryId = _userTicketIdsPerLotteryId[_user][_lotteryId].length;
         require(numberTicketsBoughtAtLotteryId>0,"No ticket for this user!");
       
       


        uint64[] memory _lotteryTicketIds = new uint64[](numberTicketsBoughtAtLotteryId);
        uint32[] memory _ticketNumbers = new uint32[](numberTicketsBoughtAtLotteryId);
       

        for (uint256 i; i < numberTicketsBoughtAtLotteryId; ) {
            _lotteryTicketIds[i] = _userTicketIdsPerLotteryId[_user][_lotteryId][i];
            _ticketNumbers[i] = _tickets[_lotteryTicketIds[i]].number;

            unchecked{++i;}//gas opt
        }
        
        uint32 _WinningTicketCount=0;
        uint256 _totalUserPrize=0;
        // uint256 _rewardForBracket=0;
        uint256[][] memory _rewardForBracket = new uint256[][](_lotteryTicketIds.length);
    
        for (uint256 i; i < _lotteryTicketIds.length;) {
            _rewardForBracket[i] = new uint256[](6); // Initialize each inner array with size 6
            unchecked{++i;}//gas opt
        }

         //getting all rewards   
         for (uint256 i ; i < _lotteryTicketIds.length;)
          {
            for(uint8 j;j<6;)//bracket size
            {
                _rewardForBracket[i][j]=_calculateRewardsForTicketId(_lotteryId,_lotteryTicketIds[i],j);
                  unchecked{++j;}//gas opt

            }
              unchecked{++i;}//gas opt
          }
         //calculating needed array size
         uint256 _rewardothers=0;
         for (uint256 i ; i < _lotteryTicketIds.length;)
          {
            for(uint8 j;j<6;)//bracket size
            {
              
                if(_rewardForBracket[i][j]>0)
                {
                    // //its a winner in this bracket
                     if(j<5)
                    {
                        _rewardothers=0;
                        for(uint8 k=j+1;k<6;)
                        {
                            if(_rewardForBracket[i][k]!=0)//looking inside upper brackets
                            {
                                _rewardothers++;
                               
                           
                            }
                              unchecked{++k;}//gas opt
                        }
                        if(_rewardothers==0)
                        {
                             _WinningTicketCount++;//there exists no higher bracket
                        }
                       
                    }  
                   
                   
                }
                  unchecked{++j;}//gas opt

            }
              unchecked{++i;}//gas opt
          }
        
        WinningTicket[] memory _WinningTickets=new WinningTicket[](_WinningTicketCount);
        
        _rewardothers=0;
        if(_WinningTicketCount!=0)
        {
        _WinningTicketCount=0;
       
         
         for (uint256 i ; i < _lotteryTicketIds.length;)
          {
            for(uint8 j;j<6;)//bracket size
            {
              
             
               
               if(_rewardForBracket[i][j]>0)
                {
                     // //its a winner in this bracket
                     if(j<5)
                    {
                        _rewardothers=0;
                        for(uint8 k=j+1;k<6;)
                        {
                            if(_rewardForBracket[i][k]!=0)//looking inside upper brackets
                            {
                                _rewardothers++;
                               
                           
                            }
                              unchecked{++k;}//gas opt
                        }
                        if(_rewardothers==0)
                        {
                             //it's a winner in this bracket and theres no higher bracket
                              // True = ticket claimed
                            if (_tickets[_lotteryTicketIds[i]].owner == address(0)) {
                            _WinningTickets[_WinningTicketCount].claimed = true;
                            } else {
                                // ticket not claimed (includes the ones that cannot be claimed)
                            _WinningTickets[_WinningTicketCount].claimed = false;
                            }
                            _WinningTickets[_WinningTicketCount].id=_lotteryTicketIds[i];
                            _WinningTickets[_WinningTicketCount].bracket=j; 
                            _WinningTickets[_WinningTicketCount].number=_ticketNumbers[i];
                            _WinningTickets[_WinningTicketCount].prize=_rewardForBracket[i][j];
                            _WinningTicketCount++;//there exists no higher bracket
                            _totalUserPrize+=_rewardForBracket[i][j];
                        }
                       
                    }  
                   
                   
                  
                }
                  unchecked{++j;}//gas opt

            }
              unchecked{++i;}//gas opt
          }
        }

          return (_totalUserPrize,_WinningTickets);

         





   }


   function viewUserLotteries(address _user) external view returns(uint32 [] memory )
   {
   
   
    uint32 _countOfLottos=0;
    for(uint32 i=1;i<= currentLotteryId ;)
    {
         if(_userTicketIdsPerLotteryId[_user][i].length!=0)
            _countOfLottos++;
       
       unchecked{++i;}//

    }
    uint32[] memory _lotto =new  uint32[](_countOfLottos);
    _countOfLottos=0;
     for(uint32 i=1;i<= currentLotteryId ;)
    {
         if(_userTicketIdsPerLotteryId[_user][i].length!=0)
         {
             _lotto[_countOfLottos]=i;
            _countOfLottos++;
         }
         unchecked{++i;}//gas opt

    }
    return (_lotto);


   }
/********************************************************************* */
function _lowgas_inc_256(uint256 a)private  pure returns (uint256)    
    {
        uint256 _dummy;
        _dummy=a;
        _dummy++;
        return _dummy;

    }
 function _lowgas_inc_64(uint64 a)private  pure returns (uint64)    
    {
        uint64 _dummy;
        _dummy=a;
        _dummy++;
        return _dummy;

    } 
 function _lowgas_inc_32(uint32 a)private  pure returns (uint32)    
    {
        uint32 _dummy;
        _dummy=a;
        _dummy++;
        return _dummy;

    }     

   function _lowgas_add_256(uint256  a,uint256  b)private  pure returns (uint256)    
    {
        uint256 am=a;
        uint256 bm=b;

        return am+bm ;

    }
    function _lowgas_add_32(uint32  a,uint32  b)private  pure returns (uint32)    
    {
        uint32 am=a;
        uint32 bm=b;

        return am+bm ;

    }  
}