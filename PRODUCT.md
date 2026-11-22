# Product

What Zugriff is for, for whom, and what it deliberately leaves out. What it does today, its
commands and its numbers are in `README.md`.

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS desktop app for Apple Silicon, tested on macOS 27. Zig 0.17 on nanoui (Metal and
AppKit), resident as an accessory agent without a Dock icon, started by a launch agent. No web
wrapper, no other platforms.

## Users

Keyboard-first people on their own Mac who start many apps a day and want a palette that is
there the moment they press the hot key. The interface is German.

## Product Purpose

A small, native command palette. The hot key shows a centred palette that takes typing at once;
the search finds installed apps, and Return opens the selection. Opening comes before any
content: the window and the hot key are ready before the app scan, any index or any rendering.

Success means: press the hot key, the palette is there, type, the right app opens. No stolen
focus, no waiting for content, nothing leaves the Mac.

## Positioning

A native, pre-created non-activating panel that becomes the key window without activating the
app, an opening guarantee (window and hot key before any content), and local, single-purpose
features without an extension platform.

## Capabilities and Constraints

Confirmed:

- Global hot key, palette centred on the screen with the pointer, 640×420.
- Fuzzy search over installed apps (titles and bundle-identifier parts), launched through Launch
  Services. A rescan on every show (at most every 2 s) finds apps installed or removed since.
- Direct opening without a search: an existing absolute path (`/…`, `~/…`) becomes the one row
  that opens it (`⌘↵` reveals it in the Finder), an `http(s)` address opens the default browser.
  Only an existence check: no index, no network.
- App icons from `NSWorkspace`, cached as 64 px PNG files, loaded in batches after the palette is
  visible, with a monogram tile until then.
- Keyboard control: ↑/↓ (also Ctrl-P/N), Return, Escape; no show or hide animation.
- Translucent window: the system blur (HUD material) behind fixed-alpha theme surfaces, text fully
  opaque, the appearance fixed to dark so the blur stays dark in light mode.
- Calculator in the app search: a typed or pasted task (German or English notation, words such as
  `mal`, `zzgl.` and `von`, units with `in`) shows a result card above the app hits. Return copies
  as shown and closes, `⌥↵` copies only the number, `⇧↵` the task with the result; other readings
  (percentages, a point as decimal separator, MiB and GiB) as rows. Several pasted lines are
  calculated one by one and summed; `=` alone shows the session's history, kept in memory only;
  reopened within 90 s, the last calculation is still there. Exact fractions, no network and
  therefore no exchange rates.
- Emoji picker on its own hot key (`⌃⌘Space`), on `:` at the start of a query or on the *Emoji*
  row: a grid with the recently used emoji and the Unicode groups, search in German and English
  names, keywords (CLDR) and shortcodes (gemoji). 1,906 emoji of Unicode 16 compiled in. Return
  inserts into the app in front, `⌘↵` copies, Tab opens the skin tones and remembers the choice,
  `⌘1`–`⌘9` insert recently used emoji.
- Inserting borrows the pasteboard: the emoji goes in marked transient, the panel closes, `⌘V`
  follows after 50 ms, and the previous content comes back after 600 ms unless something else
  copied in between. Without the Accessibility permission, or while secure input is on, Return
  copies only and the footer says so.
- A help on `?` with one example per topic.
- Single instance over a Unix socket (`show`, `hide`, `toggle`, `emoji`, `status`, `quit`);
  headless `apps`, `emojis`, `calc` and `icons` commands.
- Optional unloading after an idle time: the window only, or the whole UI process behind a small
  daemon that keeps the hot keys.

Limits:

- macOS only.
- Apps, direct opening, calculator, emoji and help. No file search, no clipboard history, no
  extensions. The pasteboard is read only for the user's `⌘V` and to save it before inserting an
  emoji; it is written when a result is copied and for the duration of an insert.
- No configuration file. The emoji picker remembers the skin tone and up to 24 recently used
  emoji in `~/Library/Application Support/zugriff/emoji.txt`: emoji only, no text.
- The Accessibility permission belongs to the code signature. An ad-hoc signed build loses it with
  every new build; a binary signed with a certificate keeps it.
- `⌘V` is posted as key code 9 (the V position). Layouts with another letter there (Dvorak) are
  not checked.
- No usage-based ranking, no signed `.app` bundle, no App Store, no telemetry, no network.
- Dark only. Light mode, input methods for CJK, VoiceOver and several displays are not verified.

## Non-goals

- Other platforms (Windows, Linux, iOS, Android).
- A plugin or extension API, or compatibility with other launchers' extensions.
- Cloud sync, accounts, telemetry or network access.
- Replacing Spotlight as a whole: no file index, no system-wide indexing.
- Clipboard history or AI features, unless decided explicitly.

## Brand Commitments

- Name: Zugriff, German for *access*. German interface; direct, short wording.
- A warm dark theme (accent `#f0b35a`, background `#101116`).
- A calm, native macOS look: no marketing, no telemetry, no decorative animation.
- Translucent rather than opaque: the desktop stays visible behind the palette as colour and
  movement, never as a readable picture.

## Product Principles

1. **Opening is sacred.** Window and hot key first, content asynchronously. No show waits for a
   scan, a search or rendering.
2. **Keyboard-first.** Every core action without the mouse; immediate feedback, a clear
   selection, Return and Escape.
3. **Native and local.** macOS conventions, no web wrapper, no cloud, no telemetry.
4. **Familiar keys.** `⌘Space`, a centred palette, the keys people already know from launchers.
5. **Small surface.** One clear action per row; features only after a proven need, no speculative
   platform.

## Accessibility & Inclusion

- Full keyboard control and a visible selection.
- High contrast in the dark theme; light mode and a full VoiceOver audit are still open.
- No animations, so reduced motion holds by default.
- German interface texts; no state is shown by colour alone.

## Decisions and planned work

Confirmed:

- A non-activating panel that does not take the focus; no window animation.
- An asynchronous app scan with a loading state; the opening contract is in `AGENTS.md`.
- No file search: it went unused and was expensive in the background.
- SemVer changesets for every commit; releases only when asked for.
- Translucency through the AppKit blur with fixed theme alpha. Liquid Glass (`NSGlassEffectView`)
  is deliberately not used: its inactive appearance, cached backdrop and milky default would need
  private API.
- Calculator: the result card above the hits; Return copies as shown and closes; a reopen shortly
  after shows the calculation again (90 s); the history stays in memory; no exchange rates and no
  inserting into the app in front.
- Emoji picker: on `⌃⌘Space` and `:`, with skin tones; Return inserts (with the Accessibility
  permission, else copies); the recently used emoji and the skin tone are saved. Emoji next to the
  apps and a picker at the text cursor are deliberately left out.

Planned:

- A configuration file for the hot keys and the theme.
- Usage-based ranking.
- A signed `.app` bundle with a packaged launch agent.

Open:

- Clipboard history and extensions: add them or leave them out for good.
- Ready-made binaries and other ways to install.
