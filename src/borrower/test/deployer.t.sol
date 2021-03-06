// Copyright (C) 2020 Centrifuge

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

pragma solidity >=0.5.15 <0.6.0;

import "ds-test/test.sol";
import { Title } from "tinlake-title/title.sol";
import { TitleFab } from "../fabs/title.sol";
import { PileFab } from "../fabs/pile.sol";
import { ShelfFab} from "../fabs/shelf.sol";
import { NAVFeedFab } from "../fabs/navfeed.sol";
import { NFTFeedFab } from "../fabs/nftfeed.sol";
import { CollectorFab } from "../fabs/collector.sol";


import "../deployer.sol";
import { SimpleToken } from "../../test/simple/token.sol";

contract DeployerTest is DSTest {
    Title nft;
    SimpleToken dai;
    TitleFab titlefab;
    ShelfFab shelffab;
    PileFab pilefab;
    NAVFeedFab feedFab;
    CollectorFab collectorFab;
    Title title;

    function setUp() public {
        nft = new Title("SimpleNFT", "NFT");
        dai = new SimpleToken("DDAI", "Dummy Dai", "1", 0);
        titlefab = new TitleFab();
        shelffab = new ShelfFab();
        pilefab = new PileFab();
        collectorFab = new CollectorFab();
        feedFab = new NAVFeedFab();
   }

    function testBorrowerDeploy() public logs_gas {
        uint discountRate = uint(1000000342100000000000000000);
        BorrowerDeployer deployer = new BorrowerDeployer(address(0), address(titlefab), address(shelffab), address(pilefab), address(collectorFab), address(feedFab), address(dai), "Test", "TEST", discountRate);

        deployer.deployTitle();
        deployer.deployPile();
        deployer.deployFeed();
        deployer.deployShelf();
        deployer.deployCollector();
        deployer.deploy();
    }
}
