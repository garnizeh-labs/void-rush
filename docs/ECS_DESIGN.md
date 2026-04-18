---Version: 0.1.1-draft
Status: Phase 1 — MVP / Phase 3 — Planned
Phase: P1 | P3
Last Updated: 2026-04-15
Authors: Team (Antigravity)
Spec References: [LC-0100, LC-0200, LC-0300, LC-0400]
Tier: 4
License: CC-BY-4.0
---

# Aetheris Engine — ECS Architecture & Design Document

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [ECS in the Five-Stage Pipeline](#2-ecs-in-the-five-stage-pipeline)
3. [Phase 1 — `BevyWorldAdapter`](#3-phase-1--bevyworldadapter)
4. [Phase 3 — `aetheris-ecs-custom`](#4-phase-3--aetheris-ecs-custom)
5. [ECS ↔ Persistence Bridge](#5-ecs--persistence-bridge)
6. [Adaptive Zero-Trust Hashing](#6-adaptive-zero-trust-hashing)
   - [6.4 Audit Worker — Actor Pattern](#64-audit-worker--actor-pattern)
7. [Entity Identity System](#7-entity-identity-system)
8. [Server Affinity & Single-Writer Principle](#8-server-affinity--single-writer-principle)
9. [Telemetry & Performance Targets](#9-telemetry--performance-targets)
10. [Open Questions](#10-open-questions)
11. [Appendix A — Glossary](#appendix-a--glossary)
12. [Appendix B — Decision Log](#appendix-b--decision-log)

---

## Executive Summary

The Entity Component System (ECS) is the **authoritative simulation core** of the Aetheris engine.
Every player position, health value, cooldown timer, and AI state lives exclusively inside the ECS.
Nothing in the engine mutates game state outside of it.

Aetheris operates two ECS implementations across its lifecycle, both satisfying the same
`WorldState` trait from `aetheris-protocol`:

| Phase | Crate | Backend | Rationale |
|---|---|---|---|
| **P1 — MVP** | `aetheris-ecs-bevy` | `bevy_ecs` | Battle-tested, fast to iterate, rich change detection |
| **P3 — Artisanal** | `aetheris-ecs-custom` | Hand-written SoA | Hyper-optimized for `extract_deltas` at 25K entity scale |

The `WorldState` trait is the firewall between them. Swapping P1 for P3 requires zero changes to
the server game loop, the network layer, or the encoder — only the concrete implementation changes.

This document covers:

- **How** the ECS fits into the five-stage tick pipeline.
- **What** the P1 adapter does today (implemented).
- **How** the P3 custom ECS will be designed (specified here).
- **How** the ECS connects to the persistence layer without blocking the simulation.
- **How** cryptographic integrity is enforced adaptively without exhausting the CPU.

---

## 2. ECS in the Five-Stage Pipeline

The ECS participates in three of the five tick stages. Its budget is fixed and enforced by telemetry
(see [LC-0100](../roadmap/archive/phase-0-foundation/specs/LC-0100_tick_pipeline.md) for the full timing contract).

```
┌──────────────────────────────────────────────────────────────────┐
│  16.6ms Tick Budget (60 Hz)                                      │
│                                                                  │
│  [1. Poll]   [2. Apply]   [3. Simulate]   [4. Extract]  [5. Send]│
│   1.0ms       2.0ms         8.0ms           2.5ms        2.0ms  │
│               ▲              ▲               ▲                   │
│               │              │               │                   │
│         WorldState::    ECS Systems     WorldState::             │
│         apply_updates()  (physics,      extract_deltas()         │
│                          AI, rules)                              │
└──────────────────────────────────────────────────────────────────┘
```

**Stage 2 — Apply:** `WorldState::apply_updates()` injects inbound client input commands and
any server-authoritative corrections into the ECS. The ECS does not validate the semantics of
these updates; it applies them to the correct entity identified by `NetworkId`.

**Stage 3 — Simulate:** The ECS runs all registered systems (physics, AI, game rules). This stage
owns the largest budget (8.0ms) because it is where the actual game computation happens. The
simulation is entirely CPU-bound; it never touches the network or the database.

**Stage 4 — Extract:** `WorldState::extract_deltas()` scans all replicated components for
changes since the last tick. Only dirty components are emitted as `ReplicationEvent`s. This is
the most performance-sensitive ECS operation: at 25K entities with a 10% churn rate, it must
produce ~2,500 events in under 2.5ms.

### 2.1 The `WorldState` Contract

The ECS never speaks directly to the transport or encoder. It speaks only to the `WorldState` trait, which is defined in `aetheris-protocol` and contains no game-library types.

See [PROTOCOL_DESIGN.md §1](PROTOCOL_DESIGN.md#1-worldstate--ecs-adapter) for the canonical trait definition of `WorldState`.

The game loop only ever holds a `Box<dyn WorldState>`. At startup, it is handed either a
`BevyWorldAdapter` (P1) or the custom ECS adapter (P3). The loop itself is identical in both
phases.

---

## 3. Phase 1 — `BevyWorldAdapter`

### 3.1 Crate Structure

```
crates/aetheris-ecs-bevy/
├── Cargo.toml        # depends on: aetheris-protocol, bevy_ecs, bimap, metrics, tracing
└── src/
    ├── lib.rs        # public exports: BevyWorldAdapter, ComponentReplicator, Networked marker
    ├── adapter.rs    # WorldState implementation
    └── registry.rs   # ComponentReplicator trait + DefaultReplicator<T>
```

**Key design decision:** The dependency is on `bevy_ecs` alone — not on the full `bevy` crate.
This avoids pulling in the asset system, the windowing system, the render graph, and hundreds of
other subsystems that have no place on a headless game server. `bevy_ecs` is a self-contained
ECS library that can be used without any other Bevy component.

### 3.2 `BevyWorldAdapter` Internals

```
BevyWorldAdapter {
    world: bevy_ecs::World           // The ECS storage engine
    bimap: BiHashMap<NetworkId, Entity>  // The identity bridge (see §7)
    replicators: BTreeMap<ComponentKind, BoxedReplicator>  // Component registry
    next_network_id: u64             // Monotonic ID allocator (see §7.3)
    last_extraction_tick: Option<Tick>   // Bevy change-detection cursor
}
```

The `bimap` is the most critical field. It is a strict bijection between the protocol's `NetworkId`
and Bevy's internal `Entity` (which embeds both an index and a generation counter). Invariants B1
through B4 from [LC-0400](../roadmap/archive/phase-0-foundation/specs/LC-0400_worldstate_ecs_contract.md) govern this
structure: bijection, atomicity, immutability after insertion, and no ID recycling.

### 3.3 Component Registry — `ComponentReplicator`

Not all ECS components are replicated. The adapter distinguishes:

- **Replicated components:** Registered via `BevyWorldAdapter::register_replicator()`. These are
  emitted by `extract_deltas()` with a `ComponentKind` discriminant. Examples: `Position`,
  `Health`, `Velocity`.
- **Server-only components:** Never registered. Examples: `SuspicionScore`, `PathfindingState`,
  `SpawnTimer`.

Every replicated component type gets a `DefaultReplicator<T>` which implements the
`ComponentReplicator` trait:

```rust
pub trait ComponentReplicator: Send + Sync {
    fn kind(&self) -> ComponentKind;

    /// Extracts a ReplicationEvent if the component changed since last_tick.
    fn extract(
        &self,
        world: &World,
        entity: Entity,
        network_id: NetworkId,
        tick: u64,
        last_tick: Option<Tick>,
    ) -> Option<ReplicationEvent>;

    /// Applies a raw byte payload from the network back into the ECS.
    fn apply(&self, world: &mut World, entity: Entity, update: ComponentUpdate);
}
```

Registration is performed **once at server startup** and is immutable at runtime (Invariant R1 from
LC-0400). The `ComponentKind → component type` mapping must be a strict bijection (Invariant R2).

### 3.4 Change Detection

P1 uses Bevy's built-in change detection. Every component in `bevy_ecs` carries two `Tick` values:
`added` and `changed`. The `DefaultReplicator<T>` compares these against the adapter's
`last_extraction_tick` cursor:

```
Tick N-1 extraction: last_extraction_tick = Some(Tick(N-1))

Tick N extraction:
  For each entity × replicator:
    if component.changed_ticks > last_extraction_tick → emit ReplicationEvent
    else                                               → skip
  last_extraction_tick = Some(Tick(N))
```

After `extract_deltas()` returns, `world.clear_trackers()` resets the change detection state.
A second call to `extract_deltas()` within the same tick, with no mutations, returns an empty
`Vec` (Invariant D3 from LC-0400).

### 3.5 Known Limitations of P1

These limitations are **acceptable in P1** and are the motivation for P3:

| Limitation | Impact | P3 Solution |
|---|---|---|
| O(entities × replicators) scan in `extract_deltas` | CPU cost grows with entity count even when 90% are idle | SoA dirty-bit columns; only scan dirty rows |
| Bevy's change tick is a `u32` | Wraps after ~4B increments (at 60Hz: ~2.2 years) | Custom `u64` tick counter |
| `BTreeMap` replicator lookup by `ComponentKind` | Log-time per component type during extraction | Array-indexed column access |
| `Arc<dyn ComponentReplicator>` vtable call per component | Indirection on the hot path | Monomorphized column iterators |
| No parallel system execution | Systems run sequentially inside `simulate()` | Rayon-based parallel scheduler |

---

## 4. Phase 3 — `aetheris-ecs-custom`

> **Prerequisite:** P2 stress tests must confirm that `aetheris-ecs-bevy` is the measured bottleneck before this crate is written. See [ENGINE_DESIGN.md](ENGINE_DESIGN.md#10-evolutionary-roadmap) for the evolutionary path.

### 4.1 Storage Model — Archetypes + Structure of Arrays (SoA)

The custom ECS uses an **archetype-based, Structure-of-Arrays** layout. An archetype is a unique
set of component types. All entities sharing the same component set live in the same archetype.

```
Archetype {Position, Health, Velocity}:
  positions:  [P0, P1, P2, P3, ...]   ← contiguous f32×3 array
  healths:    [H0, H1, H2, H3, ...]   ← contiguous u32 array
  velocities: [V0, V1, V2, V3, ...]   ← contiguous f32×3 array
  dirty_bits: [bitset per component column]
  entity_ids: [NetworkId, ...]         ← same index as component rows
}
```

**Why SoA?** A physics system iterating positions and velocities accesses only those two arrays,
loading each into a single cache line. An AoS (Array of Structs) layout would interleave
`Position`, `Health`, `Velocity`, and `dirty_bit` bytes — the physics system would load (and
pollute the cache with) health and dirty data it never reads.

At 25K entities with a 64-byte cache line:

- **AoS:** Each entity occupies ~40 bytes. Iterating positions pulls in unrelated fields.
- **SoA:** Position column is contiguous. Iterating positions is a pure sequential memory read at
  ~40 GB/s peak memory bandwidth — the loop becomes SIMD-friendly.

### 4.2 Dirty-Bit Tracking

The P3 custom ECS replaces Bevy's tick-based change detection with **per-column dirty bitsets**.

Each component column in each archetype has a companion `dirty: BitVec` of the same length. When
a system writes to a component, it sets the corresponding bit. `extract_deltas()` iterates only
the set bits — skipping all unchanged rows in a single `trailing_zeros()` operation.

```
Column Position (length 25,000):
  dirty_bits: [0b00100010_00000001_...] ← only bits 0, 7, 13 are set
  fetch:      [P0, P7, P13]             ← 3 entities emit ReplicationEvents
  clear:      dirty_bits.fill(false)    ← O(N/64) words cleared, not O(N) rows
```

**Cost comparison at 25K entities, 10% dirty:**

| Method | Work per extract |
|---|---|
| Bevy tick scan (P1) | 25,000 × `CompTicks::is_changed()` comparisons |
| SoA dirty-bit scan (P3) | 25,000 / 64 = 391 64-bit words scanned, then ~2,500 fetches |

The dirty-bit scan is 64× fewer memory accesses in the dominant (no-change) path.

**Critical invariant:** Dirty bits MUST be cleared atomically with the event emission in
`extract_deltas()`. If a system writes to a component between `extract_deltas()` starting and
clearing, that write must set the bit again. This is safe because `extract_deltas()` runs on the
single simulation thread with no concurrent writers (Stage 4 is sequential).

### 4.3 Query System

The query system provides typed, zero-allocation iterators over archetype columns. Queries are
composable via type-level filters:

```rust
// Iterates all entities with both Position and Velocity, mutable access to Position.
for (network_id, pos, vel) in world.query::<(NetworkId, &mut Position, &Velocity)>() {
    pos.x += vel.dx * dt;
    pos.y += vel.dy * dt;
    // Dirty bit for Position is set automatically by the DerefMut impl.
}
```

**Dirty-bit propagation via `DerefMut`:** The mutable reference returned by a column accessor is
a wrapper type. Its `DerefMut` implementation sets the corresponding dirty bit on first write.
This means the game code does not set dirty bits manually — they are set as a side effect of any
`&mut` access to a component column.

**Archetype iteration:** A query compiles a static list of archetype indices that match its type
signature at registration time. Iteration jumps between matching archetypes without scanning
non-matching ones.

### 4.4 System Scheduler

P3 introduces a parallel system scheduler powered by `rayon`. Systems declare their data access as
type-level parameters (e.g., `Read<Position>`, `Write<Velocity>`). The scheduler builds a
dependency graph at startup:

```
Systems with no data conflicts → rayon::join (parallel)
Systems with a write-read conflict → sequential ordering
```

**No runtime conflict detection.** The dependency graph is built once at server startup. Dynamic
system registration is not supported in P3. This is a deliberate constraint: predictable,
auditable parallelism over flexible-but-opaque scheduling.

The scheduler runs inside `WorldState::simulate()`. From the game loop's perspective, the call is
still single-threaded and returns when all systems have completed.

### 4.5 Migration Path from P1

The migration is designed to be a drop-in swap. The checklist:

1. `aetheris-ecs-custom` implements `WorldState` with the **identical method signatures**.
2. All invariants from [LC-0400](../roadmap/archive/phase-0-foundation/specs/LC-0400_worldstate_ecs_contract.md) remain
   satisfied: bimap bijection, atomic spawn/despawn, no NetworkId recycling.
3. The `LocalId` wrapping contract changes: P3 uses `row_index: u32 || generation: u32` packed
   into a `u64` (see §7.2). The `to_bits()` / `from_bits()` round-trip contract is preserved.
4. The `ComponentKind` registry is identical. Components registered with the same `ComponentKind`
   values produce identical `ReplicationEvent` payloads — the encoder and transport layers see no
   difference.
5. Regression suite from QA-1 runs unchanged against the P3 adapter (M700 milestone).

---

## 5. ECS ↔ Persistence Bridge

The bridge between the boiling-hot simulation and the cold persistence tier is handled via asynchronous, lock-free channels to ensure I/O latency never blocks the tick budget.

See [PERSISTENCE_DESIGN.md](PERSISTENCE_DESIGN.md) for the full architectural specification of the persistence bridge, micro-batching strategy, and the event ledger schema.

### 5.2 Event Sourcing — Append-Only Model

The ECS never issues `UPDATE` statements to the database. It only **appends events**. This is the
foundation of the event ledger:

```sql
-- Cold Tier (TimescaleDB / ClickHouse)
CREATE TABLE entity_events (
    event_id        UUID NOT NULL,          -- UUIDv7 / ULID (globally unique + time-sortable)
    server_node_id  TEXT NOT NULL,          -- which node emitted this event
    network_id      BIGINT NOT NULL,        -- the entity's NetworkId
    component_kind  SMALLINT NOT NULL,      -- which component changed
    tick            BIGINT NOT NULL,        -- server monotonic tick counter
    occurred_at     TIMESTAMPTZ NOT NULL,   -- UTC wall-clock (snapshot boundary, see LC-0200)
    payload         BYTEA NOT NULL,         -- raw encoded delta (same bytes as the wire format)
    chain_hash      BYTEA                   -- SHA-256 Merkle hash. NULL for Baseline entities and
                                            -- non-economic events. Populated by the ECS at
                                            -- emission. NEVER computed by the Persistence Sink.
                                            -- Verified offline by the Audit Worker (see §6.4).
) PARTITION BY RANGE (occurred_at);
```

**Why UUIDv7/ULID for `event_id`?** Standard auto-incrementing `SERIAL` columns require a
centralized sequence — a write bottleneck when multiple server nodes write concurrently. UUIDv7 and
ULID are globally unique, require no coordination, and are **monotonically increasing within the
same millisecond** — preserving time-sortability without a central coordinator.

**Why keep the wire payload in `payload`?** The raw encoded bytes are stored as-is. This means
a row can be decoded back into a `ComponentUpdate` using the same `Encoder` that produced it,
without any schema migration or data translation. The event ledger is codec-independent.

**Why store `chain_hash` in the row instead of recomputing it?** The Audit Worker needs a compact
cursor: instead of reading all preceding rows to reconstruct `H_{N-1}`, it reads `chain_hash`
from the last verified row and uses it directly as `H_prev` for the next step. This makes auditing
O(new events) rather than O(all history). The stored hash does not replace verification — it is
precisely what the Audit Worker verifies by independently recomputing it from scratch.

### 5.3 Time-Travel Reconstruction

The combination of periodic snapshots (Warm Tier) and the event ledger (Cold Tier) enables
**exact state reconstruction at any point in time**:

```
Reconstruct world state at: Tuesday 2026-04-15T14:32:00.000Z

1. Load the nearest preceding Snapshot from PostgreSQL (Warm Tier):
   → Snapshot taken at 2026-04-15T00:00:00.000Z (midnight)
   → Deserialize into a fresh WorldState instance

2. Replay all events from the Cold Tier:
   WHERE network_id IN (affected_entities)
     AND occurred_at > '2026-04-15T00:00:00Z'
     AND occurred_at <= '2026-04-15T14:32:00Z'
   ORDER BY tick ASC, event_id ASC    -- UUIDv7 sorts correctly within a tick

3. Apply each event via WorldState::apply_updates():
   → The reconstructed world is now identical to Tuesday at 14:32:00.000Z
```

**Use cases:**

- **Exploit investigation:** An item duplication exploit detected on Tuesday can be rolled back to
  Monday without a full database restore. The server reconstructs the exact state before the
  exploit and computes the diff.
- **Anti-cheat auditing:** Any player's action history can be replayed frame-by-frame.
- **Matchmaking replays:** Game servers can reconstruct any match for post-match analysis.

### 5.4 Data Temperature Topology

The ECS participates in a five-tier data architecture. Each tier has different access latency,
durability, and cost characteristics:

```
                    ┌──────────────────────────────────┐
🔥 Boiling          │  ECS (In-Memory)                 │  nanoseconds
  (L1 Cache)        │  SharedArrayBuffer (WASM client) │  volatile
                    └──────────────┬───────────────────┘
                                   │ on tick boundary (mpsc channel)
                    ┌──────────────▼───────────────────┐
🌶️  Hot             │  Redis Cluster                   │  < 1ms
  (Routing Truth)   │  Session keys, affinity locks    │  ephemeral
                    └──────────────┬───────────────────┘
                                   │ on snapshot boundary (every N ticks)
                    ┌──────────────▼───────────────────┐
☀️  Warm            │  PostgreSQL                      │  1–5ms
  (Relational Core) │  Hourly/daily entity Snapshots   │  ACID
                    └──────────────┬───────────────────┘
                                   │ streamed from persistence sink
                    ┌──────────────▼───────────────────┐
❄️  Cold            │  TimescaleDB / ClickHouse        │  5–50ms
  (Event Ledger)    │  Append-only delta events        │  high write throughput
                    └──────────────┬───────────────────┘
                                   │ async export job (daily/weekly)
                    ┌──────────────▼───────────────────┐
🧊 Freezing         │  S3 / R2 (Parquet files)         │  seconds
  (Data Lake)       │  ML datasets, economic audits    │  near-zero marginal cost
                    └──────────────────────────────────┘
```

The ECS lives entirely in the **Boiling tier**. It is the only tier with nanosecond access. Every
other tier is written to asynchronously and never blocks the simulation thread.

---

## 6. Adaptive Zero-Trust Hashing

### 6.1 The Problem

Hashing every physics state change at 60Hz for 25,000 players would consume:

```
25,000 entities × 60 ticks/s × SHA-256 (≈ 200ns/hash) ≈ 300ms CPU/second
```

This is 30% of a single CPU core — permanently — just for integrity checking. It is not
sustainable. Aetheris implements **adaptive** hashing: the audit frequency is driven by a
per-entity `SuspicionScore`, not by a fixed rate.

### 6.2 The Merkle Chain

All economic and critical state transitions are bound by a cryptographic hash chain:

```
H_0 = SHA-256("genesis" || server_id)
H_N = SHA-256(H_{N-1} || tick || network_id || payload)
```

Where `payload` is the raw encoded bytes of the `ReplicationEvent` — the same bytes written to the
event ledger. This means the hash chain is verifiable independently of any in-memory state: an
auditor can reconstruct it entirely from the Cold Tier events.

**Write path (blind):** The Persistence Sink inserts rows into the Cold Tier without computing or
verifying hashes. The `chain_hash` column was computed by the ECS at emission and is treated as
an opaque byte column by the Sink. This decoupling means that I/O backpressure cannot produce
false-positive tamper alerts, and INSERT throughput is never gated by cryptographic work.

**Audit path (offline) — `CHAIN_INTERRUPT` vs `CHAIN_BREACH`:** Hash verification is performed
exclusively by the Audit Worker (§6.4), which reads the Cold Tier asynchronously. The Audit
Worker distinguishes two structurally exclusive failure modes:

| Failure Mode | Evidence in the Cold Tier | Root Cause | Severity | Response |
|---|---|---|---|---|
| `CHAIN_INTERRUPT` | Tick N absent; tick N+1 present | mpsc backpressure dropped a batch | Availability failure | Log `WARN`; re-anchor from tick N+1; continue |
| `CHAIN_BREACH` | Row at tick N present; `SHA-256(H_{N-1} \|\| tick \|\| payload)` ≠ `chain_hash` | Row tampered externally | Integrity failure | Log `ERROR`; increment `aetheris_audit_chain_breach_total`; alert |

A `CHAIN_INTERRUPT` is a **missing row** — backpressure leaves no row at all. A `CHAIN_BREACH`
requires a **present row with corrupted content**. These two modes are mutually exclusive by
definition, which makes the **Backpressure Masking Attack** structurally impossible: an adversary
who forces I/O backpressure can only create `CHAIN_INTERRUPT`s (absent rows), never
`CHAIN_BREACH`es (corrupted present rows).

**Re-anchoring on interrupt:** When the Audit Worker detects a tick gap for any entity, it
advances its cursor to the next available row and uses that row's `chain_hash` as the new anchor.
All events after the gap are fully verified. The gap itself is an irrecoverable audit loss,
recorded in `aetheris_audit_chain_interrupt_total`.

**Where it lives in the ECS:** Each entity that participates in the Merkle chain carries a
server-only component (never replicated to clients):

```rust
/// Server-only. Not registered with any ComponentReplicator.
/// Stores the running hash chain state for this entity.
#[derive(Component)]
pub struct MerkleChainState {
    pub previous_hash: [u8; 32],
    pub last_audited_tick: u64,
    pub suspicion_score: u32,
}
```

### 6.3 Adaptive Audit Frequencies

The `suspicion_score` is computed by the ECS simulation systems during Stage 3. It rises when
anomalous patterns are detected (impossible velocities, boundary exploits, statistical outliers
against peer entities) and decays exponentially during clean ticks.

> **Canonical definition:** The authoritative score ranges, increment values, and decay policy
> are defined in [SECURITY_DESIGN.md §8](SECURITY_DESIGN.md#8-suspicionscore-system).
> The table below is a summary; SECURITY_DESIGN is the source of truth.

| Suspicion Level | Score Range | Audit Frequency | Behavior |
|---|---|---|---|
| **Baseline** | 0–99 | Every 600 ticks (~10s) | Hash and compare once per 10 seconds |
| **Elevated** | 100–499 | Every 60 ticks (1s) | Hash and compare once per second |
| **Critical** | 250+ | Every tick (16.6ms) | Hash every tick; lock the player's thread; force WASM client to send confirmation hashes; neutralize in real-time |

**Escalation:** Score increases by a configurable amount per anomaly type (e.g., +20 for velocity
outlier, +80 for teleportation detection, +500 for Merkle chain breach). Capped at `u32::MAX`.

**Decay:** Score decreases by 1 per clean tick (a tick with no anomalies detected for this entity).
A score of 500 returns to Baseline after 401 clean ticks (~6.7 seconds).

**Cost at scale:** At 25K players with 1% under active suspicion (250 players):

```
250 players × 1 hash/tick = 250 SHA-256 ops/tick × 200ns = 50µs/tick
```

This is 0.3% of the 16.6ms tick budget — negligible.

### 6.4 Audit Worker — Actor Pattern

Integrity verification is performed asynchronously by the Audit Worker.

See [AUDIT_DESIGN.md](AUDIT_DESIGN.md) for the actor-based architecture of the audit system and its operational constraints.

---

## 7. Entity Identity System

### 7.1 The Three Identity Layers

Aetheris uses three distinct identifiers for an entity. Each lives in a different layer and serves
a different purpose:

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer         │ Type          │ Scope          │ Persisted? │        │
├───────────────┼───────────────┼────────────────┼────────────┤        │
│ ECS-internal  │ LocalId(u64)  │ Single process │ No         │        │
│ Network wire  │ NetworkId(u64)│ All nodes      │ No*        │        │
│ Persistence   │ UUIDv7 / ULID │ All time       │ Yes        │        │
└─────────────────────────────────────────────────────────────────────┘
  * NetworkId appears in the event ledger payload but is not the primary key.
```

**`LocalId`** wraps the ECS backend's internal handle. It is opaque to every layer except the ECS
adapter. It is never serialized to the network or the database.

**`NetworkId`** is assigned by the server at spawn and communicated to all clients. It is the
identifier used in every `ReplicationEvent` and `ComponentUpdate`. It is not a database primary
key — it is a session-scoped routing handle.

**UUIDv7 / ULID** is the persistence-layer primary key for event ledger rows. It is globally
unique across all server nodes and all time. It requires no central coordinator to generate.

### 7.2 `LocalId` Semantics — P1 vs P3

The `LocalId` wrapping contract must satisfy a round-trip invariant across both ECS backends:

**P1 — `bevy_ecs::Entity`:**

```rust
// Wrap: Entity → LocalId
let local_id = LocalId(entity.to_bits());

// Unwrap: LocalId → Entity
let entity = Entity::from_bits(local_id.0);
```

Bevy's `Entity::to_bits()` encodes a 32-bit index and a 32-bit generation in a single `u64`. The
generation counter **must** be preserved. Stripping it would allow two entities with the same index
(different generations) to appear identical in the bimap — a silent desync.

**P3 — Custom ECS row handle:**

```rust
// Row handle: 32-bit archetype_id + 32-bit row_index + generation
struct RowHandle { archetype_id: u16, row_index: u32, generation: u16 }

// Wrap: RowHandle → LocalId
let local_id = LocalId(
    ((archetype_id as u64) << 48) | ((generation as u64) << 32) | (row_index as u64)
);
```

The round-trip contract `LocalId → original handle` must hold exactly, including the generation.
When an archetype row is reused for a new entity, the generation counter increments, invalidating
any stale `LocalId` that may be held by the bimap. The bimap is always cleared on despawn
(atomically with the ECS removal), so no stale `LocalId` should exist in steady state.

### 7.3 `NetworkIdAllocator`

The server maintains a monotonically increasing, lock-free allocator for `NetworkId`:

```rust
/// Thread-safe, lock-free, monotonically increasing NetworkId allocator.
/// The value 0 is permanently reserved as the null/unassigned sentinel.
pub struct NetworkIdAllocator {
    next: AtomicU64,
}

impl NetworkIdAllocator {
    pub fn new() -> Self {
        // Start at 1; 0 is the null sentinel.
        Self { next: AtomicU64::new(1) }
    }

    pub fn allocate(&self) -> NetworkId {
        NetworkId(self.next.fetch_add(1, Ordering::Relaxed))
    }
}
```

**No recycling.** Despawned entities' `NetworkId`s are never reused (Invariant B4, LC-0400). A
late-arriving packet for a despawned entity with ID `9942` must not be misapplied to a newly
spawned entity that happens to receive the same ID.

**At 60Hz with 25K spawns/despawns per second:** The allocator would wrap `u64::MAX` after
approximately 9.8 billion years. Overflow is a design non-issue.

---

## 8. Server Affinity & Single-Writer Principle

When multiple server nodes write to the same event ledger, a naive implementation allows two nodes
to submit conflicting events for the same entity — breaking the Merkle chain (§6.2) and creating
hash collisions.

Aetheris prevents this with the **Single-Writer Principle**: at any moment, a given `NetworkId` is
exclusively owned by exactly one server node.

### 8.1 Redis as Routing Truth

The Hot Tier (Redis Cluster) maintains a distributed lock for each active entity:

```
Key:   affinity:{network_id}
Value: {node_id}
TTL:   30 seconds (auto-renewed by the owning node each tick batch)
```

When Node 1 owns Player X (`affinity:9942 = "node-1"`), Node 2 is **mathematically prohibited**
from emitting events for Player X. If Node 2 receives a client input for Player X (e.g., during a
re-routing), it forwards the input to Node 1 via the internal Control Plane (gRPC) rather than
applying it locally.

### 8.2 Implications for the ECS

From the ECS's perspective, the Single-Writer Principle means:

- The `BevyWorldAdapter` (or the P3 custom adapter) on any given node only ever contains entities
  **owned by that node**. It does not hold ghost entries for entities owned elsewhere.
- `spawn_networked()` on Node 1 automatically acquires the Redis affinity lock.
- `despawn_networked()` on Node 1 releases the lock.
- A node restart causes all its affinity locks to expire via TTL. The matchmaking system
  re-assigns those entities to healthy nodes, which re-spawn them in their respective local ECS
  from the last Snapshot + event replay.

### 8.3 Scaling Topologies

The Single-Writer Principle enables two orthogonal scaling strategies:

**Geographic Zoning:** Each node owns a spatial partition of the world.

```
Node 1 → entities in the Forest zone   (NetworkIds 1..=8000)
Node 2 → entities in the City zone     (NetworkIds 8001..=20000)
```

**Instanced Architecture:** Each node owns an isolated match or world instance.

```
Node 1 → Global Lobby     (25K players browsing)
Node 2 → Arena Match #447 (10 players)
Node 3 → Arena Match #448 (10 players)
```

Both topologies are transparent to the ECS layer. The adapter does not know or care which topology
is active — it only knows which entities it owns.

---

## 9. Telemetry & Performance Targets

### 9.1 Metrics Emitted by the ECS Layer

| Metric | Type | Stage | Description |
|---|---|---|---|
| `aetheris_ecs_entities_networked` | Gauge | Always | Current count of replicated entities in this node's ECS |
| `aetheris_ecs_extraction_count` | Counter | Stage 4 | Total `ReplicationEvent`s emitted since server start |
| `aetheris_ecs_deltas_per_tick` | Histogram | Stage 4 | Events per `extract_deltas()` call (measures churn rate) |
| `aetheris_ecs_extract_duration_ms` | Histogram | Stage 4 | Wall time for `extract_deltas()` |
| `aetheris_ecs_simulate_duration_ms` | Histogram | Stage 3 | Wall time for `simulate()` |
| `aetheris_world_apply_duration_ms` | Histogram | Stage 2 | Wall time for `apply_updates()` |
| `aetheris_world_unknown_entity_updates_total` | Counter | Stage 2 | Updates discarded due to unknown `NetworkId` |
| `aetheris_persistence_dropped_batches_total` | Counter | Sink | Batches dropped due to full mpsc channel |
| `aetheris_suspicion_score_elevated` | Gauge | Simulate | Players currently at Elevated suspicion |
| `aetheris_suspicion_score_critical` | Gauge | Simulate | Players currently at Critical suspicion |
| `aetheris_audit_chain_interrupt_total` | Counter | Audit Worker | Tick gaps in the event ledger — backpressure drops (availability failure, not tamper) |
| `aetheris_audit_chain_breach_total` | Counter | Audit Worker | Hash mismatches on present rows — external tamper detected (integrity failure) |
| `aetheris_audit_worker_lag_ticks` | Gauge | Audit Worker | Ticks between server head and last verified tick — measures audit freshness |
| `aetheris_audit_workers_active` | Gauge | Audit Worker | Active `EntityAuditActor` instances in the pool |

### 9.2 Tracing Spans

Every `WorldState` method must be wrapped in a `tracing::instrument` span. The spans are the
primary tool for identifying which stage is blowing the tick budget:

```
tick[N] ──┬── world.apply_updates    [2.0ms max]
          ├── world.simulate         [8.0ms max]
          └── world.extract_deltas  [2.5ms max]
```

If any span exceeds its budget for 3 consecutive ticks, the engine logs a `LATENCY_BREACH` warning
with the current entity count and the excess duration (as specified in LC-0100 §3).

### 9.3 Performance Targets by Phase

| Metric | P1 Target (1K entities) | P3 Target (25K entities) |
|---|---|---|
| `extract_deltas` P99 latency | < 2.5ms | < 2.5ms |
| `simulate` P99 latency | < 8.0ms | < 8.0ms |
| Bimap lookup (`get_local_id`) | < 100ns (O(1)) | < 100ns (O(1)) |
| `spawn_networked` | < 500µs | < 500µs |
| Memory per replicated entity | < 500 bytes | < 200 bytes (SoA packing) |
| Bandwidth per tick (10% churn) | Baseline | < 40 MB/s total egress |

P3 targets are aspirational until P2 stress tests (M400–M490) provide measured baselines.
The P3 target for `extract_deltas` is identical to P1 — the goal is to maintain P1 latency at
25× the entity count, not to make it faster at P1 scale.

---

## 10. Open Questions

| Question | Context | Impact |
|---|---|---|
| **Parallel Extract** | Can `extract_deltas` be parallelized across archetypes in P3? | Reduced stage 4 duration on multi-core servers. |
| **SIMD Hashing** | Should Merkle hashing use AVX-512/NEON instructions? | Reduced CPU cost for critical suspicion audits. |
| **Archetype Fragmentation** | How do we handle "singleton" archetypes created by frequent component adds/removes? | Memory fragmentation and query performance. |

---

## Appendix A — Glossary

### Mini-Glossary (Quick Reference)

- **Archetype**: A unique combination of component types stored in contiguous SoA memory.
- **Bimap**: The bidirectional mapping between `NetworkId` and `LocalId`.
- **SoA (Structure of Arrays)**: A memory layout optimized for SIMD and cache efficiency.
- **Dirty Bit**: A per-column bitset indicating which rows were mutated this tick.
- **Merkle Chain**: A cryptographic sequence binding state changes for auditability.

[Full Glossary Document](../GLOSSARY.md)

| Term | Definition |
|---|---|
| **Archetype** | A unique combination of component types. All entities with the same component set live in the same archetype. |
| **Bimap** | Bidirectional map (`NetworkId ↔ LocalId`). The identity bridge between the protocol and the ECS backend. |
| **Change Detection** | Mechanism to determine which components changed since the last `extract_deltas()` call. P1: Bevy's tick comparison. P3: dirty-bit columns. |
| **Cold Tier** | TimescaleDB / ClickHouse. Append-only event ledger for all `ReplicationEvent` deltas. |
| **CRP** | Component Replication Protocol. The wire format and semantics for ECS state changes. Defined in DESIGN.md §5. |
| **Dirty Bit** | A single bit per component per entity indicating whether the component was written since the last extraction. |
| **Event Sourcing** | Architecture pattern where state is derived by replaying an ordered sequence of immutable events, not from mutating rows. |
| **Hot Tier** | Redis Cluster. Stores affinity locks, session routing, and matchmaking state. |
| **LocalId** | ECS-internal entity handle. Wraps the backend's native type. Never crosses the network boundary. |
| **Merkle Chain** | Per-entity cryptographic hash chain binding all state changes in order. `H_N = SHA-256(H_{N-1} || tick || payload)`. |
| **Micro-Batching** | Accumulating multiple writes over a time window (1 second) before issuing a single bulk `INSERT`. |
| **NetworkId** | Protocol-level entity identifier. Server-assigned, globally unique per session. The only ID that crosses the network boundary. |
| **Server Affinity** | Property that a given `NetworkId` is owned by exactly one server node at any moment. Enforced by Redis locks. |
| **Single-Writer Principle** | No two server nodes may emit events for the same `NetworkId` concurrently. |
| **SoA** | Structure of Arrays. Storage layout where each component type has its own contiguous array, enabling SIMD-friendly iteration. |
| **Suspicion Score** | Server-only ECS component. An 8-bit value (0–255) driving the adaptive hashing audit frequency. |
| **Time-Travel** | Reconstructing the world state at an arbitrary past moment using a Snapshot + sequential event replay. |
| **Warm Tier** | PostgreSQL. Stores periodic Snapshots of entity state for time-travel reconstruction and disaster recovery. |
| **Audit Worker** | Asynchronous Tokio service that reads the Cold Tier and verifies Merkle chain integrity. Decoupled from the tick pipeline. Implemented as a supervised pool of `EntityAuditActor`s managed by a `RouterActor`. |
| **Backpressure Masking Attack** | A theoretical attack where an adversary induces I/O backpressure to force `CHAIN_INTERRUPT`s, attempting to mask tamper evidence. Structurally prevented by the write/audit path separation (§6.2): backpressure produces absent rows, never corrupted ones. |
| **CHAIN_BREACH** | Integrity failure: a row exists in the Cold Tier with a `chain_hash` that does not match its independently recomputed value. Indicates external tamper. Cannot be caused by backpressure. |
| **CHAIN_INTERRUPT** | Availability failure: an expected tick is absent from the event ledger because an mpsc batch was dropped under backpressure. Not a tamper indicator. Triggers WARN log and cursor re-anchoring in the Audit Worker. |
| **RouterActor** | Supervisor Tokio task that manages the `EntityAuditActor` pool, spawning and despawning actors in response to `SuspicionChanged` messages from the ECS simulation thread. |

---

## Appendix B — Decision Log

| Date | Decision | Rationale | Alternatives Considered |
|---|---|---|---|
| 2026-04-15 | Use `bevy_ecs` (not full `bevy`) in P1 | Avoids pulling in rendering, asset, and windowing subsystems onto a headless server. Only the ECS is needed. | Full `bevy` binary (too heavy); `hecs` (less mature change detection); `shipyard` (schedule model mismatch) |
| 2026-04-15 | P3 storage: SoA archetypes, not AoS | `extract_deltas` is the measured bottleneck in the P2 stress test hypothesis. SoA enables contiguous iteration with SIMD; dirty-bit columns enable O(dirty/64) scan instead of O(entities). | AoS with hash-based dirty tracking (less cache-friendly); retained Bevy (can't reach P3 target at 25K scale) |
| 2026-04-15 | Dirty bits via `DerefMut` wrapper, not explicit `mark_dirty()` | Eliminates an entire class of bugs where a system writes a component but forgets to set the dirty flag. The compiler enforces it via the borrow checker. | Explicit `mark_dirty(entity, ComponentKind)` call in every system (error-prone); polling all components every tick (O(N) cost, violates D1) |
| 2026-04-15 | UUIDv7/ULID for persistence primary keys | Globally unique without a centralized sequence. Inherently time-sortable. No lock contention across multiple writer nodes. | `SERIAL` auto-increment (central bottleneck); raw `NetworkId` as primary key (not stable across sessions) |
| 2026-04-15 | Event Sourcing (append-only) instead of UPDATE | Enables time-travel debugging. Makes the Merkle chain trivially verifiable from the raw event ledger. Eliminates UPDATE lock contention under high write concurrency. | UPSERT-based updates (no audit trail); snapshot-only (no per-tick delta granularity) |
| 2026-04-15 | Adaptive hashing (suspicion-driven) instead of fixed-rate | Fixed 60Hz hashing for 25K players = 300ms CPU/second. Adaptive reduces this to < 1ms/second in steady state, concentrating cryptographic cost precisely where it is needed. | Fixed-rate 10-second hashing (misses real-time exploits); client-side hashing (trivially spoofable) |
| 2026-04-15 | Redis for affinity locks (not ZooKeeper/etcd) | Already required in the Hot Tier for session routing. Reusing it for affinity avoids introducing a third coordination system. Lock TTL provides automatic failure handling without a watchdog process. | etcd (operational overhead, not already required); in-memory coordinator (single point of failure) |
| 2026-04-15 | Write/audit path separation — Blind INSERT | Decoupling hash verification from the write path prevents backpressure-induced false-positive tamper alerts (`CHAIN_BREACH` vs `CHAIN_INTERRUPT`) and removes all cryptographic cost from the INSERT hot path. | Hash verification at INSERT time (mixes write throughput with audit throughput; enables the Backpressure Masking Attack); Chain Reset Protocol (collapses the two failure modes, making tamper evidence indistinguishable from operational data loss) |
| 2026-04-15 | Actor pattern for the Audit Worker | Independent actor per entity prevents one slow audit from blocking all others. Cursor state `(last_tick, last_hash)` is local to each actor — no shared mutable state, borrow-checker-enforced, independently testable. Linear scalability: actor count grows with Elevated/Critical population. | Monolithic polling loop (O(N) sequential, shared cursor map); rayon parallel loop (no natural lifecycle management per entity); database stored procedure (poor portability, no `tracing` instrumentation) |
| 2026-04-15 | Tiered mpsc send strategy (try_send / send_timeout 2ms / 10ms) | The correct tradeoff between tick budget and audit integrity is entity-specific. A flat fire-and-forget policy silently drops Merkle chain links for active exploit suspects. A flat blocking policy stalls the server under any I/O load. The timeout ceiling (10ms) bounds the worst-case tick overrun to a p99-acceptable value. | Uniform `try_send` (drops Critical entity events unacceptably); uniform blocking `send` (stalls tick budget under I/O load); per-entity dedicated channel (O(N) channel overhead) |
