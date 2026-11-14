# Zugriff (Zig)

Schnelle, native Command Palette für macOS, in Zig 0.17 auf
[nanoui](https://github.com/justrach/nanoui) gebaut. Ein Nachbau von
`zugriff-menu-rust`
(Rust und GPUI), den es seit 2026-11-14 ersetzt. Dessen `PRODUCT.md` bestimmt,
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
  `⌘1`–`⌘9` zuletzt verwendete. Mit der Maus fügt ein Klick ein, Rechtsklick
  oder langes Drücken öffnet die Hauttöne. Einfügen braucht die Bedienungshilfen-Erlaubnis;
  ohne sie und bei aktivem Eingabeschutz kopiert `↵` nur.
- Hilfe: `?` zeigt, was die Palette versteht, mit je einem Beispiel; `↵` setzt
  das Beispiel ins Suchfeld. `help` und `hilfe` bringen die Zeile „Hilfe“ über
  die App-Treffer. Im leeren Suchfeld steht rechts „? Hilfe“, und bis die
  Hilfe einmal offen war, nennt der Fuß den Tipp dazu.
- Steuerung des laufenden Agents über einen Unix-Socket.

## Bauen und starten

Die Toolchain kommt aus `mise.toml` (Zig 0.17.1, ziglint).

```sh
mise install
mise x -- zig build                         # zig-out/bin/zugriff
mise x -- zig build -Doptimize=ReleaseSafe  # für den Alltag
./zig-out/bin/zugriff run --hotkey alt+space
```

Standard-Hotkeys sind `Cmd+Space` (Palette) und `Ctrl+Cmd+Space` (Emoji). Lehnt
macOS einen Hotkey ab, weil er schon vergeben ist, schreibt der Agent das ins
Log und läuft ohne ihn weiter; dann Spotlight umstellen oder `--hotkey` nutzen.

```text
zugriff                        Palette starten (Cmd+Space, Ctrl+Cmd+Space)
zugriff run [--hotkey <spec>] [--emoji-hotkey <spec|none>]
            [--unload-after <s|never>] [--unload-mode window|process]
                               Palette mit eigenen Hotkeys starten, optional entladen
zugriff show                   Laufende Palette anzeigen
zugriff hide                   Laufende Palette ausblenden
zugriff toggle                 Laufende Palette umschalten
zugriff emoji                  Emoji-Auswahl anzeigen
zugriff quit                   Laufende Palette beenden
zugriff status                 Version und Einfüge-Erlaubnis der laufenden Palette
zugriff apps [query]           Installierte Apps suchen (ohne UI)
zugriff emojis [suche]         Emoji suchen wie in der Palette (ohne UI)
zugriff icons                  App-Icons in den Cache rendern (ohne UI)
zugriff calc <aufgabe>         Aufgabe rechnen wie in der Palette (ohne UI)
zugriff --version              Version
```

## Speicher

Standardmäßig hält der Agent die fertige Palette bereit (Fenster, Metal,
Atlanten, Caches), damit der Hotkey sie innerhalb eines Frames zeigt.
`--unload-after <sekunden>` gibt nach dieser Ruhezeit Speicher frei, auf eine
von zwei Arten (`--unload-mode`):

- `window` (Standard): Das versteckte Fenster wird geschlossen und beim
  nächsten Aufruf neu angelegt. Eingabe, letzte Rechnung und Emoji-Verlauf
  bleiben erhalten.
- `process`: Ein kleiner Daemon (`src/daemon.zig`) hält Hotkeys und Socket
  und startet die Palette als eigenen UI-Prozess (`zugriff ui`, intern).
  Der UI-Prozess beendet sich nach der Ruhezeit ganz; die letzte Rechnung
  geht dabei verloren, der Emoji-Verlauf liegt in der Datei und bleibt.
  Was nach dem Hotkey getippt wird, solange der UI-Prozess noch startet,
  nimmt ein unsichtbares Fangfenster des Daemons an; die Palette übernimmt
  es, sobald sie vorne ist. Neben Text gilt das für ↵ (auch mit ⇧, ⌥, ⌘),
  ⎋, ⇥, ↑ und ↓: Sie wirken nach der Übergabe in derselben Reihenfolge, ↵
  erst, wenn die App-Liste da ist. Der Hotkey ein zweites Mal schließt die
  Palette wieder, auch mitten im Start.

```sh
./zig-out/bin/zugriff run --hotkey alt+space --unload-after 60
./zig-out/bin/zugriff run --hotkey alt+space --unload-after 60 --unload-mode process
```

Gemessen auf einem Retina-Mac (ReleaseSafe, macOS 27). Speicher mit
`footprint`; Öffnen ist die Zeit von `show` bis die Palette laut
Fensterliste sichtbar ist, mit einem Messsockel von etwa 40–50 ms (CLI,
Socket, Abfragetakt), der in allen Spalten steckt:

| | bleibt geladen | `window` | `process` |
|---|---|---|---|
| Ruhe, nie geöffnet | 24 MB | 23 MB | 9 MB (Daemon) |
| offen (Apps / Emoji) | 47 / 66 MB | 47 / 66 MB | 9 MB + 59 / 66 MB |
| Ruhe nach Nutzung | 49–52 MB | 34–39 MB | 9 MB |
| Öffnen aus der Ruhe | ~60 ms | ~100 ms | ~210 ms |

`window` gibt GPU-Puffer und Atlanten ganz frei; den Rest hält malloc (nur
etwa 9 MB davon sind noch belegt, die übrigen Seiten bleiben wegen verstreut
belegter Blöcke beim Prozess). `process` gibt alles frei, kostet beim
Öffnen aber den Start des UI-Prozesses mit AppKit und Metal.

## Neben der Rust-Version

Beide Versionen teilen sich ihre Dateien:

- Socket `~/Library/Application Support/zugriff/control.sock`
- Emoji-Einstellungen `~/Library/Application Support/zugriff/emoji.txt`
- Icon-Cache `~/Library/Caches/tech.piparo.zugriff/icons`

Nur die Zig-Version legt `~/Library/Application Support/zugriff/help-seen` an,
sobald die Hilfe einmal offen war.

Läuft der Rust-Agent, sieht die Zig-Version dessen Socket und zeigt nur dessen
Palette an. Zum Ausprobieren den Rust-Agent beenden oder die Zig-Version mit
eigenem `HOME` starten. Beide Binaries heißen `zugriff`.

## Installieren

```sh
make install
```

baut einen sauberen Stand in ReleaseSafe, signiert ihn mit Identität und
Kennung der Rust-Version, legt ihn als `~/.local/share/zugriff/bin/zugriff`
ab (dort lag die Rust-Binary) und startet den LaunchAgent
`local.zugriff` neu. Den LaunchAgent legt das Maschinen-Setup an; er
startet die Palette mit `--unload-after 60 --unload-mode process`.

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
- Emoji mit der Maus: Rechtsklick (oder Control-Klick) und 0,5 s langes
  Drücken auf ein Emoji öffnen die Hauttöne, ein zweiter Rechtsklick schließt
  sie. `PRODUCT.md` beschreibt die Hauttöne nur über `⇥`.
- Größe: etwa 4,3 MB in ReleaseSafe gegenüber etwa 12 MB der Rust-Binary; die
  Emoji-Tabelle ist in beiden einkompiliert.
- Apple Intelligence: AppKit meldet unter macOS 27 jede App bei App Intents
  an und bereitet die Writing Tools vor; das lädt rund 500 Systembibliotheken
  bis hin zu WebKit, die die Palette nicht braucht. `src/mac/intelligence.zig`
  ersetzt diese sechs privaten Methoden vor dem Start durch leere, wenn ihre
  Signatur passt. Gemessen auf macOS 27.2: 658 statt 1166 geladene Bibliotheken
  nach dem Start, Start bis Socket etwa 129 statt 139 ms, Öffnen im Modus
  `process` etwa 119 statt 130 ms, der Daemon 7,9 statt 9,0 MB. Texteingabe
  (Akzente, Eingabemethoden) bleibt unverändert.

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
Rust-Version (`--from-rust <data.rs>` aus einem Checkout von `zugriff-menu-rust`).

Jeder Commit bringt ein Changeset mit; Ablauf und Release in `CONTRIBUTING.md`.

## Aufbau

```text
src/core/        Suche, Katalog, Emoji-Tabelle und Rechner, ohne Plattformcode
src/mac/         Apps finden, Icons, Starten, Hotkeys, Panel, Einfügen (AppKit/Carbon)
src/ui/          Palette, Rechner-, Emoji- und Hilfe-Ansicht auf nanoui, Theme, Emoji-Bilder
src/agent.zig    Residenter Agent: Fenster und Hotkeys zuerst, dann Inhalte im Hintergrund
src/daemon.zig   Daemon für --unload-mode process: Hotkeys und Socket, startet den UI-Prozess
src/control.zig  Unix-Socket für show, hide, toggle, emoji, status und quit
src/main.zig     Befehlszeile
src/shots.zig    Offscreen-Screenshots für `zig build shots`
```

## Lizenz

Fremdlizenzen in `THIRD_PARTY_NOTICES.md` und `licenses/`.
