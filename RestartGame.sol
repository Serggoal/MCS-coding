// SPDX-License-Identifier: MIT

import "./IERC20.sol";

pragma solidity ^0.8.0;

contract RestartGame is IERC20 {
    address public owner;
    uint public totalTokens;
    mapping(address => uint) balances;
    mapping(address => mapping(address => uint)) allowances;
    string public name = "GameToken";
    string public symbol = "GAMT";
    uint public stopSupply;
    //uint public contractBalance; 
    uint public remainsTokens;
    uint public fullBalance;
    uint public startAmout = 100000000000000000 wei; // 0,1 ether;
    uint public rateGame = 500000000000000 wei; // 0,0005 Eth
    uint public rateDepo = 100000000000000 wei; // 0,0001 Eth
    bool public restartPoint;

    constructor(uint _stopSupply) {
        owner = msg.sender;
        stopSupply = _stopSupply;
    }

    modifier enoughTokens(address _from, uint _amount) {
        require(balanceOf(_from) >= _amount, "Not enough tokens!");
        _;
    }

    modifier onlyOwner() {
       require(msg.sender == owner, "Only owner");
       _;
    }

    modifier startOrNot() {
       require(restartPoint == true, "Game is over!");
       _;
    }

    event Rewarding(address receiver, uint howManyRewards);

     function getBalance() public view returns (uint) {
       return address(this).balance;
  }


    function setStopSupply(uint _stopSupply) public onlyOwner {
      stopSupply = _stopSupply;
    }

    function setRateGame(uint _rateGame) public onlyOwner {
      rateGame = _rateGame;
    }

    function setRateDepo(uint _rateDepo) public onlyOwner {
      rateDepo = _rateDepo;
    }

    function decimals() public override pure returns(uint) {
        return 18; //без нулей после единицы ефира (1 token = 1 Eth), max=18 - дает 1+ (18 нулей)
    }

    function totalSupply() public override view returns(uint) {
        return totalTokens;
    }

    function balanceOf(address account) public override view returns(uint) {
        return balances[account];
    }

    function transfer(address to, uint amount) external override enoughTokens(msg.sender, amount) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }

    function allowance(address holder, address spender) external override view returns(uint) {
        return allowances[holder][spender];
    }

    function approve(address spender, uint amount) external override {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    function fransferFrom(address sender, address recipient, uint amount) public override enoughTokens(sender, amount) {
        allowances[sender][recipient] -= amount;
        balances[sender] -= amount;
        balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }
    
    function mint(uint amount) private {
        balances[msg.sender] += amount;
        totalTokens += amount;
        
        if(totalTokens >= stopSupply) {
           remainsTokens = totalTokens;
           fullBalance = getBalance();
           restartPoint = !restartPoint;
        }
      
        emit Transfer(address(0), msg.sender, amount);
    }

    // функция ручной выплаты. Если (totalTokens >= stopSupply), 
    // то нужно активировать эту кнопку на фронте для этой функции
    function _rewardTokenHolders() public {
        require(balances[msg.sender] != 0, "You haven't tokens!");
        require(stopSupply <= remainsTokens, "The game is still going on!");
        
        address payable receiver = payable(msg.sender);
        receiver.transfer(_howManyRewards(msg.sender));

        emit Rewarding(receiver, _howManyRewards(msg.sender));
    }

    function _howManyRewards(address _player) private returns(uint) {
        uint currentAmountPlayerTokens = balances[_player];

        balances[_player] = 0;
        totalTokens -= currentAmountPlayerTokens;
      return fullBalance / remainsTokens * currentAmountPlayerTokens;
    }

    // момент первой поставки ликвидности для старта игры
    function startGame() public payable {
        require(totalTokens == 0, "Game is already started!");
        require(msg.value >= startAmout, "Incorrect sum");

        remainsTokens = 0;
        fullBalance = 0;

        uint tokensToDepo = msg.value / rateDepo;
        mint(tokensToDepo);
        restartPoint = !restartPoint;
        // возможно нужно отправлять токены сразу на аккаунт поставщика ликвидности...
        //либо сделать возможность клейма, чтобы иметь возможность перемещать
    }

        // процесс поставки ликвидности в игру. В замен ликвидности получает токены

    function depo() public startOrNot payable {
        require(totalTokens != 0, "Game isn't yet started!");
        require(totalTokens < stopSupply, "Game is over!");
        require(msg.value > 10000000000000000 wei, "Incorrect sum!"); // 0,01 Eth
    
          uint tokensToDepo = msg.value / rateDepo;
          mint(tokensToDepo);
        
        // возможно нужно отправлять токены сразу на аккаунт поставщика ликвидности...
         //либо сделать возможность клейма, чтобы иметь возможность перемещать
    }

    // процесс игры, когда пользователь делает ставку и запускает Бота
    // _result поступает с фронта, либо выиграл(1), либо проиграл(2)

    function playGame(uint _result) external startOrNot payable {
        
        require(totalTokens < stopSupply, "Game is over!");
        require(msg.value > 1000000000000000 wei, "Incorrect sum!"); // 0,001 Eth 
        
        uint rewardPlayer;
        require((msg.value * 2) <= getBalance(), "Not enouth funds in game!");
        address addressPlayer = payable(msg.sender);
        rewardPlayer = msg.value * 2;
        uint tokensToGame;

        if(_result == 1) {
            payable(addressPlayer).transfer(rewardPlayer);
        } else if(_result == 2) {
            tokensToGame = msg.value / rateGame;
            mint(tokensToGame);
            // возможно нужно отправлять токены сразу на аккаунт проигравшего...
            //либо сделать возможность клейма, чтобы иметь возможность перемещать
        }
        emit Rewarding(addressPlayer, rewardPlayer);
    }

    fallback() external payable {
    }

    receive() external payable {
    }

}