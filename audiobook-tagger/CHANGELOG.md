# Changelog

All notable changes to audiobook-tagger. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versioning is
[semantic](https://semver.org/).

---

## [1.28.0] - 2026-07-21

### Fixed
- `rename` skipped single-file books entirely (the `total < 2` guard), so a
  lone `Book.m4b` was never renamed. Single-file books now use
  `rename_template_single` (default `{title}`).
- `organize` built its `Author/Series/Book` tree under whatever path it was
  given, so pointing it at one book folder nested the destination inside the
  source (`Cannot move a directory into itself`). It now roots the tree at the
  configured library, or climbs to a safe base, and skips any move whose
  destination is inside its source.
- Series titles that reduce to a generic marketing subtitle
  (`He Who Fights with Monsters 9: A LitRPG Adventure`) no longer lose their
  real name — the `Series N` form is kept instead of `A LitRPG Adventure`.

### Added
- `rename_template_single` for single-file books.

---

## [1.27.0] - 2026-07-21

### Fixed
- `album_template` was rendered before the `--plex` field mapping, which then
  overwrote it. It is now applied last.
- Album-sort no longer doubles the series prefix when `album_template` already
  contains it (`Series 06 - Series 06 - Title`). The sort string is built from
  the title rather than the rendered album.

### Added
- `album_template` exposed in the config file and menu (**T → 16**).

---

## [1.26.0] - 2026-07-21

### Fixed
- **Album-sort was only correct for MP3.** MP4 wrote `soal` as the bare book
  title and Vorbis wrote no sort tag at all, so series did not group in Plex
  for M4B/M4A libraries. All three formats now share one builder producing
  `Series 06 - Title`, zero-padded, falling back to `Series - Title` when the
  volume has no number.

### Added
- `album_template` (default `{title}`) for putting the series in the visible
  album tag instead of relying on sort order.

---

## [1.25.0] - 2026-07-21

### Added
- `chapter_title_template` for the TITLE tag on multi-file books, which Plex
  displays as the chapter name — e.g. `Chapter {track}`,
  `{title} - Part {track2}`. Single-file books keep the book title. Warns if
  the template contains no `{track}`/`{track2}`, since every file would then
  be named identically.

---

## [1.24.0] - 2026-07-21

### Changed
- **Backups are now incremental.** Each entry is appended to `snapshot.jsonl`
  and fsync'd *before* its file is written, so a crash, kill or Ctrl-C still
  leaves a complete record of everything already changed. `snapshot.json` is
  still written at the end; rollback reads either. Truncated final lines are
  skipped with a warning.
- Ctrl-C stops cleanly, cancels pending work, finalises the snapshot and prints
  the exact rollback command.

### Added
- `rollback --list`, marking runs that did not finish as `INTERRUPTED`.
- `rollback` accepts a bare snapshot name as well as a path.

---

## [1.23.0] - 2026-07-21

### Added
- `fields` command listing every field name and the tag it writes per format.
- Warning when `--overwrite-fields` includes `author` but not `albumartist` —
  they are different tags (TPE1 vs TPE2), and rippers often park the narrator
  in Album Artist.
- Menu validates field names when entering an overwrite list.

---

## [1.22.0] - 2026-07-21

### Fixed
- **Audible search is keyword-first.** The `title` parameter matches a
  product's full title, and series entries are named
  `Warriors: Omen of the Stars #6: The Last Hope`, so `title=The Last Hope`
  returned nothing. Strategies now run keywords+author → keywords →
  title+author → title.
- Candidate titles are compared against their trailing segment too, so
  `The Last Hope` scores 100 against that full product name instead of 58 —
  previously the right book was fetched and then discarded.

### Added
- `strip_series_from_title` (default on) so the album tag reads `The Last Hope`
  rather than Audible's full product title.
- `search` command showing each strategy, the parameters sent, result counts
  and per-candidate scores against the acceptance floor. Menu option 15.

---

## [1.21.0] - 2026-07-21

### Added
- Warning when `--force` and `--overwrite-fields` are combined — force
  overwrites everything, making the field list meaningless.
- The echoed command line is shell-quoted so it can be pasted directly.

---

## [1.20.0] - 2026-07-21

### Fixed
- An album tag matching the parent folder is a series or box-set name, not a
  title (`Warriors 1: The Prophecies Begin`). The book's own folder name is
  used instead and the album becomes the series.
- Several search terms are tried before giving up, so a junk album tag no
  longer sinks an otherwise findable book.

### Added
- Typing free text at the ASIN prompt runs a fresh Audible search and redraws
  the candidate list.

---

## [1.19.0] - 2026-07-21

### Fixed
- Ripper placeholders (`Unknown Album`, `Unknown Artist`, `Track 3`,
  `<unknown>`, and Windows Media Player's `Unknown Album (4/6/2009 ...)`) are
  ignored rather than treated as titles and propagated into searches, folder
  names and filenames. Genuine titles like `Unknown Soldier` are kept.
- Shelf shorthand is stripped before searching (`SoS1 - The Shadow of
  Saganami` → `The Shadow of Saganami`).
- A bare Enter at the main menu redraws instead of quitting; only `Q`/`quit`/
  `exit` or EOF exits.

---

## [1.18.0] - 2026-07-21

### Added
- `preserve_mtime` (default on): each file's access and modified times are
  restored after a write, and on Windows the NTFS creation time too, via
  `SetFileTime`. `rollback` preserves them the same way. `--no-preserve-mtime`
  opts out.

---

## [1.17.0] - 2026-07-20

### Fixed
- **Multi-value ID3 frames were being concatenated.** ID3v2.3 separates several
  values with `/`, and `safe_name` deleted it as an illegal filename character,
  producing `Kristen WelchMeredith Mitchell`. Now `Kristen Welch, Meredith
  Mitchell`.
- `organize`/`rename` had their provider chain hardcoded to `existing, folder`,
  so they inherited junk tags instead of using the configured providers.
- Audible IDs are not always `B0xxxxxxxx`; ten-digit numeric IDs and pasted
  `audible.com/pd/...` URLs are now accepted.
- Cataloguing noise is stripped before searching (`Book 9 (Special) - Author -
  Title`, `Title (Series #1) by Author`).

### Added
- Series written to iTunes movement frames (`MVNM`/`MVIN`, `©mvn`/`©mvi`,
  `MOVEMENTNAME`/`MOVEMENT`) alongside `TXXX:SERIES`, controlled by
  `series_frames`.
- `organize_template`, `organize_template_no_series`, `rename_template`.
- Path diagnostics: close-name suggestions, case differences, stray whitespace,
  en/em dashes and curly quotes. The menu validates a library path on entry.
- `organize` refuses to move a book that matched below 100% with no ASIN.

---

## [1.16.0] - 2026-07-20

### Fixed
- A file carrying both `TDRC` and `TYER`/`TDAT` displayed as
  `2014\2014-06-17`. The year write now honours `--overwrite-fields year`, and
  normalising a date to its year no longer requires forcing at all.

### Added
- `verify` reports missing track totals (`n of 0`) as a note.

---

## [1.15.0] - 2026-07-20

### Added
- `comment_source`: `summary` (default), `series`, `both`, `none` — Audible has
  no comment field, so this decides what a comment should contain.
- **Menu settings persist.** Changes mark the session dirty, quitting offers to
  save, **C → 1** saves on demand. Saving re-renders the commented config with
  current values. Every menu toggle has a config key, so saved settings also
  apply to plain command-line runs.

---

## [1.14.0] - 2026-07-20

### Fixed
- `--overwrite-fields track` and `disc` were silently ignored; only
  `--force`/`--renumber` reached those writes.
- `--plex` unconditionally forced the flat genre, discarding `audible_genre`.

### Added
- Warnings when `provider_order` omits `existing` or `folder`.

---

## [1.13.0] - 2026-07-20

### Fixed
- **MP3 comments were never written.** `_write_id3` wrote a description frame
  but never `m.comment`; MP4 and Vorbis did. Now written as `COMM` with an
  empty description, which is what tag editors show as "Comment".

### Added
- `--overwrite-fields LIST` — overwrite named fields without `--force`.
- The `--plex` comment is deterministic instead of preferring an existing one.

---

## [1.12.0] - 2026-07-20

### Fixed
- Files sorted lexicographically, so `Part 10` landed between `Part 1` and
  `Part 2` and track numbers came out wrong. Now natural-sorted.
- Per-file titles were derived from filenames and collapsed inconsistently, so
  files in one book disagreed. Every file now carries the book title;
  `--chapter-titles` restores the old behaviour.
- Year is written as a single 4-digit value, clearing `TYER`/`TDAT`/`TDRL`/
  `TORY`/`TRDA` first.

### Added
- `inspect` command: raw tag frames plus the parsed interpretation.

---

## [1.11.0] - 2026-07-20

### Added
- Every command and flag reachable from the menu, across five settings screens
  (tag options, matching, providers, network/output, config).
- `-o/--option KEY=VALUE` to override any config key from the command line.
- Explicit `menu` subcommand.

---

## [1.10.0] - 2026-07-20

### Added
- `TXXX:AUTHOR_URL` built from Audible's author ASIN.
- Interactive menu, with a write guard requiring a dry run first.
- `--manual` (prompt on every book) and `-y/--yes` (never prompt).
- A commented config is written automatically when none is found.
- README.

### Fixed
- `--plex` album mapping is re-applied after a manual ASIN pick.

---

## [1.9.0] - 2026-07-20

### Added
- `-p/--providers` to override the provider order without a config file.
- `doctor` queries Audible per sampled book, not just once.

---

## [1.8.0] - 2026-07-20

### Fixed
- Title-only matches are held to a higher floor (`title_only_threshold`,
  default 90). `Foundation and Empire` scored 88 against `Foundation and Earth`
  once the author agreed — a wrong book, not a match.
- `--plex` no longer overrides `audible_genre`.

### Added
- TLS handling: certifi support, `ca_bundle`, `ssl_verify`, and targeted advice
  when a probe fails with `CERTIFICATE_VERIFY_FAILED`.
- Audible cover art requested at up to 2400px, upscaling the CDN filename.
- Default provider order puts `audible` first.

---

## [1.7.0] - 2026-07-20

### Added
- **Audible catalog provider** using the public, unauthenticated
  `/1.0/catalog/products` endpoint — no account or API key. Supplies narrator,
  publisher, summary, release date, series and index, ASIN, language and cover
  art. Region-selectable via `audible_region`.
- `doctor` probes Audible live and reports the result.

---

## [1.6.0] - 2026-07-20

### Added
- `--find-json` also scans the working directory, the script's folder, Desktop,
  and `\OpenAudible` on other fixed drives; `--scan PATH` adds more.
- Per-field counts in the scan output rather than present/absent.

---

## [1.5.0] - 2026-07-20

### Added
- `doctor --find-json`: searches the disk for library JSON files and reports
  which fields each one actually contains.

---

## [1.4.0] - 2026-07-20

### Fixed
- Cover art indexed recursively, since OpenAudible nests it under `art\`.
- Match hints have collection words trimmed (`Foundation Series` vs
  `Foundation`) before prefix stripping.

---

## [1.3.0] - 2026-07-20

### Fixed
- Path matching used `token_set_ratio`, which scored
  `...series 7 foundation and earth` against `...series 3 foundation` at 97 and
  matched the wrong volume. Now sequence-based with a 97 floor.
- Merged OpenAudible entries keyed on folder path rather than ASIN, which had
  split one book into two records.

### Added
- Multiple OpenAudible JSON sources merged, earlier files winning.
- Field-coverage table in `doctor`.

---

## [1.2.0] - 2026-07-20

### Fixed
- Series-prefixed titles (`Foundation 01 - Prelude to Foundation`) are stripped
  to the book title, with the number harvested as the series index.
- Track sequences validated per disc rather than across the whole book.

### Added
- `doctor` command.
- `--renumber` to rewrite track numbers 1..N without a full `--force`.

---

## [1.1.0] - 2026-07-19

### Fixed
- OpenAudible provider rewritten against the real schema — `narrated_by`, not
  `narratedBy`. HTML stripped from summaries, language normalised to ISO-639-2,
  cover lookup repaired.
- Books matched on their recorded folder path rather than fuzzy title guessing.
- A missing OpenAudible library is a visible warning listing every path tried.

### Added
- `openaudible_json`, `openaudible_genre`.

---

## [1.0.1] - 2026-07-19

### Fixed
- Source is pure ASCII with an encoding declaration. Literal en/em dashes in
  regexes became invalid bytes when the file was saved as ANSI on Windows,
  producing `SyntaxError: Non-UTF-8 code starting with '\x96'`.

---

## [1.0.0] - 2026-07-19

### Added
- Initial release. Scans a library, identifies books through a configurable
  provider chain, and writes Plex- and Audiobookshelf-friendly tags across MP3,
  M4B/M4A, FLAC and OGG.
- Providers: existing tags, OpenAudible, Open Library, Google Books,
  MusicBrainz, folder inference.
- Cover art download, resize and embed. Verification, duplicate detection, and
  HTML/CSV/JSON reports. Dry-run mode. Transaction-safe rollback. Parallel
  processing. YAML/JSON config and daily logs.
