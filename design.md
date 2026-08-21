# Monknot — design language and UI rules

Authoritative reference for the Monknot macOS app (markdown, PDF and code editor). Read this
before implementing, refining or proposing any interface work.

Monknot is a **native SwiftUI/AppKit app**. Glyphs are **SF Symbols**. Type is **SF Pro Text** for
UI and **SF Mono** for code. Everything below is prescriptive: if a choice is not derivable from
these rules, it is not a Monknot choice.

The character to aim for is **calm, quiet, native macOS chrome** — closer to Finder and Xcode than
to a web app. Surfaces separate by tone and a hairline. Colour is scarce. Nothing moves that does
not have to.

---

## 0. Five principles

1. **One row primitive.** `30 tall · 10 padding-x · 15 glyph in an 18 column · 8 gap · 13 label`.
   File tabs, sidebar rows, menu rows, overlay results and outline peek rows are all this row.
2. **Depth is a property of the surface class, not the colour mode.** Docked never casts. Resting
   never casts. Only floating casts — in both modes.
3. **Two type weights.** 400 for all content, 600 for headings. Nothing is ever bolder for being
   hovered, selected or focused.
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
ink2      = ink @ 62%     label at rest
ink3      = ink @ 40%     glyph at rest, secondary text
ink4      = ink @ 24%     disabled

line      = ink @ (dark ? 9%  : 12%)    structural seams + control borders
line2     = ink @ (dark ? 6%  : 8%)     in-container dividers only
frame     = ink @ (dark ? 14% : 9%)     window rim

hover     = ink @ (dark ? 6%  : 5.5%)
press     = ink @ (dark ? 11% : 10%)

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

**Note the inversion on `line`.** Dark runs *lighter* (9%) than light (12%). Dark already has a
large luminance step between canvas and sidebar doing the separation, so the line only hints. Light
has almost no step — near-white on near-white — so the line carries the seam alone. Getting this
backwards makes light chrome look seamless and dark chrome look over-ruled.

### 1.3 Where accent is allowed — exactly five places

1. The active tab's kind glyph
2. The selected sidebar row's glyph
3. A dirty/unsaved dot
4. A toggle button whose panel is open, or a search match option that is on
5. The terminal glyph of a session awaiting input

Nothing else in the chrome is coloured. If a sixth use appears, one of these five gives it up.
Glyphs are **never** tinted by file type, folder colour or language.

### 1.4 Ink ladder

`ink4` disabled → `ink3` glyph at rest and secondary text → `ink2` label at rest → `ink` label or
glyph when its row is hovered or active.

Hover moves one step up this ladder **and** adds a `hover` fill. Selection moves one step up **and**
adds `sel`. Search match options are the one exception: their selected state uses an `accent` glyph
with no resting fill, so the option stays visually subordinate to the query field.

---

## 2. Depth — the surface class decides, not the mode

Assign the class first; the treatment follows mechanically.

| Class | What | Treatment |
|---|---|---|
| **Docked** | sidebar, titlebar, tab strip, inspector, status bar, panel headers | tone step + one `line` hairline. **Never a shadow.** |
| **Contained** | cards, grouped rows, fields, tab chips, composer, sidebar selection | `e1` — a 1px ring, nothing else, both modes. **Never a shadow.** |
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
| `line` | ink 9% dark / 12% light | **Structural:** sidebar, pane, titlebar, status-bar edges. **Control:** segmented shell, chrome icon button, field, secondary push button. |
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
- Around an active icon button — the fill does it.
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

- **400 (regular)** — everything the user reads as content: every row, tab, pill, field, button
  label, body and help text. Selected or not, hovered or not, focused or not.
- **600 (semibold)** — headings, group eyebrows, window titles.

No medium/500 anywhere in the chrome. No bold/700 anywhere at all.

### 4.2 Never bolder on

Hover · selection · focus · press · active · current.

A label that thickens on selection reflows its own glyphs by a fraction of a point, so the row
appears to twitch under the pointer, and running down a list makes the whole column breathe. It
also reads as a permanent property rather than a reversible state. If an item needs more presence it
takes a fill plus one step up the ink ladder — fill is a far louder signal than weight.

### 4.3 Sizes

| Role | Size / line-height |
|---|---|
| Document h1 | 22 / 1.2, tracking −0.02em, weight 600 |
| Row + tab + button label | 13 / 1 |
| Body prose | 13.5 / 1.6 |
| Secondary + caption | 12 / 1.4 |
| Eyebrow / group header | 10 / 1, tracking 0.09em, uppercase, weight 600 |
| Code, session numbers | 13 / 1.65 SF Mono (12 in pills) |

### 4.4 Shortcut labels

Standalone keyboard-shortcut metadata uses one shared **12/400 rounded system** label everywhere.
The rounded design keeps modifier symbols such as ⇧, ⌘, ⌥ and ⌃ at one optical height. Do not use
the monospaced code face or a smaller local font for these labels. The component has exactly two
presentations. A **quiet hint** uses `ink3` with no fill, border or padding. A **reference key cap**
in Settings or the Keyboard Shortcuts reference uses `ink2`, 9 horizontal and 4 vertical padding,
radius 6 and `surf3`/inset fill. A key cap contains only the key or modifier sequence; trigger
context such as “after [[” belongs in the action label. Shortcut text embedded in prose, help
strings, tooltips and native menu items keeps the surrounding native text treatment.

---

## 5. Controls

### 5.1 Icon-only button

`28 × 28` box, radius 8, **17pt symbol** centred. No padding value — the box and the centring do it.
The 28 is the **outer** dimension including the 1px border; a 28 content box plus a border renders
30 and stops matching the 28 shells beside it.

| State | Treatment |
|---|---|
| Rest | no fill, 1px `line`, `ink2` glyph |
| Hover | `hover` fill, `ink` glyph, border unchanged |
| Pressed | `press` fill |
| On (panel open) | `accsoft` fill, `accent` glyph, **still only the `line` border** |
| Disabled | 40% opacity, `ink4` glyph |

**Search option exception.** Match Case and Match Whole Word use the same standard `28 × 28` box
and 17pt symbol in both search surfaces, but stay transparent at rest whether off or on. On uses an
`accent` glyph. Hover alone adds the standard full-box `hover` fill; pressed uses `press`. Keyboard
focus uses the standard ring, never the hover fill. As with every icon button nested in a
fixed-height search shell, contain that ring inside its 28-point box so focus cannot enlarge the
shell's visual envelope. Keep the native selected accessibility state in sync with the icon.

### 5.2 No double edge on active

Except for the search option toggles defined above, an active icon button gets **fill and glyph
colour only**. It does not swap its border to `accent`.
The button already sits in or beside a bordered shell, so an accent stroke reads as a second,
brighter rim around an already-outlined box — a glowing ring the eye reads as an error state.
**Fill is the state; the border is structure and never changes with state.**

### 5.3 Text push button

Two heights, no third: **28 in bars and banners, 30 in sheets.** Padding-x 12, radius 8, label
13/400.

- **Secondary** — `surf3` fill, 1px `line`, `bezel` seat.
- **Primary** — `accent` fill, `onaccent` label, no border and no bezel.
- **Destructive** — `danger` fill, white label.

Hover lightens the fill by one step. It never changes padding, size, weight or elevation.

`bezel` (`0 1px 1px sh 5%` light, `none` dark) is the one-pixel seat that makes a macOS bezel look
pressable without looking raised. It is the only shadow a resting surface ever gets.

### 5.4 Button with glyph and label

Padding **10 leading / 12 trailing** — asymmetric on purpose, because the glyph's own side bearing
adds optical space on the left. Glyph 15 in an 18 column, gap 8, label 13. Identical to a row, by
design.

### 5.5 Segmented control

Cell `28 × 22`, radius 6, 16pt symbol, 2 between cells, 2 shell padding, 1px `line` shell, **no
track fill**. The outer box lands on 28 tall, matching every other control in the bar.

- Selected: flat `sel` fill + `ink` glyph. **No shadow and no border** — nothing inside a control
  floats.
- Idle `ink2`; hover `hover` + `ink`.
- Momentary variants (back/forward) never take a selected fill; each segment disables independently
  and the control never resizes.

### 5.6 Hover timing

120ms ease on **fill and foreground colour only**. Never animate size, position, elevation, border
or weight. The hover fill covers the whole 28pt box, not an inset — an inset highlight makes the
target look smaller than it is.

### 5.7 Other controls

Field 28 · toggle 34×20 with a 16 knob, capsule track · stepper 26 · slider track 4 / knob 16 ·
overlay row 34 · badge 22.

---

## 6. Proportion — every ratio, so nothing is eyeballed

| Relationship | Rule |
|---|---|
| Glyph beside a label | **label + 2** (~1.15). 13 → 15, 12 → 14, 11 → 13. At 1.0 the icon sits below cap height and reads as an afterthought; past 1.3 it leads and the name becomes its caption. Round to odd values so a 1.5 stroke lands on a pixel boundary. |
| Gap, glyph to label | **label × 0.6**, rounded even. 13 → 8, 12 → 7, 11 → 6. Always smaller than the glyph it follows, or the two stop grouping as one object. |
| Icon-only button | **glyph fills 60% of the box.** 17/28, 16/26, 15/24. Below 55% the button looks empty; above 70% the glyph crowds the radius. |
| Row height | **label × 2.3**, rounded even. 13 → 30, 12 → 26, 11 → 22. |
| Row padding-x | **height ÷ 3**, rounded even. 30 → 10, 26 → 8, 22 → 7. Leading and trailing always equal. |
| Secondary glyph (close, chevron) | **primary − 4** (15 → 11); hit target **glyph + 5** (11 → 16). Deliberately off the label ratio — these are not content, and sizing them like content gives a row three things all claiming to be the subject. |
| Dot indicator | **glyph ÷ 2.5** → 6. |
| Bar divider | **bar height × 0.36.** 16 in a 44 titlebar, 13 in a 36 panel header. Never full height — a full-height rule turns a bar into a table. |
| Bar height | **row height + 14.** A 30 tab in a 44 titlebar leaves 7 of air each side. |

**Where the ratios stop.** Editor body text, PDF page content and empty-state illustrations are not
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
| **8** | Every standalone control, no exception: icon button, push button, field, tab chip, sidebar row, list row, badge, segmented shell, popover row, stepper. |
| **12** | Container **and** floating layer: cards, grouped lists, popovers, menus, toasts, peek card, terminal panel, the window. Same value on purpose — they are one structural tier, and giving a menu a different radius than the card it visually replaces makes it look imported. |
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

- **Beside a label:** nominally `size = label + 2` → 15pt next to a 13pt label. The tall
  `doc.text` / `doc.richtext` contours use a 14pt optical size inside the same 18pt column.
- **Alone in a button:** nominally 17pt in a 28pt button. Optical ceilings are measured from the
  rendered symbol bounds: whole-word search is 12.5pt; `curlybraces` and `link` are 13pt;
  `magnifyingglass`, `checklist`, `photo`, document glyphs, and the diagonal terminal arrows are
  14pt; the two sidebar glyphs are 15pt. Other symbols retain the nominal size.

Both scale by the zoom factor. Weight is `.regular` **everywhere** — `.medium` on a 15pt symbol
reads as a different icon set two rows down.

### 8.3 Fixed glyph column

Every symbol beside a label sits in `.frame(width: 18 * z, alignment: .center)`.

SF Symbols have different intrinsic widths — `folder` is wide, `doc.text` narrow, `doc.richtext`
narrower still — so without a fixed column the label's left edge moves from row to row. **This is
the single cause of a ragged-looking sidebar and this is the fix.** The column is 18 because the
widest glyph in the set at 15pt measures 17.4pt.

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

`sidebar.left` · `chevron.left` / `chevron.right` · `line.3.horizontal` (source) · `eye` (preview) ·
`sidebar.right` · `folder` / `folder.fill` when selected · `doc.text` markdown · `doc.richtext` PDF ·
`terminal` · `xmark` · `plus` · `gearshape` · `list.bullet.indent` (outline peek) · `clock`
(recents).

Use the **outline (non-fill) variant everywhere** except a selected folder.

### 8.8 Rendering mode

`.symbolRenderingMode(.monochrome)` with `.foregroundStyle` from the ink ladder. Never hierarchical
or palette in the chrome — multi-tone symbols introduce a second grey that is not in the ladder, and
against `ink3` at rest it reads as a rendering bug.

### 8.9 When SF Symbols will not do

Only three cases:

1. **Outline rail dashes** — not glyphs at all. Draw as 2pt rounded `Capsule()` shapes; no symbol
   encodes heading depth.
2. **File-kind badge for an unknown extension** — SF Symbols has no generic-with-extension glyph.
   Draw `doc` and overlay the extension in 7pt SF Mono.
3. **Trailing indicator in a native macOS `Menu` label** — SwiftUI promotes a standalone SF Symbol
   to the menu's leading icon position and discards non-text trailing content. Use SF Pro's `⌄`
   down-arrowhead as a separate 10pt regular text run so it remains trailing. Its ink center is
   3.2pt below the 13pt title's ink center, so apply a scalable +3.2pt baseline offset.

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

**PDF is the exception.** A page has a true physical size, so over a PDF ⌘+ zooms the **page** and
leaves the workspace alone. The chrome stays at the workspace factor. Zoom is therefore two
independent values; the status bar shows whichever the focused view owns.

Everything else zooms with the workspace — including **every page of Settings**, not just the editor.

---

## 10. Layout — the shell

### 10.1 Titlebar, 44 tall

Left to right: traffic lights + sidebar toggle + back/forward │ **tab strip** │ flexible gap │ view
mode │ terminal toggle.

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

The in-document ⌘F surface is find-only: query, Match Case, Match Whole Word, result count,
previous/next and close. Replacement belongs only to Find in Workspace in the sidebar.
Inspect Links remains an ⌥⌘L menu command and appears in the Markdown source editor's native
context menu; it is never a titlebar affordance.

### 10.2 Markdown mode cluster

The trailing controls read as one set because they share every number: 28 tall, radius 8, 1px `line`,
6 between them. Left is the two-cell view-mode segmented (`line.3.horizontal` / `eye`); right is the
terminal toggle. Nothing in the cluster has a fill except the selected segment and the toggle when
its panel is open. **If one of them needs a different height or a heavier border, it does not belong
in the cluster.**

**View mode is two cells: Source and Preview.** A side-by-side editor is a *window arrangement*, not
a view mode — it belongs in the Window menu with its own shortcut, not in a control whose other
cells switch how one pane renders.

**Disabled, not hidden.** For PDF and plain text the whole view-mode control drops to 40% opacity
with `ink4` glyphs. Controls never appear or disappear between file kinds — the toolbar must not
reflow.

### 10.3 Tab strip — hug, cap, scroll

Geometry: 30 tall, radius 8, 3 between chips, strip inset 3 inside the titlebar, no dividers.
Content: `10 padding · 15 kind glyph (18 column) · 8 gap · 13 label · 8 gap · 16 trailing slot · 10
padding`.

- **Width:** hug the label, cap at **220 outer**. No minimum, no floor, no shrinking. A tab is the
  same width with thirty open as with two, so the strip the user learned stays put. The 16 trailing
  slot is reserved at every width so nothing shifts when the pointer enters.
- **Scroll:** horizontal scroller. Two-finger horizontal and ⇧-wheel scroll it. A plain vertical
  wheel over the titlebar does nothing and is **never** forwarded to the document. Momentum and
  rubber-band come from the platform scroller — do not reimplement them. No scrollbar is drawn: the
  strip is 30 tall and a bar would take a third of it.
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
- **Close:** 11pt glyph in a 16 round target, `ink3` → `ink` on hover. Visible on the active tab and
  on hover; the reserved slot means it never changes layout. ⌘W closes the active tab; middle-click
  closes any tab.
- **Pinned:** sits left of the unpinned run and scrolls with everything else. Pinning is about order
  and session persistence, not about staying on screen.

Do not add compression tiers, width floors, condensed icon-only chips, least-recently-used overflow
lists, hidden-count pills or overflow menus. They are several mechanisms for what one scroller does,
and they share one defect: the tab you were reading changes size or vanishes because you opened
something unrelated.

### 10.4 Sidebar

Header 40 (name + chevron, 22 actions) · row 30 · list gutter 6 · 2 between rows · 16 indent per
depth · disclosure chevron 10 · footer row 30, Settings only.

Rows are the **row primitive, identical to a tab**, on purpose.

Folders use `folder`, `folder.fill` when selected. Files use `doc.text` / `doc.richtext`. Both sit in
the 18pt column — this is what keeps the left edge of the names straight.

### 10.5 Outline rail

A right-edge dash rail, always present, no toolbar button. Dash length encodes heading level: **22 /
14 / 9**, thickness 2, radius 2. Current section is `accent`, others `ink3`.

Hover reveals a soft hit target plus a floating peek card (radius 12, `e2`, fadeUp entrance). It is a
**scroll map**, not a list — it maps the whole document at every zoom.

### 10.6 Terminal panel

Header 36. Divider 1×13. New-session and close-panel buttons 26 box / 16 glyph, outside the scroller
so adding a session never moves them.

**Session pill: fixed 43 × 24, radius 8.** `terminal` glyph at 14 + gap 6 + session number in 12pt SF
Mono. **No session name** — four pills all reading "zsh" identify nothing, and each costs a third of
the strip. The number is what tells them apart. No hug, no cap, no condensed form, no separate dot.

Run state tints the glyph, the only coloured element in the header:
`ok` running · `accent` awaiting input · `ink3` idle or exited 0 · `danger` exited non-zero.

Close: 10pt `xmark` in a 14 target, on the active pill and on hover. The strip scrolls with the same
24pt trailing fade; being clipped by the panel edge is correct.

The header order is session scroller → 13pt divider → fullscreen → new session → close panel.
Fullscreen is one 26/14 optical control: diagonal arrows point out when docked and in when expanded.
The smaller symbol size compensates for the diagonal-arrow symbol's larger visible bounds and
balances it with the adjacent 16pt `plus` and `xmark` glyphs. The control temporarily covers the
document area while leaving the titlebar and left sidebar in place. The
document stays mounted, the terminal divider is disabled, and the active button uses the normal
`accsoft`/`accent` treatment. Restoring returns to the exact pre-expand terminal width. Closing the
panel clears fullscreen, so reopening uses the docked width. ⌃⌘↩ toggles fullscreen; Escape does
not.

### 10.7 Scale table — every box and glyph at 1×

Glyph size and box size are two different numbers and both are fixed. **A glyph is never sized to
fill its box.** If an icon looks small, that is correct — macOS chrome glyphs are 15–17pt, never 20+.

| Region | Metrics |
|---|---|
| Titlebar | bar 44 · traffic light 12 · chrome button 28 box / 17 glyph · segmented 28 outer (22 cell + 2 padding + 1 border) / 16 glyph · divider 1×16 · strip inset 3 · 3 between chips |
| File tab | chip 30 · padding-x 10 · kind glyph 14 optical in 18 column · gap 8 · label 13 · trailing slot 16 · close 11 · dirty dot 6 · pin 11 · max width 220 · no minimum |
| Sidebar | header 40 · row 30 · padding-x 10 · folder glyph 15 / file glyph 14 optical in 18 column · gap 8 · label 13 · chevron 10 · indent 16 · gutter 6 · 2 between rows · header action 26/16 (search 14 optical) · footer 30/15 |
| Markdown toolbar | heading selector 100×30, radius 8, label 13 regular, trailing `⌄` 10 regular / +3.2 baseline · icon button 30 box / 17 nominal glyph · inline code and link 13 optical · task list and image 14 optical · dividers 1×20 · gaps 6 |
| Terminal | header 36 · pill 43×24 · glyph 14 · gap 6 · number 12 mono · close 10 in 14 · new/close buttons 26/16 · fullscreen 26/14 optical · divider 1×13 |
| Elsewhere | field 28 · push button 28 bars / 30 sheets · toggle 34×20, knob 16 · stepper 26 · slider track 4 / knob 16 · overlay row 34 · settings row 28/15 · outline dash 22/14/9 × 2 |

**Hard ceilings.** No chrome glyph over 17. No square button over 28. No row over 34. The only glyphs
above 17 anywhere are empty-state illustrations at 34, which are not controls.

---

## 11. Motion

- **120ms ease** on hover: fill and foreground colour only.
- **180ms standard ease** for terminal fullscreen: width only, with no fade or scale.
- **fadeUp** for overlays, toasts and the outline peek card entrance.
- Never animate size, position, elevation, border or weight except for the explicit terminal
  fullscreen width transition above.
- Honour Reduce Motion: entrances become instant opacity changes; hover colour transitions may stay.

---

## 12. Settings

Instant apply plus **Revert**. No Save button — a Save button in a preferences window implies the
change has not happened yet, which is false in every macOS app since 10.7.

Category rows 28 / glyph 15. Segmented cells 28×22 like everywhere else. Quieter header than the main
window: name + chevron, 22 actions.

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

**`contrast`** (0–100, default 40) scales the ink ladder's mid stops only:
`ink2 = 62% × (0.85 + contrast/100 × 0.375)`, same factor on `ink3` and `ink4`. `ink` and `surface`
never move — contrast adjusts legibility of secondary text, it does not push the extremes. At the
default 40 the factor is 1.0 and the ladder is exactly §1.2.

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
- [ ] Accent clears 4.5:1 against `onaccent`, and `ink2` clears 4.5:1 against `surface`.
- [ ] Accent appears in at most the five allowed places.
- [ ] No shadow on anything docked or at rest. Floating things cast in both modes.
- [ ] `line` on structural seams; `line2` only inside containers.
- [ ] One ring per boundary. No separate border on top of an elevation token.
- [ ] Active buttons have fill + glyph colour only, no accent ring; search options use the documented
      accent-glyph-only exception.
- [ ] Only weights 400 and 600. Nothing bolder when hovered, selected or focused.
- [ ] Radii are only 2/6/8/12/16/capsule. Child = parent − 4.
- [ ] Declared box sizes are outer sizes: a 28 button measures 28 including its border.
- [ ] Push buttons are 28 (bars) or 30 (sheets). No third height.
- [ ] Rows that hold the same kind of thing use identical numbers.
- [ ] Symbols sit in the 18pt column, `.regular`, `.monochrome`, cap-height centred.
- [ ] No chrome glyph over 17. No square button over 28.
- [ ] Every metric derives from `workspaceZoom`. No `.scaleEffect`. Nothing clamped.
- [ ] Hairlines, shadows and focus rings do not scale.
- [ ] Tabs hug to 220 and scroll; fades appear only where content actually overflows.
- [ ] Terminal pills show glyph + number, never a session name.
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
6. **Weight 500 surviving somewhere** — most often in a state style rather than the base style, so
   it only appears on hover or selection.
7. **Documentation describing a mechanism that no longer exists** — when you change a component,
   sweep for the *vocabulary* of the old model (its numbers, its part names), not just the phrase
   you remember writing.
8. **Fixing one instance and missing its siblings** — the same component usually appears in several
   places. Sweep by pattern, never by location.
9. **A rule promising a state nothing renders**, or a rendered state no rule covers — spec and
   implementation must agree in both directions.
10. **`.scaleEffect` for zoom** — soft text, smudged hairlines, hit rectangles in the wrong place.
