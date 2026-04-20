# Void Rush

© Contributors — Licensed under CC BY 4.0

A top-down 3D space MMO built on the Aetheris engine — Newtonian physics, contested sectors, and high-fidelity planetary simulation.

## The Proving Ground

**Void Rush** is the flagship demonstration of the Aetheris engine's capabilities. It pushes the boundaries of browser-native multiplayer by simulating a persistent universe where thousands of players interact in real-time. Every ship's thruster follows Newtonian laws, every asteroid is a destructible entity, and every trade route is contested in a living, player-driven economy.

> **[Read the Game Design Document](docs/VOID_RUSH_GDD.md)** — ship classes, weapons, economy loops, and world architecture.
>
> 🚀 **Latest Milestone:** **M10146** — Multirepo Consolidation & Hardening (Completed)

[![Build Status](https://github.com/garnizeh-labs/void-rush/actions/workflows/ci.yml/badge.svg)](https://github.com/garnizeh-labs/void-rush/actions)
[![Rust Version](https://img.shields.io/badge/rust-1.94%2B-blue.svg?logo=rust)](https://www.rust-lang.org/)
[![License: CC BY 4.0](https://img.shields.io/badge/License-CC%20BY%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by/4.0/)

## Quickstart

```bash
# 1. Run world quality gate (fmt, clippy, tests)
just check

# 2. Build local documentation
just docs
```

### 🛠️ Common Tasks

| Command | Category | Description |
| :--- | :--- | :--- |
| `just check` | **Quality** | Complete PR validation: Linters, tests, and documentation audit. |
| `just docs` | **Doc** | Generate technical design and world specifications. |

For a full list of commands, run `just --list`.

## Documentation Entry Points

- **[VOID_RUSH_GDD.md](docs/VOID_RUSH_GDD.md):** Master game design document.
- **[THEME_WORLD_DESIGN.md](docs/THEME_WORLD_DESIGN.md):** Visual identity and environmental rules.
- **[ECS_DESIGN.md](docs/ECS_DESIGN.md):** Entity-Component-System layout for world entities.

## Design Philosophy

1. **Systems-First:** Gameplay arises from the interaction of simulated systems (Physics, Economy, AI).
2. **Open Contribution:** A reference world designed to be extended by the community.
3. **Engine-Stress:** Every feature is a stress test for the underlying Aetheris Engine.

---
License: CC BY 4.0
