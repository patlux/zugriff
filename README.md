# Zugriff (Zig)

Schnelle, native Command Palette für macOS, in Zig 0.17 auf
[nanoui](https://github.com/justrach/nanoui) gebaut. Ein Nachbau von
[`zugriff-menu`](../zugriff-menu) (Rust und GPUI); dessen `PRODUCT.md` bestimmt,
was die Palette tun soll. Dieses README nennt, was hier anders ist.

Zugriff läuft als residenter Agent ohne Dock-Icon. Ein globaler Hotkey blendet
mittig auf dem Bildschirm unter dem Mauszeiger eine Palette ein, in die sofort
getippt werden kann. Die App davor behält den Fokus.

## Was es kann

- Apps suchen: Fuzzy-Suche über installierte Apps und Bundle-ID-Teile, `↵`
  startet, `⌘↵` zeigt die App im Finder. App-Icons kommen aus `NSWorkspace`
  und liegen als PNG im Cache.
- Direkt öffnen: ein absoluter Pfad (`/…`, `~/…`) öffnet die Datei, eine
  `http(s)`-Adresse den Browser.
- Rechnen: Aufgaben in deutscher oder englischer Schreibweise tippen oder
  einfügen, mit Prozenten wie am Taschenrechner, Einheiten, anderen Lesarten
  und mehrzeiligen Tabellen mit Summe. `↵` kopiert das Ergebnis, `⌥↵` nur die
  Zahl, `⇧↵` mit Aufgabe.
- Emoji: `Ctrl+Cmd+Space`, `:` am Anfang der Suche oder die Zeile „Emoji“.
  Deutsch oder englisch suchen, `⇥` Hauttöne, `↵` einfügen, `⌘↵` kopieren,
  `⌘1`–`⌘9` zuletzt verwendete. Einfügen braucht die Bedienungshilfen-Erlaubnis;
  ohne sie und bei aktivem Eingabeschutz kopiert `↵` nur.
- Steuerung des laufenden Agents über einen Unix-Socket.

## Bauen und starten

Die Toolchain kommt aus `mise.toml` (Zig 0.17.1, ziglint).

```sh
mise install
mise x -- zig build                         # zig-out/bin/zugriff-zig
mise x -- zig build -Doptimize=ReleaseSafe  # für den Alltag
./zig-out/bin/zugriff-zig run --hotkey alt+space
```

Standard-Hotkeys sind `Cmd+Space` (Palette) und `Ctrl+Cmd+Space` (Emoji). Lehnt
macOS einen Hotkey ab, weil er schon vergeben ist, schreibt der Agent das ins
Log und läuft ohne ihn weiter; dann Spotlight umstellen oder `--hotkey` nutzen.

```text
zugriff-zig                    Palette starten (Cmd+Space, Ctrl+Cmd+Space)
zugriff-zig run [--hotkey <spec>] [--emoji-hotkey <spec|none>]
                               Palette mit eigenen Hotkeys starten
zugriff-zig show               Laufende Palette anzeigen
zugriff-zig hide               Laufende Palette ausblenden
zugriff-zig toggle             Laufende Palette umschalten
zugriff-zig emoji              Emoji-Auswahl anzeigen
zugriff-zig quit               Laufende Palette beenden
zugriff-zig status             Version und Einfüge-Erlaubnis der laufenden Palette
zugriff-zig apps [query]       Installierte Apps suchen (ohne UI)
zugriff-zig emojis [suche]     Emoji suchen wie in der Palette (ohne UI)
zugriff-zig icons              App-Icons in den Cache rendern (ohne UI)
zugriff-zig calc <aufgabe>     Aufgabe rechnen wie in der Palette (ohne UI)
zugriff-zig --version          Version
```

## Neben der Rust-Version

Beide Versionen teilen sich ihre Dateien:

- Socket `~/Library/Application Support/zugriff/control.sock`
- Emoji-Einstellungen `~/Library/Application Support/zugriff/emoji.txt`
- Icon-Cache `~/Library/Caches/tech.piparo.zugriff/icons`

Läuft der Rust-Agent, sieht `zugriff-zig` dessen Socket und zeigt nur dessen
Palette an. Zum Ausprobieren den Rust-Agent beenden oder die Zig-Version mit
eigenem `HOME` starten. In der Prozessliste heißt die Zig-Version `zugriff-zig`,
die Rust-Version `zugriff`. Es gibt noch kein Install-Target und keinen LaunchAgent.

## Unterschiede

- Rechner: Statt fend-core rechnet ein eigener Auswerter mit exakten Brüchen
  (`src/core/calc`). Die Tests der Rust-Version gelten unverändert. Wo fend nur
  näherungsweise rechnet, ist das Ergebnis hier exakt: `tan 45` ergibt `1`
  statt `≈ 1`, `log 1000` ergibt `3` statt `≈ 3`. Wechselkurse gibt es in beiden
  Versionen nicht.
- Emoji-Bilder: nanoui zeichnet Text einfarbig. Emoji rendert CoreText deshalb
  einzeln in farbige Bilder (`src/ui/glyphs.zig`), nur die sichtbaren und jedes
  nur einmal. Die Schrift „Apple Color Emoji“ von macOS 27 schneidet 🫡 selbst
  ab; das sieht auch in anderen Apps so aus.
- Größe: etwa 4,3 MB in ReleaseSafe gegenüber etwa 12 MB der Rust-Binary; die
  Emoji-Tabelle ist in beiden einkompiliert.

## Entwicklung

```sh
make verify                   # Changesets, Build, zig fmt, Tests (Debug, ReleaseSafe), ziglint
mise x -- zig build shots     # Zustände der Palette als PNG in zig-out/shots, offscreen
```

Die Tests rendern die Palette offscreen mit `ui.Tester`; sie öffnen kein
Fenster und registrieren keine Hotkeys. Den echten Agent nur auf einem
GUI-Testrechner starten (siehe `AGENTS.md`).

Die Emoji-Tabelle (`src/core/emoji_data.zig` mit den Texten in
`src/core/emoji_strings.txt`) erzeugt nur `scripts/emoji_data.py`,
aus gepinnten Quellen (`--sources <ordner>`) oder aus der Tabelle der
Rust-Version (`--from-rust <data.rs>`).

Jeder Commit bringt ein Changeset mit; Ablauf und Release in `CONTRIBUTING.md`.

## Aufbau

```text
src/core/        Suche, Katalog, Emoji-Tabelle und Rechner, ohne Plattformcode
src/mac/         Apps finden, Icons, Starten, Hotkeys, Panel, Einfügen (AppKit/Carbon)
src/ui/          Palette, Rechner- und Emoji-Ansicht auf nanoui, Theme, Emoji-Bilder
src/agent.zig    Residenter Agent: Fenster und Hotkeys zuerst, dann Inhalte im Hintergrund
src/control.zig  Unix-Socket für show, hide, toggle, emoji, status und quit
src/main.zig     Befehlszeile
src/shots.zig    Offscreen-Screenshots für `zig build shots`
```

## Lizenz

Fremdlizenzen in `THIRD_PARTY_NOTICES.md` und `licenses/`.
