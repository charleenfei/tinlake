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
pragma experimental ABIEncoderV2;

import "./../fixed_point.sol";
import "tinlake-auth/auth.sol";
import "tinlake-math/math.sol";

interface EpochTrancheLike {
    function epochUpdate(uint epochID, uint supplyFulfillment_,
        uint redeemFulfillment_, uint tokenPrice_, uint epochSupplyCurrency, uint epochRedeemCurrency) external;
    function closeEpoch() external returns(uint totalSupply, uint totalRedeem);
}

interface ReserveLike {
    function file(bytes32 what, uint currencyAmount) external;
    function totalBalance() external returns (uint);
}

contract AssessorLike is FixedPoint {
    function calcSeniorTokenPrice(uint NAV, uint reserve) external returns(Fixed27 memory tokenPrice);
    function calcJuniorTokenPrice(uint NAV, uint reserve) external returns(Fixed27 memory tokenPrice);
    function maxReserve() external view returns(uint);
    function calcUpdateNAV() external returns (uint);
    function seniorDebt() external returns(uint);
    function seniorBalance() external returns(uint);
    function seniorRatioBounds() external view returns(Fixed27 memory minSeniorRatio, Fixed27 memory maxSeniorRatio);
    function changeSeniorAsset(uint seniorRatio, uint seniorSupply, uint seniorRedeem) external;
}


contract EpochCoordinator is Auth, Math, FixedPoint  {
    struct OrderSummary {
        // all variables are stored in currency
        uint  seniorRedeem;
        uint  juniorRedeem;
        uint  juniorSupply;
        uint  seniorSupply;
    }

    modifier minimumEpochTimePassed {
        require(safeSub(block.timestamp, lastEpochClosed) >= minimumEpochTime);
        _;
    }
                        // timestamp last epoch closed
    uint                public lastEpochClosed;
    uint                public minimumEpochTime = 1 days;

    EpochTrancheLike    public juniorTranche;
    EpochTrancheLike    public seniorTranche;

    ReserveLike         public reserve;
    AssessorLike        public assessor;

    uint                public lastEpochExecuted;
    uint                public currentEpoch;

    OrderSummary        public bestSubmission;
    uint                public bestSubScore;
    bool                public gotValidPoolConSubmission;
    OrderSummary        public order;

    Fixed27             public epochSeniorTokenPrice;
    Fixed27             public epochJuniorTokenPrice;

    uint                public epochNAV;
    uint                public epochSeniorAsset;
    uint                public epochReserve;

    bool                public submissionPeriod;

                        // weights of the scoring function
    uint                public weightSeniorRedeem  = 1000000;
    uint                public weightJuniorRedeem  =  100000;
    uint                public weightsJuniorSupply =   10000;
    uint                public weightsSeniorSupply =    1000;

                        // challenge period end timestamp
    uint                public minChallengePeriodEnd;
    uint                public challengeTime;

    uint                public bestRatioImprovement;
    uint                public bestReserveImprovement;

                        // constants
    int                 public constant SUCCESS = 0;
    int                 public constant NEW_BEST = 0;
    int                 public constant ERR_CURRENCY_AVAILABLE = -1;
    int                 public constant ERR_MAX_ORDER = -2;
    int                 public constant ERR_MAX_RESERVE = - 3;
    int                 public constant ERR_MIN_SENIOR_RATIO = -4;
    int                 public constant ERR_MAX_SENIOR_RATIO = -5;
    int                 public constant ERR_NOT_NEW_BEST = -6;
    uint                public constant BIG_NUMBER = ONE * ONE;
    uint                public constant IMPR_RATIO_WEIGHT =  10000;
    uint                public constant IMPR_RESERVE_WEIGHT = 1000;

    constructor(uint challengeTime_) public {
        wards[msg.sender] = 1;
        challengeTime = challengeTime_;

        lastEpochClosed = block.timestamp;
        currentEpoch = 1;
    }

    function file(bytes32 name, uint value) public auth {
        if(name == "challengeTime") {
            challengeTime = value;
        } else if (name == "minimumEpochTime") {
            minimumEpochTime = value;
        } else if (name == "weightSeniorRedeem") { weightSeniorRedeem = value;}
          else if (name == "weightJuniorRedeem") { weightJuniorRedeem = value;}
          else if (name == "weightsJuniorSupply") { weightsJuniorSupply = value;}
          else if (name == "weightsSeniorSupply") { weightsSeniorSupply = value;}
          else { revert("unkown-name");}
     }

    /// sets the dependency to another contract
    function depend (bytes32 contractName, address addr) public auth {
        if (contractName == "juniorTranche") { juniorTranche = EpochTrancheLike(addr); }
        else if (contractName == "seniorTranche") { seniorTranche = EpochTrancheLike(addr); }
        else if (contractName == "reserve") { reserve = ReserveLike(addr); }
        else if (contractName == "assessor") { assessor = AssessorLike(addr); }
        else revert();
    }

    function closeEpoch() external minimumEpochTimePassed {
        require(submissionPeriod == false);
        lastEpochClosed = block.timestamp;
        currentEpoch = safeAdd(currentEpoch, 1);

        reserve.file("maxcurrency", 0);

        (uint orderJuniorSupply, uint orderJuniorRedeem) = juniorTranche.closeEpoch();
        (uint orderSeniorSupply, uint orderSeniorRedeem) = seniorTranche.closeEpoch();

        //  if no orders exist epoch can be executed without validation
        if (orderSeniorRedeem == 0 && orderJuniorRedeem == 0 &&
        orderSeniorSupply == 0 && orderJuniorSupply == 0) {

            juniorTranche.epochUpdate(currentEpoch, 0, 0, 0, orderJuniorSupply, orderJuniorRedeem);
            seniorTranche.epochUpdate(currentEpoch, 0, 0, 0, orderSeniorSupply, orderSeniorRedeem);
            lastEpochExecuted = safeAdd(lastEpochExecuted, 1);
            return;
        }

        // take a snapshot of the current system state
        epochNAV = assessor.calcUpdateNAV();
        epochReserve = reserve.totalBalance();

        // calculate in DAI
        epochSeniorTokenPrice = assessor.calcSeniorTokenPrice(epochNAV, epochReserve);
        epochJuniorTokenPrice = assessor.calcJuniorTokenPrice(epochNAV, epochReserve);

        epochSeniorAsset = safeAdd(assessor.seniorDebt(), assessor.seniorBalance());

        /// calculate currency amounts
        order.seniorRedeem = rmul(orderSeniorRedeem, epochSeniorTokenPrice.value);
        order.juniorRedeem = rmul(orderJuniorRedeem, epochJuniorTokenPrice.value);
        order.juniorSupply = orderJuniorSupply;
        order.seniorSupply = orderSeniorSupply;

        /// can orders be to 100% fulfilled
        if (validate(orderSeniorRedeem, orderJuniorRedeem,
            orderSeniorSupply, orderJuniorSupply) == SUCCESS) {

            _executeEpoch(orderSeniorRedeem, orderJuniorRedeem,
                orderSeniorSupply, orderJuniorSupply);
            return;
        }

        submissionPeriod = true;
    }

    /// number denominated in WAD
    /// all variables expressed as currency
    function saveNewOptimum(uint seniorRedeem, uint juniorRedeem, uint juniorSupply,
        uint seniorSupply, uint score) internal {

        bestSubmission.seniorRedeem = seniorRedeem;
        bestSubmission.juniorRedeem = juniorRedeem;
        bestSubmission.juniorSupply = juniorSupply;
        bestSubmission.seniorSupply = seniorSupply;

        bestSubScore = score;
    }

    function submitSolution(uint seniorRedeem, uint juniorRedeem,
        uint juniorSupply, uint seniorSupply) public returns(int) {
        require(submissionPeriod == true, "submission-period-not-active");

        int valid = _submitSolution(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply);

        if(valid == SUCCESS && minChallengePeriodEnd == 0) {
            minChallengePeriodEnd = safeAdd(block.timestamp, challengeTime);
        }
        return valid;
    }

    function _submitSolution(uint seniorRedeem, uint juniorRedeem,
        uint juniorSupply, uint seniorSupply) internal returns(int) {

        int valid = validate(seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);

        if(valid  == ERR_CURRENCY_AVAILABLE || valid == ERR_MAX_ORDER) {
            // core constraint violated
            return valid;
        }

        // core constraints and pool constraints are satisfied
        if(valid == SUCCESS) {
            uint score = scoreSolution(seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);

            if(gotValidPoolConSubmission == false) {
                gotValidPoolConSubmission = true;
                saveNewOptimum(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply, score);
                // solution is new best => 0
                return SUCCESS;
            }

            if (score < bestSubScore) {
                // solution is not the best => -6
                return ERR_NOT_NEW_BEST;
            }

            saveNewOptimum(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply, score);

            // solution is new best => 0
            return SUCCESS;
        }

        // proposed solution does not satisfy all pool constraints
        // if we never received a solution which satisfies all constraints for this epoch
        // we might accept it as an improvement
        if (gotValidPoolConSubmission == false) {
            return _improveScore(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply);
        }

        // proposed solution doesn't satisfy the pool constraints but a previous submission did
        return ERR_NOT_NEW_BEST;
    }

    function absDistance(uint x, uint y) public view returns(uint delta) {
        if (x == y) {
            // gas optimization: for avoiding an additional edge case of 0 distance
            // distance is set to the smallest value possible
            return 1;
        }
        if(x > y) {
            return safeSub(x, y);
        }
        return safeSub(y, x);
    }

    function checkRatioInRange(Fixed27 memory ratio, Fixed27 memory minRatio,
        Fixed27 memory maxRatio) public view returns (bool) {
        if (ratio.value >= minRatio.value && ratio.value <= maxRatio.value ) {
            return true;
        }
        return false;
    }

    function _improveScore(uint seniorRedeem, uint juniorRedeem,
        uint juniorSupply, uint seniorSupply) internal returns(int) {
        Fixed27 memory currSeniorRatio = Fixed27(calcSeniorRatio(epochSeniorAsset,
            epochNAV, epochReserve));

        int err = 0;
        uint impScoreRatio = 0;
        uint impScoreReserve = 0;

        if (bestRatioImprovement == 0) {
            // define no orders score as benchmark if no previous submission exists
            (err, impScoreRatio, impScoreReserve) = scoreImprovement(currSeniorRatio, epochReserve);
            saveNewImprovement(impScoreRatio, impScoreReserve);
        }

        uint newReserve = calcNewReserve(seniorRedeem, juniorRedeem, seniorSupply, juniorSupply);

        Fixed27 memory newSeniorRatio = Fixed27(calcSeniorRatio(calcSeniorAssetValue(seniorRedeem, seniorSupply,
            epochSeniorAsset, newReserve, epochNAV), epochNAV, newReserve));

        (err, impScoreRatio, impScoreReserve) = scoreImprovement(newSeniorRatio, newReserve);

        if (err  == ERR_NOT_NEW_BEST) {
            // solution is not the best => -1
            return err;
        }

        saveNewImprovement(impScoreRatio, impScoreReserve);

        // solution doesn't satisfy all pool constraints but improves the current violation
        // improvement only gets 0 points for alternative solutions in the feasible region
        saveNewOptimum(seniorRedeem, juniorRedeem, juniorSupply, seniorSupply, 0);
        return NEW_BEST;
    }

    function scoreReserveImprovement(uint newReserve_) public view returns (uint score) {
        if (newReserve_ <= assessor.maxReserve()) {
            // highest possible score
            return BIG_NUMBER;
        }
        // normalize reserve by defining maxReserve as ONE
        Fixed27 memory normalizedNewReserve = Fixed27(rdiv(newReserve_, assessor.maxReserve()));

        return rmul(IMPR_RESERVE_WEIGHT, rdiv(ONE,  absDistance(safeDiv(ONE, 2), normalizedNewReserve.value)));
    }

    function scoreRatioImprovement(Fixed27 memory newSeniorRatio) public view returns (uint) {
        (Fixed27 memory minSeniorRatio, Fixed27 memory maxSeniorRatio) = assessor.seniorRatioBounds();
        if (checkRatioInRange(newSeniorRatio, minSeniorRatio, maxSeniorRatio) == true) {

            // highest possible score
            return BIG_NUMBER;
        }
        // absDistance of ratio can never be zero
        return rmul(IMPR_RATIO_WEIGHT, rdiv(ONE, absDistance(newSeniorRatio.value,
                safeDiv(safeAdd(minSeniorRatio.value, maxSeniorRatio.value), 2))));
    }

    function saveNewImprovement(uint impScoreRatio, uint impScoreReserve) internal {
        bestRatioImprovement = impScoreRatio;
        bestReserveImprovement = impScoreReserve;
    }

    function scoreImprovement(Fixed27 memory newSeniorRatio_, uint newReserve_) public view returns(int, uint, uint) {
        uint impScoreRatio = scoreRatioImprovement(newSeniorRatio_);
        uint impScoreReserve = scoreReserveImprovement(newReserve_);

        // the highest priority has fixing the currentSeniorRatio
        // if the ratio is improved, we can ignore reserve
        if (impScoreRatio > bestRatioImprovement) {
            // we found a new best
            return (NEW_BEST, impScoreRatio, impScoreReserve);
        }

        // only if the submitted solution ratio score equals the current best ratio
        // we determine if the submitted solution improves the reserve
        if (impScoreRatio == bestRatioImprovement) {
              if (impScoreReserve > bestReserveImprovement) {
                  return (NEW_BEST, impScoreRatio, impScoreReserve);
              }
        }
        return (ERR_NOT_NEW_BEST, impScoreRatio, impScoreReserve);
    }


    // weights of the scoring function
    function scoreSolution(uint seniorRedeem, uint juniorRedeem,
        uint juniorSupply, uint seniorSupply) public view returns(uint) {
        // weights of the scoring function
        return safeAdd(safeAdd(safeMul(seniorRedeem, weightSeniorRedeem), safeMul(juniorRedeem, weightJuniorRedeem)),
            safeAdd(safeMul(juniorSupply, weightsJuniorSupply), safeMul(seniorSupply, weightsSeniorSupply)));
    }

    /*
        returns newReserve for gas efficiency reasons to only calc it once
    */
    function validateCoreConstraints(uint currencyAvailable, uint currencyOut, uint seniorRedeem, uint juniorRedeem,
        uint seniorSupply, uint juniorSupply) public view returns (int err) {
        // constraint 1: currency available
        if (currencyOut > currencyAvailable) {
            // currencyAvailableConstraint => -1
            return ERR_CURRENCY_AVAILABLE;
        }

        // constraint 2: max order
        if (seniorSupply > order.seniorSupply ||
        juniorSupply > order.juniorSupply ||
        seniorRedeem > order.seniorRedeem ||
            juniorRedeem > order.juniorRedeem) {
            // maxOrderConstraint => -2
            return ERR_MAX_ORDER;
        }

        // successful => 0
        return SUCCESS;
    }

    function validatePoolConstraints(uint reserve, uint seniorAsset) public view returns (int err) {
        // constraint 3: max reserve
        if (reserve > assessor.maxReserve()) {
            // maxReserveConstraint => -3
            return ERR_MAX_RESERVE;
        }

        uint assets = safeAdd(epochNAV, reserve);

        (Fixed27 memory minSeniorRatio, Fixed27 memory maxSeniorRatio) = assessor.seniorRatioBounds();

        // constraint 4: min senior ratio constraint
        if (seniorAsset < rmul(assets, minSeniorRatio.value)) {
            // minSeniorRatioConstraint => -4
            return ERR_MIN_SENIOR_RATIO;
        }
        // constraint 5: max senior ratio constraint
        if (seniorAsset > rmul(assets, maxSeniorRatio.value)) {
            // maxSeniorRatioConstraint => -5
            return ERR_MAX_SENIOR_RATIO;
        }
        // successful => 0
        return SUCCESS;
    }

    // all parameters in WAD and denominated in currency
    function validate(uint seniorRedeem, uint juniorRedeem,
        uint seniorSupply, uint juniorSupply) public view returns (int) {

        uint currencyAvailable = safeAdd(safeAdd(epochReserve, seniorSupply), juniorSupply);
        uint currencyOut = safeAdd(seniorRedeem, juniorRedeem);

        int err = validateCoreConstraints(currencyAvailable, currencyOut, seniorRedeem,
            juniorRedeem, seniorSupply, juniorSupply);

        if(err != SUCCESS) {
            return err;
        }

        uint newReserve = safeSub(currencyAvailable, currencyOut);

        return validatePoolConstraints(newReserve, calcSeniorAssetValue(seniorRedeem, seniorSupply,
            epochSeniorAsset, newReserve, epochNAV));
    }

    function executeEpoch() public {
        require(block.timestamp >= minChallengePeriodEnd && minChallengePeriodEnd != 0);

        _executeEpoch(bestSubmission.seniorRedeem ,bestSubmission.juniorRedeem,
            bestSubmission.seniorSupply, bestSubmission.juniorSupply);
    }

    function calcSeniorAssetValue(uint seniorRedeem, uint seniorSupply,
        uint currSeniorAsset, uint reserve, uint NAV) public view returns (uint seniorAsset) {

        uint seniorAsset =  safeSub(safeAdd(currSeniorAsset, seniorSupply), seniorRedeem);
        uint assets = calcAssets(NAV, reserve);
        if(seniorAsset > assets) {
            seniorAsset = assets;
        }

        return seniorAsset;
    }

    function calcAssets(uint NAV, uint reserve_) public pure returns(uint) {
        return safeAdd(NAV, reserve_);
    }


    function calcSeniorRatio(uint seniorAsset, uint NAV, uint reserve_) public view returns(uint) {
        uint assets = calcAssets(NAV, reserve_);
        if(assets == 0) {
            return 0;
        }
        return rdiv(seniorAsset, assets);
    }

    function calcFulfillment(uint amount, uint totalOrder) public view returns(Fixed27 memory percent) {
        if(amount == 0 || totalOrder == 0) {
            return Fixed27(0);
        }
        return Fixed27(rdiv(amount, totalOrder));
    }

    function calcNewReserve(uint seniorRedeem, uint juniorRedeem,
        uint seniorSupply, uint juniorSupply) public view returns(uint) {

        return safeSub(safeAdd(safeAdd(epochReserve, seniorSupply), juniorSupply),
            safeAdd(seniorRedeem, juniorRedeem));
    }

    function _executeEpoch(uint seniorRedeem, uint juniorRedeem,
        uint seniorSupply, uint juniorSupply) internal {

        uint epochID = safeAdd(lastEpochExecuted, 1);

        seniorTranche.epochUpdate(epochID, calcFulfillment(seniorSupply, order.seniorSupply).value,
            calcFulfillment(seniorRedeem, order.seniorRedeem).value,
            epochSeniorTokenPrice.value,order.seniorSupply, order.seniorRedeem);

        juniorTranche.epochUpdate(epochID, calcFulfillment(juniorSupply, order.juniorSupply).value,
            calcFulfillment(juniorRedeem, order.juniorRedeem).value,
            epochSeniorTokenPrice.value, order.juniorSupply, order.juniorRedeem);

        uint newReserve = calcNewReserve(seniorRedeem, juniorRedeem
        , seniorSupply, juniorSupply);

        uint seniorAsset = calcSeniorAssetValue(seniorRedeem, seniorSupply,
           epochSeniorAsset, newReserve, epochNAV);


        uint newSeniorRatio = calcSeniorRatio(seniorAsset, epochNAV, newReserve);


        assessor.changeSeniorAsset(newSeniorRatio, seniorSupply, seniorRedeem);
        reserve.file("maxcurrency", newReserve);
        // reset state for next epochs
        lastEpochExecuted = epochID;
        submissionPeriod = false;
        minChallengePeriodEnd = 0;
        bestSubScore = 0;
        gotValidPoolConSubmission = false;
        bestRatioImprovement = 0;
        bestReserveImprovement = 0;
    }
}