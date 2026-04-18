---
Version: 0.2.0-draft
Status: Phase 0 — Design
Phase: P1 | P2 | P3+
Last Updated: 2026-04-18
Authors: Team (Antigravity)
Spec References: [ENGINE_DESIGN, CLIENT_DESIGN, VOID_RUSH_GDD, PLAYGROUND_DESIGN]
Tier: 4
License: CC-BY-4.0
---

# Aetheris Theme & World System

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Core Concepts — World vs Theme](#1-core-concepts--world-vs-theme)
3. [Architecture Overview](#2-architecture-overview)
4. [CSS Token Hierarchy](#3-css-token-hierarchy)
5. [World Manifest Format](#4-world-manifest-format)
6. [Theme Manifest Format](#5-theme-manifest-format)
7. [Built-in Worlds](#6-built-in-worlds)
8. [Keyboard Shortcut Namespacing](#7-keyboard-shortcut-namespacing)
9. [Runtime Switching](#8-runtime-switching)
10. [Glassmorphism Design Language](#9-glassmorphism-design-language)
11. [File & Directory Layout](#10-file--directory-layout)
12. [Integration Contract (Engine → World)](#11-integration-contract-engine--world)
13. [Phased Delivery Roadmap](#12-phased-delivery-roadmap)
14. [Appendix A — Decision Log](#appendix-a--decision-log)
15. [Appendix B — Glossary](#appendix-b--glossary)

> **Version note:** v0.2.0 adds §7.4 key normalization (`code` vs `key`) and §8.5 Render Worker synchronization on theme change.

---

## Executive Summary

The Aetheris Engine is a general-purpose authoritative-server multiplayer engine. The HTML shell around the WebGPU canvas — the HUD, menus, overlays, auth screens, and debug panels — is not generic: it belongs to the *application* running on the engine, not to the engine itself.

This document defines the **World** and **Theme** system: a two-tier visual abstraction that lets each application built on the engine own its complete visual identity (World), while still supporting controlled variations within that identity (Theme), all without touching the engine core.

The first application is **Aetheris: Void Rush**, a space MMO. Its World ships with this engine release. The developer-facing Playground is an internal World of its own (`aetheris-playground`), sharing primitives but carrying different purpose.

The design draws inspiration from the Facit admin template's variable-driven approach (700+ CSS custom properties, multiple demo styles) applied to the domain of game engine shells rather than business dashboards.

---

## 1. Core Concepts — World vs Theme

### 1.1 What is a World?

A **World** is a complete, self-contained UI shell for a specific application built on the Aetheris Engine. It defines:

| Aspect | What the World owns |
|--------|---------------------|
| **Identity** | Name, slug, icon, font stack |
| **Layout grammar** | Sidebar vs HUD vs overlay topology |
| **Design language** | Whether it is glassmorphic, flat, skeuomorphic, minimal, etc. |
| **Component vocabulary** | Specific UI components (e.g., spaceship HUD, chat panel, minimap) |
| **Keyboard namespace** | Reserved hotkey ranges for game-layer actions |
| **Default theme** | Which theme is active at first load |
| **Available themes** | The set of themes users can switch between |

Switching Worlds is analogous to switching between entirely different apps. You cannot meaningfully partial-apply a World — it is all-or-nothing.

**Examples:**

| World Slug | Application | Design Language |
|------------|-------------|-----------------|
| `aetheris-playground` | Engine sandbox / developer tool | Tech-glass dark |
| `void-rush` | Space MMO (Aetheris: Void Rush) | Sci-fi glassmorphic dark |
| `nexus-hub` | (Future) social/hub layer | Minimal frosted light |
| `forge` | (Future) level / world editor | IDE-inspired dark |

### 1.2 What is a Theme?

A **Theme** is a named variable-set that lives inside a World. It changes the surface colors, accent palette, opacity levels, blur intensity, and spacing scale — but it does **not** change component structure, layout, or the font stack.

Themes are the mechanism for supporting:

- **Dark / Light / High-Contrast** accessibility modes
- **Seasonal** or **event-based** palette swaps
- **Personal preference** (e.g., warmer amber accents vs. cool cyan)
- **Reduced-motion / performance** mode (lower blur, simpler shadows)

**Examples within the `void-rush` World:**

| Theme Slug | Description |
|------------|-------------|
| `nebula` (default) | Deep space dark, cyan accent, heavy glass blur |
| `pulsar` | Darker navy, electric indigo accent, sharper glass |
| `eclipse` | Near-black, amber-gold accent, soft glass |
| `starfield-lite` | Lower blur, simplified shadows — for performance |

### 1.3 Conceptual Map

```
Aetheris Engine
├── World: void-rush          ← sci-fi space MMO shell
│   ├── Theme: nebula          (default)
│   ├── Theme: pulsar
│   └── Theme: eclipse
│
├── World: aetheris-playground ← developer sandbox
│   ├── Theme: blueprint       (default, current aesthetic)
│   └── Theme: blueprint-lite  (lower blur, accessibility)
│
└── World: nexus-hub           (future)
    ├── Theme: frost           (default, light frosted)
    └── Theme: night           (dark mode)
```

### 1.4 What a World is NOT

- A World is **not** a Rust crate. It is a frontend concern — HTML, CSS, TypeScript.
- A World does **not** modify the WASM binary or the ECS simulation.
- A World does **not** own the `<canvas>` rendering — that belongs to the Render Worker.
- A World **cannot** break the engine API contract (see §11).

---

## 2. Architecture Overview

```
playground/
  worlds/
    void-rush/
      world.css          ← World-level tokens and layout primitives
      world.ts           ← World manifest + registration
      themes/
        nebula.css        ← Theme token overrides
        pulsar.css
        eclipse.css
      components/
        hud.html
        minimap.html
    aetheris-playground/
      world.css
      world.ts
      themes/
        blueprint.css     ← Current aesthetic (this release)
        blueprint-lite.css
      components/
        sidebar.html
        shortcut-overlay.html

  src/
    world-registry.ts    ← Runtime World/Theme loader
    shortcuts.ts         ← Keyboard shortcut namespace registry
    main.ts
    playground.ts
    game.worker.ts
    render.worker.ts
```

The **World Registry** (`world-registry.ts`) is the single authority on:

- Which World is active
- Which Theme within that World is active
- Applying/removing CSS to `<html data-world="..." data-theme="...">`
- Persisting the user's last choice to `localStorage`

---

## 3. CSS Token Hierarchy

All tokens live as CSS custom properties on `:root` and are replaced in layers:

### Layer 1 — Engine base (immutable, engine-owned)

```css
/* Always present regardless of World. These are engine internals. */
:root {
  --engine-version: '0.1.0';
  --engine-z-modal: 1000;
  --engine-z-overlay: 900;
  --engine-z-hud: 800;
  --engine-z-sidebar: 700;
  --engine-z-canvas: 0;
}
```

### Layer 2 — World primitives (world-owned, theme-invariant)

```css
/* world.css — these don't change between themes */
:root {
  --world-font-display: 'Inter', system-ui, sans-serif;
  --world-font-mono: 'JetBrains Mono', monospace;
  --world-radius-sm: 4px;
  --world-radius-md: 8px;
  --world-radius-lg: 16px;
  --world-radius-xl: 24px;
  --world-sidebar-width: 320px;
  --world-header-height: 52px;
  --world-transition-speed: 0.2s;
  --world-transition-ease: cubic-bezier(0.4, 0, 0.2, 1);
}
```

### Layer 3 — Theme variables (theme-owned, hot-swappable)

```css
/* nebula.css — all semantic color + glass tokens */
:root {
  /* Surfaces */
  --bg-base:          #070c1a;
  --bg-surface:       rgba(10, 20, 40, 0.80);
  --bg-elevated:      rgba(15, 30, 55, 0.88);
  --bg-overlay:       rgba(5, 12, 28, 0.92);

  /* Accents */
  --accent-primary:   #38bdf8;
  --accent-secondary: #818cf8;
  --accent-danger:    #f87171;
  --accent-success:   #4ade80;
  --accent-warning:   #fbbf24;

  /* Text */
  --text-primary:     #f1f5f9;
  --text-secondary:   rgba(241, 245, 249, 0.65);
  --text-muted:       rgba(241, 245, 249, 0.40);
  --text-on-accent:   #0f172a;

  /* Borders */
  --border-subtle:    rgba(255, 255, 255, 0.06);
  --border-normal:    rgba(255, 255, 255, 0.10);
  --border-strong:    rgba(255, 255, 255, 0.18);
  --border-accent:    rgba(56, 189, 248, 0.40);

  /* Glassmorphism */
  --glass-blur:       20px;
  --glass-saturate:   180%;
  --glass-bg:         rgba(10, 20, 40, 0.70);
  --glass-border:     rgba(255, 255, 255, 0.08);
  --glass-shadow:     0 8px 32px rgba(0, 0, 0, 0.50),
                      0 2px 8px rgba(0, 0, 0, 0.30),
                      inset 0 1px 0 rgba(255, 255, 255, 0.06);

  /* Grid background (playground) */
  --grid-line:        rgba(255, 255, 255, 0.04);
  --grid-size:        40px;
}
```

### Layer 4 — Component overrides (component-scoped, optional)

Individual components may scope tokens:

```css
/* Sidebar-specific overrides */
#sidebar {
  --glass-blur: 24px;
  --glass-bg: rgba(8, 16, 32, 0.82);
}
```

---

## 4. World Manifest Format

Each World exposes a `WorldManifest` TypeScript object:

```typescript
// world.ts
import type { WorldManifest } from '../../src/world-registry';

export const manifest: WorldManifest = {
  slug: 'void-rush',
  displayName: 'Void Rush',
  description: 'Aetheris: Void Rush — sci-fi space MMO',
  version: '0.1.0',
  defaultTheme: 'nebula',
  themes: [
    { slug: 'nebula',          displayName: 'Nebula',        cssPath: './themes/nebula.css' },
    { slug: 'pulsar',          displayName: 'Pulsar',        cssPath: './themes/pulsar.css' },
    { slug: 'eclipse',         displayName: 'Eclipse',       cssPath: './themes/eclipse.css' },
    { slug: 'starfield-lite',  displayName: 'Starfield Lite', cssPath: './themes/starfield-lite.css' },
  ],
  worldCssPath: './world.css',
  // Keyboard shortcut namespace reserved for this world's game-layer actions
  shortcutNamespace: 'game',
};
```

---

## 5. Theme Manifest Format

```typescript
interface ThemeManifest {
  slug: string;
  displayName: string;
  cssPath: string;
  /** Whether this theme targets light or dark color scheme */
  colorScheme: 'dark' | 'light';
  /**
   * If true, suppresses backdrop-filter and complex shadows.
   * Intended for performance-constrained devices.
   */
  reducedEffects?: boolean;
  /** Accessibility: if true, increases contrast ratios to WCAG AA+ */
  highContrast?: boolean;
}
```

---

## 6. Built-in Worlds

### 6.1 `aetheris-playground` (ships with engine)

The developer sandbox world. This is the first World to be implemented.

| Property | Value |
|----------|-------|
| Purpose | Engine dev, debugging, performance benchmarking |
| Layout | Sidebar (right) + full canvas |
| Default theme | `blueprint` |
| Audience | Engine developers |

**Blueprint theme aesthetic:**

- Deep navy base (`#070c1a`)
- Cyan primary accent (`#38bdf8`)
- Heavy glassmorphism on sidebar and overlays
- `JetBrains Mono` for telemetry values
- Grid background on canvas area

### 6.2 `void-rush` (Phase 1 game world)

The first player-facing World. Shares many Blueprint primitives but adds game-specific components.

| Property | Value |
|----------|-------|
| Purpose | Space MMO gameplay shell |
| Layout | Full-screen canvas + floating HUD panels |
| Default theme | `nebula` |
| Audience | End players |

**Nebula theme aesthetic:**

- Near-black deep-space base (`#070c1a` → `#0d0d1f`)
- Electric cyan accent + indigo secondary
- Frosted glass HUD panels with gradient borders
- Animated background (star field, nebula gradients)
- Scanline subtle texture overlay

---

## 7. Keyboard Shortcut Namespacing

Each World declares which keyboard ranges/combinations it owns. The engine's `ShortcutRegistry` enforces no two registrations conflict at runtime.

### 7.1 Namespaces

| Namespace | Owner | Description |
|-----------|-------|-------------|
| `engine` | Engine core | Reserved — must not be used by worlds |
| `debug` | Engine core | Debug/dev shortcuts |
| `ui` | Active World | World-level UI interactions |
| `game` | Active World | Game-layer actions (movement, abilities) |

### 7.2 Reserved Engine Shortcuts

| Shortcut | Namespace | Action |
|----------|-----------|--------|
| `Ctrl+F3` | `debug` | Toggle wireframe debug overlay |
| `Ctrl+Shift+F3` | `debug` | Toggle world grid overlay |
| `Escape` | `engine` | Close top-most modal / overlay |
| `?` | `engine` | Open shortcut help panel |
| `F1` | `engine` | Open shortcut help panel (alias) |

### 7.3 Conflict Resolution Policy

1. `engine` namespace > all others (cannot be overridden)
2. `debug` namespace > `ui` and `game`
3. `ui` and `game` are co-equal — conflicts between them produce a **registration error** in development builds
4. A shortcut registered in `game` namespace is **automatically suppressed** when a UI input element (INPUT, TEXTAREA, SELECT) has focus
5. A shortcut registered in `ui` namespace is also suppressed when focus is inside the canvas element

### 7.4 ShortcutDescriptor Type

Browser keyboard events expose two distinct fields that serve different purposes:

| Field | Represents | Example (AZERTY `q` key) | Best for |
|-------|-----------|--------------------------|----------|
| `KeyboardEvent.key` | **Character produced** — locale/layout dependent | `"a"` | UI shortcuts that match typed characters: `'?'`, `'Escape'`, `'F3'` |
| `KeyboardEvent.code` | **Physical position** — layout-independent | `"KeyQ"` | Game controls: `'KeyW'`, `'KeyA'`, `'KeyS'`, `'KeyD'` — same position on any keyboard layout |

`ShortcutDescriptor` supports both fields. **Resolution rule:** if `code` is provided it is matched against `KeyboardEvent.code` and takes precedence; otherwise `key` is matched against `KeyboardEvent.key`. At least one of the two must be present.

```typescript
interface ShortcutDescriptor {
  /**
   * Character-level key matched against KeyboardEvent.key.
   * Use for UI shortcuts and named keys: 'Escape', 'F3', '?', 'Enter'.
   * Required if `code` is not provided.
   */
  key?: string;
  /**
   * Physical key position matched against KeyboardEvent.code.
   * Use for game controls: 'KeyW', 'KeyA', 'KeyS', 'KeyD', 'Space'.
   * Takes precedence over `key` when both are provided.
   */
  code?: string;
  /** Modifier flags */
  ctrl?:  boolean;
  shift?: boolean;
  alt?:   boolean;
  meta?:  boolean;
  /** Namespace determines precedence and suppression rules */
  namespace: 'engine' | 'debug' | 'ui' | 'game';
  /** Human-readable label shown in the help overlay */
  label:    string;
  /** Category for grouping in the help overlay */
  category?: string;
  /** Handler to call when triggered */
  handler:  () => void;
  /** If true, calls e.preventDefault() */
  preventDefault?: boolean;
}
```

The `ShortcutRegistry` dispatch loop generates two candidate IDs per event and checks both, preferring the `code`-based match:

```typescript
private handleKeyDown(e: KeyboardEvent): void {
  // code-based lookup first (game/positional shortcuts)
  const codeId = buildId({ code: e.code, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey });
  // key-based fallback (UI/character shortcuts)
  const keyId  = buildId({ key:  e.key,  ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey });
  const descriptor = this.shortcuts.get(codeId) ?? this.shortcuts.get(keyId);
  // ... apply suppression rules, call handler
}
```

---

## 8. Runtime Switching

### 8.1 World switching

World switching requires a **page reload** because:

- The layout grammar may differ (sidebar vs. HUD vs. split-view)
- Component HTML is part of the World and is not hot-swappable without re-mounting
- Font stacks need to be loaded

The World Registry stores the desired World in `localStorage` before reloading.

```typescript
worldRegistry.switchWorld('void-rush');
// → saves to localStorage, triggers window.location.reload()
```

### 8.2 Theme switching (hot-swap, no reload)

Themes are pure CSS. Switching a theme:

1. Removes the current theme's `<link rel="stylesheet">` from `<head>`
2. Injects the new theme's stylesheet
3. Updates `<html data-theme="...">` attribute
4. Saves choice to `localStorage`
5. Notifies the Render Worker (see §8.5)

```typescript
worldRegistry.switchTheme('pulsar');
// → hot-swaps CSS, no reload needed
```

### 8.5 Render Worker synchronization

The WebGPU Render Worker runs in an isolated thread and has no access to the DOM or CSS. A theme switch that changes background or text colors must be reflected in the worker — otherwise debug overlay lines (M1011) can become invisible against the new background.

After the CSS `<link>` swap, `switchTheme()` reads the resolved token values and sends a best-effort postMessage to the Render Worker:

```typescript
// Inside WorldRegistry.switchTheme() — after <link> injection
const style = getComputedStyle(document.documentElement);
this.renderWorker?.postMessage({
  type: 'theme_changed',
  payload: {
    bgBase:         style.getPropertyValue('--bg-base').trim(),       // WebGPU clear_color
    textPrimary:    style.getPropertyValue('--text-primary').trim(),  // debug label color
    reducedEffects: activeThemeManifest.reducedEffects ?? false,
  },
});
```

`WorldRegistry` receives the worker reference via `setRenderWorker(worker: Worker)` — it does **not** import the worker module directly (avoids coupling). If the worker is uninitialized when a theme switch occurs, the message is dropped silently and the render defaults (blueprint dark values) remain in effect.

The Render Worker message handler:

```rust
// render.worker — MessageType::ThemeChanged handler
MessageType::ThemeChanged { bg_base, text_primary, .. } => {
    render_state.set_clear_color(parse_css_color(&bg_base));
    debug_draw.set_label_color(parse_css_color(&text_primary));
}
```

**Tokens read on theme change:**

| CSS token | Render Worker use |
|-----------|------------------|
| `--bg-base` | `wgpu::RenderPassColorAttachment` clear color |
| `--text-primary` | Debug label / overlay line color (M1011) |

### 8.3 Persistence

```typescript
// localStorage keys
const STORAGE_WORLD_KEY = 'aetheris:world';
const STORAGE_THEME_KEY = 'aetheris:theme';
```

### 8.4 Query-param override (dev convenience)

```
/?world=void-rush&theme=eclipse
```

Useful for screenshot automation and QA. Does not persist to `localStorage`.

---

## 9. Glassmorphism Design Language

The first World (`aetheris-playground`) and the first game World (`void-rush`) both use **glassmorphism** as their design language. This section codifies the rules.

### 9.1 Core Properties

Every glass panel must apply:

```css
.glass-panel {
  background: var(--glass-bg);
  backdrop-filter: blur(var(--glass-blur)) saturate(var(--glass-saturate));
  -webkit-backdrop-filter: blur(var(--glass-blur)) saturate(var(--glass-saturate));
  border: 1px solid var(--glass-border);
  box-shadow: var(--glass-shadow);
}
```

### 9.2 Depth Levels

| Level | Token role | Usage |
|-------|-----------|-------|
| **Base** | `--bg-base` | Document background |
| **Surface** | `--bg-surface` + glass | Persistent panels (sidebar, header) |
| **Elevated** | `--bg-elevated` + glass | Floating panels, dropdowns |
| **Overlay** | `--bg-overlay` + glass | Modals, dialogs, full-screen overlays |

Higher depth = higher `backdrop-filter: blur` value and lower background opacity (more glass effect).

### 9.3 Border Treatment

Borders must feel like light catching on glass edges:

- Top/left edge: `rgba(255,255,255, 0.12)` (light catch)
- Right/bottom edge: `rgba(0,0,0, 0.20)` (shadow edge)

Implementation:

```css
border: 1px solid var(--glass-border);
/* Or for explicit edge treatment: */
border-top: 1px solid rgba(255, 255, 255, 0.12);
border-left: 1px solid rgba(255, 255, 255, 0.12);
border-right: 1px solid rgba(0, 0, 0, 0.20);
border-bottom: 1px solid rgba(0, 0, 0, 0.20);
```

### 9.4 Performance Guard

On devices where `backdrop-filter` is expensive (integrated GPU, low-end mobile), the `starfield-lite` / `blueprint-lite` themes set:

```css
:root {
  --glass-blur: 4px;            /* reduced */
  --glass-saturate: 100%;       /* disabled */
  --glass-bg: rgba(10, 20, 40, 0.94); /* nearly opaque */
}
```

The `prefers-reduced-motion` media query additionally disables transition animations:

```css
@media (prefers-reduced-motion: reduce) {
  * {
    transition: none !important;
    animation: none !important;
  }
}
```

---

## 10. File & Directory Layout

```
playground/
  worlds/
    aetheris-playground/
      world.css
      world.ts
      themes/
        blueprint.css          ← Current default theme (ships in this release)
        blueprint-lite.css     ← Performance / accessibility variant
    void-rush/
      world.css                ← (Phase 1 game world — future)
      world.ts
      themes/
        nebula.css
        pulsar.css
        eclipse.css
        starfield-lite.css

  src/
    world-registry.ts          ← WorldRegistry class
    shortcuts.ts               ← ShortcutRegistry class
    main.ts                    ← index.html entry point
    playground.ts              ← playground.html entry point
    game.worker.ts
    render.worker.ts

  index.html                   ← Auth / player-facing client
  playground.html              ← Developer sandbox
```

---

## 11. Integration Contract (Engine → World)

The engine guarantees these HTML elements will exist in any World's HTML:

| Element ID | Type | Purpose |
|------------|------|---------|
| `#engine-canvas` | `<canvas>` | WebGPU render target (engine-controlled) |
| `#status` | any | Engine status text (aria-live) |

Everything else (sidebars, overlays, modals, HUDs) is World-owned. The engine will never read or write IDs outside this contract.

### 11.1 World-provided hooks

Worlds may optionally expose:

```typescript
interface WorldHooks {
  /** Called when the engine transitions to the connected state */
  onConnected?(clientId: string): void;
  /** Called on engine fatal error */
  onFatalError?(message: string): void;
  /** Called each tick with telemetry data */
  onMetrics?(metrics: EngineMetrics): void;
}
```

---

## 12. Phased Delivery Roadmap

### Phase 0 — Foundation (This release)

- [ ] Define CSS token hierarchy (§3)
- [ ] Implement `ShortcutRegistry` (`shortcuts.ts`)
- [ ] Revamp `playground.html` with glassmorphism + token system
- [ ] Revamp `index.html` with glassmorphism + token system
- [ ] Create `worlds/aetheris-playground/` directory structure
- [ ] Extract `blueprint.css` theme from inline styles
- [ ] Create `world-registry.ts` stub (load only, no switching UI yet)
- [ ] Add `?` shortcut → shortcut help overlay

### Phase 1 — Theme Switcher UI

- [ ] Build theme picker component (top-right dropdown or settings panel)
- [ ] Implement hot-swap theme switching
- [ ] Ship `blueprint-lite.css` for performance mode
- [ ] `prefers-color-scheme` auto-detection

### Phase 2 — Void Rush World

- [ ] Create `worlds/void-rush/` with `nebula.css` default theme
- [ ] Design game HUD component vocabulary (health, minimap, chat)
- [ ] Port auth screen to void-rush World aesthetic
- [ ] Implement World switching (with reload)

### Phase 3 — Multi-World Platform

- [ ] Dynamic World loader (import() splitting per world)
- [ ] World manifest validation at build time
- [ ] Theme marketplace scaffold (community worlds/themes)
- [ ] World-level i18n / locale support

---

## Appendix A — Glossary

| # | Decision | Rationale |
|---|----------|-----------|
| A1 | World switching requires reload | Layout DOM is World-specific; hot-swapping HTML structure reliably is complex and error-prone |
| A2 | Theme switching is CSS-only, hot-swap | Pure CSS custom property replacement is trivially safe and instant |
| A3 | Engine owns only `#engine-canvas` and `#status` | Minimal surface area keeps engine/world coupling near zero |
| A4 | Glassmorphism as P0 design language | Aesthetic cohesion with space MMO theme; `backdrop-filter` is now widely supported (Chrome 76+, Firefox 103+, Safari 9+) |
| A5 | CSS custom properties over CSS-in-JS | Zero runtime overhead, works in plain HTML without framework dependency |
| A6 | `ShortcutRegistry` with namespace precedence | Prevents future World/engine shortcut conflicts as the system grows |
| A7 | World manifest as TypeScript (not JSON) | Type safety + ability to co-locate handler logic in the same module |
| A8 | `theme_changed` postMessage to Render Worker | Worker thread has no DOM access; otherwise debug lines become invisible on light/high-contrast themes |
| A9 | `ShortcutDescriptor` accepts `code` (physical) **or** `key` (character), not exclusively one | UI shortcuts must match typed characters (locale-safe); game controls must match physical position (layout-independent) |

---

## Appendix B — Decision Log

| Term | Definition |
|------|-----------|
| **World** | A complete UI shell for a specific application built on the engine |
| **Theme** | A named CSS variable-set that lives inside a World |
| **Blueprint** | The design language of the `aetheris-playground` World |
| **Glass panel** | A UI surface using `backdrop-filter: blur()` and semi-transparent background |
| **Token** | A CSS custom property that encodes a design decision |
| **Namespace** | A logical grouping of keyboard shortcuts by ownership level |
| **World Manifest** | A TypeScript object describing a World's metadata and available themes |
| **ShortcutRegistry** | The engine-level service that manages all keyboard shortcut registrations |
| **`theme_changed`** | postMessage sent from `WorldRegistry.switchTheme()` to the Render Worker carrying resolved CSS token values |
| **`key` field** | `ShortcutDescriptor` field matched against `KeyboardEvent.key` — locale-dependent character |
| **`code` field** | `ShortcutDescriptor` field matched against `KeyboardEvent.code` — layout-independent physical key position |
