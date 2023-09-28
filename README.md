# Cygnus Pools using DAI + Spark Protocol

<img align="center"  src="https://miro.medium.com/v2/resize:fit:1024/1*E3m8mzvB_eAgF6NFQXz-kw.png">

<b>Most of the Cygnus pools so far relied on USDC to:</b>
1. Price the liquidity deposited
2. Lend and borrow USDC using liquidity as collateral

<br />
These new pools are a strategy that instead of relying on USDC and different strategies (such as depositing unused USDC on Compund, Aave, etc.), it relies solely on DAI and Savings DAI.

Lenders deposit DAI and borrowers can deposit liquidity from DEXes such as Balancer, Gamma, Uniswap, etc. and borrow DAI using their liquidity as collateral

## TODO

1. These contracts were tested on Ethereum mainnet as sDAI is only live on Ethereum at the moment. Soon Spark will be live on Polygon's zkEVM, contracts will need to be tested to make sure the interface is implemented correctly.
2. The collateral contracts were tested with Gamma's UniswapV3 pools for simplicity. Ideally we should test with dexes that have good synergy with DAI and allow better yield farming.
