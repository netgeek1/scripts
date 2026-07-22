# audiobook-tagger

Scan, identify, tag, verify and report on an audiobook library, writing
Plex- and Audiobookshelf-friendly tags across MP3, M4B/M4A, FLAC and OGG.

Metadata comes from Audible's public catalog by default — no account, no API
key. Every write is snapshotted first, so any run can be undone.

---

## Install

```
py -m pip install mutagen certifi rapidfuzz PyYAML Pillow
```

Only `mutagen` is strictly required. The rest are strongly recommended:

| Package | Without it |
|---|---|
| `mutagen` | nothing works — hard requirement |
| `certifi` | `CERTIFICATE_VERIFY_FAILED` on Windows when reaching Audible |
| `rapidfuzz` | matching falls back to `difflib`, noticeably worse |
| `PyYAML` | config must be JSON instead of YAML |
| `Pillow` | covers are embedded at whatever size they arrive |

Python 3.8+. Use `py` rather than `python` on Windows — the launcher works
regardless of PATH.

---

## Quick start

Run it with no arguments for the menu (or `py audiobook_tagger.py menu`):

```
py audiobook_tagger.py
```

```
==========================================================================
  audiobook-tagger
==========================================================================
  library   : C:\Users\Administrator\OpenAudible\books
  providers : audible, openaudible, existing, folder
  tag flags : --plex --ask-asin --report html,csv,json
  dry run   : NOT yet run

  ACTIONS
   1. Doctor        - config, providers, TLS, per-book matching (no writes)
   2. Tag DRY RUN   - show exactly what would change
   3. Tag WRITE     - apply tags
   4. Tag MANUAL    - prompt on every book, then write
   5. Verify        - report gaps in current tags
   6. Report        - inventory, no lookups
   7. Match         - show matches only, never writes
   8. Cover         - fetch and embed covers only
   9. Normalize     - rewrite existing tags consistently, no lookups
  10. Organize      - move folders into Author/Series/Book NN - Title
  11. Rename        - rename track files consistently
  12. Rollback      - restore tags from a snapshot
  13. Find library JSON files on disk

  SETTINGS
   L. Library path        T. Tag options        M. Matching and prompts
   P. Providers           N. Network and output C. Config file
   Q. Quit
```

Every command and every flag is reachable from here — nothing is
command-line only. The settings screens cover:

- **T — Tag options**: Plex mapping, `--force`, `--renumber`, `--only-missing`,
  cover-file writing, snapshots on/off, cover mode (auto/replace/keep/remove),
  genre, cover size, Audible genre.
- **M — Matching and prompts**: `--ask-asin`, `--manual`, `--yes`, and the
  `ask_below` / `match_threshold` / `title_only_threshold` values.
- **P — Providers**: add, remove, reorder, or apply a preset.
- **N — Network and output**: network on/off, debug dumping, verbosity,
  workers, Audible region, report formats.
- **C — Config file**: choose one, clear the override, write a fresh default,
  or print the current settings as config keys to paste in.

Each action prints the exact command line it is about to run, so the menu
doubles as a way to learn the CLI.

Option 3 refuses to write until a dry run has been done with the same
settings, unless you type `WRITE` to override.

The recommended first sequence is **1 → 2 → 3**: confirm the providers are
reachable, read the dry-run report, then commit.

---

## Command line

```
py audiobook_tagger.py [global options] <command> [library] [command options]
```

| Command | Does |
|---|---|
| `doctor` | Diagnose config, providers, TLS and per-book matching. Writes nothing. |
| `tag` | Identify and write tags. The main command. |
| `verify` | Check the library as it stands, report gaps. |
| `report` | Inventory without any lookups. |
| `cover` | Fetch and embed covers only. |
| `match` | Show what would be matched; forced dry run. |
| `normalize` | Rewrite existing tags consistently, no lookups. |
| `organize` | Move folders into `Author/Series/Book NN - Title`. |
| `rename` | Rename track files consistently. |
| `rollback` | Restore tags from a backup snapshot. |
| `menu` | Interactive menu; also the default with no arguments. |
| `inspect` | Dump every raw tag frame in a file or folder, plus how the tool reads them. |

Global options: `-c CONFIG`, `-v`, `-q`, `-j WORKERS`, `-p/--providers LIST`,
`-y/--yes`, `--no-network`, `--debug-data`, and `-o/--option KEY=VALUE` to
override any config key without editing the file:

```
py audiobook_tagger.py -o ask_below=95 -o audible_region=uk tag D:\Audiobooks
```

`tag` options: `--plex`, `--force`, `--renumber`, `--only-missing`,
`--ask-asin`, `--manual`, `--dry-run`, `--replace-cover`, `--keep-cover`,
`--remove-cover`, `--write-cover-file`, `--no-backup`, `--report FORMATS`.

Typical run:

```
py audiobook_tagger.py -c config.yaml tag --plex --force --renumber --dry-run
py audiobook_tagger.py -c config.yaml tag --plex --force --renumber
```

### Series sorting in Plex

The album tag stays the book title. The **album-sort** tag carries the series:

```
album (TALB / ©alb / ALBUM)          The Last Hope
sort  (TSOA / soal / ALBUMSORT)      Omen of the Stars 06 - The Last Hope
```

Set the Plex library to **Album sorting: By Name** and the series groups in
reading order under the author, while each book keeps its own cover, summary
and progress. Zero-padding means book 10 does not sort before book 2; a series
without a number gets `Series - Title`.

If you would rather see the series in the album tag itself:

```yaml
album_template: "{series} {index2} - {title}"     # default is "{title}"
```

Fields: `{title}` `{series}` `{index}` `{index2}` `{author}` `{year}`
`{narrator}`. Books with no series fall back to the title alone.

### Chapter names (multi-file books)

Plex shows the TITLE tag as the chapter name. By default every file in a book
carries the book title, so a 30-file book shows 30 identically named tracks.
`chapter_title_template` fixes that without depending on filenames:

```yaml
chapter_title_template: "Chapter {track}"        # Chapter 1, Chapter 2, ...
# or "{title} - Part {track2}"                   # Six of Crows - Part 01
# or "{title} ({track}/{total})"                 # Six of Crows (1/5)
```

Fields: `{track}` `{track2}` `{total}` `{title}` `{series}` `{index}`
`{index2}` `{author}` `{narrator}` `{year}`. Single-file books (a chaptered
M4B) always keep the book title — the template only applies where a book is
split across files. A template without `{track}` or `{track2}` warns, since
every file would end up identically named.

Menu **T → 15**. The TITLE tag counts as the `title` field, so an existing
title needs `--overwrite-fields title` (or `--force`) to be replaced.

`--chapter-titles` is the older behaviour: derive each file's title from its
filename. Only useful after `rename` has normalised them.

### Overwriting selectively

By default nothing already populated is touched, which is safe but leaves
inconsistent tags in place. `--force` overwrites everything.
`--overwrite-fields` sits between the two.

**They are alternatives, not partners.** `--force` overwrites every field, so
combining it with `--overwrite-fields` makes the list meaningless — the run
warns when both are set. In the menu that means turning **T → 2** (force) off
before **T → 11** (field list) does anything.

```
py audiobook_tagger.py tag D:\Audiobooks --plex --overwrite-fields title,comment
```

Run `py audiobook_tagger.py fields` for the full field-to-tag mapping. Two
that catch people out:

- **`author` is the Artist tag (TPE1); `albumartist` is Album Artist (TPE2).**
  They are separate tags with separate field names. `--plex` sets both to the
  author, but listing only `author` leaves the Album Artist tag alone — which
  matters, since rippers often park the narrator there. List both.
- **`track` is driven by `--renumber`**, not by a provider, and `--renumber`
  rewrites track numbers 1..N in file order regardless of the overwrite
  settings. Leave it off to keep existing track numbers.

`track` and `disc` work here too; `--renumber` is the shorthand for rewriting
track numbers 1..N in file order.

### Series

Series is written to two places, because readers disagree on where to look:

| | Series name | Number |
|---|---|---|
| ID3 (MP3) | `MVNM` + `TXXX:SERIES` | `MVIN` + `TXXX:SERIES-PART` |
| MP4 (M4B/M4A) | `©mvn` + `SERIES` freeform | `©mvi` + `SERIES-PART` freeform |
| Vorbis | `MOVEMENTNAME` + `SERIES` | `MOVEMENT` + `SERIES-PART` |

**Use the movement frames** (`MVNM`/`MVIN`, `©mvn`/`©mvi`) if you have to pick
one. They are the iTunes "Album Movement" fields, they are what Audiobookshelf
and most audiobook players read, and unlike `TXXX` they survive editors that
drop unknown user frames. `TXXX:SERIES` is written alongside for tools that
expect it. Control this with `series_frames: txxx | movement | both`
(default `both`). The sort field `TSOA` still gets `Series NN - Title` so a
series sorts in reading order in Plex.

### Organize and rename

Both use the resolved metadata — the same provider chain as `tag`, not the raw
folder names — and both are template-driven:

```yaml
organize_template: "{author}/{series}/Book {index2} - {title}"
organize_template_no_series: "{author}/{title}"
rename_template: "{track2} - {title}"
```

Available fields: `{author}` `{title}` `{series}` `{index}` `{index2}`
`{narrator}` `{year}` `{asin}` `{track}` `{track2}` `{total}`. `index2` and
`track2` are zero-padded. Empty fields collapse rather than leaving stray
separators.

`organize` refuses to move a book that matched below 100% and has no ASIN —
moving folders on a guess is not recoverable the way a tag write is. Tag first,
then organize.

### Placeholder tags

Ripper placeholders are ignored rather than treated as real metadata:
`Unknown Album`, `Unknown Artist`, `Untitled`, `Track 3`, `<unknown>`, and
Windows Media Player's dated form `Unknown Album (4/6/2009 11:31:23 AM)`.
Without this they propagate into search queries, folder names and filenames.
Genuine titles that merely start with the word are unaffected —
`Unknown Soldier` is kept.

Shelf shorthand at the front of a title is also stripped before searching, so
`SoS1 - The Shadow of Saganami` is looked up as `The Shadow of Saganami`.

### File timestamps

Writing a tag rewrites the file, which normally resets its modified date and
loses the library's chronology. `preserve_mtime` (on by default) captures each
file's access and modified times before the write and restores them after. On
Windows the NTFS creation time is restored too, via `SetFileTime`.

Turn it off with `--no-preserve-mtime`, or menu **T → 13**, if you would rather
see which files a run actually touched.

`rollback` preserves timestamps the same way, so undoing a run does not stamp
every file with the current time either.

### Comments

Audible has no comment field, so `comment_source` decides what a comment
should contain:

| Value | Comment becomes |
|---|---|
| `summary` *(default)* | the book description from Audible |
| `series` | `Series, Book N` (or just the series when there's no number) |
| `both` | series line, blank line, then the description |
| `none` | comments are left alone entirely |

**`provider_order` needs `existing` and `folder`.** Dropping them is a common
mistake: with only `audible` in the chain, any field Audible does not supply
(comments, for instance — Audible has no comment field) is empty, and empty
fields are never written, so the old value stays on disk. The tool warns when
either is missing. A good default is `[audible, existing, folder]`.

`--force` is needed to correct tags that are already populated but wrong
(a series-prefixed album, for instance). Without it, nothing populated is
touched.

---

## Configuration

If no config file is found, one is written next to the script as
`audiobook-tagger.yaml`, fully commented, with any discoverable OpenAudible
paths pre-filled. Edit `library` and re-run.

Discovery order: `-c` if given, then `audiobook-tagger.{yaml,yml,json}` in the
working directory, then the same names next to the script.

The menu persists its settings. Changing anything marks the session dirty,
quitting offers to save, and **C → 1** saves on demand. Saving re-renders the
commented file with your values, so the explanatory comments survive.
Everything the menu toggles has a config key, so the settings you save become
the defaults for plain command-line runs too.

Keys that matter most:

```yaml
library: "C:/Users/Administrator/OpenAudible/books"
provider_order: [audible, openaudible, existing, folder]
audible_region: us
genre: "Audiobook"
match_threshold: 82
title_only_threshold: 90
ask_below: 100
```

**`provider_order` is precedence.** The first provider to supply a field wins;
later ones only fill gaps. Put the source you trust most first. `folder`
(inference from the directory layout) should stay last.

Available providers: `audible`, `openaudible`, `existing`, `openlibrary`,
`google`, `musicbrainz`, `folder`.

Override without editing the file:

```
py audiobook_tagger.py -p audible,existing,folder tag D:\Audiobooks
```

---

## What gets written

Plex reads the standard frames; the `TXXX` frames are what Audiobookshelf and
similar servers pick up.

| Field | ID3 | MP4 | Vorbis |
|---|---|---|---|
| Book title | `TALB` | `©alb` | `ALBUM` |
| Author | `TPE1` / `TPE2` | `©ART` / `aART` | `ARTIST` / `ALBUMARTIST` |
| Narrator | `TCOM` | `©wrt` | `COMPOSER` + `NARRATOR` |
| Track | `TRCK` as `n/total` | `trkn` | `TRACKNUMBER` + `TRACKTOTAL` |
| Publisher | `TPUB` | `©pub` | `PUBLISHER` |
| Year | `TDRC` | `©day` | `DATE` |
| Language | `TLAN` (ISO-639-2) | freeform | `LANGUAGE` |
| Description | `COMM:description` | `desc` / `ldes` | `DESCRIPTION` |
| Series / index | `TXXX:SERIES` / `SERIES-PART` | freeform | `SERIES` / `SERIES-PART` |
| ASIN | `TXXX:ASIN` | freeform | `ASIN` |
| Book page | `TXXX:AUDIBLE_URL` | freeform | `AUDIBLE_URL` |
| Author page | `TXXX:AUTHOR_URL` | freeform | `AUTHOR_URL` |
| Sort fields | `TSOA` / `TSO2` / `TSOP` | `soal` / `soaa` | — |

`TSOA` is built as `Series NN - Title` so a series sorts in reading order in
Plex while the album keeps its real title.

---

## Matching

1. **ASIN** — from an existing tag, or found in a folder name or filename
   (`Foundation [B005T6ZETM]`). Exact, always preferred.
2. **Folder path** — OpenAudible records each book's path; an exact match beats
   any fuzzy guess.
3. **Title + author** — scored, and held to the higher `title_only_threshold`,
   because title-only matching is the weakest evidence available.

Scoring blends token-set with sequence similarity. Pure token-set rates
"Foundation and Earth" against "Foundation" at 100, which silently tags the
wrong book; the blend scores it 78.

**Search is keyword-first.** Audible's `title` parameter matches the full
product title, and series entries are named
`Warriors: Omen of the Stars #6: The Last Hope` — so `title=The Last Hope`
returns nothing, exactly as it would on the website. Queries are tried as
`keywords+author`, `keywords`, `title+author`, `title`, stopping at the first
that returns results.

Candidate titles are also compared against their trailing segment, so
`The Last Hope` scores 100 against that full product name instead of 58. The
series prefix is then stripped from the title that gets written
(`strip_series_from_title`, on by default), so the album tag reads
`The Last Hope` while the series fields carry `Omen of the Stars #6`.

Use the `search` command to see exactly what Audible returns for a phrase:

```
py audiobook_tagger.py search "The Last Hope" --author "Erin Hunter"
```

It prints each strategy, the parameters sent, how many results came back, and
each candidate's score against the acceptance floor. Menu option 15.

Several search terms are tried before a book is given up on. An album tag that
matches the parent folder is a series or box-set name, not a title
("Warriors 1: The Prophecies Begin"), so the book's own folder name is used
instead and the album becomes the series. If the first query returns nothing,
the folder-derived title is tried next.

When a book matches below `ask_below` and `--ask-asin` is set, you get scored
candidates and a prompt:

```
  UNCERTAIN MATCH  (no match)
  folder : ...\Foundation Series\2 - Forward
  best   : 'Forward' by 'Isaac Asimov'

  Audible candidates:
    1. [ 76.5] Forward the Foundation | Isaac Asimov | Larry McKeever | 2011-10-19 | Foundation #2 | B005WWT30E

  Enter a number, paste an ASIN (B0XXXXXXXX), 's' to skip this book,
  or press Enter to accept the best match as-is.
```

Typing anything that is not a number, ASIN, ID or URL runs a fresh Audible
search for that text and redraws the candidate list, so a book the automatic
queries could not find can be located by hand without leaving the run.

`--manual` prompts on every book regardless of score. `--yes` never prompts —
use it for scheduled tasks so they cannot hang waiting for input.

Prompting forces single-threaded operation so the output stays readable.

---

## Undo

Every file touched is snapshotted **before** it is written, cover art
included. Each entry is appended to `snapshot.jsonl` and flushed to disk
immediately, so a crash, a kill, or Ctrl-C still leaves a complete record of
everything already changed. `snapshot.json` is written at the end as a
convenience; rollback reads whichever exists.

```
py audiobook_tagger.py rollback --list       # what is available
py audiobook_tagger.py rollback              # most recent snapshot
py audiobook_tagger.py rollback 20260720-180720
py audiobook_tagger.py rollback -n           # preview
```

`--list` marks any snapshot whose run did not finish:

```
  snapshots under C:\audiobook-tagger\backups
    20260721-191702      4 file(s)  INTERRUPTED - partial run
```

Ctrl-C during a run stops cleanly rather than aborting mid-file, and prints the
rollback command for that run.

Rollback restores the fields this tool manages. It does not restore foreign
frames it never read.

Backup directories are relative to the working directory by default — set
`backup_dir` to an absolute path if you run from more than one place, or
rollback won't find the snapshot.

---

## Reports

Written to `reports/` as HTML, CSV and JSON. Columns worth watching:

- **providers** — which sources actually contributed. If `audible` is absent,
  it isn't being consulted.
- **score** — match confidence. Anything under 100 deserves a look.
- **issues** — real problems (missing author, cover, publisher…).
- **notes** — informational only, e.g. unusual track numbering. No provider
  supplies track numbers, so this never counts as a failure.

---

## Troubleshooting

**`CERTIFICATE_VERIFY_FAILED` / `unable to get local issuer certificate`**
Python has no usable CA bundle. `py -m pip install certifi` fixes most cases.
Behind a TLS-inspecting proxy or AV, export its root to PEM and set
`ca_bundle: "C:/path/root.pem"`. Last resort: `ssl_verify: false`.

**`SyntaxError: Non-UTF-8 code starting with '\x96'`**
The file was saved as ANSI. The source is pure ASCII as shipped — re-download
rather than re-saving from an editor set to ANSI.

**`'python' is not recognized`**
Use `py`.

**A provider contributes nothing**
Run `doctor`. It shows which config was loaded, every path checked for
OpenAudible's JSON, per-field coverage of what that JSON can supply, a live
Audible probe, and per-book match results for both providers.

**Wrong metadata got written**
`rollback`, then raise `title_only_threshold`, or re-run with `--ask-asin`.

**M4A/M4B tracks show as a bare number, not `n/total`**
That is a storage difference, not a bug. ID3 keeps `TRCK` as one string
(`"1/30"`); MP4 keeps `trkn` as a pair, and most tag editors show only the
first half in a Track column. Run `inspect` to see the real pair, e.g.
`trkn [(1, 2)]`. If the total is genuinely `0`, `verify` reports
`track total missing (n of 0)` and `--renumber` fixes it.

**Tags don't look right**
`py audiobook_tagger.py inspect "D:\Audiobooks\Author\Book"` prints every raw
frame in every file plus the parsed interpretation, so you can see exactly what
is on disk rather than trusting a tag editor's column layout.

**Everything, in detail**
`--debug-data` logs every provider response and dumps the raw JSON under
`logs/payloads/<date>/`, numbered in call order, alongside the parsed result
for each book.

---

## Notes and limits

- Audible's catalog endpoint is public but undocumented. Field names can
  change and heavy use may be rate-limited; every call fails soft and the
  chain continues to the next provider.
- Roughly two HTTP calls per book (search plus cover) at about one per
  second. Once ASINs are written, later runs match by ASIN directly — faster
  and exact.
- OpenAudible's internal `books.json` is often far sparser than its
  File → Export dump. `doctor --find-json` finds every library JSON on disk
  and reports which fields each one actually carries.
- `--dry-run` changes nothing and still produces a full report.
