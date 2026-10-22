# Pake GUI

`isenough ui` serves `Sources/isenough/web` on `127.0.0.1` with a random token and prints
`http://127.0.0.1:<port>/?token=<token>`. The page shows offloaded apps, cache usage, pin/unpin,
evict, backend status, and cold session tiers.

`scripts/build-ui.sh` copies those assets to `.build/ui`. When `pake` is installed it wraps the
page as `256isenough.app`. Set `ISENOUGH_UI_URL` to the URL `isenough ui` printed. CI sets
`ISENOUGH_SKIP_PAKE=1` so packaging is skipped. Pake is GPL-3.0; review licensing before
distributing a generated wrapper. It is a tray/window UI, not a native Dock-less menu-bar extra.
