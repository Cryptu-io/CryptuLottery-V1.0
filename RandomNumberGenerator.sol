//SPDX-License-Identifier: MIT
//Author: C.W from Cryptu.io
//VRF2 V2 fork of pancakeswap's RandomGenerator contract
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";

interface IRandomNumberGenerator {
    /**
     * Requests randomness from a user-provided seed
     */
     function getRandomNumber() external returns ( uint256 requestId);
    /**
     * View latest lotteryId numbers
     */
    function viewLatestLotteryId() external view returns (uint256);

    /**
     * Views random result
     */
    function viewRandomResult() external view returns (uint32);
}
// interface IPancakeSwapLottery {
//     /**
//      * @notice Buy tickets for the current lottery
//      * @param _lotteryId: lotteryId
//      * @param _ticketNumbers: array of ticket numbers between 1,000,000 and 1,999,999
//      * @dev Callable by users
//      */
//     function buyTickets(uint256 _lotteryId, uint32[] calldata _ticketNumbers) external;

//     /**
//      * @notice Claim a set of winning tickets for a lottery
//      * @param _lotteryId: lottery id
//      * @param _ticketIds: array of ticket ids
//      * @param _brackets: array of brackets for the ticket ids
//      * @dev Callable by users only, not contract!
//      */
//     function claimTickets(
//         uint256 _lotteryId,
//         uint256[] calldata _ticketIds,
//         uint32[] calldata _brackets
//     ) external;

//     /**
//      * @notice Close lottery
//      * @param _lotteryId: lottery id
//      * @dev Callable by operator
//      */
//     function closeLottery(uint256 _lotteryId) external;

//     /**
//      * @notice Draw the final number, calculate reward in CAKE per group, and make lottery claimable
//      * @param _lotteryId: lottery id
//      * @param _autoInjection: reinjects funds into next lottery (vs. withdrawing all)
//      * @dev Callable by operator
//      */
//     function drawFinalNumberAndMakeLotteryClaimable(uint256 _lotteryId, bool _autoInjection) external;

//     /**
//      * @notice Inject funds
//      * @param _lotteryId: lottery id
//      * @param _amount: amount to inject in CAKE token
//      * @dev Callable by operator
//      */
//     function injectFunds(uint256 _lotteryId, uint256 _amount) external;

//     /**
//      * @notice Start the lottery
//      * @dev Callable by operator
//      * @param _endTime: endTime of the lottery
//      * @param _priceTicketInCake: price of a ticket in CAKE
//      * @param _discountDivisor: the divisor to calculate the discount magnitude for bulks
//      * @param _rewardsBreakdown: breakdown of rewards per bracket (must sum to 10,000)
//      * @param _treasuryFee: treasury fee (10,000 = 100%, 100 = 1%)
//      */
//     function startLottery(
//         uint256 _endTime,
//         uint256 _priceTicketInCake,
//         uint256 _discountDivisor,
//         uint256[6] calldata _rewardsBreakdown,
//         uint256 _treasuryFee
//     ) external;

//     /**
//      * @notice View current lottery id
//      */
//     function viewCurrentLotteryId() external returns (uint256);
// }

contract RandomNumberGenerator is VRFV2WrapperConsumerBase,
    ConfirmedOwner, IRandomNumberGenerator {
         event RequestSent(uint256 requestId, uint32 numWords);
    // event RequestFulfilled(
    //     uint256 requestId,
    //     uint256[] randomWords,
    //     uint256 payment
    // );
    //***********************************************************
    event RandomGenerated(uint256 LotteryId,uint32 randomNumber);
    //*********************************
    struct RequestStatus {
        uint256 paid; // amount paid in link
        bool fulfilled; // whether the request has been successfully fulfilled
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; /* requestId --> requestStatus */

    // past requests Id.
    uint256[] public requestIds;
    uint256 public lastRequestId;

     address public pancakeSwapLottery;
    bytes32 public keyHash;
    bytes32 public latestRequestId;
    uint32 public randomResult;
    uint256 public fee;
    uint256 public latestLotteryId;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFV2Wrapper.getConfig().maxNumWords.
    uint32 numWords = 2;

    // // Address LINK - hardcoded for Sepolia
    // address linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // // address WRAPPER - hardcoded for Sepolia
    // address wrapperAddress = 0xab18414CD93297B0d12ac29E63Ca20f515b3DB46;
    //0x699d428ee890d55D56d5FC6e26290f3247A762bd

     // // Address LINK - hardcoded for bsctest
     address linkAddress = 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06;

    // // address WRAPPER - hardcoded for bsctest
     address wrapperAddress = 0x699d428ee890d55D56d5FC6e26290f3247A762bd;

    //We changed this to get the link,wrapper addresses and num of words in the constructor
    constructor(address _linkAddress,address _wrapperAddress,uint32 _numwords)
        ConfirmedOwner(msg.sender)
        VRFV2WrapperConsumerBase(_linkAddress,_wrapperAddress)
    {
        //must check the num of words
        numWords=_numwords;
    }

    // function requestRandomWords()
    //     external
    //     onlyOwner
    //     returns (uint256 requestId)
    // {
    //     requestId = requestRandomness(
    //         callbackGasLimit,
    //         requestConfirmations,
    //         numWords
    //     );
    //     s_requests[requestId] = RequestStatus({
    //         paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
    //         randomWords: new uint256[](0),
    //         fulfilled: false
    //     });
    //     requestIds.push(requestId);
    //     lastRequestId = requestId;
    //     emit RequestSent(requestId, numWords);
    //     return requestId;
    // }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        ///*********************************************************
          randomResult = uint32(1000000 + (_randomWords[0] % 1000000));
          require(pancakeSwapLottery!=address(0),"Lottery contract address not set!");
        //  latestLotteryId = IPancakeSwapLottery(pancakeSwapLottery).viewCurrentLotteryId();
          emit RandomGenerated(latestLotteryId, randomResult);
        //**********************************************************
        // emit RequestFulfilled(
        //     _requestId,
        //     _randomWords,
        //     s_requests[_requestId].paid
        // );
    }

    function getRequestStatus(
        uint256 _requestId
    )
        external
        view
        returns (uint256 paid, bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].paid > 0, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.paid, request.fulfilled, request.randomWords);
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    //using SafeERC20 for IERC20;

   

   
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
     * @notice Request randomness from a user-provided seed
     *
     */
    function getRandomNumber() external override returns ( uint256 requestId) {
     
     
     
     
      
       //****************************************** */
       //temporary disabled
        //require(msg.sender == pancakeSwapLottery, "Only PancakeSwapLottery");
       
        //**************************************************** */
        require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK tokens");

        //********************************************
       
       requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
            randomWords: new uint256[](0),
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
        //*******************************************
       // latestRequestId = requestRandomness(keyHash, fee, _seed);
      //  require(1<0,uint2str(latestLotteryId));
    }

    /**
     * @notice Change the fee
     * @param _fee: new fee (in LINK)
     */
    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    /**
     * @notice Change the keyHash
     * @param _keyHash: new keyHash
     */
    function setKeyHash(bytes32 _keyHash) external onlyOwner {
        keyHash = _keyHash;
    }

    /**
     * @notice Set the address for the PancakeSwapLottery
     * @param _pancakeSwapLottery: address of the PancakeSwap lottery
     */
    function setLotteryAddress(address _pancakeSwapLottery) external onlyOwner {
        pancakeSwapLottery = _pancakeSwapLottery;
    }

  

    /**
     * @notice View latestLotteryId
     */
    function viewLatestLotteryId() external view override returns (uint256) {
        return latestLotteryId;
    }

    /**
     * @notice View random result
     */
    function viewRandomResult() external view override returns (uint32) {
        return randomResult;
    }

    // /**
    //  * @notice Callback function used by ChainLink's VRF Coordinator
    //  */
    // function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
    //     require(latestRequestId == requestId, "Wrong requestId");
    //     randomResult = uint32(1000000 + (randomness % 1000000));
    //     latestLotteryId = IPancakeSwapLottery(pancakeSwapLottery).viewCurrentLotteryId();
    // }
}