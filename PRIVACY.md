# Privacy

256isenough has no telemetry, analytics, crash reporting, or update pings. It
does not phone home, and the project runs no server.

## What it reads on your Mac

- Installed apps in `/Applications` and `~/Applications`: bundle metadata, sizes,
  code signatures, and the Spotlight last-used date. `isenough recommend` uses
  these to rank apps. Nothing leaves the Mac because of it.
- Coding-agent session folders, only when you run `isenough sessions`.

## What it writes, and where

- Local state, configuration, and the copied engine:
  `~/Library/Application Support/256isenough/`
- Downloaded app images: `~/Library/Caches/256isenough/`
- Packed app images, manifests, and one device file per Mac: the repo you chose
  (a local folder, iCloud Drive, an SMB/NFS share, or a WebDAV server). The
  device file holds a random device id, the name you gave the Mac, its hostname,
  macOS version, CPU architecture, and which images it uses. Every Mac that can
  read the repo can read those device files.
- Passwords for SMB or WebDAV repos and the optional session encryption key go
  into the macOS Keychain, not into `config.json`.

Your repo provider (Apple for iCloud Drive, or whoever runs your share or WebDAV
server) sees the files 256isenough stores there. Their privacy policy applies to
that copy.

## Network use

256isenough talks only to the repo you configured. The dashboard (`isenough ui`
and the menu-bar app) listens on `127.0.0.1` with a random token per run, so other
machines on your network cannot reach it.

## Removing everything

Run `isenough unpack APP` for each packed app (or use the dashboard), then delete
the two folders above and the repo folder. Full uninstall steps are in the
README.
