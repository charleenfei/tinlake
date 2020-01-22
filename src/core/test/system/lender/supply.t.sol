// Copyright (C) 2019 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

import "../system.t.sol";

contract SupplyTest is SystemTest {

    Investor juniorInvestor;
    address  juniorInvestor_;

    function setUp() public {
        baseSetup();
        WhitelistOperator juniorOperator = lenderDeployer.juniorOperator();
        juniorInvestor = new Investor(address(juniorOperator), currency_, address(lenderDeployer.juniorERC20()));
        juniorInvestor_ = address(juniorInvestor);

        juniorOperator.relyInvestor(juniorInvestor_);
    }
    
    function supply(uint balance, uint amount) public {
        currency.mint(juniorInvestor_, balance);
        juniorInvestor.doSupply(amount);
    }
    
    function testSupply() public {
        uint investorBalance = 100 ether;
        uint supplyAmount = 10 ether;
        supply(investorBalance, supplyAmount);
        assertEq(currency.balanceOf(juniorInvestor_), investorBalance - supplyAmount);
        assertEq(lenderDeployer.juniorERC20().balanceOf(juniorInvestor_), supplyAmount);
        assertEq(currency.balanceOf(address(borrowerDeployer.shelf())), supplyAmount);
    }
}

