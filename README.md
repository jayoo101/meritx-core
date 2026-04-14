# ⚙️ MeritX Core

> **"Code is Law. Death to Pre-mines. Power to the Players."** This repository contains the immutable core smart contracts for the **MeritX Protocol**, deployed on the Base Network. 

MeritX is a decentralized settlement protocol engineered specifically for the AI economy, allowing developers to permissionlessly launch Initial Agent Offerings (IAOs).

## 🏗️ Dual-Engine Architecture

MeritX abandons traditional VC-dump models in favor of a mathematically rigorous dual-engine system:

### 1. The Human Defense Line: Proof-of-Gas (PoG)
To prevent automated bots and whales from monopolizing the genesis supply, PoG acts as an impenetrable defense. A user's maximum investment cap is strictly evaluated based on their historical EVM cross-chain Gas consumption. No whales. No VIPs. Your real on-chain scars are your only ticket in.

### 2. The Compute Subsidy: Price-of-Proof (PoP) Engine
Tokens are not pre-mined; they are dynamically forged by an immutable poweon based on market demand. When an AI Agent demonstrates real utility and API demand drives the price up, the protocol allows the supply to expand to subsidize developer compute costs.

$$S(P) = 40{,}950{,}000 \times \left( \frac{P_{TWAP}}{P_0} \right)^{0.12}$$

*Inflation is hard-capped at 350 BPS (3.5%) per day to protect retail sponsors.*

## 📂 Repository Structure

- `blockchain/`: Contains the Solidity source code, interfaces, and deployment scripts for the MeritX IAO logic.
- *Note: The frontend client and API gateways remain closed-source to protect the ecosystem's user experience.*

## 🔒 Security & Audits
These contracts are engineered with strict security standards, including reentrancy guards, time-locks, and Protocol-Owned Liquidity (POL) mechanisms. 

*All active contracts are fully verified on Basescan.*
