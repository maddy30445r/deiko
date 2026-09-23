---
name: Deiko for macOS
description: Point at your screen and say what should change; your agent gets the brief.
colors:
  accent: "#4a5bac"
  accent-mark: "#4050a0"
  accent-wash: "#eef1ff"
  ink: "#161618"
  ink-on-ink: "#ffffff"
  paper: "#fafafb"
  card: "#ffffff"
  hairline: "#ececef"
  wall-top: "#dfe4ff"
  wall-bottom: "#f5f6ff"
  coin-fill: "rgba(74, 91, 172, 0.14)"
  coin-shine: "rgba(255, 255, 255, 0.5)"
  capture-red: "#e5382e"
  alert-red: "#ff3b30"
  needs-you: "#c93400"
  done-green: "#248a3d"
  region-teal: "#0090a8"
  shadow: "rgba(30, 36, 90, 0.15)"
typography:
  display:
    fontFamily: "Bricolage Grotesque 12pt SemiBold, -apple-system, sans-serif"
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.1
    letterSpacing: "-0.56px"
  headline:
    fontFamily: "Bricolage Grotesque 12pt SemiBold, -apple-system, sans-serif"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.48px"
  title:
    fontFamily: "Bricolage Grotesque 12pt SemiBold, -apple-system, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.3px"
  body:
    fontFamily: "-apple-system, SF Pro Text, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: "-apple-system, SF Pro Text, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.35
  mono:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "11.5px"
    fontWeight: 400
    lineHeight: 1.5
rounded:
  control: "8px"
  card: "14px"
  panel: "18px"
  pill: "999px"
spacing:
  sidebar: "198px"
  pane-gutter: "26px"
  pane-top: "44px"
  card-padding: "14px"
  row-y: "11px"
  stack: "16px"
components:
  button-ink:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ink-on-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "6px 14px"
  button-ink-disabled:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ink-on-ink}"
    rounded: "{rounded.control}"
    padding: "6px 14px"
  card-inset:
    backgroundColor: "{colors.card}"
    rounded: "{rounded.card}"
    padding: "14px"
  chip-wash:
    backgroundColor: "{colors.accent-wash}"
    textColor: "{colors.accent-mark}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  sidebar-row:
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "7px 9px"
  sidebar-row-selected:
    backgroundColor: "{colors.accent-wash}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
    padding: "7px 9px"
  capture-pill:
    backgroundColor: "{colors.capture-red}"
    textColor: "{colors.ink-on-ink}"
    rounded: "{rounded.pill}"
    padding: "9px 17px 9px 14px"
  orb-card:
    backgroundColor: "{colors.card}"
    rounded: "{rounded.panel}"
    padding: "16px"
    width: "400px"
---

# Design System: Deiko for macOS

## Overview

**Creative North Star: "The Instrument and the Studio"**

Deiko is two things on one Mac, and the whole system falls out of telling them apart. The **instrument** is what appears over somebody else's work — the coin, the capturing pill, the cursor ring, the card that catches a finished brief. It is small, opaque where it must survive any wallpaper, and it never asks for a decision it can avoid. The **studio** is the one window Deiko owns — the dashboard, the board of past briefs, personas, settings. There it can be paper and hairlines and room to think, because nothing is underneath it.

The world is the same one the marketing site is built in — white and paper grey, near-black ink, one indigo the product owns — translated for a window that has to survive dark mode. Every colour is a light/dark pair built twice rather than dimmed once: a card is lighter than its ground in the dark and darker in the light, and the primary button, ink in daylight, inverts to the accent at night because near-black on near-black is a button nobody can find.

Precision is the floor, not the point. There is one display face and it is allowed on titles only; one accent and it is spent on the gesture; one red and it means a microphone is open — and inside that discipline the app is meant to be **charming**: quirky where it costs nothing, funny about the problem rather than about itself, written the way a developer friend would say it. The restraint exists so the charm has somewhere to land. A window that is merely correct is a failure of this design, not a conservative reading of it.

Charm here is specific: it lives in the copy ("drag the coin onto the agent · click it for more"), in the coin being an object you can pick up and throw, in empty states that dare you to try the gesture, and in the product admitting what it is ("this is a scrappy little demo we hacked together so you can have a go"). It never lives in decoration bolted onto a control, and it never costs somebody clarity at 11pt.

**Key Characteristics:**
- Paper-grey grounds, white cards, hairline borders, one indigo accent (`#4a5bac`).
- Bricolage Grotesque on titles only; the system face carries every control and every sentence.
- Light and dark are two builds of the same system, never one dimmed.
- Red means a microphone is open, and is the one colour that never moves.
- Colours drawn onto somebody else's pixels are fixed, not dynamic.
- Sentence case everywhere; no tracked uppercase labels.
- Charming and quirky inside the discipline — the copy, the coin and the empty states carry it; never the chrome.

## Colors

A near-monochrome studio palette with one indigo, three state colours and a lavender wall that only ever sits behind a header.

### Primary
- **Deiko Indigo** (`#4a5bac`, dark `#92a6f1`): the only hue the product owns — oklch(0.50 0.13 272) in daylight, oklch(0.74 0.11 272) at night. Desaturated enough not to glow over code and far from every system semantic colour, so red and orange keep their meanings even for somebody whose macOS accent is blue. It marks the gesture: the coin, the ring, the selected sidebar row, progress, focus.
- **Mark Indigo** (`#4050a0`, dark `#afc1ff`): the indigo that carries text and small glyphs — the stroke on the coin, chip labels, the ellipsis menu. Brighter than the accent against a wash.
- **Indigo Wash** (`#eef1ff`, dark accent at 16%): the tint behind indigo text — chips, glyph tiles, the coin's socket, a selected row.

### Tertiary (state)
- **Capture Red** (`#e5382e`): the capturing pill's body, and nothing else. Deliberately NOT dynamic and NOT translucent — the one opaque surface Deiko draws, identical over any wallpaper, unchanged by Reduce Transparency because it was never transparent.
- **Alert Red** (`#ff3b30`): the menu bar's recording tint, also fixed. The menu bar's darkness follows the desktop behind it while a dynamic colour resolves against the app's own appearance; the two disagree, and a fixed bright value cannot fall into that gap.
- **Needs You** (`#c93400`, dark `#ff9f0a`): permissions and failures. Never recording.
- **Done Green** (`#248a3d`, dark `#30d158`): the sent checkmark and granted permissions, and nothing else.
- **Region Teal** (`#0090a8`, dark `#40cbe0`): the pulse that marks a region capture. A point capture pulses in the accent; the two are distinguishable at a glance mid-session.

### Neutral
- **Paper** (`#fafafb`, dark `#1e1f26`): a window's ground. Cards sit ON this, never the reverse.
- **Card** (`#ffffff`, dark `#26272f`): the grouping surface every window is built from.
- **Hairline** (`#ececef`, dark white at 9%): 1px, and never more. The entire border vocabulary.
- **Ink** (`#161618`, dark `#92a6f1`): the primary button. In the dark it inverts to the accent.

### Wall
- **Lavender Wall** (`#dfe4ff` to `#f5f6ff`, dark `#343a63` to `#262838`): the one place colour fills an area. It goes behind a header, a gesture strip or an empty state — never behind a control, which is how it stays a backdrop instead of a theme.

### Named Rules
**The Red Means Capturing Rule.** Red appears only as evidence that a microphone is open. If it appears anywhere else, that is a bug in the design, not a styling choice.

**The Spent-On-The-Gesture Rule.** Indigo marks what Deiko does: pointing, carrying, selecting, focusing, progressing. It never fills a section or a generic button; the primary button is ink.

**The Foreign Pixels Rule.** A colour drawn onto content Deiko did not render — ink on a captured crop, the pill over a wallpaper, the menu bar tint — is a fixed value, never a dynamic pair. Dynamic colours resolve against Deiko's appearance, and that is not the appearance they will be seen against.

**The Rebuilt-Not-Dimmed Rule.** Dark mode is a second build of the same system. Cards get lighter than their ground, ink inverts to the accent, and shadows go from indigo-tinted to black.

## Typography

**Display Font:** Bricolage Grotesque 12pt SemiBold, bundled with the app (SIL OFL), registered into the process only — Deiko never installs a font on anybody's Mac.
**Body Font:** the system face (SF Pro Text).
**Mono:** SF Mono, for briefs, personas, keycaps and session ids.

**Character:** an inky, slightly quirky grotesque for the few words that say whose app this is, against the face macOS hinted for everything read at 11pt. The contrast is size and tracking, not weight theatre.

### Hierarchy
- **Display** (600, 28px, -0.02em): a dashboard number, and nothing else.
- **Headline** (600, 24px, -0.02em): the pane title at the top of Dashboard, Board, Personas and Settings.
- **Title** (600, 14–19px, -0.02em): section headings, card names, the orb's verdict line.
- **Body** (400, 13px): every control label and every sentence.
- **Label** (400, 11px, secondary): notes under a control, metadata, timestamps.
- **Mono** (400, 11–12px): the persona file, keycaps, the brief, crop counts.

### Named Rules
**The Charm Pays Rent Rule.** Every quirk has to earn its place by doing a job — naming the gesture, admitting a limit, making an object feel throwable. A joke that costs a reader clarity, or a flourish that decorates a control, is cut. Dry is a bug; cute-at-the-expense-of-legible is the same bug wearing a hat.

**The Titles Only Rule.** Bricolage carries window titles, card headings and the orb's verdict. Never a control label, never anything under 14pt. If the file is missing, every window falls back to the system face and still reads correctly.

**The Normal Volume Rule.** Section headings are sentence case. The tracked uppercase label this app used to shout in ("DEIKO NEEDS TO SEE AND HEAR WHAT YOU POINT AT") is not in the design any more.

## Layout

The window is 980×660 (minimum 860×560), split into a fixed 198px sidebar on paper and a content pane on card white, divided by a hairline. The sidebar is furniture, not navigation that collapses: four places, always visible, with the brand mark at the top and the trial meter pinned to the bottom.

The title bar is transparent and its title hidden, so both columns have to leave the room it would have taken: the sidebar's brand row starts 44px down, clear of the traffic lights, and pane content starts 44px down, clear of the bar.

Every pane opens the same way — a 24px title, a 12.5px secondary line under it, then content — and scrolls as one column at a 26px gutter with 16px between blocks. Cards hold rows at 14px horizontal and 11px vertical padding, separated by hairline dividers rather than gaps. The board is the one grid: cards at a 210px minimum, 14px apart, reflowing with the window.

Floating surfaces are sized to their job, not to the window: the orb card is exactly 400pt wide and as tall as its contents measure, the review panel is 620×640, and the capturing pill is centred 62pt from the top of the screen.

## Elevation & Depth

Depth is soft, cool and singular: one long, low-contrast shadow tinted indigo, plus a 1px hairline, so a card reads as paper resting on a desk. Nothing is layered more than one level deep — a card never sits on a card.

Translucency is reserved for surfaces that float over other applications. The orb card and review panel are `regularMaterial` with the card colour at 72% over it: the material is what makes them legible over a dark editor and what answers Reduce Transparency without a second code path, and the card colour pulls them back toward the paper white everything else is made of.

### Shadow Vocabulary
- **Card rest** (`0 7px 13px rgba(30, 36, 90, 0.15)`, black at 40% in the dark): every card, row and preview.
- **Card hover** (`0 9px 16px`, same colour): a board card lifts 1px on hover; a selected persona row carries it at rest.
- **Coin** (`0 2px 3px black at 30%`, growing to `0 8px 14px` at 45% while held): the only shadow that changes on touch, and it scales with the coin's diameter.

### Named Rules
**The Indigo Shadow Rule.** Shadows are long, soft and tinted indigo (`rgba(30, 36, 90, …)`); never hard, never black at full strength in daylight. The site's equivalent uses a negative spread to keep the shadow under the card rather than around it; AppKit has no spread, so the same shape is bought with a weaker colour and a lower offset. A stronger one reads as a cloud.

## Shapes

Corners are generous and nested, and they get smaller as they get deeper: 18px for floating panels (the orb card, the review panel), 14px for cards, rows and previews, 8px for controls and glyph tiles, and full pills for status and chips. Borders are 1px hairlines and nothing else.

Circles belong to the mark. The Deiko mark is a ring with a centred dot drawn at stroke = diameter/10 and dot = diameter/4 — the same proportions on the 56pt coin, the 24pt sidebar mark and the 14pt menu bar icon. A dashed circle means "not yet": the socket a thrown coin left behind.

## Components

### Buttons
- **Shape:** 8px radius, 6px × 14px padding, 13px medium label.
- **Primary (ink):** ink fill, white label; in the dark, accent fill with near-black label. Disabled drops to 35% opacity — read from the environment inside the style, because a `ButtonStyle` is not a `View` and a disabled primary that looks enabled is the bug that ships otherwise.
- **Everything else** is a system button. The app does not restyle secondary buttons; macOS already draws them better than a custom one would.

### Chips
- **Wash chip:** indigo wash, mark-indigo 11px label, pill radius, 3px × 8px. Marks a default, a crop count, an agent name or "your own text".

### Cards / Containers
- **Corner Style:** 14px (`InsetCard`).
- **Background:** card white on paper; in the dark, lighter than the ground.
- **Shadow Strategy:** card rest, see Elevation.
- **Border:** 1px hairline.
- **Internal Padding:** 14px; rows inside are separated by dividers inset 14px, never by gaps.

### Navigation
The sidebar is a fixed column of four rows: 13px label, 17px symbol, 8px radius. Selected takes the indigo wash with an accent symbol and a semibold label; hover takes 5.5% ink. The brand mark and wordmark sit above, the trial meter below, and neither is a link.

### Inputs / Fields
System text fields at 12–13px, rounded-border style. The app does not restyle the caret or the focus ring; the system's are correct and accessible.

### The capturing pill
A fixed red capsule, centred at the top of the screen, carrying a blinking white dot, a tabular timer, a four-bar waveform and the name of whichever recogniser is listening. It is opaque, it is never dynamic, and it is the only red thing on screen.

### The coin
The brand mark as a physical object: a filled circle with a rim light across the top half, a 1.5pt ring and the mark inside, at any diameter — 56pt on the orb, 24pt in the sidebar. Everything inside scales from `diameter / 56`; the size is a parameter, never a frame around a fixed drawing.

### Empty states
An empty pane sits on the lavender wall with a 16px title and one line that says what to do next. An empty state is an invitation, so it names the gesture ("double-tap Right Option") and never apologises for having nothing in it.

## Do's and Don'ts

### Do:
- **Do** put content on paper and group it in white cards with a hairline and the card-rest shadow.
- **Do** keep Bricolage for titles at 14pt and above, and let the system face carry everything else.
- **Do** build every new colour as a light/dark pair, and check the dark one is not just the light one dimmed.
- **Do** fix any colour that lands on pixels Deiko did not draw.
- **Do** give every state a shape change, not only a colour change — the menu bar mark swells, badges and dashes rather than merely tinting.
- **Do** write section headings in sentence case.
- **Do** scale a component by its own size parameter, never by wrapping a fixed drawing in a smaller frame.
- **Do** answer the pointer: rows and cards that can be opened carry a hover state.
- **Do** write like a developer friend who is funny about the problem: plain, specific, a little quirky, never corporate. "Nothing heard you — Deiko needs the microphone" beats "Audio input unavailable".
- **Do** spend personality on the moments that repeat — the empty state, the thing you drag, the sentence under a number — where it compounds instead of decorating.

### Don't:
- **Don't** use red for anything except an open microphone.
- **Don't** fill an area with the accent; it marks the gesture, and the primary button is ink.
- **Don't** put the lavender wall behind a control — it goes behind headers, gesture strips and empty states.
- **Don't** nest a card in a card, or a scroll view in a scroll view.
- **Don't** set a tracked uppercase label anywhere.
- **Don't** use glass or material except on a surface that floats over another application.
- **Don't** let a custom surface skip Reduce Transparency, Increase Contrast or accessibility text sizes; what Apple draws, Apple maintains, and what we draw is ours to check.
- **Don't** mistake "native and restrained" for permission to be dry. A pane of correct grey rows with no voice in it has failed this system as surely as a gradient would.
