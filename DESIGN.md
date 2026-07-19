# Cepessa Sessions (desktop) — Design System

Target: the 2026-07 "floating-bar-first" distillation. Swift files: `desktop/Desktop/Sources/Theme/`.

## Surfaces (exactly two treatments)
1. **Bar surface** — the floating pill and status-bar popover replacements. One capsule/rounded rect, near-solid light fill (`paper` at ~0.97 over `.ultraThinMaterial` on pre-26, single `.glassEffect` on macOS 26+), ONE hairline stroke (`hairline` at 0.5 opacity), ONE shadow (y:6 r:14, ~0.10). No gradient stacks, no white top-glow shadows, no double strokes.
2. **Window surface** — the session window and settings. Plain `backgroundPrimary` window background, content separated by whitespace and 1px hairlines only. Cards only for the transcript speaker bubbles; nothing else gets a card.

Delete/stop using: `cepessaGlassPanel`, `cepessaCanvas`, `cepessaPaper`, `cepessaInstrumentStrip`, the two floating-toolbar gradient modifiers, `CepessaStatusSkeuomorphicButtonStyle`.

## Radii (collapse 9 tokens → 3)
- `bar` = capsule (999)
- `panel` = 14 (windows, popovers, sheets, transcript bubbles)
- `control` = 8 (buttons, fields, chips)

## Color — Restrained strategy
Tinted neutrals + one state accent, nothing else.
- Neutrals: keep `paper 0xFFFFFF`→ retint to 0xFEFEFD; `paperDeep 0xFAFAF9`; `ink 0x1D1D1F`; text secondary `0x636366`; tertiary `0x8E8E93`; hairline `0xE8E8EA`.
- **Recording red `0xE5484D`** is the only saturated color and appears only while recording (record dot, stop button, status-bar icon tint, timer text).
- Processing/progress: `ink` at reduced opacity, no color.
- Success/warning/error keep system values but appear only in transient notices.
- Remove: `purple*` aliases, `purpleGradient`, `speakerColors` array (speakers differentiate by weight/initials, not six grays), `moss/copper` poetic names → plain semantic names.

## Typography
System font only. Four sizes: 11 (caption), 13 (body/controls), 15 (section title), 22 (timer, monospaced digits, medium). Weights: regular, medium, semibold. Keep `scaledFont` infrastructure.

## Motion
One curve everywhere: `.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)` (already used by the bar). Keep `CepessaPressStyle` (scale 0.975). No move+opacity+scale combos; pick one transition per element. Respect Reduce Motion (already wired).

## Layout
- Floating bar: 8pt internal gaps, 10pt padding, height 44 idle / 52 recording.
- Session window: single column, max content width 720, 24pt outer padding, no sidebars or rails.
- Menus: native `NSMenu`/SwiftUI `Menu` everywhere; the custom `CepessaToolbarMenu` popover is retired.
