<!--
  Live document — update this file whenever:
    • a new ECS component is added or renamed
    • a new gameplay system is specified or implemented
    • the core game loop changes
    • ship class stats or weapon specs are balanced
    • phase scope changes (P1 → P2 → P3+)
    • a new engine feature is required by gameplay
  Version history is tracked via git. Bump the Version field on every edit.
-->

---
Version: 1.0.0
Last Updated: 2026-04-19
Phase: P1 specification / P1 implementation in progress
Engine Dependency: aetheris-engine 0.3.0 / aetheris-protocol 0.2.4
GDD Reference: docs/VOID_RUSH_GDD.md
---

# Copilot Instructions — void-rush

Void Rush is the **flagship validation game** for the Aetheris Engine. It is a top-down
3D browser-based space MMO (mining, combat, trading) that proves every engine subsystem
works end-to-end under real gameplay load. This repository is **documentation-only** in
Phase 1; implementation lives in `aetheris-engine` and `aetheris-client`.

> **Rule**: Every game feature in this repository must trace back to an engine subsystem
> it exercises. No feature is added unless it validates something in the engine.

---

## Repository Layout

```
docs/
  VOID_RUSH_GDD.md        # Master Game Design Document — single source of truth
  ECS_DESIGN.md           # 25+ ECS components, system architecture
  PLATFORM_DESIGN.md      # Browser targets, WebTransport, WASM constraints
  THEME_WORLD_DESIGN.md   # Art direction, UI design tokens, world aesthetic
README.md                 # Project overview and engine validation rationale
```

---

## Core Gameplay Loop

```
Mine asteroids → Collect ore into cargo hold → Travel to Station
       ↑                                              ↓
  Respawn                                      Sell ore for credits
  at Station                                         ↓
       ↑                                      Buy ship upgrades
  Die in PvP ← Attack other haulers ← Equip stronger weapons
```

**The risk-reward mechanic**: Ore increases ship mass
($a_{eff} = F / (m_{hull} + m_{ore} \times n_{ore})$),
making loaded ships slower and easier to attack. This is the core tension.

---

## Engine Systems Map

Every gameplay feature is an explicit test of an engine capability:

| Gameplay System | Engine Feature Validated | Phase |
|---|---|---|
| Ship movement + inertia | 60 Hz tick budget, Newtonian physics | P1 |
| Cargo mass penalty | Variable-mass CSP reconciliation | P1 |
| 3 ship classes | `WorldState::spawn_kind`, component schema | P1 |
| PvP weapons (4 types) | Ballistic event replication (not entity) | P1 |
| Client-side prediction | `InputCommand` pipeline + rollback | P1 |
| Safe Zone enforcement | Server-authoritative spatial rules | P1 |
| Spatial AoI | Spatial hash grid, 4-filter pipeline | P1 |
| Priority channels P0–P5 | `ChannelRegistry`, congestion shedding | P1 |
| Ore → Credits economy | `EconomyService` gRPC, idempotency keys | P1 |
| 1,000 concurrent players | tick p99 ≤ 16.6 ms gate criterion | P1 |
| Merkle chain anti-cheat | `MerkleChainState`, `SuspicionScore` | P1 |
| Sector instancing + jump gates | `RoomAndInstance`, entity budget (6,700) | P1 |
| Player crafting + auction house | Inventory gRPC, event-sourced economy | P2 |
| Multi-crew capital ships | Federation, cross-sector entity ownership | P3+ |

---

## Ship Classes

Three asymmetric classes create natural counters:

| Class | Entity Type | HP | Accel | Cargo | Role |
|---|---|---|---|---|---|
| **Interceptor** | `1` | Low | High | None | Scout / Assassin |
| **Dreadnought** | `2` | High | Low | None | Tank / Blocker |
| **Hauler** | `3` | Medium | Medium | Large | Trader (high-value target) |

**Counter triangle**: Interceptor beats Hauler (speed), Dreadnought beats Interceptor (HP), Hauler beats Dreadnought (cargo value — no reason to fight).

In ECS terms, each ship is a Bevy entity with:
- `Networked(NetworkId)` — marks it as network-replicated
- `Ownership(ClientId)` — prevents spoofed input from other clients
- `Transform` (`ComponentKind(1)`) — position/rotation, sent every tick
- `ShipStats`, `Velocity`, `CargoHold`, `Wallet`, `Health` — gameplay components

---

## ECS Component Schema (Phase 1)

```rust
// Core spatial (replicated via ComponentKind(1))
Transform { x, y, z, rotation, entity_type }
Velocity  { dx, dy, dz }

// Physics
ShipStats  { hull_hp: u16, shield_hp: u16, energy: f32, max_accel: f32, mass: f32 }
Loadout    { chassis: u8, weapon: u8, engine: u8, shield: u8 }

// Economy
CargoHold  { slots: [OreStack; 8], total_mass: f32 }
Wallet     { credits: i64 }   // integer cents, NEVER f32

// Combat
Health       { current: u16, max: u16 }
DamageState  { shield_remaining: u16, hull_remaining: u16, invuln_ticks: u8 }

// Network identity (required on every networked entity)
Networked(NetworkId)
Ownership(ClientId)

// AI
AiState { patrol_target: Option<NetworkId>, aggro_target: Option<NetworkId> }
```

> **`ComponentKind` registry**: `1` is reserved for `Transform`. All new component
> kinds start from `2`. Each kind requires a registered `BoxedReplicator` in
> `BevyWorldAdapter`.

---

## Weapon Systems

```
Pulse Laser  — hitscan, instant hit, energy cost per shot
Beam Laser   — channeled, continuous energy drain, DPS while held
Mining Laser — hitscan, extracts ore from asteroids (PvE only, 0 PvP damage)
Seeker Missile — homing projectile, tracks target NetworkId, 3s TTL
```

**Ballistic replication rule**: Projectiles are **NOT** replicated as ECS entities.
The server broadcasts a `BallisticEvent` (fired, hit, miss). Clients render locally
using the known positions + velocity vectors. This avoids ~200 extra entity slots per
sector in heavy combat.

```
Server: fires event → NetworkEvent::ReliableMessage { BallisticEvent::LaserFired { ... } }
Client: receives event → renders beam/missile locally → no entity in SAB
```

---

## Sector Architecture

| Zone | Description | Damage | Respawn |
|---|---|---|---|
| **Safe Zone** | Station radius (~500 m) | Nullified | Yes |
| **Contested** | Inner ring | Normal | Nearest station |
| **Lawless** | Outer ring | Normal + NPC drones | Nearest station |

- Hard cap: **6,700 entities per sector** (SAB limit: 8,192 × 80% safety margin)
- Jump gates transition players between sectors (no seamless travel in P1)
- Each sector is a separate server process; no entity state crosses sector boundary in P1

---

## Priority Channels

Under network congestion, the scheduler sheds lower-priority channels first:

| Channel | Priority | Content | Rule |
|---|---|---|---|
| P0 | Critical | Player's own entity state | Never shed |
| P1 | High | Combat events (damage, death, kills) | Never shed |
| P2 | Medium | AoI neighbors (nearby ships) | Shed at heavy congestion |
| P3 | Low | Distant entities (outer AoI ring) | Shed first |
| P4 | Background | Asteroids, loot, environment | Shed freely |
| P5 | Cosmetic | Emotes, effects | Shed freely |

---

## Performance Contracts (Phase 1 Gate Criteria)

| Metric | Target |
|---|---|
| Server tick p99 | ≤ 16.6 ms |
| Concurrent players / sector | ≥ 100 (gate), 1,000 (stretch) |
| Client FPS (Chrome/Firefox) | ≥ 30 fps |
| Entity budget / sector | ≤ 6,700 |
| Auth round-trip | ≤ 500 ms |
| Economy transaction | ≤ 200 ms p99 |

---

## Key Design Principles

- **Server is authoritative.** Clients predict locally; server always wins on conflicts.
- **Integer money.** `Wallet.credits` is always `i64` (integer cents). Never `f32`.
- **Ballistic events, not entities.** Projectiles are events, not ECS entities.
- **Safe Zones are server-enforced.** Client cannot bypass damage nullification.
- **Ownership gates every update.** An entity without `Ownership(ClientId)` rejects all client mutations.
- **No speculative features.** Every game system must map to a row in the engine systems table above.
