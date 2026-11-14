---
type: added
bump: minor
---

Unload the whole palette process between uses: run --unload-after <seconds> --unload-mode process keeps only a small daemon with the hot keys (about 9 MB) and starts the palette as its own process on the next hot key, which ends itself after the idle time.
