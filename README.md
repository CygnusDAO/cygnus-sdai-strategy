# Cygnus pools that rely on DAI for the oracle and lending pools

Most of the Cygnus pools so far relied on USDC to:
1. Price the liquidity deposited
2. Lend and borrow using liquidity as collateral

These new pools are a strategy that instead of relying on USDC and different strategies (such as depositing unused USDC on Compund, Aave, etc.), it relies solely on DAI and Savings DAI.

The collateral contracts were tested with Gamma's UniswapV3 pools, without taking into account rewarders. Ideally we would need to use collaterals that have good synergy with DAI, such as Curve LPs, Stable balancer pools, etc.
