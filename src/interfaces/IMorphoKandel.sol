// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC4626Kandel, IERC20} from "./IERC4626Kandel.sol";
interface IMorphoKandel is IERC4626Kandel {
     function claimRewardsForToken(IERC20 token, uint256 amount, bytes32[] calldata proof, address receiver)
    external;
}