# Yield Exposed Token

Yield Exposed Token is the core of the STB (Stake The Bridge) system. Built from the ground up to be reusable, it offers complete STB functionality out of the box, allowing you to create new yeTokens in just a few lines of code.

### Stake The Bridge

The Stake The Bridge system is comprised of:

- Yield Exposed Token (Layer X)
- Native Converter (Layer Y*s*)
- Migration Manager (Layer X)

A Yield Exposed Token (yeToken) is an

- ERC-20 token
- ERC-4626 vault
- LxLy Bridge extension

enabling simultaneous depositing and bridging of widely used tokens, such as WETH, USDC, USDT, and DAI.

For more information, see the NatSpec.

## Usage

> **Note**
> 
> Before proceeding, update Foundry:
> 
> ```shell
> foundryup
> ```

**Install**

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

**Coverage**

```shell
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