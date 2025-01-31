# Yield Exposed Token

Yield Exposed Token is the core of the Stake The Bridge (STB) system. Built from the ground up to be reusable, it offers complete STB functionality out of the box, allowing you to create new yeTokens in just a few lines of code.

## Stake The Bridge

The STB system is comprised of:

- Layer X
  - [Yield Exposed Token](src/YieldExposedToken.sol)
  - [Migration Manager](src/MigrationManager.sol) (singleton)
- Layer Y
  - [Custom Token](src/CustomToken.sol)
  - [Native Converter](src/NativeConverter.sol)

### Yield Exposed Token

A Yield Exposed Token (yeToken) is an

- [ERC-20](https://eips.ethereum.org/EIPS/eip-20) token
- [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) vault
- [LxLy Bridge](https://github.com/0xPolygonHermez/zkevm-contracts) extension

enabling deposits and bridging of assets such as WBTC, WETH, USDC, USDT, and DAI, while producing yield.

For more information, see the NatSpec documentation.

## Usage

**Prerequisite**

```
foundryup
```

**Install**

```
forge soldeer install & bun install
```

**Build**

```
forge build
```

**Test**

```
forge test
```

**Coverage**

```
forge coverage --ir-minimum --report lcov && genhtml -o coverage lcov.info
```

## License
​
Licensed under either of

- Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

---

© 2025 PT Services DMCC