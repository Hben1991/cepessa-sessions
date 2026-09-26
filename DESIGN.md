# Cepessa Sessions desktop design

Sessions is Cepessa's recorder. Its visual language is Cepessa's First Light
onboarding, carried into a tool that is used many times a day: a night sky, the
orb's warm light, cream ink, words that arrive out of focus and settle. It is
restrained where First Light is theatrical — no sky shader behind text, no
sound — because a transcript is read for minutes at a time and the recorder
sits on top of real work all day.

The source of truth is `desktop/Desktop/Sources`: `Theme/` for the system,
`Meetings/UI/` for the surfaces.

## Product shape

An accessory app: no Dock icon, no window at launch. Two surfaces are always
there — the **floating capsule** and the **menu-bar mark** — and two open on
demand: the **sessions window** (library and reader) and **Settings**.

Commands: All Sessions `⌘O`, Import Audio `⇧⌘I`, Export Transcript `⌘E`,
Settings `⌘,`. In the reader: back `⌘[`, text size `⌘+ ⌘- ⌘0`, play/pause
`Space`. In the library: search `⌘F`.

## Tokens (`Theme/`)

- **`SessionsPalette`** — three families that never stand in for each other:
  - *Sky*: `nightSkyTop/Mid/Bottom`, the night the capsule and the dark window
    are made of.
  - *Light*: `lightCore`, `sunriseGold`, `cloudCoral`, `nova*`. Identity,
    emphasis and "working". Never a status colour; finished is shown by the
    absence of a signal, not by green.
  - *Signal*: `recording` (redder than coral, live capture only) and
    `attention` (amber, always with a symbol).
  Names mirror `CepessaBrandPalette` in the Cepessa app so the two can share
  one token set when Sessions is embedded there. Window colours adapt: warm
  paper by day, deep sky at night; every ink clears 4.5:1 on its canvas.
- **`SessionsType`** — Cal Sans for what is *said* (titles, empty states),
  Geist for what is *read* (transcripts, UI), SF with monospaced digits for
  clocks. Both faces ship in the app (SIL OFL, `Resources/Fonts/OFL.txt`).
  Neither draws Hebrew, so each carries a cascade to the matching SF face.
- **`SessionsMotion`** — arrivals (opacity from nothing while a 14pt blur falls
  away, a few points of rise, 0.55 s ease-out, 60 ms stagger capped at ten
  items), departures (recede: blur, 3% smaller, 0.28 s ease-in), the capsule
  spring (response 0.46, damping 0.88), and `SessionsWordReveal`, a
  `TextRenderer` that brings a line in word by word in reading order.
- **`SessionsSurfaces`** — `SessionsAtmosphere` (the window's still sky),
  `sessionsNightGlass` (floating chrome), `sessionsRaised` (fields on the
  atmosphere), and the shared button styles.
- **`SessionsOrb`** — the recorder's face (below).
- **`SessionsStatus`** — one status vocabulary for every surface, and
  `SessionsStatusLight`: red pulse while recording, gold while transcribing,
  amber when something needs a look, nothing when ready.

## The floating capsule

One object that changes width, always night whatever the system appearance,
because dark glass with cream ink is the combination that reads on every
document it floats over. 44 pt tall in every state; only the width moves.

- **At rest**: the orb and ⋯. One click on the orb records.
- **Recording**: orb · timer · two measured level bars (microphone, system
  audio) · mute · region capture · stop · ⋯. Region capture is one click, no
  menu. Stop is the one saturated control and never moves.
- **Folded** (the owner clicks the orb while recording, persisted): orb · timer
  · levels.
- **Transcribing / needs attention**: orb and a two-line status column;
  clicking the orb opens that session.
- **Notice**: a pinned screenshot or file is confirmed in full for 2.6 s.

The orb breathes on the Cepessa orb's 5.4 s period and its halo follows the
*measured* audio level; a source that is not capturing shows an empty track,
never a fake flicker. Muted is a cool, slashed sphere; a missing source adds a
dashed amber ring; transcribing dims the orb behind a gold arc of real
progress (or a slow turn when there is none).

⋯ and right-click open the capsule menu, drawn in the same night glass:
capture the whole screen, attach a file, recent sessions, the library, import,
settings, hide, quit — with ↑ ↓ Return Esc. Right-click adds Stop, Mute and
Fold at the top.

Mechanics that must be kept: the panel carries transparent bleed derived from
the shadow (`panelBleed`); a morph grows the panel first, animates the shape,
and settles the panel on SwiftUI's completion (with a watchdog); controls take
no clicks while the shape moves; the capsule hangs from a persisted top-centre
anchor and widths are even, unrounded points so it never walks across the
screen; hover changes light, never geometry.

## The sessions window

Full-size content with a transparent title bar: the atmosphere runs to the top
edge and the traffic lights sit on it. The top strip drags the window.

- **Library**: "Sessions" in the display face, a search field across titles
  and transcripts, then every recording grouped by day (Today, Yesterday,
  weekday and date) — time, title, the first words said, and a status light
  only when something is happening or wrong. Hebrew rows read from the right.
- **Reader**: a 680 pt measure. The date line in gold small caps; the title in
  the display face, revealed word by word, double-click to rename; the status
  line only when there is a transcript to qualify; the recording as a line of
  light; pinned attachments as a strip; then the transcript as turns — each voice
  named once, in its own light by order of appearance, Geist 17 on generous
  leading, right-aligned when it is Hebrew, screenshots inline where they were
  pinned. Only the header and the first ten turns arrive with motion: long
  text is read, not watched. Without words yet, one line in the display face
  says what is happening ("Listening.", "Writing it down.", "The transcript
  didn't finish.") and offers the one action that helps.

## Settings

A native grouped `Form` — real pickers, toggles and keyboard behaviour — on
the same atmosphere, under one line in the display face. Destructive storage
actions stay behind a confirmation that names what will be deleted.

## Menu-bar mark

An original S of two opposing rounded voice strokes, drawn as an 18 pt
template image with a monochrome badge for recording, transcribing, attention
or ready. The editable reference is
`desktop/Desktop/Sources/Resources/sessions-status-mark.svg`.

## App icon

The orb rising over a line of first light on a night tile. Rendered from
`desktop/Desktop/Branding/render-app-icon.swift`; the `.icns` is built from
that render.

## Accessibility and settings of the Mac

- Reduce Motion: no springs, blurs or reveals; state changes still read.
- Reduce Transparency: the capsule and menu become opaque night.
- Increase Contrast: the capsule rim becomes a solid cream edge.
- Every custom control has a label, and the orb exposes its one action plus
  the transport action. Colour is never the only carrier of a state.

## Change rules

- Keep identity light and operational signal apart. Green does not mean done.
- Nothing moves behind text. Motion arrives and settles; it does not loop
  except where it reports something live (the orb, a pulse).
- Decorative motion never impersonates measured activity, progress or a
  completed action.
- Test light and dark, Hebrew and English, Reduce Motion, Reduce Transparency
  and Increase Contrast when changing shared tokens or the capsule. The
  fixture renders (`CEPESSA_RENDER_FIXTURES=<dir>`, see
  `SessionsFixtureRenderTests`) cover every surface in both appearances.
