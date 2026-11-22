# Changelog

Versions follow SemVer. Entries come from the Markdown changesets in `.changeset/`.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the local release workflow.

## 0.3.0 - 2026-11-22

### Added

- Speak English or German: the palette, the help, the emoji picker and the command line follow the first preferred language of macOS, and every command takes --language de|en.
- Calculate in English notation where macOS writes numbers with a decimal point: 1,299.50 × 2, 95.2%, $1,545.81, units such as 14 days or 11.81 inches, and the words times, divided by and of. A number that reads two ways (1,250 or 1.250) offers the other reading.
- In English, the emoji picker shows English names and group titles and ranks English names first; German names still find their emoji.

### Changed

- Keep the app icons in ~/Library/Caches/zugriff/icons, next to the other files of Zugriff. The palette renders them again once after the update.

## 0.2.2 - 2026-11-15

### Changed

- Show the palette sooner the first time it opens: whether Zugriff may insert emoji (the Accessibility permission) is checked while it starts, not when the palette opens.
- The palette appears sooner after the hot key, already with the blinking caret: its first frame with the keyboard is drawn while it is shown and sent to the screen at once. With --unload-mode process about 50 ms sooner, the resident palette's first show about 40 ms.

## 0.2.1 - 2026-11-14

### Added

- The help's footer names the running version.

## 0.2.0 - 2026-11-14

### Added

- Type ? to see what the palette understands: seven topics with an example each, and Return puts the example into the search field so the palette shows at once what it does; the footer then says the query came from the help.
- Typing help or hilfe brings up a Hilfe row above the app hits; Return on it opens the help.
- The empty search shows a quiet ? Hilfe at the right of the search field, and its footer a tip about ? until the help was opened once.

## 0.1.0 - 2026-11-14

### Added

- Search installed apps by their names and bundle identifiers: every word has to match, titles rank above aliases, and an absolute path or an http(s) address becomes the one row that opens it.
- Compile in the 1.906 emoji of Unicode 16 with German and English names, keywords and shortcodes, and search them like the Rust version: whole words before word starts, umlauts optional, recently used emoji first among equals.
- Calculate typed and pasted tasks in German or English notation, with pocket-calculator percentages, units, other readings and pasted sheets. Exact fractions replace fend-core; results match the Rust version's tests.
- Run as a resident agent: a non-activating panel on Cmd+Space and the emoji picker on Ctrl+Cmd+Space, opened before the app scan; launch apps and addresses, reveal in Finder, insert emoji with ⌘V or copy them, and control the running palette with zugriff show, hide, toggle, emoji, status and quit. App icons share the Rust version's cache.
- Free the palette's memory while it is not used: run --unload-after <seconds> closes the hidden panel after that long and makes it again on the next hot key, in a few milliseconds. The default keeps the panel loaded.
- Unload the whole palette process between uses: run --unload-after <seconds> --unload-mode process keeps only a small daemon with the hot keys (about 9 MB) and starts the palette as its own process on the next hot key, which ends itself after the idle time.
- Open an emoji's skin tones with a right-click, a Control-click or a long press (0.5 s) on its cell; a second right-click closes them. A plain click still inserts at once.

### Changed

- Shrink the binary by about 870 KB: the emoji texts are stored once instead of behind a table of slices.
- Start without loading WebKit: the palette has no web view, and dyld now loads 27 fewer system images at launch.
- Log with timestamps: every line carries the local time, the process (agent, daemon or UI) with its pid and the time since it started, and the log now covers hot keys, commands, shows with how long the panel took, hides with their reason, app scans, actions and unloading.
- Open a freshly started UI process sooner: it shows the palette as soon as its window exists instead of after the run loop starts, and scans the apps once instead of twice.
- Start faster and lighter on macOS 27: AppKit no longer registers the palette with App Intents or prepares the Writing Tools, so about 500 system libraries, WebKit among them, stay unloaded. The text input is unchanged.
- Name the binary zugriff again instead of zugriff-zig; it replaces the Rust version under the same name.

### Fixed

- Round the palette's corners again: the blurred backdrop and the shadow showed square corners around the rounded panel.
- Keep the keys typed right after the hot key while the palette process still starts (--unload-mode process): they went to the app in front, now an invisible key catcher of the daemon takes them and the palette shows them in its search field.
- Keep Return, Escape, Tab and the up and down arrows pressed while the palette process still starts (--unload-mode process): they act in order once the palette is there, Return after the app list is in, so typing a name and Return right after the hot key opens the app. The hot key again during the start closes the palette.
- Show the palette with its current content at once: after the emoji picker, opening the app search briefly showed the emoji grid before the app list.
