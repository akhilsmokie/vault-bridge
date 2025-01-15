# Yield Exposed Token

### Stake the Bridge using Vaults and LxLy

A Yield Exposed Token (yeToken) is an  
ERC4626 wrapper and LxLy bridge extension  
enabling the simultaneous depositing and bridging of widely used tokens like WETH, USDC, USDT, DAI, etc.

## Usage

**Install**

Be sure to update foundry:
```shell
foundryup
```
Then
```shell
forge soldeer install & bun install
```

**Build**

```shell
forge build
```

**Test**

```shell
forge test
```

Coverage with:
```shell
forge coverage --ir-minimum --report lcov
genhtml -o coverage lcov.info
```

## License
​
Licensed under either of

- Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

---

© 2025 Polygon Labs