//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

//Make a function that deposits tokens for devs, under their address. Make sure that this takes a fee from the dev. 
//Add a restriction on the max able to be lent so that they need to do this.

//if user lends additional tokens make sure that they cant reset withdraw date on all the lendings. (lendings would have to be after.

interface IBEP20 {

    function decimals() external view returns (uint8);        
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

}

interface IPCSRouter {

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IPancakeSwapFactory {

    function getPair(address tokenA, address tokenB) external view returns (address pair);

}

contract BearBullRouter is ReentrancyGuard{

    fallback() external payable {}
    receive() external payable {}

    constructor(IPCSRouter _pancakeSwapRouter, address payable _feeCollector){
        WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        token = IBEP20(0x4F0F2fA439C6454B4664f3C4432514Ec07c1bC28);
        pcsRouter = _pancakeSwapRouter;
        tokenAddress = 0x4F0F2fA439C6454B4664f3C4432514Ec07c1bC28;
        owner = msg.sender;
        openFee = 6;
        closeFee = 5;
        feeCollector = _feeCollector;
        maxTradeLength = 3600;
        threshold = 75;
    }

    struct shortPosition{
        address trader;
        uint256 startTime;
        uint256 amount; 
        uint256 tolerance; 
        uint256 startPrice;
        uint256 collateral;
        uint256 ethValue;
        uint256 shortNumber;
        address[] lenders;
        uint256[] amountsLent;
    }

    struct lendingInfo{
        address lender;
        uint256 lendNumber;
        uint256 amount;
        uint256 amountInTrade;
        uint256 endTime;
        uint256 rewards;
    }
    
    IPCSRouter public pcsRouter;
    IBEP20 public token;
    address public WBNB;
    address public tokenAddress;

    shortPosition[] public shorts;
    address[] public lenders;

    mapping(address => lendingInfo) public lendMap; 
    mapping(address => shortPosition) public shortMap;

    address public owner;
    uint256 public threshold;
    uint256 public maxTx;
    
    uint256 public totalLent;
    uint256 public tokensInShorts;

    bool public tradeEnabled;
    bool public lendEnabled;

    uint256 public openFee;
    uint256 public closeFee;

    address payable feeCollector;

    uint256 public feesCollected;

    uint256 public maxTradeLength;

    function changeMaxTradeLength(uint256 _maxTradeLength) external onlyOwner { 
        maxTradeLength = _maxTradeLength;
    }

    function changeFeeCollector (address payable _collector) external onlyOwner{
        feeCollector = _collector;
    }

    modifier onlyOwner {
        require(msg.sender == owner, "You are not the owner of this contract.");_;
    }

    function changeOpenFee (uint256 _fee) external onlyOwner { 
        openFee = _fee;
    }

    function changeCloseFee (uint256 _fee) external onlyOwner {
        closeFee = _fee;
    }

    function changeOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    function changeThreshold(uint256 _threshold) external onlyOwner{
        threshold = _threshold;
    }

    function enableTrade(bool _trade) external onlyOwner{
        tradeEnabled = _trade;
    }

    function enableLending(bool _lend) external onlyOwner{
        lendEnabled = _lend;
    }

    function changeMaxTx(uint256 _maxTx) external onlyOwner{
        maxTx = _maxTx;
    }

    function checkAvailable() private view returns(uint256){
        uint256 available = 0;
        for(uint256 i = 0; i < lenders.length; i++){
            if(lendMap[lenders[i]].endTime > block.timestamp + maxTradeLength){
                available += lendMap[lenders[i]].amount;
                available -= lendMap[lenders[i]].amountInTrade;
            }
        }
        
        return available;
    }
    
    function checkAvailability(uint256 desiredAmount) public view returns (bool) {
        uint256 available = 0;

        for(uint256 i = 0; i < lenders.length; i++){

            if(lendMap[lenders[i]].endTime < block.timestamp + maxTradeLength) {
                continue;
            }
            uint256 potentialAvailable = lendMap[lenders[i]].amount - lendMap[lenders[i]].amountInTrade;
            available += potentialAvailable;
            if(available >= desiredAmount){
                return true;
            }
        }
        return false;
    }


    function fulfill(uint256 amount) private returns (address[] memory, uint256[] memory) {
        uint256 totalFulfillable = 0;
        address[] memory availableLenders = new address[](lenders.length);

        uint256 lenderCount = 0;
        
        uint256[] memory amountLent = new uint256[](lenders.length);
        for(uint256 i = 0; i < lenders.length; i++){

            if(lendMap[lenders[i]].endTime < block.timestamp + 1 hours) {
                continue;
            }
            uint256 potentialFulfillable = lendMap[lenders[i]].amount - lendMap[lenders[i]].amountInTrade;
            if(potentialFulfillable >= amount - totalFulfillable){
                uint256 requiredAmount = 0;
                requiredAmount = amount - totalFulfillable;
                lendMap[lenders[i]].amountInTrade += requiredAmount;
                availableLenders[lenderCount] = lendMap[lenders[i]].lender;
                amountLent[lenderCount] = requiredAmount;
                lenderCount++;
                break;
            }
            else{
                lendMap[lenders[i]].amountInTrade += potentialFulfillable;
                totalFulfillable += potentialFulfillable;
                availableLenders[lenderCount] = lendMap[lenders[i]].lender;
                amountLent[lenderCount] = potentialFulfillable;
                lenderCount++;
            }
        }
        return (availableLenders, amountLent);
    }

    function getCollateral(uint256 amount, uint256 tolerance) public view returns (uint256){

        return ((getValue(amount * 10**token.decimals())) * tolerance / 100);

    }

    function price() private view returns (uint256) {

        address[] memory path = getPathForTokenToETH();
        uint256[] memory amountsOut = pcsRouter.getAmountsOut(10 ** token.decimals(), path);

        return amountsOut[1];
    }

    function checkPrice() external view returns (uint256) {

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(WBNB);
        uint256[] memory amountsOut = pcsRouter.getAmountsOut(10 ** token.decimals(), path);

        return amountsOut[1];
    }

    function getPathForETHToToken() private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = tokenAddress;

        return path;
    }

    function getPathForTokenToETH() private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[1] = WBNB;
        path[0] = tokenAddress;

        return path;
    }

    function getBuybackCost(uint256 amountOut) public view returns (uint256) {
        address[] memory path = getPathForETHToToken();
        uint[] memory amountsIn = pcsRouter.getAmountsIn(amountOut * 10 ** token.decimals(), path);
        return amountsIn[0];
    }

    function getValue(uint256 amountOut) public view returns (uint256){
        address[] memory path = getPathForTokenToETH();
        uint256[] memory amountsOut = pcsRouter.getAmountsOut(amountOut, path);
        return amountsOut[1];

    }

    function distributeFees(uint256 amount) private {

        uint256 totalAmount = checkAvailable();
        for (uint256 i = 0; i < lenders.length; i++){
            if(lendMap[lenders[i]].endTime > block.timestamp + maxTradeLength){
                uint256 toPay = amount * lendMap[lenders[i]].amount / totalAmount;
                lendMap[lenders[i]].rewards += toPay;
            }
        }
    }

    function lendTokens(uint256 amount, uint256 time) external nonReentrant {

        require(lendEnabled, "Lending currently unavailable.");
        
        require(amount > 0, "Not enough tokens");
        
        require(time >= (maxTradeLength/60)/60 + 1, "Lend time must be 1 hour longer than the max trade length.");

        bool success = token.transferFrom(msg.sender, address(this) , amount*10**token.decimals());
        
        require(success, "Token transfer failed.");

        if(lendMap[msg.sender].amount > 0){
            require(block.timestamp + (time * 3600) > lendMap[msg.sender].endTime, "Your new lend position must end further than your current one.");
            lendingInfo memory temp = lendingInfo({
            lender : msg.sender,
            lendNumber : lendMap[msg.sender].lendNumber,
            amount : amount + lendMap[msg.sender].amount,
            amountInTrade : lendMap[msg.sender].amountInTrade,
            endTime : block.timestamp + (time * 3600),
            rewards : 0
        });
        lendMap[msg.sender] = temp;
        }

        else{

            lendingInfo memory temp = lendingInfo({
            lender : msg.sender,
            lendNumber : lenders.length,
            amount : amount,
            amountInTrade : 0,
            endTime : block.timestamp + (time * 3600),
            rewards : 0
            
        });
        lenders.push(msg.sender);
        lendMap[msg.sender] = temp;
        }  
        totalLent += amount;

        emit TokensLent(msg.sender, amount, time);   
    }

    function withdrawTokens() external nonReentrant {
        uint256 amount = lendMap[msg.sender].amount;
        require(amount > 0, "You must withdraw more than 0 tokens.");
        require(lendMap[msg.sender].endTime < block.timestamp, "Your withdraw date has not been met.");

        uint256 _decimals = token.decimals();

        totalLent -= amount;
        delete lenders[lendMap[msg.sender].lendNumber];
        delete lendMap[msg.sender];

        bool success = token.transfer(msg.sender, amount*10**_decimals);
        require(success, "Token transfer failed.");

        emit TokensWithdrawn(msg.sender, amount);
    }

    function rescueFees(address payable _feeCollector, uint256 percentage) external onlyOwner {
        require(feesCollected > 0, "No fees have been collected.");
        uint256 feesToSend = feesCollected * percentage / 100;
        (bool success,) = _feeCollector.call{value : feesToSend}("");
        require(success, "Transfer failed");
        emit RescueFees(_feeCollector, feesToSend);

    }

    function openShort(uint256 amount, uint256 riskTolerance) external payable nonReentrant {

        require(tradeEnabled, "Trading is not enabled!");
        require(shortMap[msg.sender].amount == 0, "You already have a short position open at the moment.");
        require(amount < maxTx, "Position too large!");

        require(amount > 0, "Short position must be greater than zero!");
        //1 == 0.01
        require(riskTolerance == 100, "Risk tolerance must be between 100 during Beta!");
        
        uint256 collateralRequired = getCollateral(amount, riskTolerance);
        require(msg.value >= collateralRequired, "Insufficient collateral!");

        uint256 fees = collateralRequired * openFee / 100;
        require(msg.value >= (collateralRequired + fees), "This transaction does not cover fees!");

        distributeFees(fees/2);
        feesCollected += fees/2;

        uint256 trueAmount = amount * 10**token.decimals();
    
        require(checkAvailability(amount), "Insufficient tokens!");
        uint256 tokenPrice = price();

        address[] memory path = getPathForTokenToETH();

        bool success = token.approve(address(pcsRouter), trueAmount);
        require(success, "Token approval failed");

        uint256 deadline = block.timestamp + 100;


        uint256[] memory amounts = pcsRouter.swapExactTokensForETH(trueAmount, 0, path, address(this), deadline);

        (address[] memory _lenders,  uint256[] memory _amountsLent) = fulfill(amount);

        uint256 shortNum = shorts.length;

        shortPosition memory temp = shortPosition({
            trader : msg.sender,
            amount : amount,
            tolerance : riskTolerance,
            startTime : block.timestamp,
            startPrice : tokenPrice,
            collateral : collateralRequired,
            ethValue : amounts[1],
            shortNumber : shortNum,
            lenders : _lenders,
            amountsLent : _amountsLent
        });

        shortMap[msg.sender] = temp;
        shorts.push(temp);
        
        tokensInShorts += temp.amount;
        emit ShortOpened (msg.sender, amount, tokenPrice, msg.value);
    }

    function closeShort() external nonReentrant {
        shortPosition storage temp = shortMap[msg.sender];
        address[] storage _lenders = temp.lenders;
        uint256[] storage _amounts = temp.amountsLent;
        require(temp.amount > 0, "No short position currently open.");
        for(uint256 i = 0; i < _lenders.length ; i++){
            lendMap[_lenders[i]].amountInTrade -= _amounts[i];
            tokensInShorts -= _amounts[i];
        }

        uint256 decimals = token.decimals();
        uint256 buybackCost = getBuybackCost(temp.amount);
        uint256 toSend = 0;
        uint256 deadline = block.timestamp + 100;
        
        uint256[] memory amounts = pcsRouter.swapETHForExactTokens{value : buybackCost}(temp.amount*10**decimals, getPathForETHToToken(), address(this), deadline);
    
        toSend = temp.ethValue + temp.collateral - amounts[0];
        
        if(toSend > 0){
            (bool success,) = temp.trader.call{value: toSend}("");
            require (success, "Failed to send back ETH.");
        }

        delete shortMap[temp.trader];
        delete shorts[temp.shortNumber];
        emit ShortClosed(msg.sender, temp.amount);

    }

    function closeShortByIndex(uint256 index) public onlyOwner nonReentrant {
        shortPosition storage temp = shorts[index];
        address[] storage _lenders = temp.lenders;
        uint256[] storage _amounts = temp.amountsLent;
        require(temp.amount > 0, "No short position currently open.");
        for(uint256 i = 0; i < _lenders.length ; i++){
            lendMap[_lenders[i]].amountInTrade -= _amounts[i];
            tokensInShorts -= _amounts[i];
        }

        uint256 decimals = token.decimals();
        uint256 buybackCost = getBuybackCost(temp.amount);
        uint256 toSend = 0;
        uint256 deadline = block.timestamp + 100;
        
        uint256[] memory amounts = pcsRouter.swapETHForExactTokens{value : buybackCost}(temp.amount*10**decimals, getPathForETHToToken(), address(this), deadline);
    
        toSend = temp.ethValue + temp.collateral - amounts[0];
        
        if(toSend > 0){
            (bool success,) = temp.trader.call{value: toSend}("");
            require (success, "Failed to send back ETH.");
        }

        delete shortMap[temp.trader];
        delete shorts[temp.shortNumber];
        emit ShortClosed(msg.sender, temp.amount);
    }

    event ShortOpened(address indexed trader, uint256 amount, uint256 entryPrice, uint256 collateral);
    event ShortClosed(address indexed trader, uint256 amount);
    event TokensLent(address lender, uint256 amount, uint256 lendTime);
    event TokensDeposited(address indexed lender, uint256 amount);
    event TokensWithdrawn(address lender, uint256 amount);
    event RescueFees(address feeCollector, uint256 amount);

    function mustLiquidate(shortPosition memory _temp) private view returns (bool) {
        address[] memory path = getPathForETHToToken();
        uint256 amountOut = _temp.amount * 10**token.decimals();
        if(_temp.amount == 0){
            return false;
        }else{
            uint[] memory amounts = pcsRouter.getAmountsIn(amountOut, path);

        if (amounts[0]  >= (_temp.ethValue + _temp.collateral) * threshold / 100 || block.timestamp >= _temp.startTime + maxTradeLength){
            return true;
        }
        else return false;
        }
      
    }

    function shortsToLiquidate() private view returns (uint256[] memory){
        uint256[] memory shortNumbers = new uint256[](shorts.length);
        uint256 secondCount = 0;
        for(uint256 count = 0; count < shorts.length; count++){
            if(mustLiquidate(shorts[count])){
                shortNumbers[secondCount] = shorts[count].shortNumber;
                secondCount++;
            }
        }
        return shortNumbers;
    }

    function mustCallLiquidation() public view returns (bool){
        for(uint256 count = 0; count < shorts.length; count++){
            if(mustLiquidate(shorts[count])){
                return true;
            }else{
                continue;
            }
        }
        return false;
    }

    function toLiquidate() private view returns (shortPosition[] memory) {
        uint256 shortIndex = 0;
        shortPosition[] memory shorters = new shortPosition[](shorts.length);
        for (uint256 count = 0; count < shorts.length; count++){
            if(mustLiquidate(shorts[count])){
              shorters[shortIndex] = shorts[count];
              ++shortIndex;
            }
        }
        
        return shorters;
    }

    function liquidate() external onlyOwner {
        uint256[] memory _shorts = shortsToLiquidate();
            for (uint256 index = 0; index < shorts.length; index++){
                if(index != 0 && _shorts[index] == 0 ){
                    continue;
                }
                else{
                    closeShortByIndex(_shorts[index]);
                }
        }
    }

    function claimRewards() external nonReentrant {
        require(lendMap[msg.sender].rewards > 0, "You have not accumulated any rewards yet.");

        (bool success,) = msg.sender.call{value: lendMap[msg.sender].rewards}("");
        require (success, "Failed to send ETH.");

        lendMap[msg.sender].rewards = 0;
    }

    function emergencyRescueTokens() external onlyOwner {
        uint256 caBalance = token.balanceOf(address(this));
        require(caBalance > 0, "There currently are no tokens in the smart contract.");
    
        bool success = token.transfer(msg.sender, caBalance);
        require(success, "Token transfer failed.");
    }

    function emergencyRescueETH() external onlyOwner {
        require(address(this).balance > 0, "There currently is no ETH in the smart contract.");

        (bool success,) = msg.sender.call{value : address(this).balance}("");
        require(success, "ETH transfer failed.");
        
    }


}