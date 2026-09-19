# Cepessa Sessions desktop design

This document describes the current native macOS interface. The source of
truth is `desktop/Desktop/Sources`, especially `Theme`, the session reader,
Clips, Settings, and the floating session bar.

## Product shape

Cepessa Sessions is an accessory app. It has no Dock icon and opens no main
window at launch. The menu bar item is its persistent entry point; the floating
recording indicator is optional. Sessions, Clips, and Settings open on demand.

The application menu also exposes the core destinations through native
commands:

- Browse All Sessions: `Command-O`
- Import Audio: `Shift-Command-I`
- Show Clips: `Shift-Command-L`
- Settings: `Command-,`

## Native windows

The session reader is a quiet, opaque document surface. Long-form transcript
text uses the semantic text background, a centered reading column, native text
selection, and a native window toolbar for the current session, import,
transcription, and export. Source audio, evidence warnings, and attachments sit
with the transcript because they explain what the reader can trust.

Clips is a native two-pane `NavigationSplitView`: recordings in the sidebar,
the selected clip in the detail pane, and one capture bar anchored below the
list. It should continue to behave like a document browser rather than a
dashboard.

Settings is a grouped macOS `Form` with native sections, pickers, toggles,
progress, permission rows, and destructive confirmation. Do not replace it
with a custom settings canvas. The application shortcut and floating controls
must open this same settings window rather than separate SwiftUI and AppKit
variants.

## Surfaces and material

Readable window content is opaque. Separation comes from native lists, forms,
dividers, spacing, and semantic raised controls. Glass is reserved for the
floating session indicator, its expanded controls, and transient floating
menus. Never place transcript text or other long-form content on glass.

The floating surface uses one native glass or material fill, a lit rim, and two
shadows: a tight contact shadow and a wider ambient shadow. Its borderless host
panel includes transparent bleed derived from the ambient shadow radius and
offset. Preserve that bleed; clipping it creates a hard rectangular edge and
can hide the collapsed indicator.

On macOS 26 and later the floating surface uses Liquid Glass. Earlier systems
use regular material. Reduce Transparency switches it to an opaque semantic
surface, and Increase Contrast strengthens the rim.

## Color and type

`CepessaColors` resolves surfaces, labels, separators, and the accent through
semantic AppKit colors. This is what supports light mode, dark mode, vibrancy,
and Increase Contrast. The user's system accent marks ordinary selection and
action. System red means active capture or error; system orange means warning;
green is reserved for verified ready or success states.

Use system typography and native control metrics. Long-form text may scale
through the existing reader zoom and `scaledFont` infrastructure. Avoid fixed
display typography where a native title, label, or section header already
communicates hierarchy.

## Motion

The floating indicator is one continuous lozenge across idle, recording, and
expanded states. Its container changes geometry with the shared spring while
contents leave and enter on shorter opacity curves. The state ring stays at the
leading edge, so it travels with the capsule instead of jumping between views.

Hover changes lighting without changing geometry. Smaller state changes use a
short ease-out. Reduce Motion removes the spring and spatial offsets while
preserving state changes and readable opacity transitions. The panel expands
before its contents and shrinks only after outgoing content clears, which keeps
the glass and its controls inside the host bounds.

## Change rules

- Preserve the native reader, two-pane Clips browser, and grouped Settings
  structure unless a tested workflow requires a different hierarchy.
- Keep persistent content opaque and reserve glass for floating chrome.
- Use semantic colors and system controls before adding fixed visual tokens.
- Treat evidence, capture, processing, and conflict states truthfully; absence
  of a warning must not stand in for verified readiness.
- Test light and dark appearances, Increase Contrast, Reduce Transparency, and
  Reduce Motion when changing shared theme or floating-bar behavior.
- Avoid blanket theme rewrites. Change the smallest shared token or component
  that expresses the intended behavior.

## Menu bar mark

The Sessions mark is an original S made from two opposing rounded voice strokes.
The native renderer uses an 18-point template image so macOS controls contrast
on light, dark, and selected menu-bar backgrounds. A separate monochrome badge
identifies recording, transcription, attention, or readiness while the mark
stays recognizable. Timers, progress text, and accessibility descriptions retain
their existing behavior. The editable reference is
`desktop/Desktop/Sources/Resources/sessions-status-mark.svg`.
