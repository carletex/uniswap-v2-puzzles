// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";

contract ExactSwapWithRouter {
    /**
     *  PERFORM AN EXACT SWAP WITH ROUTER EXERCISE
     *
     *  The contract has an initial balance of 1 WETH.
     *  The challenge is to swap an exact amount of WETH for 1337 USDC token using UniswapV2 router.
     *
     */
    address public immutable router;

    constructor(address _router) {
        router = _router;
    }

    function performExactSwapWithRouter(address weth, address usdc, uint256 deadline) public {
        IERC20(weth).approve(router, 1 ether);

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = usdc;

        IUniswapV2Router(router).swapTokensForExactTokens(1337e6, 1 ether, path, address(this), deadline);
    }
}

interface IUniswapV2Router {
    /**
     *     amountOut: the exact amount of output tokens to receive.
     *     amountInMax: the maximum amount of input tokens to spend; revert if the swap would cost more.
     *     path: an array of token addresses. In our case, WETH and USDC.
     *     to: recipient address to receive the output tokens.
     *     deadline: timestamp after which the transaction will revert.
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
