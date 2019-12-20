// Copyright (C) 2019 Centrifuge
//
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

pragma solidity >=0.4.24;

import "ds-note/note.sol";

contract PileLike {
    function want() public returns (int);
}

contract QuantLike {
    uint public debt;
}

contract OperatorLike {
    function borrow(address, uint) public;
    function repay(address, uint) public;
    function balance() public returns (uint);
    function file(bytes32, bool) public;

    QuantLike public quant;
}

contract Distributor is DSNote {

    // --- Tranches ---

    struct Tranche {
        uint ratio;
        OperatorLike operator;
    }

    Tranche[] tranches;

    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) public auth note { wards[usr] = 1; }
    function deny(address usr) public auth note { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    PileLike public pile;

    constructor (address pile_) public {
        wards[msg.sender] = 1;
        pile = PileLike(pile_);
    }

    function depend (bytes32 what, address addr) public auth {
        if (what == "pile") { pile = PileLike(addr); }
        else revert();
    }

    // TIN tranche should always be added first
    function addTranche(uint ratio, address operator_) public auth {
        Tranche memory t;
        t.ratio = ratio;
        t.operator = OperatorLike(operator_);
        tranches.push(t);
    }

    function ratioOf(uint i) public auth returns (uint) {
        return tranches[i].ratio;
    }

    // if capital should flow through, all funds in reserve should be moved in pile
    function handleFlow(bool flowThrough, bool poolClosing) public auth {
        require(flowThrough);
        if (poolClosing) {
            pileHas();
        } else {
            for (uint i = 0; i < tranches.length; i++) {
                // calculates how much money is in the reserve, transfers all of this balance to the pile
                uint wadR = tranches[i].operator.balance();
                tranches[i].operator.borrow(address(pile), uint(wadR));
            }
        }
    }

    // Takes all the money from the pile, pay sr tranche debt first, then pay jr tranche debt
    function pileHas() private {
        int wad = pile.want();
        for (uint i = tranches.length - 1; i >= 0; i--) {
            QuantLike quant = tranches[i].operator.quant();
            // should be positive number here, means there is some debt in the senior tranche, or 0
            uint wadD = quant.debt();
            if (wadD >= uint(wad*-1)) {
                tranches[i].operator.repay(address(pile), uint(wad*-1));
                return;
            }
            tranches[i].operator.repay(address(pile), uint(wadD));
            wad = int(wad) + int(wadD);
        }
    }
}
