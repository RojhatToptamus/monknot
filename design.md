# Monknot — design language and UI rules

Authoritative reference for the Monknot macOS app (markdown, PDF, image and code editor, with a
video and audio player). Read this before implementing, refining or proposing any interface work.

Monknot is a **native SwiftUI/AppKit app**. Glyphs are **SF Symbols**. Type is **SF Pro Text** for
UI and **SF Mono** for code. Everything below is prescriptive: if a choice is not derivable from
these rules, it is not a Monknot choice.

The character to aim for is **calm, quiet, native macOS chrome** in the manner of Linear, Codex and
Claude: one chrome tone frames the window, and the document and terminal sit on rounded cards set
into it. Controls are fills, never outlines. Colour is scarce. Nothing moves that does not have to.
The Preview editor's surfaces (§10.10) and the window's chrome are one system: the same fills, row
geometry, radii and ink.

---

## 0. Five principles

1. **One row primitive.** `28 tall · 8 padding-x · 15 glyph in an 18 column · 8 gap · 13 label`, no
   gap between rows, inside a 10 list inset (`MonknotListRowLabel`). Sidebar rows, Recents,
   Settings' sections, Find in Workspace's results and the PDF navigator's lists are this row; a tab
   is the same row with 10 padding, for files and terminal sessions alike (`MonknotTab`). Menus and
   popovers take the editor's menu row: 30 tall, the same glyph and column, a 10 gap, inside a 6
   inset (`MonknotMenuRowLabel`). Overlay results are the menu row at 34.
2. **Depth is a property of the surface class, not the colour mode.** Docked never casts. Resting
   never casts. Only floating casts — in both modes.
3. **Two weights, one job each.** 400 for every label, sidebar names included; 600 for headings,
   titles and the workspace name. Nothing is ever bolder for being hovered, selected or focused.
4. **Five radii and a capsule.** 2 · 6 · 8 · 12 · 16. A sixth value is a mistake, not a case.
5. **One zoom factor drives the entire workspace.** Chrome and document scale together.

---

## 1. Colour

### 1.1 Everything is derived

A theme supplies **six** colours. Every other value in the interface is computed from them. Never
hand-pick a colour; add it to the derivation or it does not exist.

| Input | Meaning |
|---|---|
| `surface` | the canvas — also decides light vs dark |
| `ink` | foreground text colour |
| `accent` | the one hue that means "active/selected/current" |
| `ok` | success, running |
| `danger` | destructive, failed |
| `skill` | skill/agent affordances |

Variant is decided by **measured relative luminance**, never by a flag:
`dark = relativeLuminance(surface) < 0.45`. A theme that calls itself light but ships a `#1e1e2e`
surface renders as dark, correctly.

### 1.2 Derivation (normative)

```
bg        = surface
sidebar   = mix(surface → ink, dark ? 0.075 : 0.028)
surf2     = mix(surface → ink, dark ? 0.11  : 0.05)
surf3     = mix(surface → ink, dark ? 0.17  : 0.09)

ink       = ink
ink2      = ink @ max(72%, the least that reads 4.5:1 on chrome and surface)   label at rest
ink3      = ink @ max(50%, the least that reads 3:1 on chrome and surface)     glyph at rest, secondary text
ink4      = ink @ 30%     disabled, placeholders

line      = ink @ (dark ? 9%  : 12%)    structural seams + control borders
line2     = ink @ (dark ? 6%  : 8%)     in-container dividers only
frame     = ink @ (dark ? 14% : 9%)     window rim

hover     = ink @ (dark ? 6%  : 5.5%)
press     = ink @ (dark ? 11% : 10%)
highlight = ink @ (dark ? 9%  : 6.5%)   menu row inside a document (§10.10)
selected  = ink @ (dark ? 10% : 9%)     selected sidebar or Settings row, active terminal session
on        = ink @ (dark ? 17% : 12%)    a format that is on, in the format bar (§5.1)
track     = ink @ (dark ? 7% : 6%)      segmented track, pop-up and settings button fill
chip      = dark ? mix(surface → ink, 0.12) : surface
                                        the active tab and a selected segment, lifted out (§5.5)
chipring  = ink @ (dark ? 9% : 10%)     the chip's hairline
chipseat  = dark ? none : ink @ 9%      the chip's one-point seat (radius 0.75, y 1)
button2   = ink @ (dark ? 10% : 8%)     secondary push button

chrome    = dark ? mix(surface → #000000, 0.28) : mix(surface → ink, 0.055)
                                        titlebar, sidebar and every gap between cards (§10.0)
cardring  = ink @ (dark ? 9% : 11%)     the document, terminal and settings cards' ring
handle    = ink @ 18%, 30% while dragged  a split divider under the pointer (§10.0)

accent    = accent
onaccent  = contrast(#ffffff, accent) >= contrast(#101010, accent) ? #ffffff : #101010
sel       = mix(surface → accent, dark ? 0.28 : 0.20)
accsoft   = accent @ (dark ? 18% : 14%)

dangersoft = danger @ (dark ? 12% : 10%)
dangerline = danger @ (dark ? 22% : 20%)
```

**`onaccent` picks by measured contrast, not by a luminance threshold.** A 0.5 threshold hands
white to any accent below it, and a mid-luminance accent — a 0.40 green, a 0.44 brass — then carries
a white label at 2.2:1, which is an unreadable primary button. Compare both candidates and take the
winner. Every accent must clear **4.5:1** against its `onaccent`; if it cannot, darken the accent
rather than accepting the label.

**The ink ladder is measured, not fixed.** `ink2` and `ink3` start at 72 % and 50 % and rise, a
hundredth at a time, until they read 4.5:1 and 3:1 on both the chrome and the canvas
(`AppTheme.labelInkOpacity`, `glyphInkOpacity`). A dark ink on white keeps the floors; Catppuccin
Latte's soft ink needs 84 % and 66 %. One ladder serves the sidebar, tabs, menus, Settings and the
Preview editor (`--mk-ink2`, `--mk-ink3`), so no surface reads fainter than another.

**Note the inversion on `line`.** Dark runs *lighter* (9%) than light (12%). Dark already has a
large luminance step between canvas and sidebar doing the separation, so the line only hints. Light
has almost no step — near-white on near-white — so the line carries the seam alone. Getting this
backwards makes light chrome look seamless and dark chrome look over-ruled.

### 1.3 Where accent is allowed — exactly six places

1. The active tab's kind glyph
2. The selected sidebar row's glyph (and Settings' selected section)
3. A dirty/unsaved dot
4. The workspace monogram in the sidebar header — the window's identity, as Linear marks a workspace
5. A search match option that is on
6. The terminal glyph of a session awaiting input

Nothing else in the chrome is coloured. Panel toggles (sidebar, terminal, terminal fullscreen) never
light up: the open panel is its own state, and their glyphs already say which way they act. If a
seventh use appears, one of these gives it up.
Glyphs are **never** tinted by file type, folder colour or language.

The document is not chrome. In Preview, links and a checked task box take the accent, callouts tint
their panel with `accent` (note), `ok` (tip), `skill` (important) or `danger` (warning, caution) at
7 %, exactly as PDF export prints them; the editing surfaces floating over the document stay neutral.
Writing assistance marks the words it changes with `accent` mixed into `surface` and draws a
completion in `ink` mixed toward `accent`, in Source and Preview alike (§10.10).

### 1.4 Ink ladder

`ink4` disabled → `ink3` glyph at rest and secondary text → `ink2` label at rest → `ink` label or
glyph when its row or control is hovered or active.

Hover raises the label and the glyph to `ink` **and** adds a `hover` fill. Selection moves one step up **and**
adds the neutral `selected` fill — never an accent tint, so a selected row never reads as a text
selection and the accent glyph (§1.3) stays the only colour in it. Search match options are the one exception: their selected state uses an `accent` glyph
with no resting fill, so the option stays visually subordinate to the query field.

---

## 2. Depth — the surface class decides, not the mode

Assign the class first; the treatment follows mechanically.

| Class | What | Treatment |
|---|---|---|
| **Frame** | titlebar, sidebar, the gaps around and between cards | the `chrome` tone, no line at all: the cards' edges are the seams. **Never a shadow.** |
| **Card** | the document, the terminal, a Settings page | `surface` on `chrome`, radius 12, a `cardring` hairline. **Never a shadow.** |
| **Contained** | grouped settings rows, fields, the composer | `e1` — a 1px ring, nothing else, both modes. **Never a shadow.** |
| **Floating** | menus, popovers, toasts, peek cards, sheets, windows | shadow **in both modes** — a shadow is what says *dismissible*. |

A sidebar is not hovering above the canvas, so a shadow under it is a lie the eye catches
immediately.

### 2.1 Elevation tokens

```
dark:
  e1     inset ring: white 9%
  e2     inset ring: white 14%   +  0 8px 24px black 50%,  0 2px 6px black 34%
  e3     inset ring: white 14%   +  0 24px 60px black 64%, 0 6px 16px black 40%
  win    0 24px 60px black 64%, 0 6px 16px black 40%  + outer ring: frame
  bezel  none

light:  (shadowHue = mix(ink → accent, 10%))
  e1     inset ring: ink 12%
  e2     inset ring: sh 8%  +  0 4px 12px sh 8%,   0 1px 3px sh 5%
  e3     inset ring: sh 8%  +  0 16px 40px sh 14%, 0 4px 10px sh 6%
  win    0 16px 40px sh 14%, 0 4px 10px sh 6%  + outer ring: frame
  bezel  0 1px 1px sh 5%
```

Light shadows are **never pure black** — black on a warm white goes muddy. The 10% accent mix picks
up the theme temperature with no visible cast. Alphas stay in the 5–14% band; past that a light
shadow stops reading as shadow and starts reading as dirt. Dark shadows *are* plain black at
34–64%: there is no hue to preserve down there, only density.

Always two shadow layers: the tight key gives the edge, the wide ambient gives the lift, blur stays
2–3× the offset.

### 2.2 Windows

A window uses `win`, not `e3`: same detached ambient, but `frame` as a single **outer** ring instead
of `e3`'s inset one, because a window clips its content and its edge must be drawn outside. **One
ring per boundary** — never `e3` and `frame` together, which gives a 2px rim.

### 2.3 Never

- No shadow on anything docked.
- No shadow on anything at rest.
- No shadow stacked on a surface that already sits on a shadow.
- No inner top-only highlight — on a rounded card a single lit edge reads as a bevel, and it falls
  apart the moment the card sits against a lighter neighbour.
- No elevation change on hover. Hover changes fill, not height.

---

## 3. Borders

| Token | Value | Where |
|---|---|---|
| `line` | ink 9% dark / 12% light | **Field** and **grouped container** edges. The frame has no edges of its own (§10.0); no button, segmented control or pop-up has a border. |
| `line2` | ink 6% dark / 8% light | In-container dividers only — between rows of a card, between popover blocks, under a panel header. Always inset from the container edge so it never meets a radius. |
| `frame` | ink 14% dark / 9% light | Window rim, one per window, inside `win`. |
| elevation rings | inside `e1`/`e2`/`e3` | Part of the elevation token; must never be paired with a separate border. |
| accent stroke | 1px `accent` | **Only** a focused field. Not active buttons — see §5.2. |
| focus ring | 3px `accent` @ 35%, outside the box by default | In addition to the control's own border, never replacing it. Icon buttons nested in a fixed-height search shell contain the ring inside their box; every other control draws it outside the layout box. Neither treatment participates in layout. |

**Never use `line2` for a structural edge.** A docked pane earns no shadow, so its hairline is the
only seam it has; substituting the fainter divider token makes the sidebar edge disappear.

### 3.1 Where no stroke is allowed

- Between segments of a segmented control — the 2px gap does it.
- Between tabs — the chip does it.
- Around any button, at rest or active — the fill does it.
- Around a segmented control or pop-up — its track does it.
- Under the titlebar, beside the sidebar, around the terminal — the cards do it.
- On any hover state — a border appearing on hover reads as a jump even though nothing moved.
- On both a container and its first child at the same edge.
- On top of an elevation token.
- On a filled accent button.

### 3.2 Always a hairline

1px logical (0.5pt at 2×). Never 2px, never dashed, never a left-border accent stripe on a card,
never inset and outset on the same element. If a boundary needs more presence than a hairline, it
needs a tone step or a shadow — not a thicker line.

---

## 4. Typography

### 4.1 Two weights, total

- **400 (regular)** — every label: sidebar and menu rows, tabs, search matches, fields, button
  labels, Settings' rows, body and help text. Selected or not, hovered or not, focused or not
  (`MonknotTypography.rowTitle`).
- **600 (semibold)** — headings, panel, sheet, overlay and window titles, the workspace name
  (`MonknotTypography.panelTitle`).

No other weight in the chrome. No bold/700 anywhere at all. Three type styles cover the chrome:
label 13/400, title 13/600, and secondary 12/400 for paths, counts, captions, details and group
headers (`rowDetail`, `groupHeader`).

### 4.2 Never bolder on

Hover · selection · focus · press · active · current.

A label that thickens on selection reflows its own glyphs by a fraction of a point, so the row
appears to twitch under the pointer, and running down a list makes the whole column breathe. It
also reads as a permanent property rather than a reversible state. If an item needs more presence it
takes a fill plus one step up the ink ladder — fill is a far louder signal than weight.

### 4.3 Sizes

| Role | Size / line-height |
|---|---|
| Preview prose | 14 / 1.6 at the default 13 pt code size (prose is code size × 14⁄13) |
| Document h1 / h2 / h3 | 1.875 / 1.45 / 1.2 em of prose, line 1.2 / 1.25 / 1.3, tracking −0.021 / −0.016 / −0.01 em, weight 600; h4–h6 1 em |
| Row + tab + button label | 13 / 1 |
| Field text, overlay queries included | 13 / 1 |
| Panel, sheet, overlay and empty-state title | 13 / 1, weight 600 |
| Body prose | 13.5 / 1.6 |
| Secondary + caption | 12 / 1.4 |
| Group header (sidebar Recents, Settings sections, menus over the document) | 12 / 1.2, weight 400, `ink3`, sentence case ("Recents", "Basic blocks"), no tracking. Nothing in Monknot is uppercased. |
| Code | 13 / 1.65 SF Mono |

### 4.4 Shortcut labels

Standalone keyboard-shortcut metadata uses one shared **12/400 rounded system** label everywhere.
The rounded design keeps modifier symbols such as ⇧, ⌘, ⌥ and ⌃ at one optical height. Do not use
the monospaced code face or a smaller local font for these labels. The component has exactly two
presentations. A **quiet hint** uses `ink3` with no fill, border or padding. A **reference key cap**
in Settings or the Keyboard Shortcuts reference uses `ink2`, 9 horizontal and 4 vertical padding,
radius 6 and `surf3`/inset fill. A key cap contains only the key or modifier sequence; trigger
context such as “after [[” belongs in the action label. A list footer pairs each quiet hint with its
action in plain 12 `ink3` beside it (`↑↓` Choose · `↩` Open · `Esc` Close); words never go inside
the label. Modifiers and named keys use Apple's symbols (⌘ ⇧ ⌥ ⌃ ↩ ⇥ −); Escape is written “Esc”.
Shortcut text embedded in prose, help strings, tooltips and native menu items keeps the surrounding
native text treatment.

---

## 5. Controls

### 5.1 Icon-only button

**Two sizes, no third** (`MonknotIconButton`). Every bar uses the `28 × 28` box, radius 8, a **17pt
symbol** centred (optically capped, §8.2) — the same button as the Preview format bar's. A button
inside a row or a field (match options, a row's Remove, a stepper's − and +) is the small `22 × 22`
box, radius 6, a 13pt symbol. No padding value — the box and the centring do it. Back and forward are
two regular buttons 2 apart, with no shell around them. A button that shows or hides a panel has no
on state (§1.3). A button that opens a menu of commands (More) is the same box (`MonknotMenuButton`).
A disabled container (a PDF bar while its document loads) disables its buttons, and they draw
themselves at `ink4`; nothing dims the bar.

| State | Treatment |
|---|---|
| Rest | no fill, no border, `ink3` glyph |
| Hover | `hover` fill, `ink` glyph |
| Pressed | `press` fill |
| On (format applied) | `on` fill (`fg` at 12 % light, 17 % dark), `ink` glyph. Preview's format bar uses it for bold, italic, strikethrough, code and link, so formatting never spends the accent, a format that is on never looks like the text selection under it, and the fill still reads on a 28 pt button where the 6.5 % `highlight` of a menu row disappears |
| Open (its menu is showing) | `press` fill and `ink` glyph until the menu closes: the format bar's block selector, the table bar's Row and Column, the code language label. A callout's kind keeps its own tint at 12 % |
| Disabled | `ink4` glyph, no fill. No extra opacity on top. |

**Search option exception.** Match Case and Match Whole Word are small buttons inside the search
field in both search surfaces, and stay transparent at rest whether off or on. On uses an
`accent` glyph. Hover alone adds the standard full-box `hover` fill; pressed uses `press`. Keyboard
focus uses the standard ring, never the hover fill. As with every icon button nested in a
fixed-height search shell, contain that ring inside its 28-point box so focus cannot enlarge the
shell's visual envelope. Keep the native selected accessibility state in sync with the icon.

### 5.2 Fills, not outlines

A control's state is its fill and its glyph colour, nothing else. No button, segmented control,
pop-up or tab has a border at rest or in any state; an outlined control beside a filled one reads as
two products. Fields are the exception: they keep a `line` hairline, which a focused field turns
`accent` (§3).

### 5.3 Text push button

Two heights, no third: **28 in bars and banners, 30 in sheets.** Padding-x 12, radius 8, label
13/400.

- **Secondary** — `button2` fill, no border, no bezel.
- **Primary** — `accent` fill, `onaccent` label, no border and no bezel.
- **Destructive** — `danger` fill, white label.

Hover adds the `hover` tint over the fill and press the `press` tint (§1.4), in both themes. It never
changes padding, size, weight or elevation.

A **pop-up** (`MonknotPopUpButton`: Settings' pickers, the PDF zoom, tool, markup colour and font,
Find in Workspace's replace scope) is 28 tall: its value (13 `ink`, tabular, as wide as its longest
option, or a swatch or glyph) and a 10 `chevron.down` in `ink3`, 10 leading (8 before a swatch or
glyph) and 8 trailing, on the `track` fill; `hover` tint under the pointer, `press` while its menu is
open. Its menu is native, with the current value checked and placed over the button, as
`NSPopUpButton` places it; commands that are not values (Stroke Width…) follow a separator.

### 5.4 Button with glyph and label

Padding **10 leading / 12 trailing** — asymmetric on purpose, because the glyph's own side bearing
adds optical space on the left. Glyph 14 in a 16 column, gap 7, label 13.

### 5.5 Segmented control

Cells 24 tall (icon cells 28 wide, text cells 12 padding), radius 6, 16pt symbol, 2 between cells, 2
padding, on a `track` fill with radius 8 and **no border** (`MonknotSegmentedControl`). The outer box
lands on 28 tall, matching every other control in the bar. The titlebar's view mode, the PDF tools and
navigator, the text style popover and Settings use it.

- Selected: a **chip** lifted out of the track, the same chip as the active tab (§10.3): `chip`
  fill (the canvas colour in light, the canvas blended 12 % toward `ink` in dark), a 0.5 `chipring`
  hairline, and in light themes a one-point seat (`ink` 9 %, radius 0.75, y 1); `ink` glyph. Settings'
  text segments are the same chip.
- Idle: a glyph `ink3`, a word `ink2`; hover `hover` + `ink`.
- Momentary variants (back/forward) never take a selected fill; each segment disables independently
  and the control never resizes.

### 5.6 Hover timing

120ms ease on **fill and foreground colour only**. Never animate size, position, elevation, border
or weight. The hover fill covers the whole 28pt box, not an inset — an inset highlight makes the
target look smaller than it is.

### 5.7 Other controls

One implementation each (`MonknotFormControls.swift`, `SettingsComponents.swift`):

- **Field** 28 (`View.monknotField`): the canvas inside a `line` hairline, radius 8, 8 leading and 8
  trailing (3 when small buttons end it); focused, an `accent` hairline and a 3 pt `accsoft` ring
  outside; invalid, a `danger` hairline. Find, Find in Workspace, Replace, the rename sheets,
  workspace names and hex values.
- **Toggle** 32 × 18 capsule, 14 white knob, `accent` when on, the `track` inside a `line` hairline
  when off.
- **Stepper** 28: small − and + around a 13 tabular value on the `track` (`MonknotStepper`).
- **Slider** track 4 in the `on` fill, `accent` up to a 16 white knob (`MonknotSlider`).
- **Colour well** the system's minimal well, 44 × 22, which draws its own edge (`MonknotColorWell`).
- **Menu row** 30, **overlay row** 34 (§0).

**Empty states.** One layout everywhere: a 34 glyph in `ink3`, a 13/600 title, one 12 `ink3`
line, and at most two actions. A primary action shows its shortcut as a quiet hint beside it. No
paragraphs of explanation and no decorative glyphs.

**Sheets.** 20 padding, the 13/600 title with an optional 12 `ink2` line under it, the content, then
trailing 30 push buttons, Cancel before the default action.

**Scroll thumbs.** One thumb everywhere (`MonknotScrollbarStyle`): no track, a capsule 4pt wide at
`ink` 25 % that grows from its centre to 6pt at 45 % under the pointer, its centre 5 from the
container's edge (3 clear of it), its ends 6 clear of the lane's ends so it never runs into a card's
rounded corner. It takes its colour from the theme's `ink`.

- **Chrome lists** (sidebar, search results, palettes, panels, PDF navigator, diff panes, Settings)
  always overlay, whatever "Show scroll bars" says: the thumb appears only while the list scrolls,
  and fades. It never shows merely because the pointer is over a list: beside a divider a resting
  thumb reads as a resize handle. A chrome list takes the thumb before its first layout, so
  no legacy bar flashes and nothing shifts sideways.
- **Documents** follow the system setting, so side-by-side panes always behave alike. Overlay: the
  thumb fades as the system's does. "Always": the same thumb stays in an 11 lane with no track —
  Source and PDF through `MonknotScroller`, Preview through `html.mk-legacy-scrollbars`
  (preview.css), which the page shell carries from its first paint, never WebKit's 17pt legacy bar.
  The lane stays laid out while the document fits, so text never rewraps when it grows past one
  screen. An HTML file's preview is the file's own page and keeps WebKit's scroller.
- **The terminal** draws the thumb always (§10.6).

---

## 6. Proportion — every ratio, so nothing is eyeballed

| Relationship | Rule |
|---|---|
| Glyph beside a label | **label + 2** (13 → 15) on sidebar rows, menu rows and tabs alike. At 1.0 the icon sits below cap height and reads as an afterthought; past 1.3 it leads and the name becomes its caption. |
| Gap, glyph to label | **label × 0.6**, rounded even. 13 → 8, 12 → 7, 11 → 6. Always smaller than the glyph it follows, or the two stop grouping as one object. |
| Icon-only button | **glyph fills 60% of the box.** 17/28, 16/26, 15/24. Below 55% the button looks empty; above 70% the glyph crowds the radius. |
| Row height | **28** in the chrome, the same as a tab chip, so the sidebar's rows and the titlebar's tabs share one rhythm. Menus and popovers take 30, overlays 34. |
| Row padding-x | **8** on every row, leading and trailing equal. A row's glyph therefore sits 18 from the list's edge (10 inset + 8), and its label 44. |
| Secondary glyph (close, chevron) | chevrons **10**, semibold; the close and clear `xmark` **9** semibold in a **16** round target. Deliberately off the label ratio — these are not content, and sizing them like content gives a row three things all claiming to be the subject. |
| Dot indicator | **glyph ÷ 2.5** → 6. |
| Bar divider | Only in the Preview format bar, which floats: **bar height × 0.36** (1×16 between its groups). Docked bars — the titlebar, the terminal's bar, the PDF bar — group by space alone: items 2 apart, groups 8 apart. Never full height — a full-height rule turns a bar into a table. |
| Bar height | **tab height + 16** for the titlebar (44: 8 of air each side of a 28 control); **40** for every bar below it (`MonknotBar`: the terminal's and the PDF's, the sidebar and panel headers), 6 padding. |

**Where the ratios stop.** Editor body text, PDF page content, image pixels and empty-state illustrations are not
chrome and follow none of this. Everything from the window rim inward to the document does.

**Why this matters more than it looks.** If two rows can appear on screen at once and hold the same
kind of thing — a filename in a tab and the same filename in the sidebar — they must resolve to
identical numbers. Slightly different padding or glyph size on each makes one look smaller than the
other and the whole interface reads as miscalibrated.

---

## 7. Radius — five values and a capsule

| Value | Use |
|---|---|
| **2** | Indicator: outline rail dashes, scroll thumbs, progress fills, find-match underline. Anything whose job is to be a *mark* rather than a container. |
| **6** | Nested cell: a segmented segment, a swatch in a picker, a key cap. Only ever inside an 8 parent. |
| **8** | Every standalone control, no exception: icon button, push button, pop-up, field, tab chip, sidebar row, list row, badge, segmented track, popover row, stepper. |
| **12** | Container **and** floating layer: the document, terminal and Settings cards, grouped lists, popovers, menus, toasts, peek card. Same value on purpose — they are one structural tier, and giving a menu a different radius than the card it visually replaces makes it look imported. |
| **16** | Sheet: modals, dialogs, full overlay panels. The only radius that reads as "in front of everything". |
| **capsule** | Toggle track, any pill; a circle for a dot. A capsule is a *shape*, not a radius — never write half the height as a number, it breaks silently when the height changes. |

**Nesting: child = parent − 4, floor 6.** A 16 sheet holds 12 cards which hold 8 rows which hold 6
cells. Never nest equal radii — concentric corners at the same value look like a rendering error —
and never let a child be rounder than its parent.

---

## 8. SF Symbols — size, alignment, spacing

### 8.1 Point size, not frame

Size with `.font(.system(size: s, weight: .regular))` and let the symbol lay out at its intrinsic
size.

- **Never `.imageScale`** — small/medium/large are relative to the surrounding font and give three
  different results in three different rows.
- **Never `.frame(width:height:)` on the symbol itself** — it squashes glyphs whose aspect is not
  square.

### 8.2 The two sizes

- **Beside a label:** 15pt next to a 13pt label in the 18pt column, on sidebar rows, menu rows and
  tabs alike, so a file reads the same in a tab, the sidebar and a menu.
- **Alone in a button:** nominally 17pt in a 28pt button. Optical ceilings are measured from the
  rendered symbol bounds: whole-word search is 12.5pt; `curlybraces`, `link` and `play.rectangle`
  are 13pt; `magnifyingglass`, `checklist`, `text.quote`, document glyphs, and the diagonal
  terminal arrows are 14pt; the two sidebar glyphs are 15pt; the open strokes `plus` and the bar's
markup and history glyphs 15pt and `xmark` 14pt, which otherwise read largest in a bar; a filled
warning triangle 13pt. Preview's editor glyphs follow the same
  rule: `chevron.left.forwardslash.chevron.right` is 12pt; `textformat`, `speaker.wave.2` and
  `list.bullet.rectangle` 13pt; `tablecells`, `text.bubble`, `face.smiling`, `calendar`, the
  callout glyphs, `arrow.triangle.2.circlepath`, `arrow.up.right.square`, `plus.square.on.square`,
  `doc.on.doc`, `trash`, `pencil` and `link.badge.minus` 14pt. `photo` is sized for its ink weight
  instead: its solid mountains and sun carry more ink than an outline, so at 12pt it matches its
  neighbours. Other symbols retain the nominal size.

Both scale by the zoom factor. Weight is `.regular` **everywhere** — `.medium` on a 15pt symbol
reads as a different icon set two rows down.

### 8.3 Fixed glyph column

Every symbol beside a label in the chrome sits in `.frame(width: 18 * z, alignment: .center)`, in a
tab too.

SF Symbols have different intrinsic widths — `folder` is wide, `doc.text` narrow, `doc.richtext`
narrower still — so without a fixed column the label's left edge moves from row to row. **This is
the single cause of a ragged-looking sidebar and this is the fix.** The column is 18 because the
widest glyph in the set at 15pt measures about 17.4pt; its side bearing absorbs the rest.

### 8.4 Vertical alignment

Centre the symbol on the label's **cap height, not its baseline.** SF Symbols are drawn centred on
the cap-height band, so a baseline-aligned symbol sits visibly low.

Reliable form: `HStack(alignment: .center)` with both inside a fixed-height row — which the 30pt row
already gives you. If you must use `.firstTextBaseline`, apply an `.alignmentGuide` offset of about
`-1pt * z`.

### 8.5 Horizontal spacing

`HStack(spacing: 8 * z)` measured from the **column edge**, not the glyph edge, so the gap is
identical regardless of which symbol occupies it. Never rely on a symbol's own side bearing.

### 8.6 Optical adjustment

Exactly two symbols need a nudge because their ink is off-centre in its box: `chevron.right` in a
disclosure control moves **0.5pt right**; `magnifyingglass` moves **0.5pt left**. Nothing else. Do
not eyeball others. These positional nudges are separate from the point-size corrections above;
neither changes the control or glyph-column geometry.

### 8.7 The set

`sidebar.left` · `chevron.left` / `chevron.right` · `chevron.right` / `chevron.down` (disclosure) ·
`line.3.horizontal` (source) · `eye` (preview) · `sidebar.right` · `doc.text` markdown · `doc.richtext`
PDF · `photo` image · `play.rectangle` video and audio · `folder` (a workspace) · `terminal` · `xmark` ·
`plus` · `gearshape` · `list.bullet.indent` (outline peek).

Use the **outline (non-fill) variant everywhere** except for three status marks, where the fill is the
state: `folder.fill` for the active workspace, `pin.fill` on a pinned tab, and
`exclamationmark.triangle.fill` for a warning.

### 8.8 Rendering mode

`.symbolRenderingMode(.monochrome)` with `.foregroundStyle` from the ink ladder. Never hierarchical
or palette in the chrome — multi-tone symbols introduce a second grey that is not in the ladder, and
against `ink3` at rest it reads as a rendering bug.

### 8.9 When SF Symbols will not do

Only four cases:

1. **Outline rail dashes** — not glyphs at all. Draw as 2pt rounded `Capsule()` shapes; no symbol
   encodes heading depth.
2. **File-kind badge for an unknown extension** — SF Symbols has no generic-with-extension glyph.
   Draw `doc` and overlay the extension in 7pt SF Mono.
3. **Trailing indicator in a native macOS `Menu` label** — SwiftUI promotes a standalone SF Symbol
   to the menu's leading icon position and discards non-text trailing content. Use SF Pro's `⌄`
   down-arrowhead as a separate 10pt regular text run so it remains trailing. Its ink center is
   3.2pt below the 13pt title's ink center, so apply a scalable +3.2pt baseline offset.

4. **Block grip** — six dots in two columns of three, the drag affordance of every block editor;
   SF Symbols has no 2×3 grid. Draw 2.5pt dots on a 4 × 4.67pt pitch in an 8 × 14 box, `ink3` at rest.
   The toggle's triangle is a filled CSS triangle in the document's marker column, a marker like a
   list bullet rather than a chrome glyph.

Everywhere else a custom glyph will look imported. SF Symbols carry the system's stroke contrast and
terminal shapes; a hand-drawn 15pt icon beside them always reads as foreign. If a custom glyph is
genuinely unavoidable, match stroke 1.5 with round caps and joins at every size — a varying stroke
is what makes an icon set look sourced from different libraries.

---

## 9. Zoom — one factor, the whole workspace

⌘+ / ⌘− / ⌘0 change `workspaceZoom`. **Every** metric in the window is a function of it: titlebar,
tabs, sidebar rows, glyph point sizes, gaps, paddings, radii, outline rail width and dash lengths,
and all document text. Chrome and content move together, the way VS Code and Xcode do it.

Zooming only the body text is the usual mistake — 125% prose under an unchanged 44pt titlebar makes
the chrome look borrowed from another app.

### 9.1 Steps, not continuous

`0.8 · 0.9 · 1.0 · 1.1 · 1.25 · 1.5 · 1.75 · 2.0`

Discrete, so every level has been seen by someone. A continuous slider guarantees levels where a
13pt label rounds to 13.4 and every sidebar row sits on a different subpixel. ⌘0 returns to 1.0. The
level is per window and persists per workspace.

### 9.2 Never `.scaleEffect`

Derive every number and lay out normally. **Never wrap the window in `.scaleEffect(zoom)`.** It
rasterises text at 1× and resamples it, so labels go soft; it scales 1px hairlines into 1.25px grey
smudges; and it leaves hit rectangles at their unscaled size, so buttons stop matching where they
look.

### 9.3 Rounding

- Box metrics → whole points: `h = round(30 * z)`
- Type → nearest half point: `size = round(13 * z * 2) / 2` (SF Pro has real optical sizes; a half
  point is the finest step that still lands cleanly)

Round **once**, at the point of use, from the base number in the scale table. Never chain roundings —
`round(round(30*z)/3)` drifts.

### 9.4 What does not scale

Traffic lights (the system owns them) · the window corner radius · every 1px hairline (`line`,
`line2`, `frame`, elevation rings stay one device hairline at every zoom, because a border is a
boundary rather than an object) · shadow blur and offset, for the same reason · focus rings stay 3px.

### 9.5 Titles stay in proportion

The document h1 is 22pt at 1.0 and scales with the same factor, so the ratio between window title,
tab label and body text is constant. **Nothing is clamped.** A clamped element is exactly what makes
a zoomed interface look unbalanced, because it silently changes the proportion the eye is using to
judge everything else.

### 9.6 Outline rail under zoom

Rail width, dash lengths (22/14/9) and inter-dash gap all scale; **dash thickness stays 2pt.** The
peek card scales as a normal surface. The rail keeps mapping the whole document at every zoom, so it
stays a scroll map rather than a list that runs off the bottom.

### 9.7 Floor, and the PDF exception

At 0.8 the row is 24pt, glyph 12pt, label 10.5pt — the floor. Below that macOS hit-target guidance
breaks before the type does, which is why the scale stops there rather than at a smaller type size.

**PDF is the exception**, and an image with it. A page has a true physical size, so over a PDF or an
image ⌘+ zooms the **page** and leaves the workspace alone. The chrome stays at the workspace factor. Zoom is therefore two
independent values; the status bar shows whichever the focused view owns.

Everything else zooms with the workspace — including **every page of Settings**, not just the editor.

---

## 10. Layout — the shell

### 10.0 The frame and the cards

```
┌──────────────────────────────────────────────────────────────┐
│ ● ● ●  ⊟  ‹ ›   [ Tab ]  Tab   Tab                [≡|◉]  ⊞   │  titlebar, chrome
│ ▣ Workspace ⌄  ⌕ ✎╭───────────────────────────╮ ╭──────────╮ │
│ › Notes          │                           │ │ terminal │ │
│   Product brief  │        document card       │ │   card   │ │
│ Settings     ⌘,  ╰───────────────────────────╯ ╰──────────╯ │
└──────────────────────────────────────────────────────────────┘
```

The window is one `chrome` tone: the titlebar, the sidebar and the gaps. The document sits on a
**card** — `surface`, radius 12, a `cardring` hairline, no shadow — and so does the terminal when it
is open. Nothing else draws an edge: there is no rule under the titlebar, beside the sidebar or
around the terminal, because the cards' edges are the seams.

Every gap is **6**: between the sidebar and the document card, between the cards, and between a card
and the window's trailing and bottom edges. The gaps are the split view's dividers, so a collapsed
pane leaves its divider at the window edge as that margin, and the document card never moves when a
pane opens or closes. A divider draws nothing at rest; under the pointer, a 2 pt
`handle` line in the gap (`ink` 18 %, 30 % while dragging) shows what will move. Never `accent`. The card's top edge meets the
titlebar, 7 below the tab chips.

Settings uses the same frame: its sections on `chrome`, the page on a card inset 6 from the trailing
and bottom edges.

### 10.1 Titlebar, 44 tall

Left to right: traffic lights + sidebar toggle + back/forward │ **tab strip** │ flexible gap │ view
mode │ terminal toggle. While the sidebar is open the tab strip starts on the document card's leading
edge, so the first tab sits over the card it shows, and it follows the edge as the sidebar slides;
with the sidebar closed it follows the navigation buttons. No divider separates the groups: items
sit 2 apart (back and forward) and groups 8 apart.

The coloured leading edge of the close traffic light and the trailing edge of the terminal toggle
use the same titlebar horizontal padding. Move the native traffic-light trio as one group so its
macOS inter-button spacing remains unchanged.

Navigation leading, document actions trailing — the split Finder, Safari and Xcode use. **Exactly
two affordances right of the gap.** There is no ⋯ overflow: anything that would land in one belongs
in the menu bar, where macOS already indexes it for Help search.

Tabs live in this single 44pt bar. There is no second bar and no centred workspace title — the
workspace name appears only in the sidebar. Outline is the rail, not a button. Export, share and
print are menu items with shortcuts (⇧⌘E, ⌘P).

**Ceiling:** never more than two icon affordances right of the tab strip. Hitting the ceiling means
the next command goes to the menu bar, not into the window.

The in-document ⌘F surface is find-only and one field (§5.7): the search glyph, the query, Match
Case and Match Whole Word, the result count in 12 `ink3` tabular figures, previous/next and close,
all small buttons inside it, with no rule. Replacement belongs only to Find in Workspace in the sidebar.
Inspect Links remains an ⌥⌘L menu command and appears in the Markdown source editor's native
context menu; it is never a titlebar affordance.

### 10.2 Markdown mode cluster

The trailing controls read as one set because they share every number: 28 tall, radius 8, no
border, 8 between them (a group gap), no divider. Left is the two-cell view-mode segmented (`line.3.horizontal` /
`eye`) on its track; right is the terminal toggle. Nothing in the cluster has a fill except the
track and the selected segment's chip. **If one of them needs a different height or a border, it does
not belong in the cluster.**

**View mode is two cells: Source and Preview.** A side-by-side editor is a *window arrangement*, not
a view mode — it belongs in the Window menu with its own shortcut, not in a control whose other
cells switch how one pane renders.

**Disabled, not hidden.** For PDFs, images, video, audio and plain text the view-mode control takes
the disabled treatment of §5.1: `ink4` glyphs, its track at half strength, and no selected cell. Controls
never appear or disappear between file kinds — the toolbar must not reflow.

**No Markdown toolbar row.** Nothing docks between the titlebar and the document in any view mode, so
switching view mode never moves the document. Preview formats from surfaces that float over the text
it acts on (§10.10); Source formats from the keyboard (⌘B ⌘I ⌘E ⌘K ⇧⌘7 ⇧⌘8). The word count sits in
the editor's bottom-trailing corner: 12 `ink3`, tabular digits, on a `surface` capsule, inset 14 × 10;
its help text gives lines and words.

### 10.3 Tab strip — hug, cap, scroll

One tab for files and terminal sessions (`MonknotTab`). Geometry: 28 tall, radius 8, 3 between
tabs, strip inset 3 inside the titlebar, no dividers. On the chrome the active tab is a **chip**
lifted out of it — `chip` fill, a 1 `chipring` hairline and in light themes the one-point `chipseat`
(§5.5) — and its glyph is `accent`; inside a card (the terminal) it takes the neutral `selected`
fill, as a selected row does. Other tabs have no fill at rest and no border; the label rests at
`ink2` and the glyph at `ink3`, both `ink` under the pointer.
Content: `10 padding · 15 kind glyph (18 column) · 8 gap · 13 label · 10 padding`, then an 8 gap and
a 10 badge for a pinned tab (`pin.fill`, `ink3`) or a file missing on disk (`danger` triangle).

- **Width:** hug the label, cap at **220 outer**. No minimum, no floor, no shrinking. A tab is the
  same width with thirty open as with two, so the strip the user learned stays put. No slot is
  reserved: close appears in the glyph's own column, so nothing shifts when the pointer enters.
- **State in the glyph column:** an unsaved file carries a 6 pt `accent` dot on its glyph's corner,
  knocked out of the glyph's strokes; while saving the glyph is a 12 spinner, and a failed save a
  `danger` triangle. A sidebar row draws the same mark (`MonknotDocumentGlyph`).
- **Scroll:** horizontal scroller. Two-finger horizontal, ⇧-wheel **and a plain mouse wheel**
  scroll it: each vertical wheel notch over the strip moves it sideways. A trackpad's vertical
  swipe over the titlebar does nothing, and nothing over the strip is **ever** forwarded to the
  document. Momentum and rubber-band come from the platform scroller — do not reimplement them. No
  scrollbar is drawn: the strip is 30 tall and a bar would take a third of it.
- **Reveal:** activating, opening or restoring a tab scrolls it just inside the strip by the
  **nearest edge**, plus one 3pt gap. **Never centre it** — re-centring moves every other tab out
  from under the pointer, so the tab you meant to click next is somewhere else. If already fully
  visible, nothing scrolls.
- **Edge fade:** 24pt linear fade to `sidebar`, present on a side only while content remains that
  way, cross-fading over 120ms, non-interactive so the tab beneath stays clickable. **This is the
  only overflow affordance** — no count pill, no chevron, no menu.
- **Truncation:** only when one name alone exceeds 220. Then middle-elide the basename and keep the
  extension whole — `improving-onb…rate.md`. Head says what it is, tail says which one; tail
  truncation makes `Untitled 4` and `Untitled 5` identical. Two tabs that would still render the
  same label get the minimal distinguishing parent folder, applied only to those two. Ellipsis is
  U+2026, never three periods.
  **The app computes the elided string.** Never leave the label to the framework's default tail
  truncation — that can only clip the tail and would append a second ellipsis to an already
  middle-elided string, taking the extension with it.
- **Close:** a 9pt semibold `xmark` in a 16 round target, `ink2` → `ink` with the `hover` fill under
  the pointer. It takes the glyph's place while the pointer is over the tab, as Safari's does, active
  or not, and VoiceOver reaches it as the tab's named action. A pinned tab has none. ⌘W closes the
  active tab.
- **Pinned:** sits left of the unpinned run and scrolls with everything else. Pinning is about order
  and session persistence, not about staying on screen.

Do not add compression tiers, width floors, condensed icon-only chips, least-recently-used overflow
lists, hidden-count pills or overflow menus. They are several mechanisms for what one scroller does,
and they share one defect: the tab you were reading changes size or vanishes because you opened
something unrelated.

### 10.4 Sidebar

Width 240 on a first window, 196 at least. Header 40: the workspace **monogram** (the name's initial,
10.5/600 `onaccent`, on an 18 `accent` tile of radius 6) in the rows' glyph column, the name 13/600 on
their text edge and a 10 `chevron.down` beside it, which open the workspace switcher; then Search
Workspace and New Markdown, two regular icon buttons 2 apart. · row 28 · list inset 10, 4 above the first row · no gap between rows · 14 indent
per depth · disclosure chevron 10 · Recents group · footer row 28, Settings only, with no rule above
it. The sidebar is part of the frame: `chrome`, no edge line.

Rows are the **row primitive** (§0), on purpose.

**One glyph per row.** A folder's disclosure chevron (10pt, nudged per §8.6, turning 90° over the
hover duration, instantly with Reduce Motion) sits in the 18pt glyph column, and folders carry no
folder glyph. Files use `doc.text` / `doc.richtext` / `photo` / `play.rectangle` in the same column.
Names at one depth therefore share a left edge, and a child steps right by exactly the 14 indent.

Label 13/400 at `ink2` and glyph at `ink3` at rest — the same ladder as tabs, menus and Settings —
both `ink` on hover or press; the selected row's label is `ink` and its glyph (a file's kind glyph,
a folder's chevron) `accent`, on the `selected` fill (§1.3, §1.4). An unsaved file carries the tab's
dot on its glyph (§10.3). Quiet Sidebar takes a fifth off each opacity, once, never below 52% light /
48% dark.

**Find in Workspace** replaces the tree in the same column and keeps its geometry: the title where the
header's name sits (18 from the edge), its close button where the header's last action sits, the
query field in the 10 inset, then rows of the primitive — Replace, each file (its kind glyph and name
at 13/400, its folder in 12 `ink3`, its count) and each match (its line number right-aligned in at
least the glyph column, so short numbers put the match on the file's text edge). The status line puts
its spinner in the glyph column and its text on the text edge. A hairline inside the inset separates
the controls from the results.

**The workspace switcher** is a popover menu, 340 wide (§0): a group header, then menu rows — each
workspace with its path in 12 `ink3` and its ⌃⌘ number (Remove, a small button, replaces the number
under the pointer), the open one the current row with the `accent` `folder.fill` — a separator, Add
Workspace… and Manage Workspaces…. Labels are `ink`, glyphs `ink2`, as in the editor's menus. Find in
Workspace's Replace scope is a pop-up (§5.3).

**Selection.** The tree has one selection, as in Finder: a folder, or else the open document. Clicking a
folder selects it, opens or closes it and gives the tree keyboard focus, without closing the open
document. Clicking a file opens it; a document shown for typing (Markdown in Source or Preview, text,
or a source beside its preview) takes keyboard focus, ready for typing, while any other file (an image, a PDF, video,
audio, a preview) leaves focus in the tree, so ⌘C, ⌘X and ⌘V act on it. New Markdown, New File, New Folder and Paste put items in the
selected folder, or the selected document's folder, or the root when nothing is selected; a row's context
menu acts on that row, and the empty tree's menu and Finder drops on empty space on the root. While the
tree has focus, ⌘C, ⌘X and ⌘V copy, cut and paste the selection, Return renames it, ⌘D duplicates it and
⌘⌫ moves it to the Trash, once per press however long the key is held; with the editor, terminal or a
field focused those keys stay theirs. A created
or pasted item is selected and its folder opens; files pasted or dropped in from elsewhere open their
folder. The selection follows a rename or move, moves up to the nearest remaining folder when its folder
is removed outside Monknot, and clears when the workspace changes; open folders stay open when renamed
or moved. Nothing is selected after the selection goes to the Trash, or after the open document leaves
the workspace: the tab beside it shows, as when its tab closes, but the tree selects it only once the
user picks it.

**Row menus.** Folder and file rows start with New File and New Folder (in the folder, or beside the
file), then Rename and the location items, then Copy, Cut, Paste and Duplicate, then Move to Trash.
Paste is enabled only while the clipboard holds something to paste. Dragging a row moves the item, and
holding Option as the drag ends copies it, as Finder does.

**Recents** is a collapsible group between the tree and the footer: the chevron in the glyph column, a
group header (§4.3) and a trailing count in 12 `ink3`. Its entries are file rows one level in, whose
menu is Open and the file row's location items, and they follow a rename or move. It never
grows past a third of the sidebar; the tree keeps the rest. It is a jump list and never marks a
selection.

**Dividers** (sidebar and terminal alike). Dragging a divider past half a pane's minimum closes that
pane. A drag that pushes the *opposite* pane below its minimum closes that pane too, as the user's
choice. Narrowing the window is not a drag: it may squeeze a pane closed, and widening the window
brings it back. A divider drag never opens the opposite pane, whether the drag pushed it out or the
window squeezed it: when the drag ends, a pane that is out of the layout is closed and reopens from
its toolbar button, so a pane and its toolbar button always agree.

**Toolbar buttons always act.** When the window cannot fit the document and both side panes, the pane
shown last stays and the other steps aside: its button reads closed, and it returns on its own once the
window is wide enough or the pane that displaced it closes. With no sidebar, the terminal shows at its
minimum beside the document's minimum; if even that does not fit (high zoom in a small window),
the button beeps rather than doing nothing.

### 10.5 Outline rail

A right-edge dash rail, always present, no toolbar button. Dash length encodes heading level: **22 /
14 / 9**, thickness 2, radius 2. Current section is `accent`, others `ink3`.

Hover reveals a soft hit target plus a floating peek card (radius 12, `e2`, fadeUp entrance). It is a
**scroll map**, not a list — it maps the whole document at every zoom.

### 10.6 Terminal panel

The terminal sits on its own card (§10.0), on the document's `surface`. Its header is the card's bar
(`MonknotBar`): 40 tall, 6 padding, no divider. Expand, New Terminal and Hide Terminal Panel are
regular icon buttons 2 apart, set 8 from the session scroller and outside it, so adding a session
never moves them.

**Sessions are tabs** (§10.3, inside a card): 28 tall, hugging a `terminal` glyph and the session's
number in 13/400, the active one on the `selected` fill. **No session name** — four tabs all reading
"zsh" identify nothing. The number is what tells them apart.

Run state tints the glyph, the only coloured element in the header:
`ok` running · `accent` awaiting input · `ink3` idle or exited 0 · `danger` exited non-zero.

Close kills the session: the tab close button takes the glyph's place under the pointer, as on a
file tab. The strip scrolls like the tab strip, mouse wheel included, with the same 24pt trailing
fade; being clipped by the panel edge is correct.

**The screen belongs to the session.** Hiding the panel or switching sessions keeps the scrollback,
the alternate screen, mouse modes and the scroll position exactly as the program left them. A program
that reports the mouse (Claude Code, vim, less) scrolls as far per wheel flick as plain output does.
The scroll bar is the shared thumb (§5.7) at its resting strength.

The header order is session scroller → fullscreen → new session → close panel, set apart by space.
Fullscreen is the regular button with the diagonal arrows (14 optical): they point out when docked
and in when expanded. The control temporarily covers the
document area while leaving the titlebar and left sidebar in place. The
document stays mounted, the terminal divider is disabled, and the button shows its state by its
arrows alone (§1.3). Restoring returns to the exact pre-expand terminal width. Closing the
panel clears fullscreen, so reopening uses the docked width. ⌃⌘↩ toggles fullscreen; Escape does
not.

### 10.7 Scale table — every box and glyph at 1×

Glyph size and box size are two different numbers and both are fixed. **A glyph is never sized to
fill its box.** If an icon looks small, that is correct — macOS chrome glyphs are 15–17pt, never 20+.

| Region | Metrics |
|---|---|
| Frame | gaps 6 · cards radius 12, `cardring` 1 · card top 7 below the tab chips |
| Titlebar | bar 44 · traffic light 12 · icon button 28 box / 17 glyph, no border · segmented 28 outer (24 cells + 2 padding on a track) / 16 glyph · items 2 apart, groups 8 · strip inset 3 · 3 between tabs |
| Tab | 28 · padding-x 10 · kind glyph 15 in the 18 column · gap 8 · label 13/400 · close 9 in 16, in the glyph column on hover · unsaved dot 6 on the glyph · pin or warning badge 10 · max width 220 · no minimum |
| Bar | 40 · padding 6 · 28 controls 2 apart, groups 8 apart · no rule (terminal, PDF, panel headers) |
| Sidebar | width 240 (196 minimum) · header 40: monogram 18 (radius 6, initial 10.5/600), name 13/600, chevron 10, search and New Markdown 28/17 · row 28 · padding-x 8 · disclosure chevron 10 or file glyph 15 in the 18 column · gap 8 · label 13/400 · indent 14 · list inset 10, top 4 · no gap between rows · Recents header: chevron, group header, count 12 · footer 28 |
| Menus | popover 340 (switcher) · list inset 6 · row 30 (34 in an overlay) · glyph 15 in 18 · gap 10 · label 13 `ink` · detail 12 `ink3` · group header 12 `ink3` · separator `line2` 4 inside the inset · overlay header 44, footer 32 |
| Preview editing | format bar: 28 buttons / 17 glyph, 2 between, 4 padding, dividers 1×16, block selector label 13 with an 11 `chevron.down` · menus: width 272 (232 for Turn Into, callout kinds, table actions and languages), list padding 6, row 30 / 15 glyph (or a 12/600 `H1` tag) in the 18 column, gap 10, label 13 on a 1.35 line, hint 12 rounded `ink3`, section header 12 `ink3` sentence case, footer 32 with 12 `ink3` actions and 12 rounded `ink3` keys, submenu chevron 11, at most 380 tall; a menu of plain names (languages) has no glyph column · handles: + 22×24 and grip 18×24, radius 6, 1 apart, `ink3` at rest and `hover` fill with `ink2` on hover, 6 left of the block (left of the marker for a list item), centred on its first line · drop line 3 tall, radius 2, caret colour at 70 % · tooltip 12 on 1.45, inverted surface, padding 8 × 5, radius 6 · link editor: field 28, width 340 · code language label 22 tall / 12, top-left · all on radius 12 surfaces, rows radius 8 |
| Terminal | the bar (40) · session tabs 28, hugging glyph + number · Expand, New, Hide 28/17 |
| PDF | the bar (40): navigator 28/17, page count 12 tabular · undo, redo · modes segmented · markup actions · style pop-up · zoom pop-up · save with the unsaved dot · navigator: header 40, segmented 28, rows 28, 14 per level |
| Elsewhere | field 28 · push button 28 bars / 30 sheets · small icon button 22/13 · toggle 32×18, knob 14 · stepper 28 · slider track 4 / knob 16 · colour well 44×22 · overlay row 34 · Settings row ≥ 40, padding 12 × 8 · outline dash 22/14/9 × 2 |

**Hard ceilings.** No chrome glyph over 17. No square button over 28. No row over 34. The only glyphs
above 17 anywhere are empty-state illustrations at 34, which are not controls.

### 10.7a PDF and image bar

The PDF's card opens with its bar (`MonknotBar`, 40, no rule): the navigator toggle and the page
count (12 `ink3`, tabular, as wide as any page of the document); Undo and Redo; the tools that stay on
— Select, Draw, Erase, and for an image the area Highlight — as one segmented control; the markup
actions (Highlight, Underline, Strike Through Selection, Add Text Box) as icon buttons; the current
tool's style, a pop-up showing its colour swatch (with Stroke Width… while drawing) or, for a
selected text box, Text Style; then, outside the layouts so they never move, the zoom pop-up and Save,
disabled while clean and carrying the unsaved dot (§1.3) when not. Groups sit 8 apart, nothing is
`accent`, and nothing is ruled.

Narrower, the bar folds rather than wraps: first Undo and Redo move into More (`ellipsis`, a menu
button), then the modes and markup actions become one tool pop-up. The pages sit on the card's
surface tinted by the `track`, so a white page stands off it; the navigator sits on the surface, its
divider `line2`, its lists chrome rows with the neutral selection.

### 10.8 Images

Raster images (PNG, JPEG, GIF, HEIC, TIFF, WebP, BMP, ICO, AVIF) are workspace documents and open
in the PDF viewer, the way Preview marks up images: one page that draws the file's own pixels, never
a recompressed copy. An image opens whole, at no more than its actual size; a Retina screenshot
shows at the point size it was taken at.

The toolbar is the PDF toolbar without what belongs to pages: no page counter, no navigator, no
text-markup buttons. An image has no text to select, so its **highlighter drags out an area**; the
pen, text box, eraser, colours, undo and zoom are the PDF's own.

Until it is saved, markup is kept apart from the file. **⌘S draws it into the image in the image's
own format** (a PNG stays a PNG), and the image reopens from what was written. Formats ImageIO cannot
write (WebP), animations, and images deeper than 8 bits or neither RGB nor gray open read-only: the
tools are disabled, zoom still works. An animation shows its first frame. SVG is source and opens in
the text editor.

### 10.9 Video and audio

Video and audio that AVFoundation plays (MOV, MP4, M4V, MPEG, MP3, M4A, AAC, WAV, AIFF, CAF, FLAC)
are workspace documents, listed by extension and never read until they open. They play in AVKit's
own player with its standard inline controls; Monknot draws no controls of its own. A video keeps
its proportions inside the pane with the theme's `surface` around it, never letterbox bars. Audio
has no picture: the empty-state layout (§5.7) with a `waveform` glyph and the file name sits above
AVKit's control bar, 360 × 48 with radius 8.

Nothing plays on its own. Space plays and pauses while the player has focus. The player belongs to
the visible tab: switching or closing the tab, or closing the window, stops playback and releases
the file. A file that is missing or cannot be played shows the empty-state layout (§5.7) with a
warning glyph, the way a damaged PDF or image does. AVI and other containers AVFoundation does not
reliably play are not listed.

### 10.10 Editing in Preview

Preview is where most writing happens: an editable Markdown document is edited in place, in the same
rendering PDF export uses, with the same writing assistance as Source (below). Source stays the place
for raw Markdown and for Writing Tools; beside Source the preview is read-only, so one document never
takes typing in two places.

**The Markdown file is the document.** The page is a rendering of it, and every edit on the page —
typing, Return, Delete, a menu, slash command or drag, paste, a checkbox — becomes one text patch on
the source. Nothing is converted back from HTML, so Markdown the editor does not render (HTML, comments,
front matter, unusual syntax) is kept byte for byte, and text outside the patch never changes. A
format applied to a selection rewrites only the markers of the words it touches.

**What the page shows.** Everything in the file is visible and reachable: blank lines beyond the one
that separates blocks are empty lines the caret can sit on; a divider draws as a `line` hairline;
reference and footnote definitions, and tables with more cells than their header, show as written in a
quiet code-face block. Markers (`**`, `#`, `>`, `- [ ]`) are never shown; typing them still works — `# `,
`- `, `1. `, `[] `, `> `, three backticks and three hyphens turn the line into that block.

**Selection and caret.** Typing at the end of bold or italic text continues it, as in every text editor;
typing at the edge of a link does not extend the link. Editable text shows its spaces as typed: a space
at the end of a line draws at once and the caret moves past it, and runs of spaces keep their width
(Markdown would collapse both, so the space key would seem to do nothing). While editing, a heading
keeps spaces typed at its end, and a table cell shows a typed space beyond the one space of padding
before its pipe. Undo restores the selection a change started
from. Switching between Source and Preview keeps the selection, and Preview's undo history survives
the switch; an undo that no longer fits the text (it changed in Source) beeps instead of applying.

**Blocks.** Preview offers Notion's block set, less what a Markdown file cannot hold (databases,
columns, synced blocks, embeds). Every block is plain Markdown another editor or GitHub reads:

| Block | Markdown | On the page |
|---|---|---|
| Text, Heading 1–3 | paragraph, `#`–`###` | the type scale of §4.3 |
| Bulleted, Numbered, To-do list | `-`, `1.`, `- [ ]` | markers per level as in Notion (• ◦ ▪, 1. a. i.); every item's text on one edge, a to-do's box (1 em, radius 0.25 em, 1.5 pt ring of `ink` at 42 %; checked: `accent` fill with an `onaccent` tick, text `ink` at 45 %, struck) in the marker's place |
| Toggle list | `<details>` · `<summary>title</summary>` · blank line · body · `</details>` | a triangle in the marker column that turns 90° when open; title and body on the list text edge. Opening is a view state: the file keeps its `open` attribute. A new toggle opens. Without `</details>` it runs to the end, as HTML closes it |
| Callout | `> [!NOTE]` (TIP, IMPORTANT, WARNING, CAUTION) | a 7 % tinted panel, radius 8, its kind as a 0.875 em / 600 title; clicking the title changes the kind |
| Quote | `>` | a 2 pt bar of `ink` at 28 %, no fill |
| Table | pipe table | hairline grid, a `soft` header row on a light page and `soft-strong` on a dark one, no zebra rows |
| Divider | `---` | a `line` hairline |
| Code | fenced block | `code-bg` panel, radius 8, no border; language label top-left |
| Page | a new `Name.md` beside this note, linked here as `[Name](Name.md)` | a link |
| Link to page | `[[Title]]` | the wikilink menu |
| Image, Video, Audio, File | `![…](…)` for media, `[…](…)` for a file, through the drop import | an image, a player, a link |
| Web bookmark | `[host/path](url)` | a link |
| Table of contents | `[TOC]` | the top-level h1–h3, indented by level, each scrolling to its heading; redrawn as headings change |
| Date, Emoji | today's date as text; the system character palette | text |

**Surfaces.** All are floating (§2), radius 12 with `e2`, rows radius 8, and never move the text:

| Surface | Appears | Contents |
|---|---|---|
| Format bar | text selected with the pointer or keyboard, centred above the selection (below when there is no room) | Turn Into selector (the block's name and `chevron.down`) · bold, italic, strikethrough, inline code · link |
| Slash menu | `/` at the start of a text block — an empty line, heading or list item. Never after text, in code, a table cell or a toggle title, so a `/` in a sentence stays a slash | the blocks above in Notion's sections (Basic blocks, Media, Advanced blocks, Inline), filtered by what follows the `/`; the Markdown to type instead as a trailing hint; a footer: `↑↓` Choose `↩` Insert `Esc` Close |
| Block handles | the pointer over a block, in its left gutter; gone while typing | + (a new line below with the slash menu open on it; ⌥ above; Esc takes the line back) and the grip (drag to move; click for the block menu). A tooltip after 450 ms names both gestures |
| Block menu | a click on the grip, or ⌘/ at the caret | a search field, Turn into ›, Duplicate ⌘D, Copy, Move up ⇧⌘↑, Move down ⇧⌘↓, Delete; the block it acts on is tinted with the selection colour while it is open. Typing in the field lists the Turn Into targets too |
| Turn Into | the block menu's row (hover, → or ↩) or the format bar's selector | Text, Heading 1–3, the three lists, Toggle list, Code, Quote, Callout, the current one checked; beside the menu, aligned to its row |
| Callout kind | a click on a callout's title | Note, Tip, Important, Warning, Caution |
| Wikilink menu | `[[` in text, not in code | the workspace's Markdown notes by title, each with `doc.text`, filtered and ordered as Source's ⇥ completion (up to 12); "No matching pages" when none do, closing once the query passes three characters; ↩ or ⇥ replaces `[[` and the query with `[[Title]]` in one patch, caret after it, its own undo step "Insert Link"; `]`, `\|` or moving the caret out closes it |
| Link card | caret inside a link | the address in 12 `ink2`, Open, Edit, Remove |
| Link editor | ⌘K, Link in the format bar or card, Web bookmark, Page | one field (an address, or the new page's name); ↩ applies, Esc cancels and restores the selection |
| Table bar | caret in a table, above it, left-aligned | Row and Column menus, Delete Table |
| Code language | a code block's top-left label, 12 `ink3` | a searchable language list |

Menus follow the row primitive: the keyboard and the pointer move one highlight, a `highlight` fill
with `ink` label and glyph — neutral, so a menu over selected text never reads as a second selection.
↑/↓ or ⌃P/⌃N move it, ↩ or ⇥ chooses, → opens a submenu and ← or Esc closes it, Esc closes and keeps
the typed text. Section headers are sentence-case captions, not eyebrows. A menu above its anchor
stays attached by its bottom edge while filtering shrinks it; only the list scrolls, never the page.
Buttons and handles never take focus, so the text selection survives every click. The caret's cell
in a table carries an inset `ink3` ring; placeholders are `ink` at 32 %: "Type / to insert a block"
on the empty line holding the caret, the heading level on an empty heading, "List", "To-do" and
"Toggle" on empty items and titles, "Empty toggle" in an open toggle with nothing in it.

**Moving blocks.** A handle belongs to a top-level block (a quote, callout, toggle or table moves
whole) or to a list item with the items nested under it. Dragging fades the block to 35 %, carries an
80 % copy on the page colour (hairline ring, soft shadow, 8 pt of padding outside the block's own
edges so its text stays under the pointer) that fades out at its cut edge only when the block is
taller than 160 pt, draws a 3 pt line in the caret's colour at the nearest gap (between
top-level blocks, or between the items of the item's own list) and scrolls the page near the window
edge; Esc cancels. A drop where the block already is does nothing. The move is one patch and one undo
step ("Move"); blocks keep their own lines, a blank line goes on each side, ordered markers stay in
their places, and the moved block flashes the selection tint for 900 ms.

**Keys.** ↩ splits a block or starts the next list item; on an empty item or an empty last quote,
callout or toggle line it leaves the list, quote or toggle. ↩ in a toggle's title goes into its body
when open (onto its empty first line, or a new one) and past the toggle when closed. ⇧↩ breaks the
line inside a paragraph. ⌫ at the start of a heading, item or quote removes that formatting first,
then joins with the block above; a nested item steps out a level before it loses its marker, and an
item or heading made into text (by ⌫ or Turn Into) gets a blank line on each side, so Markdown never
reads it as more of the item or paragraph above; at the start of a callout's text it makes the callout a quote; at the
start of a toggle's title it unwraps the toggle into a paragraph followed by its body. Text never joins
across a toggle's edge, so its markup cannot break; ⌫ or ⌦ there moves the caret instead. ⌫ after a
divider or table of contents deletes it. ⇥/⇧⇥ indent and outdent list items, move between table cells
(adding a row after the last) and indent code. ⌘↩ leaves a code block. ⌘/ opens the block menu, ⌘D
duplicates the block, ⇧⌘↑/⇧⌘↓ move it. ⌘B ⌘I ⌘E ⇧⌘X ⌘K and ⌥⌘0–6 format. ⌘-click opens a link.

**Clipboard.** Copy puts the selection's Markdown on the pasteboard as plain text (markers balanced at
cut emphasis) and its rendering as HTML, so a paste into Mail stays formatted and a paste into Source
stays Markdown. Pasted HTML becomes Markdown; pasted code goes in as text; a pasted image is saved
into the workspace and linked.

**Writing assistance.** Typing in Preview gets Source's writing assistance, run by
`MarkdownPreviewFlowCoordinator` on the Markdown source and the caret's source offset: the same
sentence planner, macOS checker, Apple Intelligence models and repair decisions
(`EditorFlowRepairPolicy`), under the same four settings. The app decides; the page draws what it is
sent, inside the text as non-editable spans the caret never enters, and anything taken reaches the file
as one source patch and one undo step, after the app has checked that the text it changes is still the
text it checked. Nothing is inserted that was not on screen. As in Source, nothing is checked, repaired
or completed inside code, link addresses, URLs, HTML, front matter or a table's pipes (a link's text is
prose). Preview also leaves table cells alone: a sentence in a cell starts in another cell, so its
review could not be drawn.

| Case | When | On the page | Keys |
|---|---|---|---|
| Certain fix | a sentence ends (`.` `!` `?` or ↩) and, 0.82 s later, Apple's checker resolves everything it finds in it to exact spelling or punctuation fixes | applied at once; the changed words take the mark, rising to its peak in 220 ms and settling over the rest of a second; `⌫ undo` sits at the caret until the next key, click or caret move, except on an empty line (after ↩) | ⌫ takes it back while `⌫ undo` shows ("Accept Flow Correction", or "Fix N Flow Issues"); where it does not show, or the fix can no longer be taken back, ⌫ deletes as usual |
| Reviewed repair | a grammar fix that changes words, a spelling fix that drops letters, a choice between Apple's alternatives, or Apple Intelligence's repair of the sentence (always reviewed, and only after Apple's checker finds the repaired sentence clean) | the corrected words in place of the originals, on the mark, the rest of the sentence keeping its formatting; `⇥ apply · → next · Esc dismiss` after the sentence | ⇥ applies once the review has been drawn; → shows the next alternative; Esc dismisses it for that sentence; one space right after the sentence keeps it; any other key drops it |
| Completion | On-device writing assistance and Inline predictions on, the model available, two words or more before the caret, the rest of the line empty, and the sentence checked clean | up to eight words after the caret in `ink` mixed 54 % (light) or 42 % (dark) toward `accent` at 68 %, fading in over 180 ms; `⇥ word · hold for all` after them | a tap on ⇥ takes the next word (the rest returns once the sentence checks clean); ⇥ held 350 ms takes it all and its repeats insert nothing; typing what it shows consumes it; Esc or any other key dismisses it ("Accept Flow Word", "Accept Flow Completion") |

The mark is `accent` mixed into `surface` at 18 % (24 % dark; 28 % and 34 % with Increase Contrast),
peaking at 34 % (44 % dark), a radius-2 mark reaching 2 pt past the glyphs without moving them. Keys in
a hint are §4.4 key caps on `surf3` in 12 rounded `ink`, with a slimmer 6 × 2 padding inside a text
line, each followed by its action in 12 `ink2`; groups 11 apart, 10 after the text. VoiceOver hears
each suggestion and fix as in Source.

A suggestion shows only for the text, caret and focus it was made for: never while a menu, the link
field or a composition is open, never once the sentence has scrolled out of view (a completion must fit
on screen whole), and it goes with any edit, click or caret move. While a menu or the link field is open
nothing is checked and the models are asked nothing; when it closes without an edit (Esc), the sentence
at the caret is checked again. Tab keeps its own meanings — indent a
list item, move between table cells, choose in a menu — whenever nothing is shown, and an open menu
takes the keys first. Check Spelling While Typing also sets the page's `spellcheck`, so WebKit's own
spelling marks follow it. Edit › Check Document Now (⌘;) checks the sentence before the caret at once,
as though it were finished; Edit › Show Writing Tools (⌃⌘R) switches to Source and opens them there,
because Writing Tools rewrite text in place and the page changes only through source patches.

System inline predictions stay off in Preview (`WKWebViewConfiguration.allowsInlinePredictions` is
false). The switch is fixed for the web view's life and WebKit then shows and commits predictions
itself, so the editor could keep them neither out of code, links and the other protected Markdown
where Source turns them off, nor out of the way of its own completion. With On-device writing
assistance on, Preview offers its own completion instead; Source never shows the two at once either.

**Performance targets**, measured in WebKit by `MarkdownVisualEditorTests`:

| Measure | Target | Measured |
|---|---|---|
| Keystroke, 50 KB note, handler | p95 ≤ 4 ms | ≤ 1 ms |
| Keystroke, 1 MB document, including layout | p95 ≤ 16 ms (one frame) | median 5–8 ms, p95 8–9 ms (most of it WebKit laying out the caret) |
| Source re-parsed per keystroke | the edited blocks only | resynchronises at the next unchanged block |
| Render of a 1 MB document | within 10 % of the read-only preview | ~100 ms in JavaScriptCore |
| Opening a 1 MB document editable | ≤ 1 s | 0.6–0.9 s |

**Motion.** A surface the pointer opens (the block menu and Turn Into, the callout and language menus,
the table menus, the format bar after a mouse selection) grows in from its trigger: scale 0.97 → 1
with opacity over 150 ms, `cubic-bezier(0.23, 1, 0.32, 1)`, origin at the side that faces the anchor.
A surface the keyboard opens (the slash and wikilink menus, ⌘/, ⌘K) appears at once — typing is
never made to wait for an animation. Everything leaves in 90 ms. Handles fade 120 ms; the toggle
triangle turns in 180 ms ease-out; a pressed button or handle scales to 0.96. Only transform and
opacity animate, with one exception shared with Source: the mark on a fix just applied rises and
settles over a second, and words a completion inserts fade from a tint over 520 ms (a dead key or input
method used meanwhile takes the tint off at once, and nothing drawn changes while it composes). With Reduce Motion
nothing scales, entrances are a 120 ms fade, the moved-block flash is off, and a fix's mark holds still
at its settled strength. Nothing animates while typing.


### 10.11 The document column

Source and Preview set text in one column, so switching view mode never moves a line sideways.

**Width.** The column is the Content Width setting's share of the pane, up to a comfortable line
length: 640 pt of 13 pt text at the default 88 % (about 80 characters of the code face, 90 of the
14 pt prose), growing with the font size and zoom and scaled by the setting, so on a wide window the
setting chooses the line length and on a narrow one its share of the pane wins. At 100 % there is no
measure: the column fills the pane. `DocumentMeasure` holds the numbers for both modes.

**Edge.** Both modes centre that width: Source's first glyph and Preview's sit on the same x, to
the point. Preview's gutters (and the block handles' 44 pt) lie outside the column, never inside it.

**Contents.** Callouts, code blocks and quotes span the column; a table is as wide as its columns
need (6 em at least each), wraps its cells before it grows past the column, and scrolls sideways only
for what cannot wrap. PDF export keeps its own page width.

**Word count.** It sits in the bottom-trailing corner only while the margin beside the column holds
it (112 pt at 1×); a narrower pane hides it rather than letting it cover text.

---

## 11. Motion

- **120ms ease** on hover: fill and foreground colour only.
- **180ms standard ease** for terminal fullscreen: width only, with no fade or scale.
- **250ms ease-in-ease-out** for showing and hiding the sidebar and terminal, from the toolbar, the
  menu or the keyboard alike: AppKit's own split-view transition, opening and closing alike. The
  pane's content keeps its open width and slides under the window edge, so rows never squeeze and the
  terminal is not resized frame by frame. The document beside it takes its final width once, at the
  start, pinned to the edge that does not move, and the pane clips it as the divider slides: a web
  view's text and scroll bar move with the divider instead of re-laying out, late, on every frame.
  Any change of width keeps Preview's reading position: the block at the top of the window stays put.
- **fadeUp** for overlays, toasts and the outline peek card (120ms, 4pt). Preview's editing surfaces
  have their own rule (§10.10): grown from the trigger when the pointer opens them, instant from the
  keyboard.
- Never animate size, position, elevation, border or weight except for the explicit terminal
  fullscreen width transition and the side-pane transition above.
- Honour Reduce Motion: entrances become instant opacity changes and side panes show and hide
  instantly; hover colour transitions may stay.

---

## 12. Settings

Instant apply plus **Revert**. No Save button — a Save button in a preferences window implies the
change has not happened yet, which is false in every macOS app since 10.7.

The window uses the main window's frame (§10.0): categories on `chrome`, the page on a card inset 6
from the trailing and bottom edges. Category rows are the sidebar's rows (§10.4) in the 10 list inset,
12 below the titlebar: 28, a 15 glyph in the 18 column, a 13/400 label at `ink2`, the selected one on
the `selected` fill with an `accent` glyph.

A page pads 20 at the sides, 16 above and 24 below. Groups are the control `track`, radius 12, no
border; a row is at least 40 tall with 12 × 8 padding, its label 13 `ink` with an optional 12 `ink3`
line under it, the control trailing, and a `line2` separator inset 12. Group headers (§4.3) sit 18
above their group (none at the top of a page) and 8 above it; an accessory such as Revert sits on the
header's line without moving it. The controls are the app's own: segmented control (§5.5), pop-up
(§5.3), toggle, stepper, slider, field and colour well (§5.7), push buttons 28. File › Export PDF uses
the same rows and controls as Settings › Export, at the workspace zoom.

The window is 600 × 560 at 100% and scales with workspace zoom, never past the screen's visible area;
its pages scroll vertically inside it. A menu button is as wide as its longest option, so previewing
options never resizes it.

---

## 13. Writing and content

- Soft equal-fill banners for warnings, not danger borders. `dangersoft` fill; `dangerline` border
  only when the message is genuinely destructive.
- Short captions over before/after grids.
- No emoji. No decorative gradients. No icon-plus-coloured-left-border cards.
- Copy is matter-of-fact and specific. Say the number, not "optimised spacing".

---

## 14. Applying a `codex-theme-v1` string

Themes arrive as `codex-theme-v1:` followed by JSON. Parse it, map it onto the six inputs, then run
the §1.2 derivation. Nothing else in the app changes.

```json
codex-theme-v1:{"codeThemeId":"absolutely","theme":{
  "accent":"#cc7d5e","contrast":40,
  "fonts":{"code":"\"SFMono-Regular\"","ui":"Geist, Inter"},
  "ink":"#2d2d2b","opaqueWindows":true,
  "semanticColors":{"diffAdded":"#00c853","diffRemoved":"#ff5f38","skill":"#cc7d5e"},
  "surface":"#f9f9f7"},"variant":"light"}
```

**Mapping**

| JSON | Input |
|---|---|
| `theme.surface` | `surface` |
| `theme.ink` | `ink` |
| `theme.accent` | `accent` |
| `theme.semanticColors.diffAdded` | `ok` |
| `theme.semanticColors.diffRemoved` | `danger` |
| `theme.semanticColors.skill` | `skill` |
| `theme.fonts.ui` | UI font stack, ahead of the SF Pro fallback |
| `theme.fonts.code` | mono stack |
| `variant` | **advisory only** — verify against measured luminance |
| `contrast` | ink-ladder scalar, see below |
| `opaqueWindows` | `true` → solid `surface`; `false` → `NSVisualEffectView` behind chrome, tokens unchanged |
| `codeThemeId` | syntax highlighting only; never affects chrome |

**`variant` is advisory.** Always compute `dark = relativeLuminance(surface) < 0.45` and use that.
Here luminance is 0.946 → light, agreeing with the string. When they disagree, the measurement wins.

**`contrast`** (0–100, default 40) scales the ink ladder's floors only: `ink2` starts at
`72% × (0.85 + contrast/100 × 0.375)` and `ink3` at `50% ×` the same factor, and both still rise until
they read (§1.2). `ink`, `ink4` and `surface` never move — contrast adjusts the legibility of secondary
text, it does not push the extremes. At the default 40 the factor is 1.0 and the ladder is exactly
§1.2; Settings › Appearance › Contrast sets it (`AppTheme.inkLadderContrastFactor`).

**Fonts.** `Geist, Inter` is a *substitution*, not a redesign. Every size, weight, ratio and metric in
this document is unchanged — Geist's cap height is close enough to SF Pro Text that the
15pt-glyph-to-13pt-label ratio still holds. Do **not** re-derive proportions for a new font. Keep
`-apple-system` / SF Pro at the end of the stack so the app still looks native if Geist is missing.

### 14.1 Derived tokens for this exact theme

Computed, not chosen — check any implementation against these:

```
bg        #f9f9f7        line      ink @ 12%   rgba(45,45,43,.12)
sidebar   #f3f3f1        line2     ink @ 8%    rgba(45,45,43,.08)
surf2     #efefed        frame     ink @ 9%    rgba(45,45,43,.09)
surf3     #e7e7e5        hover     ink @ 5.5%  rgba(45,45,43,.055)
ink       #2d2d2b        press     ink @ 10%   rgba(45,45,43,.10)
ink2      rgba(45,45,43,.62)
ink3      rgba(45,45,43,.40)      accent    #cc7d5e
ink4      rgba(45,45,43,.24)      onaccent  #ffffff   (accent lum 0.283 ≤ 0.5)
                                  sel       #f0e0d8
ok        #00c853                 accsoft   rgba(204,125,94,.14)
danger    #ff5f38
skill     #cc7d5e

shadowHue #3d3530   = mix(ink → accent, 10%)

e1     inset ring rgba(45,45,43,.12)
e2     inset ring rgba(61,53,48,.08) + 0 4px 12px rgba(61,53,48,.08), 0 1px 3px rgba(61,53,48,.05)
e3     inset ring rgba(61,53,48,.08) + 0 16px 40px rgba(61,53,48,.14), 0 4px 10px rgba(61,53,48,.06)
win    0 16px 40px rgba(61,53,48,.14), 0 4px 10px rgba(61,53,48,.06) + outer ring rgba(45,45,43,.09)
bezel  0 1px 1px rgba(61,53,48,.05)
```

Two things to expect from this theme specifically. The warm terracotta accent puts `sel` at
`#f0e0d8` — a tinted surface, not a grey. That is correct: selection carries the theme's hue. And
because it is a **light** theme, `bezel` is live and `e1` is a ring with no shadow.

---

## 15. Review checklist

Before calling any UI work done:

- [ ] Every colour traces to the §1.2 derivation. No hand-picked values.
- [ ] Accent clears 4.5:1 against `onaccent`; `ink2` clears 4.5:1 and `ink3` 3:1 on `chrome` and
      `surface` (the derived ladder, §1.2).
- [ ] Accent appears in at most the six allowed places; no panel toggle lights up.
- [ ] No shadow on anything docked or at rest. Floating things cast in both modes.
- [ ] The frame is one `chrome` tone with no lines; the document, terminal and Settings pages sit on
      radius-12 cards with a `cardring` hairline, 6 from every edge and from each other.
- [ ] No button, segmented control, pop-up or tab has a border; fields keep their `line`; the one
      chip (active tab on the chrome, selected segment) has its `chipring`.
- [ ] Selection is the neutral `selected` fill, never an accent tint.
- [ ] `line2` only inside containers.
- [ ] One ring per boundary. No separate border on top of an elevation token.
- [ ] Active buttons have fill + glyph colour only, no accent ring; search options use the documented
      accent-glyph-only exception.
- [ ] Only weights 400 and 600. Nothing bolder when hovered, selected or focused.
- [ ] Radii are only 2/6/8/12/16/capsule. Child = parent − 4.
- [ ] Declared box sizes are outer sizes: a 28 button measures 28.
- [ ] Push buttons are 28 (bars) or 30 (sheets). No third height.
- [ ] Rows that hold the same kind of thing use identical numbers.
- [ ] Symbols sit in the 18pt column, tabs included, `.regular`, `.monochrome`, cap-height centred.
- [ ] Icon buttons are 28/17 in bars and 22/13 in rows and fields; no third size.
- [ ] Every bar below the titlebar is 40 with items 2 apart and groups 8 apart, and no rule.
- [ ] One scroll thumb (§5.7) on every surface: check documents with "Show scroll bars: Always",
      where WebKit would otherwise draw its own 17pt bar.
- [ ] No chrome glyph over 17. No square button over 28 (§10.7).
- [ ] Every metric derives from `workspaceZoom`. No `.scaleEffect`. Nothing clamped.
- [ ] Hairlines, shadows and focus rings do not scale.
- [ ] Tabs hug to 220 and scroll; fades appear only where content actually overflows.
- [ ] Terminal sessions are tabs showing glyph + number, never a session name.
- [ ] A divider's handle is `ink` 18 % / 30 %, never accent; chrome lists show a thumb only while they
      scroll.
- [ ] Hover animates colour only, 120ms.

---

## 16. Failure modes to check for by name

These are the mistakes this design language is most often broken by. Each has a specific visible
symptom, so they are worth checking deliberately rather than hoping to notice.

1. **`line2` used for a structural seam** — the sidebar edge disappears, because a docked pane has
   no shadow to fall back on.
2. **Inner box sizing on a bordered control** — 28 plus a 1px border renders 30, and the toolbar
   cluster stops reading as a set.
3. **A fixed width on a tab or pill** — it can no longer hug, so the cap and the truncation rules
   never engage.
4. **A fade with nothing behind it** — when strip content is narrower than its container, the fade
   advertises overflow that is not happening. Whenever you change an item's size, re-check content
   width against container width.
5. **Framework tail truncation over app-computed middle elision** — two ellipses, extension lost.
6. **A weight other than 400 or 600 surviving somewhere** — most often in a state style rather than
   the base style, so it only appears on hover or selection.
7. **Documentation describing a mechanism that no longer exists** — when you change a component,
   sweep for the *vocabulary* of the old model (its numbers, its part names), not just the phrase
   you remember writing.
8. **Fixing one instance and missing its siblings** — the same component usually appears in several
   places. Sweep by pattern, never by location.
9. **A rule promising a state nothing renders**, or a rendered state no rule covers — spec and
   implementation must agree in both directions.
10. **`.scaleEffect` for zoom** — soft text, smudged hairlines, hit rectangles in the wrong place.
