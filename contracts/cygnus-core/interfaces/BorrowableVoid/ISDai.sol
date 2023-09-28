// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.17;

interface ISDai {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function balanceOf(address user) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
