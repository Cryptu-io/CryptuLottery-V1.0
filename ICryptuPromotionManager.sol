
//gas opt version

//Author: C.W from Cryptu.io
//CryptuPromotionManger v1.0
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma abicoder v2;
interface ICryptuPromotionManager
{
     function useCode(bytes10 refCode,uint32 buyCount,uint256 commissionAmount,uint256 fee)external; 
    function getCodeDiscount(bytes10 refCode) external view returns (uint256) ;
    function getCodeComission(bytes10 refCode) external  view returns (uint256,uint256);
}