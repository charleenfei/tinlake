// Copyright (C) Centrifuge 2020
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

pragma solidity >=0.5.12;

contract Math {
    // compounding takes in an index (accumulated rate), speed (accumulation per second), timestamp (when the rate was last updated),
    // and pie (total debt of all loans with one rate divided by that rate).
    // Returns the new accumulated rate, as well as the difference between the debt calculated with the old and new accumulated rates.
    function compounding(uint48 lastUpdated, uint index, uint pie, uint speed) public view returns (uint chi, uint delta) {
        uint debt = fromPie(index, pie);
        // compounding in seconds
        require(index != 0);
        uint index_ = rmul(rpow(speed, now - lastUpdated, ONE), index);
        delta = fromPie(index_, pie) - debt;
        return (index_, delta);
    }

    // convert pie to debt amount
    function fromPie(uint index, uint pie) public pure returns (uint) {
        return rmul(pie, index);
    }

    // convert debt amount to pie
    function toPie(uint index, uint debt) public pure returns (uint) {
        return rdiv(debt, index);
    }

    // --- Math ---
    uint256 constant ONE = 10 ** 27;

    function rpow(uint x, uint n, uint base) public pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                let xx := mul(x, x)
                if iszero(eq(div(xx, x), x)) { revert(0,0) }
                let xxRound := add(xx, half)
                if lt(xxRound, xx) { revert(0,0) }
                x := div(xxRound, base)
                if mod(n,2) {
                    let zx := mul(z, x)
                    if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                    let zxRound := add(zx, half)
                    if lt(zxRound, zx) { revert(0,0) }
                    z := div(zxRound, base)
                }
            }
            }
        }
    }

    function rmul(uint x, uint y) public pure returns (uint z) {
        z = mul(x, y) / ONE;
    }

    function add(uint x, uint y) public pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) public pure returns (uint z) {
        require((z = x - y) <= x);
    }

    function mul(uint x, uint y) public pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function rdiv(uint x, uint y) public pure returns (uint z) {
        z = add(mul(x, ONE), y / 2) / y;
    }

    function div(uint x, uint y) public pure returns (uint z) {
        z = x / y;
    }
}