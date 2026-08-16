# Library Inventory Export

A [Playnite](https://playnite.link/) script extension that exports your entire game library — across every connected store (Steam, GOG, Epic, EA, Xbox, Battle.net, Ubisoft, Amazon, itch.io, and more) — as either a structured **CSV + JSON** inventory or a self-contained, browsable **HTML gallery**.

The gallery is inspired by [g-export](https://github.com/gilleswaeber/g-export), but sourced from Playnite so it covers all of your stores at once and carries richer per-game metadata.

---

## Features

Two commands are added under Playnite's **Extensions** menu:

**Export Library Inventory (CSV + JSON)** — a full tabular dump of your library, one row per game, suitable for spreadsheets, auditing, or feeding other tools.

**Export Library Gallery (HTML)** — a single, offline, dependency-free web page:

- A responsive **cover-art wall**, with each game's store shown as a coloured spine, a badge, and a filter chip.
- **Enriched cards**: score pill, release year + primary genre, completion status, and a ★ on favourites.
- A **detail panel** (click any card) showing playtime, completion, all three scores (community / critic / user), release and activity dates, platforms, developers, publishers, series, age rating, version, genres, features, tags, the description, and every link.
- **Live search**, **store filter chips**, **Installed only** and **Played only** toggles, and sorting by name, most played, recently played, highest score, or newest release.
- Per-card **Play** button (installed games — launches via `playnite://` so playtime keeps tracking) and **Store** button (opens the store page).
- A footer reporting how many games have resolvable store links.

Everything is read-only: the extension only reads the library and writes to a separate output folder. It never modifies your games.

---

## Requirements

- **Playnite** (Desktop mode — that's where the Extensions menu lives).
- **Windows** (the extension is PowerShell-based, like all Playnite script extensions).
- No other dependencies. The gallery uses only vanilla HTML/CSS/JS and works offline.

---

## Installation

1. Copy the whole `LibraryInventoryExport` folder — it must contain both `extension.yaml` and `LibraryExport.psm1` — into Playnite's extensions folder:
   - **Standard install:** `%AppData%\Playnite\Extensions\`
   - **Portable install:** the `Extensions` folder next to `Playnite.exe`
2. **Unblock the files.** Windows tags files downloaded from the internet, and Playnite won't load a blocked PowerShell script. Right-click each file → **Properties** → tick **Unblock** → OK. Or from PowerShell:
   ```powershell
   Get-ChildItem "$env:AppData\Playnite\Extensions\LibraryInventoryExport" | Unblock-File
   ```
3. Fully restart Playnite (quit from the tray, not just the window). If prompted to enable the extension, allow it. Confirm under **Main menu → Add-ons → Extensions** — *Library Inventory Export* should be listed and enabled.

> **Tip:** the two files must sit *directly* inside `Extensions\LibraryInventoryExport\`, not inside a second subfolder created by unzipping.

---

## Usage

1. (Recommended) Run **Main menu → Library → Download metadata** first. Covers, scores, genres, features, tags, and descriptions only appear for games whose metadata has been fetched.
2. Open **Main menu → Extensions** and choose either export command.
3. A summary dialog reports the counts when done; the gallery also opens in your browser automatically.

### Output

Everything is written under `Documents\Playnite Exports\`:

| Export | Output |
| --- | --- |
| CSV + JSON | `playnite-library_<timestamp>.csv` and `.json` |
| Gallery | `gallery_<timestamp>\index.html` (with a `covers\` folder of copied cover art) |

Each run is timestamped, so re-exporting never overwrites a previous snapshot.

---

## CSV / JSON fields

| Field | Description |
| --- | --- |
| `Name` | Game title |
| `Store` | Source library (Steam, GOG, Epic, etc.); `None` for manually-added games |
| `Platforms` | Platform(s), e.g. `PC (Windows)` |
| `Installed` | Whether the game is currently installed |
| `InstallDirectory` | Install path (if installed) |
| `PlaytimeHours` | Tracked playtime in hours |
| `LastPlayed` | Date last played |
| `DateAdded` | Date added to the library |
| `ReleaseDate` | Game release date |
| `CompletionStatus` | e.g. Not Played, Playing, Beaten, Completed |
| `CommunityScore` / `CriticScore` / `UserScore` | Ratings held by Playnite |
| `Favorite` / `Hidden` | Flags |
| `Genres` / `Features` / `Tags` | Semicolon-delimited lists |
| `Developers` / `Publishers` / `Series` | Semicolon-delimited lists |
| `StoreGameId` | The store's own ID (e.g. Steam appid) |
| `PlayniteId` | Playnite's internal GUID |

---

## Configuration

Editable variables sit at the top of each function in `LibraryExport.psm1`. Edit the file and restart Playnite to apply.

**CSV/JSON export (`Invoke-LibraryInventoryExport`)**

| Variable | Default | Purpose |
| --- | --- | --- |
| `$exportRoot` | `Documents\Playnite Exports` | Output location |
| `$includeHidden` | `$true` | Include games flagged Hidden (keeps a full record, duplicates and all) |

**Gallery export (`Invoke-LibraryGalleryExport`)**

| Variable | Default | Purpose |
| --- | --- | --- |
| `$exportRoot` | `Documents\Playnite Exports` | Output location |
| `$includeHidden` | `$false` | Skip games flagged Hidden |
| `$autoOpen` | `$true` | Open the page in the browser when finished |
| `$includeDescriptions` | `$true` | Embed descriptions; set `$false` to shrink the file on very large libraries |

---

## Notes & caveats

- **Metadata drives richness.** Scores, genres, features, tags, and descriptions only populate for games you've run a metadata download on. Games freshly imported may show placeholder cover tiles and sparse detail panels until then.
- **Duplicates.** Playnite imports each store's copy of a game as a separate entry and does not merge them. If you use the [DuplicateHider](https://github.com/felixkmh/DuplicateHider) extension, the copies it hides will drop out of the **gallery** (which skips hidden games) but remain in the **CSV/JSON** (which keeps everything by default). Expect the two exports to report different counts when DuplicateHider is active — that's intended, not a bug.
- **Play buttons** rely on Playnite being installed on whatever machine opens the page (the `playnite://` protocol handler is registered at install time). Viewed elsewhere — say, the gallery copied to a NAS — the Store links still work but Play does nothing.
- **Store-link coverage** improves with metadata. Steam links are always resolvable (built from the appid); other stores depend on a store link being present in the game's Links, which a metadata download or the [Link Utilities](https://github.com/HerrKnarz/Playnite-Extensions) extension can fill in.
- **Playtime and last-played** reflect only what Playnite has tracked; titles launched outside Playnite may read as unplayed until it syncs.

---

## Recommended companion extensions

- **Metadata downloaders** (built-in) — populate covers, scores, and links for the fullest output.
- **[DuplicateHider](https://github.com/felixkmh/DuplicateHider)** — collapse the same game owned on multiple stores down to one visible entry.
- **[Link Utilities](https://github.com/HerrKnarz/Playnite-Extensions)** — bulk-add store/library links so more cards get a clickable Store button.

---

## Changelog

- **1.4.0** — Metadata-rich gallery: cards show score / year / completion / favourite; clicking a card opens a detail panel with playtime, all scores, genres, features, tags, developers, publishers, series, platforms, age rating, description, and every link. Added score and release-year sorts and a *Played only* filter.
- **1.3.1** — Fix: the gallery failed with a null-method error because Playnite does not expose top-level module variables to invoked functions; the HTML template is now returned by a function.
- **1.3.0** — Cards carry **Play** (`playnite://` launch) and **Store** buttons.
- **1.2.0** — Cards link to each game's store page; footer reports link coverage.
- **1.1.0** — Added the HTML gallery export (cover wall, search, filter, sort).
- **1.0.0** — Initial CSV + JSON inventory export.

---

## Credits & license

Built for Playnite by **netgeek1**. Gallery concept inspired by [g-export](https://github.com/gilleswaeber/g-export).

Licensed under the MIT License — you're free to use, modify, and share it. (Add a `LICENSE` file if you publish it.)
