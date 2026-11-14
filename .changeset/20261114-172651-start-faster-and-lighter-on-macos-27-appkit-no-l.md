---
type: changed
bump: patch
---

Start faster and lighter on macOS 27: AppKit no longer registers the palette with App Intents or prepares the Writing Tools, so about 500 system libraries, WebKit among them, stay unloaded. The text input is unchanged.
