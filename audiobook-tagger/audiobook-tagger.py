#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
audiobook-tagger 1.27.0

Scan, identify, tag, verify and report on an audiobook library, writing
Plex- / Audiobookshelf-friendly tags across MP3, M4B/M4A, FLAC and OGG.

Every write is snapshotted first, so `rollback` can restore the previous
state of the fields this tool manages.

Required:  mutagen
Optional:  PyYAML (yaml config), rapidfuzz (better matching), Pillow (cover resize)

Author: netgeek1 / certifiedgeeks.net
License: MIT
"""

from __future__ import annotations

import argparse
import base64
import csv
import dataclasses
import datetime as dt
import hashlib
import html
import json
import logging
import os
import re
import shutil
import sys
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

__version__ = "1.27.0"
PROGRAM = "audiobook-tagger"

# --------------------------------------------------------------------------
# optional dependencies
# --------------------------------------------------------------------------

try:
    import mutagen
    from mutagen.flac import FLAC, Picture
    from mutagen.id3 import (
        APIC, COMM, ID3, ID3NoHeaderError, MVIN, MVNM, TALB, TCOM, TCON, TDRC, TIT2,
        TIT3, TLAN, TPE1, TPE2, TPOS, TPUB, TRCK, TSO2, TSOA, TSOP, TXXX,
    )
    from mutagen.mp3 import MP3
    from mutagen.mp4 import MP4, MP4Cover
    from mutagen.oggvorbis import OggVorbis
except ImportError:  # pragma: no cover
    sys.stderr.write("FATAL: mutagen is required.  pip install mutagen\n")
    raise SystemExit(2)

try:
    import yaml
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False

import difflib

try:
    from rapidfuzz import fuzz as _rf_fuzz
    HAVE_RAPIDFUZZ = True
except ImportError:
    HAVE_RAPIDFUZZ = False

try:
    from PIL import Image
    import io as _io
    HAVE_PIL = True
except ImportError:
    HAVE_PIL = False

try:
    import certifi
    HAVE_CERTIFI = True
except ImportError:
    HAVE_CERTIFI = False

import ssl

log = logging.getLogger(PROGRAM)

_SSL_CTX: Dict[str, Any] = {}
_SSL_LOCK = threading.Lock()


def ssl_context(cfg: Dict[str, Any]):
    """Build (once) the TLS context used for every outbound request.

    Windows Pythons frequently cannot find a CA bundle, producing
    CERTIFICATE_VERIFY_FAILED / 'unable to get local issuer certificate'.
    certifi solves it; a corporate TLS-inspecting proxy needs its own root
    exported to PEM and named in 'ca_bundle'.
    """
    key = f"{cfg.get('ssl_verify')}|{cfg.get('ca_bundle')}"
    with _SSL_LOCK:
        if key in _SSL_CTX:
            return _SSL_CTX[key]
        if not cfg.get("ssl_verify", True):
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            log.warning("TLS verification DISABLED (ssl_verify: false) - "
                        "traffic is encrypted but the server is not authenticated")
        else:
            bundle = str(cfg.get("ca_bundle") or "").strip()
            if bundle:
                ctx = ssl.create_default_context(cafile=bundle)
                log.debug("TLS using CA bundle %s", bundle)
            elif HAVE_CERTIFI:
                ctx = ssl.create_default_context(cafile=certifi.where())
                log.debug("TLS using certifi bundle %s", certifi.where())
            else:
                ctx = ssl.create_default_context()
        _SSL_CTX[key] = ctx
        return ctx

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------

AUDIO_EXTS = {".mp3", ".m4b", ".m4a", ".flac", ".ogg"}
COVER_NAMES = ("cover", "folder", "front", "artwork", "albumart")
COVER_EXTS = (".jpg", ".jpeg", ".png")
USER_AGENT = f"{PROGRAM}/{__version__} (+https://certifiedgeeks.net)"

# fields this tool reads and writes, in report order
FIELDS = [
    "title", "subtitle", "author", "narrator", "series", "series_index",
    "album", "albumartist", "genre", "year", "publisher", "description",
    "language", "asin", "isbn", "audible_url", "author_url", "original_release",
    "track", "disc", "comment",
]

DEFAULT_CONFIG: Dict[str, Any] = {
    "library": "",
    "genre": "Audiobook",
    "comment_source": "summary",   # summary | series | both | none
    "series_frames": "both",       # txxx | movement | both
    "strip_series_from_title": True,
    "preserve_mtime": True,        # keep each file's original timestamps
    "organize_template": "{author}/{series}/Book {index2} - {title}",
    "organize_template_no_series": "{author}/{title}",
    "rename_template": "{track2} - {title}",
    # TITLE tag for multi-file books; Plex shows it as the chapter name.
    # Empty = every file carries the book title. e.g. "Chapter {track}"
    "chapter_title_template": "",
    # Visible ALBUM tag. Default is the book title alone, with the series kept
    # in the sort tag. Use "{series} {index2} - {title}" to show it instead.
    "album_template": "{title}",
    "overwrite": False,
    "cover_size": 1000,
    "cover_quality": 88,
    "workers": min(12, (os.cpu_count() or 4)),
    "provider_order": ["audible", "openaudible", "existing", "openlibrary",
                       "google", "musicbrainz", "folder"],
    "audible_region": "us",
    "audible_genre": False,
    "openaudible_dir": "",
    "openaudible_json": "",   # str or list of paths; all are merged
    "openaudible_art_dir": "",
    "openaudible_genre": False,
    "google_api_key": "",
    "match_threshold": 82,
    "title_only_threshold": 90,
    "ask_below": 100,
    "network": True,
    "request_timeout": 15,
    "ssl_verify": True,
    "ca_bundle": "",
    "debug_data": False,
    "log_dir": "logs",
    "backup_dir": "backups",
    "report_dir": "reports",
    "skip_dirs": [".stversions", "@eaDir", "#recycle", ".git"],
    # menu-settable run options, so the menu can persist them
    "plex": False,
    "renumber": False,
    "only_missing": False,
    "chapter_titles": False,
    "write_cover_file": False,
    "no_backup": False,
    "ask_asin": False,
    "manual": False,
    "overwrite_fields": "",
    "cover_mode": "auto",
    "report_formats": "html,csv,json",
}


# ==========================================================================
# configuration
# ==========================================================================

CONFIG_SOURCE = "built-in defaults (no config file found)"


def coerce_like(current: Any, raw: str) -> Any:
    """Coerce a KEY=VALUE string to the type of the existing config value."""
    if isinstance(current, bool):
        return raw.strip().lower() in ("1", "true", "yes", "on", "y")
    if isinstance(current, int) and not isinstance(current, bool):
        return int(float(raw))
    if isinstance(current, float):
        return float(raw)
    if isinstance(current, list):
        return [x.strip() for x in raw.split(",") if x.strip()]
    return raw


def apply_overrides(cfg: Dict[str, Any], pairs: Optional[Sequence[str]]) -> None:
    for pair in pairs or []:
        if "=" not in pair:
            log.warning("ignoring malformed --option %r (expected KEY=VALUE)", pair)
            continue
        key, _, raw = pair.partition("=")
        key = key.strip()
        if key not in cfg:
            log.warning("ignoring unknown config key in --option: %s", key)
            continue
        try:
            cfg[key] = coerce_like(DEFAULT_CONFIG.get(key), raw)
        except ValueError:
            log.warning("ignoring --option %s: %r is not valid here", key, raw)


def load_config(path: Optional[str]) -> Dict[str, Any]:
    global CONFIG_SOURCE
    cfg = dict(DEFAULT_CONFIG)
    if not path:
        here = Path(__file__).resolve().parent
        for candidate in ("audiobook-tagger.yaml", "audiobook-tagger.yml",
                          "audiobook-tagger.json"):
            if Path(candidate).is_file():          # working directory first
                path = candidate
                break
            if (here / candidate).is_file():       # then next to the script
                path = str(here / candidate)
                break
    if not path:
        return cfg
    p = Path(path)
    if not p.is_file():
        raise SystemExit(f"config file not found: {p}")
    raw = p.read_text(encoding="utf-8")
    if p.suffix.lower() in (".yaml", ".yml"):
        if not HAVE_YAML:
            raise SystemExit("PyYAML not installed; use a .json config or pip install PyYAML")
        data = yaml.safe_load(raw) or {}
    else:
        data = json.loads(raw)
    unknown = set(data) - set(cfg)
    for k in unknown:
        log.warning("unknown config key ignored: %s", k)
    cfg.update({k: v for k, v in data.items() if k in cfg})
    CONFIG_SOURCE = str(p.resolve())
    return cfg


CONFIG_TEMPLATE = """\
# {program} {version} - configuration
#
# Written by the tool. Comments are preserved when the menu saves over it.
# Delete any key to fall back to its built-in default.
# Use a different file with:  -c C:/path/to/config.yaml

# --- what to process ---------------------------------------------------
# Library root. Any folder containing audio is one book; CD1/Disc 2/Part 3
# subfolders are folded into their parent.
library: "{library}"

# --- where metadata comes from -----------------------------------------
# Order IS precedence: the first provider to supply a field wins, later ones
# only fill gaps.
#   audible     - Audible's public catalog (no account needed)
#   openaudible - your local OpenAudible library JSON
#   existing    - tags already in the files      <- keep this
#   openlibrary / google / musicbrainz - fallbacks for non-Audible books
#   folder      - inferred from the directory layout, always last
# Dropping 'existing' means anything the other providers do not supply stays
# empty, and empty fields are never written - the old value survives on disk.
provider_order: [{provider_order}]

# --- Audible -----------------------------------------------------------
audible_region: {audible_region}          # us ca uk au de fr jp it es in br
audible_genre: {audible_genre}        # true = Audible's category, false = the flat genre below

# --- OpenAudible (optional) --------------------------------------------
openaudible_dir: "{openaudible_dir}"
openaudible_art_dir: "{openaudible_art_dir}"
# One path or a list; all are merged, earlier files win.
openaudible_json: "{openaudible_json}"

# --- what gets written -------------------------------------------------
genre: "{genre}"
# Audible has no comment field, so choose what a comment should contain:
#   summary - the book description   (default)
#   series  - "Series, Book N"
#   both    - series line, blank line, description
#   none    - leave comments alone
comment_source: {comment_source}
cover_size: {cover_size}
cover_quality: {cover_quality}
# Where the series name and number are written:
#   movement - MVNM/MVIN, the iTunes fields most audiobook players read
#   txxx     - TXXX:SERIES / TXXX:SERIES-PART
#   both     - both (default)
series_frames: {series_frames}
# Restore each file's original modified (and, on Windows, created) timestamp
# after writing tags, so the library keeps its chronology.
preserve_mtime: {preserve_mtime}
workers: {workers}

# --- default run options (the menu saves its toggles here) -------------
plex: {plex}
overwrite: {overwrite}              # same as --force
renumber: {renumber}
only_missing: {only_missing}
chapter_titles: {chapter_titles}
write_cover_file: {write_cover_file}
no_backup: {no_backup}
ask_asin: {ask_asin}
manual: {manual}
cover_mode: {cover_mode}            # auto | replace | keep | remove
report_formats: {report_formats}
# Overwrite only these fields even without --force, comma separated.
overwrite_fields: "{overwrite_fields}"

# --- folder and file naming (organize / rename) ------------------------
# Fields: {{author}} {{title}} {{series}} {{index}} {{index2}} {{narrator}}
#         {{year}} {{asin}} {{track}} {{track2}} {{total}}
# index2 and track2 are zero-padded. Empty fields collapse.
organize_template: "{organize_template}"
organize_template_no_series: "{organize_template_no_series}"
rename_template: "{rename_template}"
# TITLE tag for books split across several files. Plex shows TITLE as the
# chapter name, so identical titles give you N identically named tracks.
# Empty = every file gets the book title.
# Examples: "Chapter {{track}}"   "{{title}} - Part {{track2}}"   "{{title}} ({{track}}/{{total}})"
chapter_title_template: "{chapter_title_template}"
# Visible ALBUM tag. Default keeps the book title and leaves series grouping
# to the sort tag (set Plex to "Album sorting: By Name").
# Use "{{series}} {{index2}} - {{title}}" to put the series in the album itself.
album_template: "{album_template}"

# --- matching ----------------------------------------------------------
match_threshold: {match_threshold}
title_only_threshold: {title_only_threshold}   # stricter floor for title-only matches
ask_below: {ask_below}                # --ask-asin prompts below this score

# --- network / TLS -----------------------------------------------------
network: {network}
request_timeout: {request_timeout}
ssl_verify: {ssl_verify}
ca_bundle: "{ca_bundle}"

# --- output ------------------------------------------------------------
debug_data: {debug_data}
log_dir: "{log_dir}"
backup_dir: "{backup_dir}"
report_dir: "{report_dir}"
skip_dirs: [{skip_dirs}]
"""


def _yaml_bool(value: Any) -> str:
    return "true" if value else "false"


def _yaml_path(value: Any) -> str:
    return str(value or "").replace("\\", "/")


def render_config(cfg: Dict[str, Any]) -> str:
    """Render the commented template with real values."""
    def get(key):
        return cfg.get(key, DEFAULT_CONFIG.get(key))

    oa_json = get("openaudible_json")
    if isinstance(oa_json, list):
        oa_json = ", ".join(str(x) for x in oa_json)

    values = {
        "program": PROGRAM, "version": __version__,
        "library": _yaml_path(get("library")),
        "provider_order": ", ".join(get("provider_order") or []),
        "audible_region": get("audible_region"),
        "audible_genre": _yaml_bool(get("audible_genre")),
        "openaudible_dir": _yaml_path(get("openaudible_dir")),
        "openaudible_art_dir": _yaml_path(get("openaudible_art_dir")),
        "openaudible_json": _yaml_path(oa_json),
        "genre": get("genre"),
        "comment_source": get("comment_source"),
        "cover_size": int(get("cover_size")),
        "cover_quality": int(get("cover_quality")),
        "workers": int(get("workers")),
        "match_threshold": int(get("match_threshold")),
        "title_only_threshold": int(get("title_only_threshold")),
        "ask_below": int(get("ask_below")),
        "network": _yaml_bool(get("network")),
        "request_timeout": int(get("request_timeout")),
        "ssl_verify": _yaml_bool(get("ssl_verify")),
        "ca_bundle": _yaml_path(get("ca_bundle")),
        "debug_data": _yaml_bool(get("debug_data")),
        "log_dir": _yaml_path(get("log_dir")),
        "backup_dir": _yaml_path(get("backup_dir")),
        "report_dir": _yaml_path(get("report_dir")),
        "skip_dirs": ", ".join(f'"{x}"' for x in (get("skip_dirs") or [])),
        "cover_mode": get("cover_mode"),
        "series_frames": get("series_frames"),
        "preserve_mtime": _yaml_bool(get("preserve_mtime")),
        "organize_template": get("organize_template"),
        "organize_template_no_series": get("organize_template_no_series"),
        "rename_template": get("rename_template"),
        "chapter_title_template": get("chapter_title_template"),
        "album_template": get("album_template"),
        "report_formats": get("report_formats"),
        "overwrite_fields": str(get("overwrite_fields") or ""),
    }
    for key in ("plex", "overwrite", "renumber", "only_missing", "chapter_titles",
                "write_cover_file", "no_backup", "ask_asin", "manual"):
        values[key] = _yaml_bool(get(key))
    return CONFIG_TEMPLATE.format(**values)


def default_config_path() -> Path:
    """Next to the script, so it is found regardless of working directory."""
    return Path(__file__).resolve().parent / "audiobook-tagger.yaml"


def save_config(cfg: Dict[str, Any], path: Optional[Path] = None) -> Optional[Path]:
    target = Path(path) if path else default_config_path()
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(render_config(cfg), encoding="utf-8")
        return target
    except OSError as exc:
        log.warning("could not write config to %s: %s", target, exc)
        return None


def write_default_config(library: str = "") -> Optional[Path]:
    """Create a commented config, pre-filled with anything discoverable."""
    path = default_config_path()
    if path.exists():
        return None
    cfg = dict(DEFAULT_CONFIG)
    cfg["library"] = library
    home = Path.home()
    for cand in (home / "OpenAudible", home / "Documents" / "OpenAudible",
                 Path("C:/OpenAudible")):
        if cand.is_dir():
            cfg["openaudible_dir"] = str(cand)
            if (cand / "art").is_dir():
                cfg["openaudible_art_dir"] = str(cand / "art")
            if (cand / "books.json").is_file():
                cfg["openaudible_json"] = str(cand / "books.json")
            break
    return save_config(cfg, path)


def setup_logging(cfg: Dict[str, Any], verbose: bool, quiet: bool) -> None:
    log.setLevel(logging.DEBUG)
    log.handlers.clear()

    stream = logging.StreamHandler(sys.stderr)
    stream.setLevel(logging.DEBUG if verbose else (logging.WARNING if quiet else logging.INFO))
    stream.setFormatter(logging.Formatter("%(levelname)-7s %(message)s"))
    log.addHandler(stream)

    try:
        log_dir = Path(cfg["log_dir"])
        log_dir.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(log_dir / f"{dt.date.today().isoformat()}.log", encoding="utf-8")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s [%(threadName)s] %(message)s"))
        log.addHandler(fh)
    except OSError as exc:
        log.warning("file logging disabled: %s", exc)


# ==========================================================================
# text helpers
# ==========================================================================

_ARTICLE_RE = re.compile(r"^(the|a|an)\s+", re.I)
_TRAILING_ARTICLE_RE = re.compile(r",\s*(the|a|an)$", re.I)
_PAREN_RE = re.compile(r"\s*[\(\[][^)\]]*[\)\]]")
_NOISE_RE = re.compile(
    r"\b(unabridged|abridged|audiobook|audio book|mp3|m4b|cd\s*\d*|disc\s*\d*|"
    r"part\s*\d+|complete|box\s*set|narrated by .*)\b", re.I)
_WS_RE = re.compile(r"\s+")
DASHES = "-\u2013\u2014"          # hyphen, en dash, em dash (ASCII-safe source)
_NUM_PREFIX_RE = re.compile(r"^\s*(?:book|bk|vol|volume|part|#)?\s*0*(\d{1,3})\s*["
                            + DASHES + r"._)]\s*", re.I)
_SERIES_SUFFIX_RE = re.compile(
    r"[\(\[]?\s*(?P<series>[^\(\)\[\]]+?)\s*(?:,|\s)\s*(?:book|bk|vol|volume|#)\s*(?P<num>\d{1,3})\s*[\)\]]?\s*$", re.I)


def strip_accents(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", text)
                   if not unicodedata.combining(c))


def norm_key(text: str) -> str:
    """Aggressive normalisation used only for comparison."""
    if not text:
        return ""
    t = strip_accents(text).lower()
    t = _PAREN_RE.sub(" ", t)
    t = _NOISE_RE.sub(" ", t)
    t = _TRAILING_ARTICLE_RE.sub("", t.strip())
    t = _ARTICLE_RE.sub("", t.strip())
    t = re.sub(r"[^a-z0-9 ]+", " ", t)
    return _WS_RE.sub(" ", t).strip()


def ratio(a: str, b: str) -> float:
    a, b = norm_key(a), norm_key(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 100.0
    if HAVE_RAPIDFUZZ:
        return float(_rf_fuzz.token_set_ratio(a, b))
    return difflib.SequenceMatcher(None, a, b).ratio() * 100.0


def ratio_strict(a: str, b: str) -> float:
    """Sequence-similarity, NOT token-set.

    token_set_ratio scores 'foundation series 7 foundation and earth' against
    'foundation series 3 foundation' at 97 because one token set contains the
    other - catastrophic for path matching, where the number IS the identity.
    """
    a, b = norm_key(a), norm_key(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 100.0
    if HAVE_RAPIDFUZZ:
        return float(_rf_fuzz.ratio(a, b))
    return difflib.SequenceMatcher(None, a, b).ratio() * 100.0


def clean_title(name: str) -> Tuple[str, Optional[int]]:
    """Return (title, leading number) for folder/file names like '02 - Foo'."""
    number = None
    m = _NUM_PREFIX_RE.match(name)
    if m:
        number = int(m.group(1))
        name = name[m.end():]
    name = _NOISE_RE.sub(" ", name)
    name = re.sub(r"[\(\[]\s*[\)\]]", " ", name)          # empty leftovers
    name = _WS_RE.sub(" ", name.replace("_", " ")).strip(" " + DASHES + "._")
    name = _TRAILING_ARTICLE_RE.sub("", name)
    return name.strip(), number


def split_series(title: str) -> Tuple[str, Optional[str], Optional[int]]:
    """'The Gunslinger (Dark Tower, Book 1)' -> (title, series, 1)."""
    m = _SERIES_SUFFIX_RE.search(title)
    if m:
        base = title[:m.start()].strip(" " + DASHES + ",")
        series = m.group("series").strip(" " + DASHES + ",")
        if base and series and len(series) < 80:
            return base, series, int(m.group("num"))
    return title, None, None


_TAG_RE = re.compile(r"<[^>]+>")
_LANGUAGES = {
    "english": "eng", "spanish": "spa", "french": "fre", "german": "ger",
    "italian": "ita", "portuguese": "por", "dutch": "dut", "russian": "rus",
    "japanese": "jpn", "chinese": "chi", "korean": "kor", "swedish": "swe",
    "danish": "dan", "norwegian": "nor", "finnish": "fin", "polish": "pol",
}


def strip_html(text: str) -> str:
    """OpenAudible summaries are HTML fragments; tags belong nowhere in a tag."""
    if not text:
        return ""
    t = re.sub(r"<\s*br\s*/?\s*>", "\n", text, flags=re.I)
    t = re.sub(r"</\s*(p|div|li)\s*>", "\n", t, flags=re.I)
    t = _TAG_RE.sub("", t)
    t = html.unescape(t).replace("\xa0", " ")
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()


def norm_language(value: Any) -> Optional[str]:
    """'english' -> 'eng'. ID3 TLAN wants an ISO-639-2 code."""
    if not value:
        return None
    v = str(value).strip().lower()
    if v in _LANGUAGES:
        return _LANGUAGES[v]
    return v if len(v) == 3 else (v[:3] if len(v) > 3 else None)


# Ripper placeholders. Windows Media Player writes things like
# "Unknown Album (4/6/2009 11:31:23 AM)"; treating that as a title propagates
# it into filenames and search queries.
JUNK_VALUE_RE = re.compile(
    r"^\s*(?:unknown|unspecified|untitled|no\s+title|various)"
    r"(?:\s+(?:album|artist|title|author|track|genre|year))?"
    r"(?:\s*[\(\[].*?[\)\]])?\s*$"
    r"|^\s*(?:track|audio\s*track|title)\s*\d*\s*$"
    r"|^\s*<unknown>\s*$", re.I)


def is_junk_value(text: Optional[str]) -> bool:
    if not text:
        return True
    return bool(JUNK_VALUE_RE.match(str(text).strip()))


def drop_junk(m: Meta) -> Meta:
    """Blank out placeholder values so real sources can fill them instead."""
    for field_name in ("title", "album", "author", "albumartist", "narrator",
                       "series", "publisher", "genre", "comment", "subtitle"):
        value = getattr(m, field_name, None)
        if value and is_junk_value(value):
            log.debug("ignoring placeholder %s=%r", field_name, value)
            setattr(m, field_name, None)
    return m


ASIN_RE = re.compile(r"\b(B0[0-9A-Z]{8})\b")
# Audible also issues ISBN-style ten-digit product IDs, e.g.
# audible.com/pd/The-Lives-of-Saints-Audiobook/1250819148
NUMERIC_ID_RE = re.compile(r"(?:/pd/[^/\s]*/|\b)(\d{10}|\d{9}[\dXx])\b")


def find_asin(*texts: Optional[str]) -> Optional[str]:
    """Pull an Audible ASIN out of any text: folder name, filename, tag, path.

    Audible ASINs are 'B0' plus eight uppercase alphanumerics, so people often
    park them in folder names like 'Foundation [B005T6ZETM]'.
    """
    for text in texts:
        if not text:
            continue
        m = ASIN_RE.search(str(text).upper())
        if m:
            return m.group(1)
    # only fall back to numeric IDs if no B0 ASIN was found anywhere
    for text in texts:
        if not text:
            continue
        m = NUMERIC_ID_RE.search(str(text))
        if m:
            return m.group(1).upper()
    return None


def strip_series_prefix(title: str, series: Optional[str]) -> str:
    """'Foundation 01 - Prelude to Foundation' -> 'Prelude to Foundation'.

    Some taggers (OpenAudible among them) prefix the album with the series
    name and number. Left alone it corrupts the title, the sort field, and
    every fuzzy match downstream.
    """
    if not title:
        return title
    original = title
    if series:
        # only strip when a number or an explicit separator follows the series
        # name - otherwise "Foundation and Empire" loses its first word
        pat = re.compile(r"^\s*" + re.escape(series) + r"\s*"
                         r"(?:(?:book|bk|vol|volume|part|#)\s*)?"
                         r"(?:0*(\d{1,3})\s*[" + DASHES + r":,._]*"
                         r"|[" + DASHES + r":,]+)\s*", re.I)
        m = pat.match(title)
        if m and m.end() < len(title):
            title = title[m.end():].strip()
    # bare "01 - Title" with no series name in front
    m2 = _NUM_PREFIX_RE.match(title)
    if m2 and m2.end() < len(title):
        title = title[m2.end():].strip()
    return title or original


def natural_key(path: Path) -> Tuple[Any, ...]:
    """Sort 'Part 2' before 'Part 10'. Plain string sort does not."""
    parts: List[Any] = []
    for chunk in re.split(r"(\d+)", str(path).lower()):
        parts.append(int(chunk) if chunk.isdigit() else chunk)
    return tuple(parts)


def safe_name(text: str, maxlen: int = 120) -> str:
    # separators become ', ' rather than vanishing, so multi-value names stay legible
    text = re.sub(r"\s*[/\\]\s*", ", ", str(text))
    text = re.sub(r'[<>:"|?*\x00-\x1f]', "", text)
    text = text.replace("  ", " ").strip(" .")
    return text[:maxlen].strip() or "Unknown"


_TAG_RE = re.compile(r"<[^>]+>")
_BR_RE = re.compile(r"<\s*(br|/p|/div|/li)\s*/?\s*>", re.I)


def html_to_text(value: Any) -> Optional[str]:
    """OpenAudible summaries are HTML. Plex shows raw markup, so flatten it."""
    if not value:
        return None
    text = str(value)
    text = _BR_RE.sub("\n", text)
    text = _TAG_RE.sub("", text)
    text = html.unescape(text)
    text = text.replace("\u00a0", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() or None


def first_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    m = re.search(r"\d{1,4}", str(value))
    return int(m.group(0)) if m else None


def first_year(value: Any) -> Optional[int]:
    if value is None:
        return None
    m = re.search(r"(1[5-9]\d{2}|20\d{2})", str(value))
    return int(m.group(1)) if m else None


# ==========================================================================
# data model
# ==========================================================================

@dataclass
class Meta:
    """Canonical metadata for one book. All fields optional."""
    title: Optional[str] = None
    subtitle: Optional[str] = None
    author: Optional[str] = None
    narrator: Optional[str] = None
    series: Optional[str] = None
    series_index: Optional[str] = None
    album: Optional[str] = None
    albumartist: Optional[str] = None
    genre: Optional[str] = None
    year: Optional[str] = None
    publisher: Optional[str] = None
    description: Optional[str] = None
    language: Optional[str] = None
    asin: Optional[str] = None
    isbn: Optional[str] = None
    audible_url: Optional[str] = None
    author_url: Optional[str] = None
    original_release: Optional[str] = None
    track: Optional[str] = None
    disc: Optional[str] = None
    comment: Optional[str] = None
    cover: Optional[bytes] = field(default=None, repr=False)
    cover_mime: Optional[str] = None
    source: str = ""
    rel_path: Optional[str] = None      # matching hint only, never written
    match_score: Optional[float] = None  # provider confidence, never written
    rel_path: Optional[str] = None       # hint only, never written to tags

    def as_dict(self, with_cover: bool = False) -> Dict[str, Any]:
        d = {k: getattr(self, k) for k in FIELDS}
        d["source"] = self.source
        if with_cover:
            d["cover_sha1"] = hashlib.sha1(self.cover).hexdigest() if self.cover else None
        return d

    def merge_from(self, other: "Meta", overwrite: bool = False) -> List[str]:
        """Fill empty fields from `other`. Returns list of changed fields."""
        changed = []
        for k in FIELDS:
            new = getattr(other, k)
            if new in (None, "", []):
                continue
            cur = getattr(self, k)
            if cur in (None, "") or (overwrite and str(cur) != str(new)):
                setattr(self, k, new)
                changed.append(k)
        if other.cover and (not self.cover or overwrite):
            self.cover = other.cover
            self.cover_mime = other.cover_mime
            changed.append("cover")
        return changed


@dataclass
class Book:
    path: Path                       # directory holding the audio files
    files: List[Path]
    root: Path
    rel_parts: List[str] = field(default_factory=list)

    # populated during processing
    existing: Meta = field(default_factory=Meta)
    final: Meta = field(default_factory=Meta)
    issues: List[str] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)
    match_score: Optional[float] = None
    changes: List[str] = field(default_factory=list)
    status: str = "pending"          # ok | updated | skipped | failed | unknown
    error: str = ""
    providers_used: List[str] = field(default_factory=list)
    hint: Optional[Meta] = None

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def key(self) -> str:
        return f"{norm_key(self.final.author or '')}|{norm_key(self.final.title or self.name)}"


# ==========================================================================
# scanner
# ==========================================================================

def scan_library(root: Path, cfg: Dict[str, Any]) -> List[Book]:
    """A 'book' is any directory that directly contains audio files.

    Disc/part sub-folders (CD1, Disc 2, Part 3) are folded into the parent.
    """
    if not root.is_dir():
        lines = [f"library path is not a directory: {root}"]
        lines += ["  " + n for n in diagnose_path(root)]
        raise SystemExit("\n".join(lines))
    root = root.resolve()

    skip = {s.lower() for s in cfg["skip_dirs"]}
    disc_re = re.compile(r"^(cd|disc|disk|part|pt)[\s._-]*\d+$", re.I)
    groups: Dict[Path, List[Path]] = {}

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d.lower() not in skip and not d.startswith(".")]
        here = Path(dirpath)
        audio = sorted((here / f for f in filenames
                        if Path(f).suffix.lower() in AUDIO_EXTS and not f.startswith(".")),
                       key=natural_key)
        if not audio:
            continue
        owner = here
        # fold disc folders (possibly nested) into their parent
        while owner != root and disc_re.match(owner.name):
            owner = owner.parent
        groups.setdefault(owner, []).extend(audio)

    books = []
    for path, files in sorted(groups.items()):
        rel = path.relative_to(root).parts if path != root else ()
        books.append(Book(path=path, files=sorted(files, key=natural_key),
                          root=root, rel_parts=list(rel)))
    log.info("scanned %s: %d book folder(s), %d file(s)",
             root, len(books), sum(len(b.files) for b in books))
    return books


def meta_from_path(book: Book, cfg: Dict[str, Any]) -> Meta:
    """Infer author / series / title / index from the folder layout."""
    m = Meta(source="folder")
    parts = book.rel_parts or [book.path.name]
    title_raw = parts[-1]
    title, number = clean_title(title_raw)
    title, series, index = split_series(title)

    if len(parts) >= 2:
        m.author = clean_title(parts[0])[0]
    if len(parts) >= 3 and not series:
        series = clean_title(parts[-2])[0]
    if series and norm_key(series) == norm_key(m.author or ""):
        series = None

    m.title = title or title_raw
    m.series = series
    if index is not None:
        m.series_index = str(index)
    elif number is not None and series:
        m.series_index = str(number)
    m.genre = cfg["genre"]
    return m


# ==========================================================================
# tag input / output
# ==========================================================================

class TagError(RuntimeError):
    pass


# Windows FILETIME: 100-nanosecond intervals since 1601-01-01
_FILETIME_EPOCH_DIFF = 116444736000000000


def _set_windows_creation_time(path: Path, ctime_ns: int) -> bool:
    """Restore the NTFS creation timestamp. Best effort, Windows only."""
    if os.name != "nt":
        return False
    try:
        import ctypes
        from ctypes import wintypes

        value = int(ctime_ns // 100) + _FILETIME_EPOCH_DIFF
        ft = wintypes.FILETIME(value & 0xFFFFFFFF, value >> 32)
        handle = ctypes.windll.kernel32.CreateFileW(
            str(path), 256, 0, None, 3, 0x02000000, None)   # FILE_WRITE_ATTRIBUTES
        if handle in (-1, 0xFFFFFFFFFFFFFFFF, None):
            return False
        try:
            ok = ctypes.windll.kernel32.SetFileTime(handle, ctypes.byref(ft), None, None)
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
        return bool(ok)
    except Exception as exc:  # noqa: BLE001
        log.debug("could not restore creation time on %s: %s", path, exc)
        return False


class PreservedTimes:
    """Capture a file's timestamps and put them back after a write.

    Writing a tag rewrites the file, so the modified time jumps to now and the
    library loses its original chronology. Access and modified times are
    restored everywhere; the NTFS creation time is restored on Windows too.
    """

    def __init__(self, path: Path, enabled: bool = True):
        self.path = path
        self.enabled = enabled
        self.stat: Optional[os.stat_result] = None

    def __enter__(self) -> "PreservedTimes":
        if self.enabled:
            try:
                self.stat = self.path.stat()
            except OSError:
                self.stat = None
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if not self.enabled or self.stat is None or exc_type is not None:
            return False
        try:
            os.utime(self.path, ns=(self.stat.st_atime_ns, self.stat.st_mtime_ns))
        except OSError as exc2:
            log.debug("could not restore mtime on %s: %s", self.path, exc2)
        ctime_ns = getattr(self.stat, "st_birthtime_ns", None)
        if ctime_ns is None and os.name == "nt":
            ctime_ns = int(self.stat.st_ctime * 1_000_000_000)
        if ctime_ns:
            _set_windows_creation_time(self.path, int(ctime_ns))
        return False


# set once from config; the writers are plain functions and this keeps their
# signatures stable
_SERIES_STYLE = ["both"]


def sort_album_value(m: Meta) -> Optional[str]:
    """Album-sort string: 'Series 06 - Title'.

    Plex groups a series with this when the library uses
    'Album sorting: By Name'. The album tag itself stays the book title.
    Zero-padded so book 10 does not sort before book 2.
    """
    # base on the TITLE, not the album: album_template may already contain the
    # series, and prefixing that again gives 'Series 06 - Series 06 - Title'
    base = m.title or m.album
    if not base:
        return None
    if not m.series:
        return base
    if norm_key(base).startswith(norm_key(m.series)):
        return base
    idx = first_int(m.series_index)
    if idx is None:
        return f"{m.series} - {base}"
    return f"{m.series} {idx:02d} - {base}"


def _txxx_map() -> Dict[str, str]:
    return {
        "series": "SERIES",
        "series_index": "SERIES-PART",
        "narrator": "NARRATOR",
        "asin": "ASIN",
        "isbn": "ISBN",
        "subtitle": "SUBTITLE",
        "original_release": "ORIGINAL_RELEASE",
        "audible_url": "AUDIBLE_URL",
        "author_url": "AUTHOR_URL",
        "author": "AUTHOR",
    }


def read_tags(path: Path) -> Meta:
    ext = path.suffix.lower()
    try:
        if ext == ".mp3":
            return _read_id3(path)
        if ext in (".m4b", ".m4a"):
            return _read_mp4(path)
        if ext == ".flac":
            return _read_flac(path)
        if ext == ".ogg":
            return _read_ogg(path)
    except Exception as exc:  # noqa: BLE001 - any tag lib error
        raise TagError(f"{path.name}: {exc}") from exc
    raise TagError(f"unsupported format: {path.name}")


def _t(frames, key) -> Optional[str]:
    """Read a text frame, joining multiple values readably.

    ID3v2.3 stores several values in one frame separated by '/', and str()
    hands that back verbatim. Deleting the slash later (it is illegal in a
    filename) produced 'Kristen WelchMeredith Mitchell'.
    """
    v = frames.get(key)
    if v is None:
        return None
    values = [str(x).strip() for x in getattr(v, "text", []) if str(x).strip()]
    if len(values) > 1:
        text = ", ".join(values)
    else:
        text = values[0] if values else str(v)
    text = re.sub(r"\s*/\s*", ", ", text) if "/" in text and key in (
        "TPE1", "TPE2", "TCOM", "TIT2") else text
    return text.strip() or None


def _read_id3(path: Path) -> Meta:
    try:
        tags = ID3(path)
    except ID3NoHeaderError:
        return Meta(source="existing")
    m = Meta(source="existing")
    m.album = _t(tags, "TALB")
    m.albumartist = _t(tags, "TPE2")
    m.author = _t(tags, "TPE1") or m.albumartist
    m.title = _t(tags, "TIT2")
    m.subtitle = _t(tags, "TIT3")
    m.track = _t(tags, "TRCK")
    m.disc = _t(tags, "TPOS")
    m.genre = _t(tags, "TCON")
    m.year = _t(tags, "TDRC")
    m.narrator = _t(tags, "TCOM")
    m.publisher = _t(tags, "TPUB")
    m.language = _t(tags, "TLAN")
    for frame in tags.getall("COMM"):
        text = "".join(frame.text).strip()
        if not text:
            continue
        if frame.desc.lower() in ("description", "book description"):
            m.description = text
        elif not m.comment:
            m.comment = text
    rev = {v.upper(): k for k, v in _txxx_map().items()}
    if not m.series and tags.getall("MVNM"):
        m.series = _t(tags, "MVNM")
    if not m.series_index and tags.getall("MVIN"):
        m.series_index = _t(tags, "MVIN")
    for frame in tags.getall("TXXX"):
        key = rev.get((frame.desc or "").upper())
        text = "".join(frame.text).strip()
        if key and text and not getattr(m, key):
            setattr(m, key, text)
    for frame in tags.getall("APIC"):
        if frame.data:
            m.cover = frame.data
            m.cover_mime = frame.mime or "image/jpeg"
            break
    return m


MP4_FREEFORM = "----:com.apple.iTunes:"


def _read_mp4(path: Path) -> Meta:
    tags = MP4(path).tags
    m = Meta(source="existing")
    if tags is None:
        return m

    def g(key):
        v = tags.get(key)
        if not v:
            return None
        val = v[0]
        if isinstance(val, bytes):
            val = val.decode("utf-8", "replace")
        return str(val).strip() or None

    m.album = g("\xa9alb")
    m.albumartist = g("aART")
    m.author = g("\xa9ART") or m.albumartist
    m.title = g("\xa9nam")
    m.genre = g("\xa9gen")
    m.year = g("\xa9day")
    m.narrator = g("\xa9wrt")
    m.description = g("desc") or g("ldes")
    m.comment = g("\xa9cmt")
    m.publisher = g("\xa9pub")
    if tags.get("trkn"):
        t = tags["trkn"][0]
        m.track = f"{t[0]}/{t[1]}" if len(t) > 1 and t[1] else str(t[0])
    if tags.get("disk"):
        d = tags["disk"][0]
        m.disc = f"{d[0]}/{d[1]}" if len(d) > 1 and d[1] else str(d[0])
    for fkey, akey in _txxx_map().items():
        val = g(MP4_FREEFORM + akey)
        if val and not getattr(m, fkey):
            setattr(m, fkey, val)
    if not m.series:
        m.series = g("\xa9mvn")
    if not m.series_index:
        m.series_index = g("\xa9mvi")
    if tags.get("covr"):
        art = tags["covr"][0]
        m.cover = bytes(art)
        m.cover_mime = "image/png" if getattr(art, "imageformat", None) == MP4Cover.FORMAT_PNG else "image/jpeg"
    return m


def _vorbis_read(tags, m: Meta) -> Meta:
    def g(*keys):
        for k in keys:
            v = tags.get(k) or tags.get(k.lower())
            if v:
                return str(v[0]).strip() or None
        return None

    m.album = g("ALBUM")
    m.albumartist = g("ALBUMARTIST")
    m.author = g("ARTIST") or m.albumartist
    m.title = g("TITLE")
    m.subtitle = g("SUBTITLE")
    m.track = g("TRACKNUMBER")
    m.disc = g("DISCNUMBER")
    m.genre = g("GENRE")
    m.year = g("DATE")
    m.narrator = g("COMPOSER", "NARRATOR")
    m.publisher = g("PUBLISHER", "ORGANIZATION")
    m.description = g("DESCRIPTION")
    m.comment = g("COMMENT")
    m.language = g("LANGUAGE")
    m.series = g("SERIES", "MOVEMENTNAME")
    m.series_index = g("SERIES-PART", "SERIESPART", "MOVEMENT")
    m.asin = g("ASIN")
    m.isbn = g("ISBN")
    m.audible_url = g("AUDIBLE_URL")
    m.author_url = g("AUTHOR_URL")
    m.original_release = g("ORIGINAL_RELEASE")
    return m


def _read_flac(path: Path) -> Meta:
    audio = FLAC(path)
    m = _vorbis_read(audio, Meta(source="existing"))
    for pic in audio.pictures:
        if pic.data:
            m.cover, m.cover_mime = pic.data, pic.mime or "image/jpeg"
            break
    return m


def _read_ogg(path: Path) -> Meta:
    audio = OggVorbis(path)
    m = _vorbis_read(audio, Meta(source="existing"))
    blob = audio.get("metadata_block_picture")
    if blob:
        try:
            pic = Picture(base64.b64decode(blob[0]))
            m.cover, m.cover_mime = pic.data, pic.mime or "image/jpeg"
        except Exception:  # noqa: BLE001
            pass
    return m


def write_tags(path: Path, m: Meta, *, overwrite: bool, cover_mode: str,
               track: Optional[int], total: Optional[int], dry_run: bool,
               force_track: bool = False,
               force_fields: Optional[Sequence[str]] = None,
               preserve_times: bool = True) -> List[str]:
    """Write `m` to one file. Returns the list of fields actually written."""
    ext = path.suffix.lower()
    if dry_run:
        return _planned_fields(m, cover_mode)
    with PreservedTimes(path, enabled=preserve_times):
        return _write_dispatch(path, m, ext, overwrite, cover_mode, track, total,
                               force_track, force_fields)


def _write_dispatch(path: Path, m: Meta, ext: str, overwrite: bool, cover_mode: str,
                    track: Optional[int], total: Optional[int], force_track: bool,
                    force_fields: Optional[Sequence[str]]) -> List[str]:
    try:
        if ext == ".mp3":
            return _write_id3(path, m, overwrite, cover_mode, track, total, force_track,
                         set(force_fields or ()))
        if ext in (".m4b", ".m4a"):
            return _write_mp4(path, m, overwrite, cover_mode, track, total, force_track,
                         set(force_fields or ()))
        if ext == ".flac":
            return _write_flac(path, m, overwrite, cover_mode, track, total, force_track,
                          set(force_fields or ()))
        if ext == ".ogg":
            return _write_ogg(path, m, overwrite, cover_mode, track, total, force_track,
                         set(force_fields or ()))
    except Exception as exc:  # noqa: BLE001
        raise TagError(f"{path.name}: {exc}") from exc
    raise TagError(f"unsupported format: {path.name}")


def _planned_fields(m: Meta, cover_mode: str) -> List[str]:
    """Best-effort preview for --dry-run."""
    out = [k for k in FIELDS if getattr(m, k)]
    if m.cover and cover_mode != "keep":
        out.append("cover")
    if cover_mode == "remove":
        out.append("cover:remove")
    return out


def _write_id3(path: Path, m: Meta, overwrite: bool, cover_mode: str,
               track: Optional[int], total: Optional[int],
               force_track: bool = False,
               force_fields: Optional[set] = None) -> List[str]:
    force_fields = force_fields or set()
    style = str(_SERIES_STYLE[0] or "both").lower()
    try:
        tags = ID3(path)
    except ID3NoHeaderError:
        audio = MP3(path)
        audio.add_tags()
        audio.save()
        tags = ID3(path)

    written: List[str] = []

    def setf(frame_cls, key, value, field_name, **kw):
        if not value:
            return
        if (not overwrite and field_name not in force_fields
                and tags.get(key) is not None and str(tags.get(key)).strip()):
            return
        tags.setall(key, [frame_cls(encoding=3, text=[str(value)], **kw)])
        written.append(field_name)

    setf(TALB, "TALB", m.album or m.title, "album")
    setf(TPE2, "TPE2", m.albumartist or m.author, "albumartist")
    setf(TPE1, "TPE1", m.author, "author")
    setf(TIT2, "TIT2", m.title, "title")
    setf(TIT3, "TIT3", m.subtitle, "subtitle")
    setf(TCON, "TCON", m.genre, "genre")
    # A file can carry TDRC *and* TYER/TDAT at once, which tag editors show as
    # "2014\\2014-06-17". mutagen merges them on load, so the duplication is
    # invisible here - rewriting the frame is what clears it. Normalising a
    # date to its year is not a data change, so that case does not need --force;
    # a genuinely different year still does.
    existing_date = str(tags.get("TDRC") or "").strip()
    target_year = str(first_year(m.year) or m.year or "")
    same_year_different_text = bool(
        existing_date and target_year
        and str(first_year(existing_date) or "") == target_year
        and existing_date != target_year)
    if m.year and (overwrite or "year" in force_fields or not existing_date
                   or same_year_different_text):
        # Purge the v2.3 companions. A file carrying both TDRC and TYER/TDAT
        # displays as '2014\\2014-06-17' in tag editors. Stale companions alone
        # are enough reason to rewrite, even when TDRC already looks fine.
        for frame_id in ("TYER", "TDAT", "TDRL", "TORY", "TRDA"):
            tags.delall(frame_id)
        tags.setall("TDRC", [TDRC(encoding=3, text=[target_year])])
        written.append("year")
    setf(TCOM, "TCOM", m.narrator, "narrator")
    setf(TPUB, "TPUB", m.publisher, "publisher")
    setf(TLAN, "TLAN", m.language, "language")

    # sort fields keep Plex ordering sane
    sort_album = sort_album_value(m)
    if sort_album:
        if overwrite or "album" in force_fields or "series" in force_fields \
                or tags.get("TSOA") is None:
            tags.setall("TSOA", [TSOA(encoding=3, text=[sort_album])])
            written.append("sort_album")
    if m.author and (overwrite or tags.get("TSO2") is None):
        tags.setall("TSO2", [TSO2(encoding=3, text=[m.author])])
        tags.setall("TSOP", [TSOP(encoding=3, text=[m.author])])
        written.append("sort_artist")

    if track and (overwrite or force_track or "track" in force_fields
                  or tags.get("TRCK") is None):
        tags.setall("TRCK", [TRCK(encoding=3, text=[f"{track}/{total or track}"])])
        written.append("track")
    if m.disc and (overwrite or "disc" in force_fields
                   or tags.get("TPOS") is None):
        tags.setall("TPOS", [TPOS(encoding=3, text=[str(m.disc)])])
        written.append("disc")

    if m.description:
        have = any(f.desc.lower() == "description" for f in tags.getall("COMM"))
        if overwrite or "description" in force_fields or not have:
            tags.setall("COMM", [c for c in tags.getall("COMM") if c.desc.lower() != "description"])
            tags.add(COMM(encoding=3, lang="eng", desc="description", text=[m.description]))
            written.append("description")

    if m.comment:
        # COMM with an empty description is what tag editors show as "Comment".
        # This was never being written for MP3 at all.
        plain = [c for c in tags.getall("COMM") if not (c.desc or "").strip()]
        if overwrite or "comment" in force_fields or not any(
                "".join(c.text).strip() for c in plain):
            keep = [c for c in tags.getall("COMM") if (c.desc or "").strip()]
            tags.setall("COMM", keep)
            tags.add(COMM(encoding=3, lang="eng", desc="", text=[m.comment]))
            written.append("comment")

    existing_txxx = {(f.desc or "").upper(): f for f in tags.getall("TXXX")}
    for fname, desc in _txxx_map().items():
        value = getattr(m, fname)
        if not value:
            continue
        if fname in ("series", "series_index") and style == "movement":
            continue
        if (not overwrite and fname not in force_fields
                and desc.upper() in existing_txxx):
            continue
        tags.delall(f"TXXX:{desc}")
        tags.add(TXXX(encoding=3, desc=desc, text=[str(value)]))
        written.append(fname)

    if m.series and style in ("movement", "both"):
        if overwrite or "series" in force_fields or not tags.getall("MVNM"):
            tags.setall("MVNM", [MVNM(encoding=3, text=[m.series])])
            written.append("series_movement")
        if m.series_index and (overwrite or "series_index" in force_fields
                               or not tags.getall("MVIN")):
            tags.setall("MVIN", [MVIN(encoding=3, text=[str(m.series_index)])])
            written.append("series_index_movement")

    if cover_mode == "remove":
        if tags.getall("APIC"):
            tags.delall("APIC")
            written.append("cover:removed")
    elif m.cover and cover_mode in ("replace", "auto"):
        has = bool(tags.getall("APIC"))
        if cover_mode == "replace" or not has:
            tags.delall("APIC")
            tags.add(APIC(encoding=3, mime=m.cover_mime or "image/jpeg",
                          type=3, desc="Cover", data=m.cover))
            written.append("cover")

    tags.save(path, v2_version=3)
    return written


def _write_mp4(path: Path, m: Meta, overwrite: bool, cover_mode: str,
               track: Optional[int], total: Optional[int],
               force_track: bool = False,
               force_fields: Optional[set] = None) -> List[str]:
    force_fields = force_fields or set()
    style = str(_SERIES_STYLE[0] or "both").lower()
    audio = MP4(path)
    if audio.tags is None:
        audio.add_tags()
    tags = audio.tags
    written: List[str] = []

    def setf(key, value, field_name, freeform=False):
        if not value:
            return
        if not overwrite and field_name not in force_fields and tags.get(key):
            return
        tags[key] = [str(value).encode("utf-8")] if freeform else [str(value)]
        written.append(field_name)

    setf("\xa9alb", m.album or m.title, "album")
    setf("aART", m.albumartist or m.author, "albumartist")
    setf("\xa9ART", m.author, "author")
    setf("\xa9nam", m.title, "title")
    setf("\xa9gen", m.genre, "genre")
    setf("\xa9day", m.year, "year")
    setf("\xa9wrt", m.narrator, "narrator")
    setf("\xa9pub", m.publisher, "publisher")
    setf("desc", (m.description or "")[:255], "description")
    setf("ldes", m.description, "description_long")
    setf("\xa9cmt", m.comment, "comment")
    sort_album = sort_album_value(m)
    if sort_album:
        if overwrite or "album" in force_fields or "series" in force_fields \
                or not tags.get("soal"):
            tags["soal"] = [sort_album]
            written.append("sort_album")
    setf("soaa", m.albumartist or m.author, "sort_albumartist")

    if track and (overwrite or force_track or "track" in force_fields
                  or not tags.get("trkn")):
        tags["trkn"] = [(track, total or track)]
        written.append("track")
    if m.disc and (overwrite or "disc" in force_fields or not tags.get("disk")):
        d = first_int(m.disc) or 1
        tags["disk"] = [(d, d)]
        written.append("disc")

    for fname, akey in _txxx_map().items():
        setf(MP4_FREEFORM + akey, getattr(m, fname), fname, freeform=True)

    if m.series and style in ("movement", "both"):
        setf("\xa9mvn", m.series, "series_movement")
        if m.series_index:
            if overwrite or "series_index" in force_fields or not tags.get("\xa9mvi"):
                try:
                    tags["\xa9mvi"] = [int(first_int(m.series_index) or 0)]
                    written.append("series_index_movement")
                except Exception:  # noqa: BLE001
                    pass

    if cover_mode == "remove":
        if tags.get("covr"):
            del tags["covr"]
            written.append("cover:removed")
    elif m.cover and cover_mode in ("replace", "auto"):
        if cover_mode == "replace" or not tags.get("covr"):
            fmt = MP4Cover.FORMAT_PNG if (m.cover_mime or "").endswith("png") else MP4Cover.FORMAT_JPEG
            tags["covr"] = [MP4Cover(m.cover, imageformat=fmt)]
            written.append("cover")

    audio.save()
    return written


def _vorbis_write(tags, m: Meta, overwrite: bool, track, total,
                  force_track: bool = False,
                  force_fields: Optional[set] = None) -> List[str]:
    force_fields = force_fields or set()
    style = str(_SERIES_STYLE[0] or "both").lower()
    written: List[str] = []

    def setf(key, value, field_name):
        if not value:
            return
        if not overwrite and field_name not in force_fields and tags.get(key):
            return
        tags[key] = [str(value)]
        written.append(field_name)

    setf("ALBUM", m.album or m.title, "album")
    sort_album = sort_album_value(m)
    if sort_album:
        if overwrite or "album" in force_fields or "series" in force_fields \
                or not tags.get("ALBUMSORT"):
            tags["ALBUMSORT"] = [sort_album]
            written.append("sort_album")
    setf("ALBUMARTIST", m.albumartist or m.author, "albumartist")
    setf("ARTIST", m.author, "author")
    setf("TITLE", m.title, "title")
    setf("SUBTITLE", m.subtitle, "subtitle")
    setf("GENRE", m.genre, "genre")
    setf("DATE", m.year, "year")
    setf("COMPOSER", m.narrator, "narrator")
    setf("NARRATOR", m.narrator, "narrator_x")
    setf("PUBLISHER", m.publisher, "publisher")
    setf("DESCRIPTION", m.description, "description")
    setf("COMMENT", m.comment, "comment")
    setf("LANGUAGE", m.language, "language")
    if style in ("movement", "both"):
        setf("MOVEMENTNAME", m.series, "series_movement")
        setf("MOVEMENT", m.series_index, "series_index_movement")
    setf("SERIES", m.series, "series")
    setf("SERIES-PART", m.series_index, "series_index")
    setf("ASIN", m.asin, "asin")
    setf("ISBN", m.isbn, "isbn")
    setf("AUDIBLE_URL", m.audible_url, "audible_url")
    setf("AUTHOR_URL", m.author_url, "author_url")
    setf("ORIGINAL_RELEASE", m.original_release, "original_release")
    if track and (overwrite or force_track or "track" in force_fields
                  or not tags.get("TRACKNUMBER")):
        tags["TRACKNUMBER"] = [str(track)]
        tags["TRACKTOTAL"] = [str(total or track)]
        written.append("track")
    if m.disc and (overwrite or "disc" in force_fields
                   or not tags.get("DISCNUMBER")):
        tags["DISCNUMBER"] = [str(first_int(m.disc) or 1)]
        written.append("disc")
    return written


def _make_picture(m: Meta) -> Picture:
    pic = Picture()
    pic.data = m.cover
    pic.type = 3
    pic.mime = m.cover_mime or "image/jpeg"
    pic.desc = "Cover"
    if HAVE_PIL:
        try:
            with Image.open(_io.BytesIO(m.cover)) as im:
                pic.width, pic.height = im.size
                pic.depth = 24
        except Exception:  # noqa: BLE001
            pass
    return pic


def _write_flac(path: Path, m: Meta, overwrite: bool, cover_mode: str, track, total,
                force_track: bool = False,
                force_fields: Optional[set] = None) -> List[str]:
    audio = FLAC(path)
    written = _vorbis_write(audio, m, overwrite, track, total, force_track, force_fields)
    if cover_mode == "remove":
        if audio.pictures:
            audio.clear_pictures()
            written.append("cover:removed")
    elif m.cover and cover_mode in ("replace", "auto"):
        if cover_mode == "replace" or not audio.pictures:
            audio.clear_pictures()
            audio.add_picture(_make_picture(m))
            written.append("cover")
    audio.save()
    return written


def _write_ogg(path: Path, m: Meta, overwrite: bool, cover_mode: str, track, total,
               force_track: bool = False,
               force_fields: Optional[set] = None) -> List[str]:
    audio = OggVorbis(path)
    written = _vorbis_write(audio, m, overwrite, track, total, force_track, force_fields)
    if cover_mode == "remove":
        if audio.get("metadata_block_picture"):
            del audio["metadata_block_picture"]
            written.append("cover:removed")
    elif m.cover and cover_mode in ("replace", "auto"):
        if cover_mode == "replace" or not audio.get("metadata_block_picture"):
            audio["metadata_block_picture"] = [
                base64.b64encode(_make_picture(m).write()).decode("ascii")]
            written.append("cover")
    audio.save()
    return written


def read_book_tags(book: Book) -> Meta:
    """Read the first readable file, then fill gaps from the rest."""
    merged = Meta(source="existing")
    for f in book.files[:8]:
        try:
            m = read_tags(f)
        except TagError as exc:
            log.debug("tag read failed: %s", exc)
            continue
        merged.merge_from(m, overwrite=False)
    drop_junk(merged)
    # per-file track numbers are meaningless at book level, and per-file
    # titles are chapter names - the album is the book
    merged.track = None
    if merged.album:
        merged.title = merged.album
    return merged


# ==========================================================================
# metadata providers
# ==========================================================================

class RateLimiter:
    def __init__(self, min_interval: float):
        self.min_interval = min_interval
        self._lock = threading.Lock()
        self._last = 0.0

    def wait(self) -> None:
        with self._lock:
            delta = time.monotonic() - self._last
            if delta < self.min_interval:
                time.sleep(self.min_interval - delta)
            self._last = time.monotonic()


_DUMP_LOCK = threading.Lock()
_DUMP_SEQ = [0]


def dump_payload(cfg: Dict[str, Any], label: str, url: str, payload: Any) -> None:
    """Write a provider's raw response to disk for inspection."""
    if not cfg.get("debug_data"):
        return
    try:
        with _DUMP_LOCK:
            _DUMP_SEQ[0] += 1
            seq = _DUMP_SEQ[0]
            out_dir = Path(cfg["log_dir"]) / "payloads" / dt.date.today().isoformat()
            out_dir.mkdir(parents=True, exist_ok=True)
            path = out_dir / f"{seq:04d}-{re.sub(r'[^a-z0-9]+', '-', label.lower())}.json"
            path.write_text(json.dumps({"url": url, "response": payload},
                                       indent=2, ensure_ascii=False), encoding="utf-8")
        log.debug("payload dumped: %s", path)
    except Exception as exc:  # noqa: BLE001
        log.debug("payload dump failed: %s", exc)


def http_json(url: str, cfg: Dict[str, Any], limiter: Optional[RateLimiter] = None,
              label: str = "http") -> Optional[Any]:
    if not cfg["network"]:
        return None
    if limiter:
        limiter.wait()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                               "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=cfg["request_timeout"],
                                    context=ssl_context(cfg)) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
        log.debug("%s %s -> %d byte(s)", label, url, len(json.dumps(payload)))
        dump_payload(cfg, label, url, payload)
        return payload
    except Exception as exc:  # noqa: BLE001
        log.debug("HTTP failed %s: %s", url, exc)
        return None


def http_bytes(url: str, cfg: Dict[str, Any], limiter: Optional[RateLimiter] = None) -> Optional[Tuple[bytes, str]]:
    if not cfg["network"]:
        return None
    if limiter:
        limiter.wait()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=cfg["request_timeout"],
                                    context=ssl_context(cfg)) as resp:
            data = resp.read()
            mime = resp.headers.get_content_type() or "image/jpeg"
        if len(data) < 2048:
            return None
        return data, mime
    except Exception as exc:  # noqa: BLE001
        log.debug("cover fetch failed %s: %s", url, exc)
        return None


class Provider:
    name = "base"

    def __init__(self, cfg: Dict[str, Any]):
        self.cfg = cfg

    def lookup(self, hint: Meta) -> Optional[Meta]:  # pragma: no cover - interface
        raise NotImplementedError

    @staticmethod
    def title_variants(title: str) -> List[str]:
        """A title plus the plausible 'just the book' part of it.

        Audible names series entries 'Warriors: Omen of the Stars #6: The Last
        Hope'. Compared whole against a folder's 'The Last Hope' that scores
        58, so the right book gets thrown away. The trailing segment is
        compared too.
        """
        out = [title]
        m = re.search(r"#\s*\d+\s*[:\-\u2013\u2014]\s*(.+)$", title)
        if m and len(m.group(1).strip()) >= 4:
            out.append(m.group(1).strip())
        if ":" in title:
            tail = title.rsplit(":", 1)[-1].strip()
            if len(tail) >= 4:
                out.append(tail)
            head = title.split(":", 1)[0].strip()
            if len(head) >= 4:
                out.append(head)
        return list(dict.fromkeys(out))

    @staticmethod
    def title_score(a: str, b: str) -> float:
        """Blend token-set with sequence similarity.

        token_set alone rates 'Foundation and Earth' against 'Foundation' at
        100, because one token set contains the other - so a series opener
        swallows every later volume. The sequence term restores length
        sensitivity while still tolerating reordering and subtitles.
        """
        return 0.35 * ratio(a, b) + 0.65 * ratio_strict(a, b)

    def score(self, hint: Meta, title: str, author: Optional[str]) -> float:
        """Title decides; the author can corroborate but must not veto.

        Audiobook files routinely carry a series name or the narrator in
        TPE1/TPE2. Weighting that at 30% turned a perfect title match into a
        78 and threw away the right book, so a disagreeing author is now a
        small penalty rather than a third of the score.
        """
        s = max(self.title_score(hint.title or "", variant)
                for variant in self.title_variants(title))
        if hint.author and author:
            a = ratio(hint.author, author)
            if a >= 60:
                s = 0.75 * s + 0.25 * a
            else:
                s = max(0.0, s - 8.0)
        return s

    @staticmethod
    def clean_hint_title(hint: Meta) -> Optional[str]:
        """Strip a '<Series> 07 - ' prefix before comparing anything.

        The folder may call it 'Foundation Series' while the album prefix says
        'Foundation', so collection words are trimmed and each variant tried.
        """
        if not hint.title:
            return hint.title
        candidates: List[str] = []
        if hint.series:
            candidates.append(hint.series)
        if hint.rel_path:
            parts = [x for x in hint.rel_path.replace("\\", "/").split("/") if x]
            if len(parts) >= 2:
                candidates.append(clean_title(parts[-2])[0])
        extra = []
        for c in candidates:
            trimmed = re.sub(r"\s+(series|saga|trilogy|novels?|books?|collection|cycle)$",
                             "", c, flags=re.I).strip()
            if trimmed and trimmed != c:
                extra.append(trimmed)
        candidates += extra

        title = hint.title
        for c in candidates:
            out = strip_series_prefix(title, c)
            if out != title:
                title = out
                break
        title = strip_series_prefix(title, None)

        # Shelf-keeping noise people put in album tags and folder names:
        #   'Book 9 (Special) - Leigh Bardugo - The Lives of Saints'
        #   'Shadow and Bone (The Grisha #1) by Leigh Bardugo'
        before = None
        while before != title:
            before = title
            title = re.sub(r"^\s*(?:book|bk|vol|volume|part)\s*\d+\s*"
                           r"(?:[\(\[][^)\]]*[\)\]])?\s*[" + DASHES + r":]\s*",
                           "", title, flags=re.I)
            if hint.author:
                for name in [x.strip() for x in str(hint.author).split(",") if x.strip()]:
                    title = re.sub(r"^\s*" + re.escape(name) + r"\s*[" + DASHES + r":]\s*",
                                   "", title, flags=re.I)
                    title = re.sub(r"\s*\bby\s+" + re.escape(name) + r"\s*$",
                                   "", title, flags=re.I)
            title = re.sub(r"\s*[\(\[][^)\]]*#\s*\d+[^)\]]*[\)\]]\s*", " ", title)
            # shelf shorthand: 'SoS1 - The Shadow of Saganami'
            title = re.sub(r"^\s*[A-Za-z]{2,6}\s?\d{1,3}\s*[" + DASHES + r":]\s+",
                           "", title)
            title = title.strip(" " + DASHES + ",:")
        return title or hint.title


class OpenAudibleProvider(Provider):
    """Reads the local OpenAudible library JSON. No Audible login required.

    Real OpenAudible schema (verified against an exported books.json):
        title, title_short, author, narrated_by, publisher, summary (HTML),
        release_date, series_name, series_sequence, asin, language, genre,
        filename / key  -> the book's path relative to the audiobook folder
    """
    name = "openaudible"

    def __init__(self, cfg):
        super().__init__(cfg)
        self._index: List[Dict[str, Any]] = []
        self._by_path: Dict[str, Dict[str, Any]] = {}
        self._by_asin: Dict[str, Dict[str, Any]] = {}
        self._base: Optional[Path] = None
        self.sources: List[Tuple[Path, int]] = []
        self._art: Optional[Dict[str, Path]] = None
        self.art_files = 0
        self._art_lock = threading.Lock()
        self._loaded = False
        self._lock = threading.Lock()

    # -- discovery --------------------------------------------------------
    def _candidates(self) -> List[Path]:
        out: List[Path] = []
        if self.cfg["openaudible_dir"]:
            out.append(Path(self.cfg["openaudible_dir"]).expanduser())
        home = Path.home()
        out += [home / "OpenAudible", home / "Documents" / "OpenAudible",
                Path("C:/OpenAudible")]
        return out

    def _json_paths(self) -> List[Path]:
        paths: List[Path] = []
        configured = self.cfg["openaudible_json"]
        if configured:
            if isinstance(configured, str):
                configured = [configured]
            for c in configured:
                paths.append(Path(str(c)).expanduser())
        for base in self._candidates():
            paths += [base / "books.json", base / "books" / "books.json",
                      base / "library.json"]
        return paths

    def _load(self) -> None:
        """Load and MERGE every library JSON found.

        OpenAudible ships a slim books.json (title/author/filename/dates) and a
        much richer export (narrator, publisher, summary, series, ASIN). Reading
        only the first one found silently loses most of the metadata, so every
        source is merged: earlier sources win, later ones fill the gaps.
        """
        with self._lock:
            if self._loaded:
                return
            self._loaded = True
            tried: List[str] = []
            merged: Dict[str, Dict[str, Any]] = {}
            order: List[str] = []
            self.sources: List[Tuple[Path, int]] = []

            for p in self._json_paths():
                tried.append(str(p))
                if not p.is_file():
                    continue
                try:
                    data = json.loads(p.read_text(encoding="utf-8", errors="replace"))
                except Exception as exc:  # noqa: BLE001
                    log.warning("OpenAudible: could not parse %s: %s", p, exc)
                    continue
                if isinstance(data, dict):
                    data = data.get("books") or data.get("library") or []
                if not isinstance(data, list) or not data:
                    log.warning("OpenAudible: %s contained no book entries", p)
                    continue

                for e in data:
                    if not isinstance(e, dict):
                        continue
                    # identity must be the folder path: the slim books.json
                    # has no ASIN, so keying on ASIN splits one book into two
                    ident = (self._path_key(str(e.get("filename") or e.get("key") or ""))
                             or str(e.get("asin") or "").strip())
                    if not ident:
                        continue
                    if ident in merged:
                        for k, v in e.items():          # fill gaps only
                            if merged[ident].get(k) in (None, "", []) and v not in (None, "", []):
                                merged[ident][k] = v
                    else:
                        merged[ident] = dict(e)
                        order.append(ident)
                self.sources.append((p, len(data)))
                if self._base is None:
                    self._base = p.parent

            if not merged:
                log.warning("OpenAudible: no library JSON found - provider inactive. "
                            "Looked in: %s. Set 'openaudible_json' or 'openaudible_dir' "
                            "in the config to point at it.", "; ".join(tried))
                return

            self._index = [merged[i] for i in order]
            for e in self._index:
                asin = str(e.get("asin") or "").strip()
                if asin:
                    self._by_asin[asin] = e
                for field_name in ("filename", "key"):
                    rel = str(e.get(field_name) or "").strip()
                    if rel:
                        self._by_path[self._path_key(rel)] = e
            log.info("OpenAudible: %d book(s) from %d source(s): %s",
                     len(self._index), len(self.sources),
                     ", ".join(str(p) for p, _ in self.sources))

    # -- what did the library actually give us? ---------------------------
    USEFUL_FIELDS = ("title", "author", "narrated_by", "publisher", "summary",
                     "release_date", "series_name", "series_sequence", "asin",
                     "language")

    def coverage(self) -> Dict[str, int]:
        out: Dict[str, int] = {}
        for f in self.USEFUL_FIELDS:
            out[f] = sum(1 for e in self._index if e.get(f) not in (None, "", []))
        return out

    # -- matching ---------------------------------------------------------
    @staticmethod
    def _path_key(rel: str) -> str:
        rel = rel.replace("\\", "/").strip("/ ")
        return norm_key(rel.replace("/", " "))

    def _find(self, hint: Meta) -> Tuple[Optional[Dict[str, Any]], float, str]:
        if hint.asin and hint.asin in self._by_asin:
            return self._by_asin[hint.asin], 100.0, "asin"

        # OpenAudible records each book's folder path - an exact structural
        # match beats any amount of fuzzy title guessing
        if hint.rel_path:
            key = self._path_key(hint.rel_path)
            if key and key in self._by_path:
                return self._by_path[key], 100.0, "path"
            if key:
                best, score = None, 0.0
                for pkey, entry in self._by_path.items():
                    r = ratio_strict(key, pkey)
                    if r > score:
                        best, score = entry, r
                # near-exact only: a differing volume number must not match
                if best is not None and score >= 97.0:
                    return best, score, "path~"

        probe = dataclasses.replace(hint)
        probe.title = self.clean_hint_title(hint)
        best, best_score = None, 0.0
        for entry in self._index:
            title = str(entry.get("title") or entry.get("title_short") or "")
            s = self.score(probe, title, str(entry.get("author") or ""))
            if s > best_score:
                best, best_score = entry, s
        return best, best_score, "title"

    def lookup(self, hint: Meta) -> Optional[Meta]:
        self._load()
        if not self._index:
            return None
        best, score, how = self._find(hint)
        # a title-only hit is the weakest evidence there is: 'Foundation and
        # Empire' scores 88 against 'Foundation and Earth' once the author
        # agrees, which is a wrong book, not a match. Demand more.
        floor = self.cfg["match_threshold"]
        if how == "title":
            floor = max(floor, self.cfg["title_only_threshold"])
        if not best or score < floor:
            if best:
                log.debug("openaudible: best candidate %r scored %.0f via %s "
                          "(floor %.0f) - rejected", best.get("title"), score, how, floor)
            return None

        def g(*keys) -> Optional[str]:
            for k in keys:
                v = best.get(k)
                if v not in (None, "", []):
                    return str(v).strip() or None
            return None

        m = Meta(source=self.name)
        m.title = g("title", "title_short")
        m.subtitle = g("subtitle")
        m.author = g("author")
        m.narrator = g("narrated_by", "narratedBy", "narrator")
        m.publisher = g("publisher")
        m.description = strip_html(g("summary", "description") or "") or None
        m.asin = g("asin")
        m.language = norm_language(g("language"))
        m.series = g("series_name", "series")
        idx = g("series_sequence", "book_number")
        m.series_index = str(first_int(idx)) if first_int(idx) is not None else None
        release = g("release_date", "pubDate", "purchase_date")
        y = first_year(release)
        m.year = str(y) if y else None
        m.original_release = release
        if self.cfg["openaudible_genre"]:
            genre = g("genre")
            if genre:
                # "Literature & Fiction:Classics" -> most specific leaf
                m.genre = genre.split(":")[-1].strip() or None
        alink = g("author_link")
        if alink and alink.startswith("http"):
            m.author_url = alink
        link = g("info_link")
        if link and link.startswith("http"):
            m.audible_url = link
        elif m.asin:
            m.audible_url = "https://www.audible.com/pd/" + m.asin

        got = self._cover_for(best, m.asin)
        if got:
            m.cover, m.cover_mime = got

        m.match_score = score
        log.debug("openaudible matched %r via %s (%.0f)", m.title, how, score)
        return m

    # -- cover art on disk ------------------------------------------------
    ART_DIRS = ("art", "images", "covers", "thumbs", "Art", "Images")

    def _art_roots(self) -> List[Path]:
        roots: List[Path] = []
        if self.cfg["openaudible_art_dir"]:
            roots.append(Path(self.cfg["openaudible_art_dir"]).expanduser())
        bases: List[Path] = []
        if self._base:
            bases.append(self._base)
        bases += self._candidates()
        for base in bases:
            for sub in self.ART_DIRS:
                d = base / sub
                if d.is_dir():
                    roots.append(d)
        seen, out = set(), []
        for r in roots:
            key = str(r).lower()
            if key not in seen and r.is_dir():
                seen.add(key)
                out.append(r)
        return out

    def _build_art_index(self) -> None:
        """OpenAudible nests cover art in subdirectories under art\\, so walk it."""
        if self._art is not None:
            return
        index: Dict[str, Path] = {}
        count = 0
        for root in self._art_roots():
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                for fn in filenames:
                    ext = Path(fn).suffix.lower()
                    if ext not in COVER_EXTS:
                        continue
                    p = Path(dirpath) / fn
                    stem = Path(fn).stem
                    count += 1
                    for k in (stem.lower(), norm_key(stem)):
                        if k and k not in index:
                            index[k] = p
        self._art = index
        self.art_files = count
        if count:
            log.info("OpenAudible: indexed %d cover image(s) under %s", count,
                     ", ".join(str(r) for r in self._art_roots()))

    def _cover_for(self, entry: Dict[str, Any],
                   asin: Optional[str]) -> Optional[Tuple[bytes, str]]:
        with self._art_lock:
            self._build_art_index()
        index = self._art or {}

        rel = str(entry.get("filename") or entry.get("key") or "").strip("/ ")
        folder = rel.replace("\\", "/").rstrip("/").split("/")[-1] if rel else ""
        title = str(entry.get("title") or entry.get("title_short") or "")

        probes: List[str] = []
        if asin:
            probes += [asin.lower(), norm_key(asin)]
        for cand in (title, folder, clean_title(folder)[0] if folder else ""):
            if cand:
                probes += [cand.lower(), norm_key(cand)]

        for key in probes:
            hit = index.get(key)
            if hit:
                try:
                    mime = "image/png" if hit.suffix.lower() == ".png" else "image/jpeg"
                    return hit.read_bytes(), mime
                except OSError:
                    continue

        # finally, a cover sitting inside the book's own folder
        for root in ([self._base] if self._base else []) + self._candidates():
            if not rel:
                break
            book_dir = root / rel
            if book_dir.is_dir():
                for stem in COVER_NAMES:
                    for ext in COVER_EXTS:
                        p = book_dir / (stem + ext)
                        if p.is_file():
                            try:
                                return p.read_bytes(), ("image/png" if ext == ".png"
                                                        else "image/jpeg")
                            except OSError:
                                pass
        return None


AUDIBLE_DOMAINS = {
    "us": "api.audible.com", "ca": "api.audible.ca", "uk": "api.audible.co.uk",
    "au": "api.audible.com.au", "fr": "api.audible.fr", "de": "api.audible.de",
    "jp": "api.audible.co.jp", "it": "api.audible.it", "es": "api.audible.es",
    "in": "api.audible.in", "br": "api.audible.com.br",
}

AUDIBLE_GROUPS = ("contributors,media,product_attrs,product_desc,"
                  "product_extended_attrs,series,category_ladders")
AUDIBLE_IMAGE_SIZES = "500,1000,2400"


class AudibleProvider(Provider):
    """Audible's own catalog endpoint - no account, no API key.

    This is the same unauthenticated /1.0/catalog/products service that
    Audiobookshelf and the audnexus project use. It is not a documented,
    supported public API: fields can move and it can rate-limit, so every
    call fails soft and the chain carries on to the next provider.
    """
    name = "audible"
    limiter = RateLimiter(0.9)

    def _host(self) -> str:
        region = str(self.cfg["audible_region"] or "us").lower()
        return AUDIBLE_DOMAINS.get(region, AUDIBLE_DOMAINS["us"])

    def fetch_by_asin(self, asin: str) -> Optional[Dict[str, Any]]:
        url = (f"https://{self._host()}/1.0/catalog/products/{urllib.parse.quote(asin)}"
               f"?response_groups={AUDIBLE_GROUPS}&image_sizes={AUDIBLE_IMAGE_SIZES}")
        data = http_json(url, self.cfg, self.limiter, "audible-asin")
        if isinstance(data, dict):
            return data.get("product")
        return None

    def _attempts(self, title: str,
                  author: Optional[str]) -> List[Tuple[str, Dict[str, str]]]:
        """Query strategies, best first.

        keywords comes FIRST because Audible's own site search is keyword
        based. The `title` parameter matches the product's full title, and an
        audiobook's real title is often 'Warriors: Omen of the Stars #6: The
        Last Hope' - searching title='The Last Hope' returns nothing at all.
        """
        out: List[Tuple[str, Dict[str, str]]] = []
        seen: set = set()

        def add(label: str, extra: Dict[str, str]) -> None:
            key = tuple(sorted(extra.items()))
            if key not in seen and all(extra.values()):
                seen.add(key)
                out.append((label, extra))

        if author:
            add("keywords+author", {"keywords": f"{title} {author}"})
        add("keywords", {"keywords": title})
        if author:
            add("title+author", {"title": title, "author": author})
        add("title", {"title": title})
        return out

    def search(self, title: str, author: Optional[str]) -> List[Dict[str, Any]]:
        base = {
            "num_results": "20",
            "products_sort_by": "Relevance",
            "response_groups": AUDIBLE_GROUPS,
            "image_sizes": AUDIBLE_IMAGE_SIZES,
        }
        for label, extra in self._attempts(title, author):
            params = dict(base, **extra)
            url = (f"https://{self._host()}/1.0/catalog/products?"
                   + urllib.parse.urlencode(params))
            data = http_json(url, self.cfg, self.limiter, f"audible-{label}")
            products = [p for p in ((data or {}).get("products") or [])
                        if isinstance(p, dict)]
            log.debug("audible search [%s] %s -> %d result(s)", label,
                      {k: v for k, v in extra.items()}, len(products))
            if products:
                if label != self._attempts(title, author)[0][0]:
                    log.debug("audible: strategy %r succeeded after earlier ones failed",
                              label)
                return products
        return []

    @staticmethod
    def names(product: Dict[str, Any], key: str) -> Optional[str]:
        vals = product.get(key) or []
        out = [str(v.get("name")).strip() for v in vals
               if isinstance(v, dict) and v.get("name")]
        return ", ".join(dict.fromkeys(out)) or None

    def to_meta(self, product: Dict[str, Any], want_cover: bool = True) -> Meta:
        m = Meta(source=self.name)
        m.title = (str(product.get("title") or "").strip() or None)
        m.subtitle = (str(product.get("subtitle") or "").strip() or None)
        m.author = self.names(product, "authors")
        m.narrator = self.names(product, "narrators")
        m.publisher = (str(product.get("publisher_name") or "").strip() or None)
        summary = product.get("publisher_summary") or product.get("merchandising_summary")
        m.description = strip_html(str(summary or "")) or None
        m.asin = (str(product.get("asin") or "").strip() or None)
        m.language = norm_language(product.get("language"))
        release = (product.get("release_date") or product.get("issue_date")
                   or product.get("publication_datetime"))
        m.original_release = str(release) if release else None
        y = first_year(release)
        m.year = str(y) if y else None

        series_for_title = None
        series = product.get("series") or []
        if isinstance(series, list) and series:
            first = series[0] if isinstance(series[0], dict) else {}
            m.series = str(first.get("title") or "").strip() or None
            seq = first.get("sequence")
            n = first_int(seq)
            m.series_index = str(n) if n is not None else None
        series_for_title = m.series
        if not m.series:
            rel = product.get("relationships") or []
            for r in rel:
                if isinstance(r, dict) and r.get("relationship_type") == "series":
                    m.series = str(r.get("title") or "").strip() or None
                    n = first_int(r.get("sequence"))
                    m.series_index = str(n) if n is not None else m.series_index
                    break

        if self.cfg["audible_genre"]:
            ladders = product.get("category_ladders") or []
            leaf = None
            for lad in ladders:
                steps = (lad or {}).get("ladder") or []
                if steps:
                    leaf = str(steps[-1].get("name") or "").strip() or leaf
            if leaf:
                m.genre = leaf

        # Audible names series entries 'Warriors: Omen of the Stars #6: The
        # Last Hope'. Keep the book's own title in the album tag; the series
        # already has its own fields.
        if m.title and self.cfg.get("strip_series_from_title", True):
            cleaned = m.title
            m2 = re.search(r"#\s*\d+\s*[:" + DASHES + r"]\s*(.+)$", cleaned)
            if m2 and len(m2.group(1).strip()) >= 3:
                cleaned = m2.group(1).strip()
            elif series_for_title:
                stripped = strip_series_prefix(cleaned, series_for_title)
                if len(stripped) >= 3:
                    cleaned = stripped
            if cleaned != m.title:
                log.debug("audible: title %r -> %r", m.title, cleaned)
                m.title = cleaned

        if m.asin:
            m.audible_url = f"https://www.audible.com/pd/{m.asin}"
        authors = product.get("authors") or []
        if authors and isinstance(authors[0], dict):
            a_asin = str(authors[0].get("asin") or "").strip()
            a_name = str(authors[0].get("name") or "").strip()
            if a_asin and a_name:
                slug = urllib.parse.quote(a_name.replace(" ", "+"), safe="+")
                m.author_url = f"https://www.audible.com/author/{slug}/{a_asin}"

        if want_cover:
            m.cover, m.cover_mime = self.fetch_cover(product)
        return m

    def query_titles(self, hint: Meta) -> List[str]:
        """Ordered search terms to try. The tag is not always the best query."""
        out: List[str] = []

        def add(value: Optional[str]) -> None:
            value = (value or "").strip()
            if value and not is_junk_value(value) and value not in out:
                out.append(value)

        add(self.clean_hint_title(hint))
        if hint.rel_path:
            parts = [x for x in str(hint.rel_path).replace("\\", "/").split("/") if x]
            if parts:
                folder_title = clean_title(parts[-1])[0]
                probe = dataclasses.replace(hint)
                probe.title = folder_title
                add(self.clean_hint_title(probe))
                add(folder_title)
        add(hint.title)
        return out

    def candidates(self, hint: Meta, top: int = 8) -> List[Tuple[float, Dict[str, Any]]]:
        """Scored search results, best first - used by the interactive prompt."""
        scored: List[Tuple[float, Dict[str, Any]]] = []
        seen: set = set()
        for title in self.query_titles(hint):
            probe = dataclasses.replace(hint)
            probe.title = title
            for prod in self.search(title, hint.author):
                asin = str(prod.get("asin") or "")
                if asin and asin in seen:
                    continue
                seen.add(asin)
                s = self.score(probe, str(prod.get("title") or ""),
                               self.names(prod, "authors") or "")
                scored.append((s, prod))
            if scored and max(x[0] for x in scored) >= 100:
                break
        scored.sort(key=lambda t: -t[0])
        return scored[:top]

    def probe(self, title: str, author: Optional[str] = None) -> Tuple[bool, str]:
        """Live connectivity check. Surfaces the error rather than swallowing it."""
        params = {"num_results": "3", "products_sort_by": "Relevance",
                  "response_groups": AUDIBLE_GROUPS, "title": title}
        if author:
            params["author"] = author
        url = f"https://{self._host()}/1.0/catalog/products?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                                   "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.cfg["request_timeout"],
                                        context=ssl_context(self.cfg)) as resp:
                payload = json.loads(resp.read().decode("utf-8", "replace"))
                code = resp.status
        except Exception as exc:  # noqa: BLE001
            return False, f"{type(exc).__name__}: {exc}"
        products = payload.get("products") or []
        if not products:
            return False, f"HTTP {code} but zero products returned"
        lines = []
        for prod in products[:3]:
            lines.append("      {} | {} | {} | {}".format(
                prod.get("title"), self.names(prod, "authors"),
                self.names(prod, "narrators"), prod.get("release_date")))
        return True, f"HTTP {code}, {len(products)} result(s)\n" + "\n".join(lines)

    def fetch_cover(self, product: Dict[str, Any]) -> Tuple[Optional[bytes], Optional[str]]:
        """Largest available Audible cover.

        Amazon's CDN encodes the edge length in the filename (._SL1000_.), so a
        bigger variant can be requested directly even when the API only
        returned a small one.
        """
        images = product.get("product_images") or {}
        urls: List[str] = []
        for size in sorted(images.keys(), key=lambda k: first_int(k) or 0, reverse=True):
            val = images.get(size)
            if val:
                urls.append(str(val))
        if not urls:
            return None, None

        best = urls[0].replace("http://", "https://")
        wanted = int(self.cfg["cover_size"] or 1000)
        upscaled = re.sub(r"\._SL\d+_\.", f"._SL{max(wanted, 1000)}_.", best)
        for candidate in dict.fromkeys([upscaled, best] + urls[1:]):
            got = http_bytes(str(candidate).replace("http://", "https://"),
                             self.cfg, self.limiter)
            if got:
                return got
        return None, None

    def lookup(self, hint: Meta, want_cover: bool = True) -> Optional[Meta]:
        if hint.asin:
            product = self.fetch_by_asin(hint.asin)
            if product:
                log.debug("audible matched by ASIN %s", hint.asin)
                m = self.to_meta(product, want_cover=want_cover)
                m.match_score = 100.0
                return m

        floor = max(self.cfg["match_threshold"], self.cfg["title_only_threshold"])
        best, best_score, best_query = None, 0.0, None

        for title in self.query_titles(hint):
            probe = dataclasses.replace(hint)
            probe.title = title
            products = self.search(title, hint.author)
            if not products:
                log.debug("audible: no results for %r", title)
                continue
            for prod in products:
                cand_author = self.names(prod, "authors") or ""
                s = self.score(probe, str(prod.get("title") or ""), cand_author)
                if hint.narrator and self.names(prod, "narrators"):
                    if ratio(hint.narrator, self.names(prod, "narrators") or "") > 85:
                        s = min(100.0, s + 5.0)
                if s > best_score:
                    best, best_score, best_query = prod, s, title
            if best_score >= floor:
                break            # good enough; stop burning requests

        if not best or best_score < floor:
            if best:
                log.debug("audible: best candidate %r scored %.0f (floor %.0f) - rejected",
                          best.get("title"), best_score, floor)
            return None
        if best_query and best_query != self.clean_hint_title(hint):
            log.info("audible matched via fallback query %r", best_query)
        log.debug("audible matched %r (%.0f)", best.get("title"), best_score)
        m = self.to_meta(best, want_cover=want_cover)
        m.match_score = best_score
        return m


class OpenLibraryProvider(Provider):
    name = "openlibrary"
    limiter = RateLimiter(0.6)

    def lookup(self, hint: Meta) -> Optional[Meta]:
        if not hint.title:
            return None
        q = {"title": hint.title, "limit": "5"}
        if hint.author:
            q["author"] = hint.author
        url = "https://openlibrary.org/search.json?" + urllib.parse.urlencode(q)
        data = http_json(url, self.cfg, self.limiter, "openlibrary")
        docs = (data or {}).get("docs") or []
        best, best_score = None, 0.0
        for d in docs:
            s = self.score(hint, d.get("title") or "", (d.get("author_name") or [None])[0])
            if s > best_score:
                best, best_score = d, s
        if not best or best_score < self.cfg["match_threshold"]:
            return None
        m = Meta(source=self.name)
        m.title = best.get("title")
        m.subtitle = best.get("subtitle")
        m.author = (best.get("author_name") or [None])[0]
        y = first_year(best.get("first_publish_year"))
        m.year = str(y) if y else None
        m.publisher = (best.get("publisher") or [None])[0]
        isbns = best.get("isbn") or []
        m.isbn = isbns[0] if isbns else None
        langs = best.get("language") or []
        m.language = langs[0] if langs else None
        if best.get("cover_i"):
            got = http_bytes(f"https://covers.openlibrary.org/b/id/{best['cover_i']}-L.jpg",
                             self.cfg, self.limiter)
            if got:
                m.cover, m.cover_mime = got
        log.debug("openlibrary matched %r (%.0f)", m.title, best_score)
        return m


class GoogleBooksProvider(Provider):
    name = "google"
    limiter = RateLimiter(0.4)

    def lookup(self, hint: Meta) -> Optional[Meta]:
        if not hint.title:
            return None
        terms = f'intitle:"{hint.title}"'
        if hint.author:
            terms += f' inauthor:"{hint.author}"'
        params = {"q": terms, "maxResults": "5", "printType": "books"}
        if self.cfg["google_api_key"]:
            params["key"] = self.cfg["google_api_key"]
        url = "https://www.googleapis.com/books/v1/volumes?" + urllib.parse.urlencode(params)
        data = http_json(url, self.cfg, self.limiter, "google-books")
        items = (data or {}).get("items") or []
        best, best_score = None, 0.0
        for it in items:
            vi = it.get("volumeInfo") or {}
            s = self.score(hint, vi.get("title") or "", (vi.get("authors") or [None])[0])
            if s > best_score:
                best, best_score = vi, s
        if not best or best_score < self.cfg["match_threshold"]:
            return None
        m = Meta(source=self.name)
        m.title = best.get("title")
        m.subtitle = best.get("subtitle")
        m.author = ", ".join(best.get("authors") or []) or None
        m.publisher = best.get("publisher")
        m.description = best.get("description")
        m.language = best.get("language")
        y = first_year(best.get("publishedDate"))
        m.year = str(y) if y else None
        m.original_release = best.get("publishedDate")
        for ident in best.get("industryIdentifiers") or []:
            if ident.get("type", "").startswith("ISBN"):
                m.isbn = ident.get("identifier")
                break
        links = best.get("imageLinks") or {}
        cover_url = links.get("extraLarge") or links.get("large") or links.get("thumbnail")
        if cover_url:
            got = http_bytes(cover_url.replace("http://", "https://").replace("&edge=curl", ""),
                             self.cfg, self.limiter)
            if got:
                m.cover, m.cover_mime = got
        log.debug("google matched %r (%.0f)", m.title, best_score)
        return m


class MusicBrainzProvider(Provider):
    name = "musicbrainz"
    limiter = RateLimiter(1.1)          # MB asks for <= 1 req/sec

    def lookup(self, hint: Meta) -> Optional[Meta]:
        if not hint.title:
            return None
        query = f'release:"{hint.title}"'
        if hint.author:
            query += f' AND artist:"{hint.author}"'
        url = ("https://musicbrainz.org/ws/2/release?fmt=json&limit=5&query="
               + urllib.parse.quote(query))
        data = http_json(url, self.cfg, self.limiter, "musicbrainz")
        releases = (data or {}).get("releases") or []
        best, best_score = None, 0.0
        for r in releases:
            artist = ""
            credits = r.get("artist-credit") or []
            if credits:
                artist = credits[0].get("name") or ""
            s = self.score(hint, r.get("title") or "", artist)
            if s > best_score:
                best, best_score = r, s
        if not best or best_score < self.cfg["match_threshold"]:
            return None
        m = Meta(source=self.name)
        m.title = best.get("title")
        credits = best.get("artist-credit") or []
        if credits:
            m.author = credits[0].get("name")
        y = first_year(best.get("date"))
        m.year = str(y) if y else None
        labels = best.get("label-info") or []
        if labels and labels[0].get("label"):
            m.publisher = labels[0]["label"].get("name")
        if best.get("id"):
            got = http_bytes(f"https://coverartarchive.org/release/{best['id']}/front-500",
                             self.cfg, self.limiter)
            if got:
                m.cover, m.cover_mime = got
        log.debug("musicbrainz matched %r (%.0f)", m.title, best_score)
        return m


def build_providers(cfg: Dict[str, Any]) -> Dict[str, Provider]:
    return {
        "openaudible": OpenAudibleProvider(cfg),
        "audible": AudibleProvider(cfg),
        "openlibrary": OpenLibraryProvider(cfg),
        "google": GoogleBooksProvider(cfg),
        "musicbrainz": MusicBrainzProvider(cfg),
    }


# ==========================================================================
# cover art
# ==========================================================================

def local_cover(book: Book) -> Optional[Tuple[bytes, str]]:
    for p in sorted(book.path.iterdir()) if book.path.is_dir() else []:
        if not p.is_file() or p.suffix.lower() not in COVER_EXTS:
            continue
        if p.stem.lower() in COVER_NAMES or len(list(book.path.glob("*.jpg"))) == 1:
            try:
                mime = "image/png" if p.suffix.lower() == ".png" else "image/jpeg"
                return p.read_bytes(), mime
            except OSError:
                return None
    return None


def process_cover(data: bytes, mime: str, cfg: Dict[str, Any]) -> Tuple[bytes, str]:
    """Square-ish resize / recompress. No-op without Pillow."""
    if not HAVE_PIL:
        return data, mime
    size = int(cfg["cover_size"])
    try:
        with Image.open(_io.BytesIO(data)) as im:
            im = im.convert("RGB")
            if max(im.size) > size:
                im.thumbnail((size, size), Image.LANCZOS)
            buf = _io.BytesIO()
            im.save(buf, format="JPEG", quality=int(cfg["cover_quality"]), optimize=True)
            return buf.getvalue(), "image/jpeg"
    except Exception as exc:  # noqa: BLE001
        log.debug("cover processing failed: %s", exc)
        return data, mime


def save_cover_file(book: Book, m: Meta, dry_run: bool) -> None:
    if not m.cover:
        return
    target = book.path / ("cover.png" if (m.cover_mime or "").endswith("png") else "cover.jpg")
    if target.exists() or dry_run:
        return
    try:
        target.write_bytes(m.cover)
    except OSError as exc:
        log.warning("could not write %s: %s", target, exc)


# ==========================================================================
# backup / rollback
# ==========================================================================

class Backup:
    """Snapshot of the managed fields (and cover) for every file we touch.

    Each entry is appended to snapshot.jsonl and flushed to disk BEFORE the
    corresponding file is written, so a crash, a kill, or Ctrl-C still leaves a
    complete record of everything already changed. snapshot.json is written at
    the end as a convenience; rollback reads either.
    """

    def __init__(self, cfg: Dict[str, Any], enabled: bool = True):
        self.dir = Path(cfg["backup_dir"]) / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.enabled = enabled
        self.entries: List[Dict[str, Any]] = []
        self._lock = threading.Lock()
        self._stream = None
        self._started = False

    def _open(self) -> None:
        if self._started:
            return
        self.dir.mkdir(parents=True, exist_ok=True)
        self._stream = (self.dir / "snapshot.jsonl").open("a", encoding="utf-8")
        header = {"_meta": {"program": PROGRAM, "version": __version__,
                            "started": dt.datetime.now().isoformat(timespec="seconds")}}
        self._stream.write(json.dumps(header, ensure_ascii=False) + "\n")
        self._stream.flush()
        os.fsync(self._stream.fileno())
        self._started = True
        log.info("backup: recording to %s", self.dir / "snapshot.jsonl")

    def add(self, path: Path, m: Meta) -> None:
        """Record a file's current state. Must be called before writing it."""
        if not self.enabled:
            return
        entry: Dict[str, Any] = {"file": str(path),
                                 "tags": {k: getattr(m, k) for k in FIELDS}}
        with self._lock:
            self._open()
            if m.cover:
                digest = hashlib.sha1(m.cover).hexdigest()
                cover_path = self.dir / f"{digest}.img"
                if not cover_path.exists():
                    cover_path.write_bytes(m.cover)
                entry["cover"] = digest
                entry["cover_mime"] = m.cover_mime
            self.entries.append(entry)
            try:
                self._stream.write(json.dumps(entry, ensure_ascii=False) + "\n")
                self._stream.flush()
                os.fsync(self._stream.fileno())      # survive a hard kill
            except OSError as exc:
                log.warning("backup append failed for %s: %s", path, exc)

    def flush(self) -> Optional[Path]:
        if not self.enabled or not self.entries:
            return None
        with self._lock:
            path = self.dir / "snapshot.json"
            payload = {"program": PROGRAM, "version": __version__,
                       "created": dt.datetime.now().isoformat(timespec="seconds"),
                       "entries": self.entries}
            try:
                path.write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                                encoding="utf-8")
            except OSError as exc:
                log.warning("could not write %s: %s", path, exc)
                return self.dir / "snapshot.jsonl"
            if self._stream is not None:
                try:
                    self._stream.close()
                except OSError:
                    pass
                self._stream = None
        log.info("backup written: %s (%d file(s))", path, len(self.entries))
        return path


def load_snapshot(target: Path) -> Tuple[Path, List[Dict[str, Any]]]:
    """Read a snapshot directory or file, preferring the complete .json."""
    if target.is_dir():
        for name in ("snapshot.json", "snapshot.jsonl"):
            candidate = target / name
            if candidate.is_file():
                target = candidate
                break
        else:
            raise SystemExit(f"no snapshot found in {target}")
    if not target.is_file():
        raise SystemExit(f"snapshot not found: {target}")

    if target.suffix == ".jsonl":
        entries = []
        for line in target.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                log.warning("skipping truncated line in %s", target)   # crash mid-write
                continue
            if isinstance(record, dict) and "file" in record:
                entries.append(record)
        return target, entries

    payload = json.loads(target.read_text(encoding="utf-8"))
    return target, payload.get("entries", [])


def list_snapshots(cfg: Dict[str, Any]) -> int:
    base = Path(cfg["backup_dir"])
    if not base.is_dir():
        print(f"  no backup directory at {base.resolve()}")
        return 1
    found = sorted(d for d in base.iterdir() if d.is_dir())
    if not found:
        print(f"  no snapshots under {base.resolve()}")
        return 1
    print("")
    print(f"  snapshots under {base.resolve()}")
    for d in found:
        try:
            _, entries = load_snapshot(d)
        except SystemExit:
            print(f"    {d.name}  (unreadable)")
            continue
        complete = (d / "snapshot.json").is_file()
        print(f"    {d.name}  {len(entries):>5} file(s)"
              f"  {'complete' if complete else 'INTERRUPTED - partial run'}")
    print("")
    print("  restore with:  rollback <name>      (or no name for the most recent)")
    print("")
    return 0


def do_rollback(cfg: Dict[str, Any], snapshot: Optional[str], dry_run: bool) -> int:
    base = Path(cfg["backup_dir"])
    if snapshot:
        target = Path(snapshot)
        if not target.exists() and (base / snapshot).exists():
            target = base / snapshot           # accept a bare snapshot name
    else:
        dirs = sorted(d for d in base.glob("*") if d.is_dir()
                      and ((d / "snapshot.json").is_file()
                           or (d / "snapshot.jsonl").is_file()))
        if not dirs:
            raise SystemExit(f"no snapshots found under {base.resolve()}")
        target = dirs[-1]

    snap, entries = load_snapshot(target)
    if snap.suffix == ".jsonl":
        log.warning("using the incremental log %s - that run did not finish, "
                    "so this restores only the files it had already changed", snap)
    log.info("rolling back %d file(s) from %s", len(entries), snap)
    failed = 0
    for entry in entries:
        path = Path(entry["file"])
        if not path.is_file():
            log.warning("missing, skipped: %s", path)
            failed += 1
            continue
        m = Meta(source="rollback")
        for k, v in (entry.get("tags") or {}).items():
            if k in FIELDS:
                setattr(m, k, v)
        cover_mode = "keep"
        if entry.get("cover"):
            cp = snap.parent / f"{entry['cover']}.img"
            if cp.is_file():
                m.cover = cp.read_bytes()
                m.cover_mime = entry.get("cover_mime") or "image/jpeg"
                cover_mode = "replace"
        if dry_run:
            log.info("[dry-run] would restore %s", path)
            continue
        try:
            write_tags(path, m, overwrite=True, cover_mode=cover_mode,
                       track=first_int(m.track), total=None, dry_run=False,
                       preserve_times=bool(cfg.get("preserve_mtime", True)))
            log.info("restored %s", path)
        except TagError as exc:
            log.error("rollback failed: %s", exc)
            failed += 1
    return failed


# ==========================================================================
# verification
# ==========================================================================

REQUIRED = [
    ("title", "Missing Album/Title"),
    ("author", "Missing Author"),
    ("narrator", "Missing Narrator"),
    ("genre", "Missing Genre"),
    ("publisher", "Missing Publisher"),
    ("year", "Unknown Year"),
    ("description", "Missing Description"),
]


def verify_book(book: Book) -> List[str]:
    """Return real problems. Track-sequence findings go to book.notes instead:
    no metadata provider supplies track numbers, so an unusual sequence is an
    observation about the files, not a tagging failure."""
    issues: List[str] = []
    book.notes = []
    m = book.final if any(getattr(book.final, f) for f in FIELDS) else book.existing
    for fname, label in REQUIRED:
        if not getattr(m, fname):
            issues.append(label)
    if not m.cover:
        issues.append("Missing Cover")

    # track numbers may legitimately restart inside each disc, so validate
    # per disc rather than demanding 1..N across the whole book
    per_disc: Dict[int, List[Optional[int]]] = {}
    for f in book.files:
        try:
            t = read_tags(f)
        except TagError:
            issues.append("Unreadable file: " + f.name)
            continue
        disc = first_int(t.disc) or 1
        per_disc.setdefault(disc, []).append(first_int(t.track))
    for f in book.files:
        ext = f.suffix.lower()
        try:
            if ext in (".m4b", ".m4a"):
                trkn = (MP4(f).tags or {}).get("trkn")
                if trkn and len(trkn[0]) > 1 and not trkn[0][1]:
                    book.notes.append(f"{f.name}: track total missing (n of 0)")
            elif ext == ".mp3":
                raw = _t(ID3(f), "TRCK") if ID3(f).get("TRCK") is not None else None
                if raw and "/" not in raw:
                    book.notes.append(f"{f.name}: track number has no total")
        except Exception:  # noqa: BLE001
            pass

    if len(book.files) > 1:
        for disc, numbers in sorted(per_disc.items()):
            if len(numbers) < 2:
                continue
            label = f"disc {disc}: " if len(per_disc) > 1 else ""
            if any(n is None for n in numbers):
                book.notes.append(f"{label}some files have no track number")
            elif sorted(n for n in numbers if n) != list(range(1, len(numbers) + 1)):
                book.notes.append(f"{label}track numbers are not 1..{len(numbers)}")

    if len(book.files) == 1 and book.files[0].suffix.lower() in (".m4b",):
        try:
            audio = MP4(book.files[0])
            if not getattr(audio, "chapters", None):
                issues.append("Missing Chapters")
        except Exception:  # noqa: BLE001
            pass
    return issues


def find_duplicates(books: Sequence[Book]) -> List[List[Book]]:
    groups: Dict[str, List[Book]] = {}
    for b in books:
        title = (b.final.album or b.final.title
                 or b.existing.album or b.existing.title or b.name)
        author = (b.final.albumartist or b.final.author
                  or b.existing.albumartist or b.existing.author or "")
        groups.setdefault(f"{norm_key(author)}|{norm_key(title)}", []).append(b)
    return [g for g in groups.values() if len(g) > 1]


# ==========================================================================
# processing pipeline
# ==========================================================================

@dataclass
class Options:
    dry_run: bool = False
    force: bool = False
    plex: bool = False
    cover_mode: str = "auto"       # auto | replace | keep | remove
    no_backup: bool = False
    write_cover_file: bool = False
    only_missing: bool = False
    renumber: bool = False
    ask_asin: bool = False
    chapter_titles: bool = False
    force_fields: Tuple[str, ...] = ()
    preserve_mtime: bool = True
    manual: bool = False
    non_interactive: bool = False
    ask_below: float = 100.0


def resolve_metadata(book: Book, cfg: Dict[str, Any], providers: Dict[str, Provider],
                     opts: Options) -> Meta:
    """Run the provider chain in configured order and merge the results."""
    book.existing = read_book_tags(book)
    folder = meta_from_path(book, cfg)

    final = Meta(source="merged")
    path_asin = find_asin("/".join(book.rel_parts), book.path.name,
                          *[f.name for f in book.files[:4]],
                          book.existing.comment, book.existing.album)
    if path_asin and not book.existing.asin:
        log.info("%s: using ASIN %s found in the path/filename", book.path.name, path_asin)

    # An album tag identical to the parent folder is a series or box-set name
    # ("Warriors 1: The Prophecies Begin"), not this book's title. Prefer the
    # book's own folder name and treat the album as the series.
    album = book.existing.album or book.existing.title
    parent = book.rel_parts[-2] if len(book.rel_parts) >= 2 else ""
    hint_series = folder.series
    if album and parent and ratio(album, parent) >= 88 and folder.title:
        log.debug("%s: album %r matches parent folder - using folder title %r",
                  book.path.name, album, folder.title)
        hint_series = hint_series or album
        album = folder.title

    hint = Meta(
        title=album or folder.title,
        series=hint_series,
        author=book.existing.albumartist or book.existing.author or folder.author,
        asin=book.existing.asin or path_asin,
        rel_path="/".join(book.rel_parts),
    )
    hint.title = Provider.clean_hint_title(hint)

    for name in cfg["provider_order"]:
        if name == "existing":
            final.merge_from(book.existing, overwrite=False)
            book.providers_used.append("existing")
            continue
        if name == "folder":
            final.merge_from(folder, overwrite=False)
            book.providers_used.append("folder")
            continue
        provider = providers.get(name)
        if provider is None:
            log.warning("unknown provider in provider_order: %s", name)
            continue
        try:
            got = provider.lookup(hint)
        except Exception as exc:  # noqa: BLE001
            log.debug("%s lookup error: %s", name, exc)
            got = None
        if got:
            if got.match_score is not None:
                book.match_score = max(book.match_score or 0.0, got.match_score)
            log.debug("%s returned for %s: %s", name, book.path.name,
                      json.dumps(got.as_dict(with_cover=True), ensure_ascii=False))
            added = final.merge_from(got, overwrite=False)
            if added:
                book.providers_used.append(name)
            if not hint.author and got.author:
                hint.author = got.author

    # folder inference always acts as the final safety net
    final.merge_from(folder, overwrite=False)

    # local cover file beats nothing
    if not final.cover:
        got = local_cover(book)
        if got:
            final.cover, final.cover_mime = got

    # normalise
    if final.title:
        prefix_series = final.series or folder.series
        stripped = strip_series_prefix(final.title, prefix_series)
        if stripped != final.title:
            if not final.series_index:
                n = first_int(final.title[:len(final.title) - len(stripped)])
                if n is not None:
                    final.series_index = str(n)
            final.title = stripped
        base, series, index = split_series(final.title)
        final.title = base
        if series and not final.series:
            final.series = series
        if index and not final.series_index:
            final.series_index = str(index)
    final.album = final.album or final.title
    final.albumartist = final.albumartist or final.author
    final.genre = final.genre or cfg["genre"]
    if final.year:
        y = first_year(final.year)
        final.year = str(y) if y else None
    if final.series_index:
        n = first_int(final.series_index)
        final.series_index = str(n) if n is not None else None
    if final.description:
        final.description = strip_html(final.description) or None
    final.language = norm_language(final.language)
    if final.description and len(final.description) > 4000:
        final.description = final.description[:3997] + "..."

    apply_output_mapping(final, cfg, opts)

    if final.cover:
        final.cover, final.cover_mime = process_cover(final.cover, final.cover_mime or "image/jpeg", cfg)
    final.rel_path = hint.rel_path
    book.hint = hint
    return final


def apply_output_mapping(final: Meta, cfg: Dict[str, Any], opts: "Options") -> None:
    """Final field mapping. Must run again after any late metadata change
    (a manual ASIN pick), or album/albumartist keep their pre-pick values."""
    final.album = final.album or final.title
    final.albumartist = final.albumartist or final.author
    final.genre = final.genre or cfg["genre"]
    if opts.plex:
        final.album = final.title
        final.albumartist = final.author
        # only impose the flat genre when the user has not asked for the
        # provider's own genre
        if not cfg.get("audible_genre") or not final.genre:
            final.genre = cfg["genre"]

    # album_template last: --plex sets album from title, so rendering earlier
    # would just be overwritten
    template = str(cfg.get("album_template") or "{title}").strip()
    if template and template != "{title}" and final.title:
        idx = first_int(final.series_index)
        fields = {
            "title": final.title or "",
            "series": final.series or "",
            "index": str(idx) if idx is not None else "",
            "index2": f"{idx:02d}" if idx is not None else "",
            "author": final.author or "",
            "year": final.year or "",
            "narrator": final.narrator or "",
        }
        try:
            rendered = template.format(**fields)
            rendered = re.sub(r"\s{2,}", " ", rendered).strip(" -,:")
            if rendered:
                final.album = rendered
        except (KeyError, IndexError, ValueError) as exc:
            log.warning("bad album_template %r: %s", template, exc)

    # Audible has no comment field, so decide what a comment should be
    source = str(cfg.get("comment_source") or "summary").lower()
    series_line = None
    if final.series:
        series_line = (f"{final.series}, Book {final.series_index}"
                       if final.series_index else final.series)
    if source == "series":
        final.comment = series_line or final.comment
    elif source == "summary":
        final.comment = final.description or series_line or final.comment
    elif source == "both":
        parts = [x for x in (series_line, final.description) if x]
        final.comment = "\n\n".join(parts) or final.comment
    elif source == "none":
        final.comment = None


def prompt_for_asin(book: Book, final: Meta, audible: Optional["AudibleProvider"],
                    hint: Meta) -> Optional[str]:
    """Ask the operator to confirm or supply an ASIN for a non-exact match."""
    print("")
    print("-" * 72)
    print(f"  UNCERTAIN MATCH  ({'no match' if book.match_score is None else f'{book.match_score:.0f}%'})")
    print(f"  folder : {book.path}")
    print(f"  tags   : album={book.existing.album!r} artist={book.existing.author!r}")
    print(f"  best   : {final.title!r} by {final.author!r}"
          f"{' / ' + final.narrator if final.narrator else ''}"
          f"{' / ASIN ' + final.asin if final.asin else ''}")

    query: Optional[str] = None
    while True:
        options: List[str] = []
        if audible is not None:
            probe = dataclasses.replace(hint)
            if query:
                probe.title = query
                probe.rel_path = None
            try:
                cands = audible.candidates(probe)
            except Exception as exc:  # noqa: BLE001
                cands = []
                print(f"  (candidate lookup failed: {exc})")
            if cands:
                print("")
                print(f"  Audible candidates{' for ' + repr(query) if query else ''}:")
                for i, (score, prod) in enumerate(cands, start=1):
                    asin = str(prod.get("asin") or "")
                    options.append(asin)
                    series = prod.get("series") or [{}]
                    stitle = series[0].get("title") if series and isinstance(series[0], dict) else ""
                    seq = series[0].get("sequence") if series and isinstance(series[0], dict) else ""
                    print(f"   {i:>2}. [{score:5.1f}] {prod.get('title')}"
                          f" | {audible.names(prod, 'authors')}"
                          f" | {audible.names(prod, 'narrators')}"
                          f" | {prod.get('release_date') or ''}"
                          f" | {stitle}{' #' + str(seq) if seq else ''}"
                          f" | {asin}")
            else:
                print("")
                print(f"  No Audible results{' for ' + repr(query) if query else ''}"
                      f" (tried: {', '.join(repr(t) for t in audible.query_titles(probe))})")

        print("")
        print("  Enter a number, paste an ASIN / numeric ID / audible.com URL,")
        print("  type any other text to search Audible for it,")
        print("  's' to skip this book, or Enter to accept the best match.")
        try:
            answer = input("  > ").strip()
        except EOFError:
            return None
        if not answer:
            return None
        if answer.lower() in ("s", "skip"):
            return "SKIP"
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return options[int(answer) - 1] or None
        found = find_asin(answer)
        if found:
            return found
        if audible is None:
            print("  Audible is not in provider_order - cannot search.")
            return None
        query = answer          # treat it as a new search term and loop
        print(f"  Searching Audible for {query!r}...")


def tag_book(book: Book, cfg: Dict[str, Any], providers: Dict[str, Provider],
             opts: Options, backup: Backup) -> Book:
    try:
        book.final = resolve_metadata(book, cfg, providers, opts)

        needs_prompt = (opts.manual
                        or book.match_score is None
                        or book.match_score < opts.ask_below)
        if opts.ask_asin and needs_prompt and not opts.non_interactive:
            audible = providers.get("audible")
            chosen = prompt_for_asin(book, book.final, audible if isinstance(
                audible, AudibleProvider) else None, book.hint or Meta())
            if chosen == "SKIP":
                book.status = "skipped"
                book.notes.append("skipped by operator")
                return book
            if chosen and isinstance(audible, AudibleProvider):
                product = audible.fetch_by_asin(chosen)
                if product:
                    picked = audible.to_meta(product)
                    picked.match_score = 100.0
                    book.final.merge_from(picked, overwrite=True)
                    book.match_score = 100.0
                    book.providers_used.append("audible:manual")
                    apply_output_mapping(book.final, cfg, opts)
                    if book.final.cover:
                        book.final.cover, book.final.cover_mime = process_cover(
                            book.final.cover, book.final.cover_mime or "image/jpeg", cfg)
                    log.info("%s: operator selected ASIN %s", book.path.name, chosen)
                else:
                    log.warning("%s: ASIN %s returned nothing", book.path.name, chosen)

        if not book.final.title or not book.final.author:
            book.status = "unknown"
            book.issues.append("Could not determine title/author")
            log.warning("unidentified: %s", book.path)
            return book

        if opts.only_missing and book.existing.title and book.existing.author and book.existing.cover:
            book.status = "skipped"
            return book

        total = len(book.files)
        changed: List[str] = []
        for idx, f in enumerate(sorted(book.files, key=natural_key), start=1):
            try:
                original = read_tags(f)
            except TagError:
                original = Meta(source="existing")
            backup.add(f, original)
            per_file = dataclasses.replace(book.final)
            per_file.cover = book.final.cover
            per_file.cover_mime = book.final.cover_mime
            # Every file in a book carries the book's title by default, so all
            # files agree. Deriving a title per file from its filename makes
            # them disagree (noise-stripping collapses 'X Part 2' to 'X'), and
            # Plex shows the album title anyway.
            if total > 1 and opts.chapter_titles:
                chap, _ = clean_title(f.stem)
                per_file.title = chap or book.final.title
            elif total > 1 and cfg.get("chapter_title_template"):
                chap = render_chapter_title(cfg["chapter_title_template"],
                                            book, idx, total)
                if chap:
                    per_file.title = chap
            written = write_tags(f, per_file, overwrite=opts.force,
                                 cover_mode=opts.cover_mode, track=idx, total=total,
                                 dry_run=opts.dry_run, force_track=opts.renumber,
                                 force_fields=opts.force_fields,
                                 preserve_times=opts.preserve_mtime)
            changed.extend(written)

        if opts.write_cover_file:
            save_cover_file(book, book.final, opts.dry_run)

        book.changes = sorted(set(changed))
        book.status = "updated" if book.changes else "ok"
        log.info("%s%s -> %s [%s]", "[dry-run] " if opts.dry_run else "",
                 book.path.name, book.final.title, ", ".join(book.providers_used) or "none")
    except Exception as exc:  # noqa: BLE001
        book.status = "failed"
        book.error = str(exc)
        log.error("failed %s: %s", book.path, exc)
    return book


class Interrupted(RuntimeError):
    """Ctrl-C during processing. Carries whatever finished."""

    def __init__(self, done: Sequence[Book]):
        super().__init__("interrupted")
        self.done = list(done)


def run_parallel(books: Sequence[Book], fn, workers: int) -> List[Book]:
    out: List[Book] = []
    if workers <= 1:
        try:
            for b in books:
                out.append(fn(b))
        except KeyboardInterrupt:
            raise Interrupted(out)
        return out

    pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="tag")
    futures = {pool.submit(fn, b): b for b in books}
    try:
        for fut in as_completed(futures):
            book = futures[fut]
            try:
                out.append(fut.result())
            except Exception as exc:  # noqa: BLE001
                book.status = "failed"
                book.error = str(exc)
                out.append(book)
    except KeyboardInterrupt:
        for fut in futures:
            fut.cancel()
        try:
            pool.shutdown(wait=False, cancel_futures=True)
        except TypeError:                      # Python 3.8
            pool.shutdown(wait=False)
        raise Interrupted(out)
    finally:
        try:
            pool.shutdown(wait=False)
        except Exception:  # noqa: BLE001
            pass
    return sorted(out, key=lambda b: str(b.path))


# ==========================================================================
# organise / rename
# ==========================================================================

def template_fields(book: Book, index: Optional[int] = None,
                    total: Optional[int] = None,
                    sanitize: bool = True) -> Dict[str, str]:
    """Values available to the templates.

    sanitize=True strips characters illegal in filenames. Tag values keep
    their punctuation, so it is False for chapter titles.
    """
    clean = safe_name if sanitize else (lambda x, *a, **k: str(x))
    m = book.final if book.final.title else book.existing
    idx = first_int(m.series_index)
    track = index if index is not None else None
    width = max(2, len(str(total))) if total else 2
    return {
        "author": clean(m.author or ""),
        "title": clean(m.title or ""),
        "series": clean(m.series or ""),
        "index": str(idx) if idx is not None else "",
        "index2": f"{idx:02d}" if idx is not None else "",
        "year": str(m.year or ""),
        "asin": str(m.asin or ""),
        "narrator": clean(m.narrator or ""),
        "track": str(track) if track is not None else "",
        "track2": f"{track:0{width}d}" if track is not None else "",
        "total": str(total or ""),
    }


def render_template(template: str, fields: Dict[str, str]) -> Optional[str]:
    try:
        text = template.format(**fields)
    except (KeyError, IndexError, ValueError) as exc:
        log.warning("bad template %r: %s", template, exc)
        return None
    # collapse the gaps left by empty fields
    text = re.sub(r"\s*[-\u2013\u2014]\s*(?=[/\\]|$)", "", text)
    text = re.sub(r"[/\\]{2,}", "/", text)
    parts = [safe_name(part.strip(" -\u2013\u2014,"))
             for part in re.split(r"[/\\]", text) if part.strip(" -\u2013\u2014,")]
    return "/".join(p for p in parts if p) or None


def render_chapter_title(template: str, book: Book, index: int,
                         total: int) -> Optional[str]:
    """TITLE tag for one file of a multi-file book."""
    fields = template_fields(book, index=index, total=total, sanitize=False)
    try:
        text = str(template).format(**fields).strip()
    except (KeyError, IndexError, ValueError) as exc:
        log.warning("bad chapter_title_template %r: %s", template, exc)
        return None
    return text or None


def plan_layout(book: Book, root: Path, cfg: Dict[str, Any]) -> Optional[Path]:
    m = book.final if book.final.title else book.existing
    if not m.title or not m.author:
        return None
    fields = template_fields(book)
    template = (cfg["organize_template"] if m.series
                else cfg["organize_template_no_series"])
    rendered = render_template(template, fields)
    if not rendered:
        return None
    return root.joinpath(*rendered.split("/"))


def do_organize(books: Sequence[Book], root: Path, cfg: Dict[str, Any],
                dry_run: bool) -> int:
    moved = 0
    skipped = 0
    for b in books:
        m = b.final if b.final.title else b.existing
        if b.match_score is not None and b.match_score < 100 and not m.asin:
            log.warning("uncertain metadata, not moving: %s (score %.0f)",
                        b.path.name, b.match_score)
            skipped += 1
            continue
        target = plan_layout(b, root, cfg)
        if not target or target.resolve() == b.path.resolve():
            continue
        if target.exists():
            log.warning("target exists, skipping: %s", target)
            continue
        log.info("%smove %s -> %s", "[dry-run] " if dry_run else "", b.path, target)
        if not dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(b.path), str(target))
        moved += 1
    if skipped:
        log.warning("%d folder(s) skipped as uncertain - tag them first, or lower "
                    "ask_below and confirm the matches", skipped)
    return moved


def do_rename(books: Sequence[Book], cfg: Dict[str, Any], dry_run: bool) -> int:
    renamed = 0
    for b in books:
        total = len(b.files)
        if total < 2:
            continue
        for idx, f in enumerate(sorted(b.files, key=natural_key), start=1):
            stem = render_template(cfg["rename_template"],
                                   template_fields(b, index=idx, total=total))
            if not stem:
                continue
            new = f.with_name(f"{stem}{f.suffix.lower()}")
            if new == f or new.exists():
                continue
            log.info("%srename %s -> %s", "[dry-run] " if dry_run else "", f.name, new.name)
            if not dry_run:
                f.rename(new)
            renamed += 1
    return renamed


# ==========================================================================
# reports
# ==========================================================================

def build_summary(books: Sequence[Book], dupes: Sequence[Sequence[Book]]) -> Dict[str, Any]:
    return {
        "generated": dt.datetime.now().isoformat(timespec="seconds"),
        "version": __version__,
        "books_processed": len(books),
        "books_updated": sum(1 for b in books if b.status == "updated"),
        "books_ok": sum(1 for b in books if b.status == "ok"),
        "books_skipped": sum(1 for b in books if b.status == "skipped"),
        "books_failed": sum(1 for b in books if b.status == "failed"),
        "books_unknown": sum(1 for b in books if b.status == "unknown"),
        "books_with_issues": sum(1 for b in books if b.issues),
        "books_with_notes": sum(1 for b in books if b.notes),
        "books_below_100_match": sum(1 for b in books
                                     if b.match_score is not None and b.match_score < 100),
        "duplicate_groups": len(dupes),
        "files": sum(len(b.files) for b in books),
    }


def rows_for(books: Sequence[Book]) -> List[Dict[str, Any]]:
    rows = []
    for b in books:
        m = b.final if b.final.title else b.existing
        row = {"path": str(b.path), "status": b.status, "files": len(b.files),
               "providers": ", ".join(b.providers_used),
               "issues": "; ".join(b.issues), "notes": "; ".join(b.notes),
               "score": ("" if b.match_score is None else f"{b.match_score:.0f}"),
               "changes": ", ".join(b.changes),
               "error": b.error, "cover": "yes" if m.cover else "no"}
        for k in FIELDS:
            row[k] = getattr(m, k) or ""
        rows.append(row)
    return rows


def write_reports(books: Sequence[Book], dupes: Sequence[Sequence[Book]],
                  cfg: Dict[str, Any], formats: Iterable[str]) -> List[Path]:
    out_dir = Path(cfg["report_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    summary = build_summary(books, dupes)
    rows = rows_for(books)
    written: List[Path] = []

    formats = set(formats)
    if "json" in formats:
        p = out_dir / f"report-{stamp}.json"
        p.write_text(json.dumps(
            {"summary": summary, "books": rows,
             "duplicates": [[str(b.path) for b in g] for g in dupes]},
            indent=2, ensure_ascii=False), encoding="utf-8")
        written.append(p)

    if "csv" in formats:
        p = out_dir / f"report-{stamp}.csv"
        cols = (["path", "status", "files", "providers", "cover", "score"]
                + FIELDS + ["issues", "notes", "changes", "error"])
        with p.open("w", newline="", encoding="utf-8-sig") as fh:
            w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow(r)
        written.append(p)

    if "html" in formats:
        p = out_dir / f"report-{stamp}.html"
        p.write_text(render_html(summary, rows, dupes), encoding="utf-8")
        written.append(p)

    for p in written:
        log.info("report: %s", p)
    return written


def render_html(summary: Dict[str, Any], rows: List[Dict[str, Any]],
                dupes: Sequence[Sequence[Book]]) -> str:
    def esc(v):
        return html.escape(str(v or ""))

    cards = "".join(
        f'<div class="card"><div class="n">{esc(v)}</div><div class="l">{esc(k.replace("_", " "))}</div></div>'
        for k, v in summary.items() if isinstance(v, int))

    head_cols = ["status", "title", "author", "series", "series_index", "narrator",
                 "year", "publisher", "cover", "score", "providers", "issues",
                 "notes", "path"]
    thead = "".join(f"<th>{esc(c.replace('_', ' '))}</th>" for c in head_cols)
    body = []
    for r in rows:
        cls = {"updated": "u", "failed": "f", "unknown": "w", "skipped": "s"}.get(r["status"], "o")
        tds = "".join(f"<td>{esc(r.get(c))}</td>" for c in head_cols)
        body.append(f'<tr class="{cls}">{tds}</tr>')

    dup_html = ""
    if dupes:
        items = "".join("<li>" + "<br>".join(esc(b.path) for b in g) + "</li>" for g in dupes)
        dup_html = f"<h2>Duplicate candidates</h2><ul class='dupes'>{items}</ul>"

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>{PROGRAM} report</title>
<style>
 body{{font:14px/1.45 system-ui,Segoe UI,Roboto,sans-serif;margin:24px;color:#1b1b1b;background:#fafafa}}
 h1{{margin:0 0 4px}} .sub{{color:#666;margin-bottom:18px}}
 .cards{{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:22px}}
 .card{{background:#fff;border:1px solid #e2e2e2;border-radius:8px;padding:10px 16px;min-width:110px}}
 .card .n{{font-size:22px;font-weight:600}} .card .l{{color:#666;font-size:12px;text-transform:uppercase}}
 table{{border-collapse:collapse;width:100%;background:#fff;font-size:13px}}
 th,td{{border:1px solid #e6e6e6;padding:5px 8px;text-align:left;vertical-align:top}}
 th{{background:#f0f0f0;position:sticky;top:0}}
 tr.u td:first-child{{border-left:3px solid #2f7d32}}
 tr.f td:first-child{{border-left:3px solid #c62828}}
 tr.w td:first-child{{border-left:3px solid #ef6c00}}
 tr.s td:first-child{{border-left:3px solid #999}}
 td:last-child{{font-family:ui-monospace,Consolas,monospace;font-size:11px;color:#555}}
 .dupes li{{margin-bottom:8px;font-family:ui-monospace,Consolas,monospace;font-size:12px}}
</style></head><body>
<h1>{PROGRAM} report</h1>
<div class="sub">generated {esc(summary['generated'])} &middot; v{esc(summary['version'])}</div>
<div class="cards">{cards}</div>
<table><thead><tr>{thead}</tr></thead><tbody>{''.join(body)}</tbody></table>
{dup_html}
</body></html>"""


# ==========================================================================
# diagnostics
# ==========================================================================

LIBRARY_FIELDS = ("title", "author", "narrated_by", "publisher", "summary",
                  "release_date", "series_name", "series_sequence", "asin",
                  "language", "filename", "key")

SCAN_SKIP = {"node_modules", "windows", "program files", "program files (x86)",
             "$recycle.bin", "system volume information", ".git", "temp", "tmp",
             "cache", "caches", "packages", "winsxs"}


def looks_like_library(data: Any) -> Optional[List[Dict[str, Any]]]:
    """Is this JSON a list of book records?"""
    if isinstance(data, dict):
        data = data.get("books") or data.get("library") or data.get("items")
    if not isinstance(data, list) or not data:
        return None
    head = [e for e in data[:5] if isinstance(e, dict)]
    if not head:
        return None
    if not any(("title" in e or "filename" in e or "asin" in e) for e in head):
        return None
    return [e for e in data if isinstance(e, dict)]


def find_json_libraries(roots: Sequence[Path], max_depth: int = 5,
                        max_mb: int = 64) -> List[Tuple[Path, int, Dict[str, int]]]:
    """Walk for JSON files that look like OpenAudible libraries."""
    found: List[Tuple[Path, int, Dict[str, int]]] = []
    seen: set = set()
    for root in roots:
        try:
            root = root.expanduser().resolve()
        except OSError:
            continue
        if not root.is_dir() or str(root).lower() in seen:
            continue
        seen.add(str(root).lower())
        base_depth = len(root.parts)
        for dirpath, dirnames, filenames in os.walk(root):
            here = Path(dirpath)
            if len(here.parts) - base_depth >= max_depth:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames
                           if d.lower() not in SCAN_SKIP and not d.startswith(".")]
            for fn in filenames:
                if not fn.lower().endswith(".json"):
                    continue
                p = here / fn
                key = str(p).lower()
                if key in seen:
                    continue
                seen.add(key)
                try:
                    if p.stat().st_size > max_mb * 1024 * 1024:
                        continue
                    data = json.loads(p.read_text(encoding="utf-8", errors="replace"))
                except Exception:  # noqa: BLE001
                    continue
                entries = looks_like_library(data)
                if not entries:
                    continue
                counts = {f: sum(1 for e in entries if e.get(f) not in (None, "", []))
                          for f in LIBRARY_FIELDS}
                found.append((p, len(entries), counts))
    return sorted(found, key=lambda t: (-sum(1 for v in t[2].values() if v),
                                        -t[1], str(t[0])))


def do_find_json(cfg: Dict[str, Any], library: Optional[Path],
                 extra: Optional[Sequence[str]] = None) -> int:
    roots: List[Path] = [Path.cwd(), Path(__file__).resolve().parent]
    for e in extra or []:
        roots.append(Path(e).expanduser())
    if cfg["openaudible_dir"]:
        roots.append(Path(cfg["openaudible_dir"]))
    configured = cfg["openaudible_json"]
    if configured:
        for c in ([configured] if isinstance(configured, str) else configured):
            roots.append(Path(str(c)).parent)
    home = Path.home()
    roots += [home / "OpenAudible", home / "Documents", home / "Downloads",
              home / "Desktop", Path("C:/OpenAudible"), home]
    if library:
        roots.append(library.parent)
    # any OpenAudible folder sitting at the root of another fixed drive
    if os.name == "nt":
        for letter in "DEFGHIJKLMNOPQRSTUVWXYZ":
            d = Path(f"{letter}:/OpenAudible")
            try:
                if d.is_dir():
                    roots.append(d)
            except OSError:
                pass

    print("")
    print("=" * 72)
    print(f"{PROGRAM} {__version__} - JSON library scan")
    print("=" * 72)
    print("Searching (max depth 5):")
    for r in roots:
        print(f"  {r}")
    print("")

    hits = find_json_libraries(roots)
    if not hits:
        print("  No book-library JSON found.")
        print("  In OpenAudible use Library > Reveal to open the folder holding the")
        print("  live books.json, or File > Export to JSON to write a full dump.")
        print("  Add more places to search with: doctor --find-json --scan D:\\ E:\\path")
        return 1

    rich = [f for f in LIBRARY_FIELDS if f not in ("title", "author", "filename", "key")]
    for path, count, counts in hits:
        missing = [f for f in rich if not counts.get(f)]
        partialf = [f for f in rich if 0 < counts.get(f, 0) < count]
        verdict = "FULL   " if not missing else "partial"
        print(f"  [{verdict}] {path}   ({count} entries)")
        have = [f"{f} {counts[f]}/{count}" for f in LIBRARY_FIELDS if counts.get(f)]
        print(f"            has    : {', '.join(have)}")
        if missing:
            print(f"            MISSING: {', '.join(missing)}")
        if partialf:
            print(f"            partial: {', '.join(partialf)}")
        print("")

    # suggest at most two: the richest file, plus the largest one that adds
    # entries the richest lacks. Blindly merging every hit risks pulling in a
    # stale library.
    suggest = [hits[0]]
    for h in hits[1:]:
        if h[1] > hits[0][1]:
            suggest.append(h)
            break
    print("  Suggested config:")
    print("")
    print("  openaudible_json:")
    for path, _, _ in suggest:
        print(f'    - "{str(path).replace(chr(92), "/")}"')
    print("")
    counts = {c for _, c, _ in hits}
    if len(counts) > 1:
        print("  NOTE: these files hold different numbers of books "
              f"({', '.join(str(c) for c in sorted(counts, reverse=True))}).")
        print("  A smaller one may be a stale or separate library - check before")
        print("  adding it, since merged sources fill each other's gaps.")
        print("")
    return 0


FIELD_TAGS = [
    ("title",            "TALB (album)",          "\u00a9alb",  "ALBUM"),
    ("album",            "TALB (album)",          "\u00a9alb",  "ALBUM"),
    ("author",           "TPE1 (artist)",         "\u00a9ART",  "ARTIST"),
    ("albumartist",      "TPE2 (album artist)",   "aART",   "ALBUMARTIST"),
    ("narrator",         "TCOM (composer)",       "\u00a9wrt",  "COMPOSER + NARRATOR"),
    ("series",           "MVNM + TXXX:SERIES",    "\u00a9mvn",  "MOVEMENTNAME + SERIES"),
    ("series_index",     "MVIN + TXXX:SERIES-PART", "\u00a9mvi", "MOVEMENT + SERIES-PART"),
    ("genre",            "TCON",                  "\u00a9gen",  "GENRE"),
    ("year",             "TDRC",                  "\u00a9day",  "DATE"),
    ("publisher",        "TPUB",                  "\u00a9pub",  "PUBLISHER"),
    ("description",      "COMM:description",      "desc/ldes", "DESCRIPTION"),
    ("comment",          "COMM (no description)", "\u00a9cmt",  "COMMENT"),
    ("language",         "TLAN",                  "freeform", "LANGUAGE"),
    ("subtitle",         "TIT3",                  "freeform", "SUBTITLE"),
    ("asin",             "TXXX:ASIN",             "freeform", "ASIN"),
    ("isbn",             "TXXX:ISBN",             "freeform", "ISBN"),
    ("audible_url",      "TXXX:AUDIBLE_URL",      "freeform", "AUDIBLE_URL"),
    ("author_url",       "TXXX:AUTHOR_URL",       "freeform", "AUTHOR_URL"),
    ("original_release", "TXXX:ORIGINAL_RELEASE", "freeform", "ORIGINAL_RELEASE"),
    ("track",            "TRCK  (--renumber)",    "trkn",   "TRACKNUMBER"),
    ("disc",             "TPOS",                  "disk",   "DISCNUMBER"),
]


def do_fields() -> int:
    """Print which tag each field name writes. Writes nothing."""
    print("")
    print("=" * 78)
    print(f"{PROGRAM} {__version__} - field names for --overwrite-fields")
    print("=" * 78)
    print(f"  {'field':<18} {'MP3 (ID3)':<26} {'MP4':<10} Vorbis")
    print("  " + "-" * 74)
    for name, id3, mp4, vorbis in FIELD_TAGS:
        print(f"  {name:<18} {id3:<26} {mp4:<10} {vorbis}")
    print("")
    print("  Notes")
    print("   - 'author' writes the Artist tag. The Album Artist tag is a separate")
    print("     field called 'albumartist' - listing only 'author' leaves it alone.")
    print("   - With --plex both are set to the author, but they are still written")
    print("     under their own field names, so both must be listed to replace both.")
    print("   - 'track' is normally driven by --renumber (file order), not by a")
    print("     provider. --renumber rewrites it whatever the overwrite settings say.")
    print("   - 'title' and 'album' are the same tag: the book title.")
    print("   - Sort tags (TSOA/TSO2/TSOP, soal/soaa) follow the title and author")
    print("     automatically and have no field name of their own.")
    print("")
    return 0


def do_search(cfg: Dict[str, Any], title: str, author: Optional[str],
              show_raw: bool = False) -> int:
    """Query Audible directly and show every strategy's result. Writes nothing."""
    prov = AudibleProvider(cfg)
    print("")
    print("=" * 74)
    print(f"{PROGRAM} {__version__} - Audible search")
    print("=" * 74)
    print(f"  region : {cfg['audible_region']} -> {prov._host()}")
    print(f"  title  : {title!r}")
    print(f"  author : {author!r}")
    print("")

    base = {"num_results": "20", "products_sort_by": "Relevance",
            "response_groups": AUDIBLE_GROUPS, "image_sizes": AUDIBLE_IMAGE_SIZES}
    hint = Meta(title=title, author=author)
    any_hit = False
    for label, extra in prov._attempts(title, author):
        params = dict(base, **extra)
        url = f"https://{prov._host()}/1.0/catalog/products?" + urllib.parse.urlencode(params)
        data = http_json(url, cfg, prov.limiter, f"audible-{label}")
        products = [p for p in ((data or {}).get("products") or []) if isinstance(p, dict)]
        print(f"  [{label}] {extra}")
        print(f"      {len(products)} result(s)")
        if products:
            any_hit = True
            for prod in products[:8]:
                score = prov.score(hint, str(prod.get("title") or ""),
                                   prov.names(prod, "authors") or "")
                series = prod.get("series") or [{}]
                stitle = series[0].get("title") if series and isinstance(series[0], dict) else ""
                seq = series[0].get("sequence") if series and isinstance(series[0], dict) else ""
                print(f"      [{score:5.1f}] {prod.get('title')}"
                      f" | {prov.names(prod, 'authors')}"
                      f" | {prov.names(prod, 'narrators')}"
                      f" | {stitle}{' #' + str(seq) if seq else ''}"
                      f" | {prod.get('asin')}")
            if show_raw:
                print("      raw first result:")
                print(json.dumps(products[0], indent=2)[:2000])
            break
        print("")

    floor = max(cfg["match_threshold"], cfg["title_only_threshold"])
    print("")
    print(f"  acceptance floor: {floor} "
          f"(match_threshold={cfg['match_threshold']}, "
          f"title_only_threshold={cfg['title_only_threshold']})")
    if not any_hit:
        print("  Nothing found by any strategy. Try the search command with just a")
        print("  distinctive phrase and no author, or check the region setting.")
    print("")
    return 0 if any_hit else 1


def do_inspect(target: Path, limit: int = 0, raw: bool = True) -> int:
    """Dump every tag frame of every audio file under a path. Writes nothing."""
    if target.is_file():
        files = [target]
    else:
        files = sorted((p for p in target.rglob("*")
                        if p.suffix.lower() in AUDIO_EXTS and p.is_file()),
                       key=natural_key)
    if limit:
        files = files[:limit]
    if not files:
        print(f"  no audio files under {target}")
        return 1

    print("")
    print("=" * 74)
    print(f"{PROGRAM} {__version__} - raw tag dump ({len(files)} file(s))")
    print("=" * 74)

    for f in files:
        print("")
        print(f"  {f}")
        try:
            audio = mutagen.File(f)
        except Exception as exc:  # noqa: BLE001
            print(f"    UNREADABLE: {exc}")
            continue
        if audio is None or audio.tags is None:
            print("    (no tags)")
            continue
        if raw:
            try:
                items = sorted(audio.tags.items(), key=lambda kv: str(kv[0]))
            except Exception:  # noqa: BLE001
                items = list(audio.tags.items())
            for key, value in items:
                text = str(value)
                if isinstance(value, (bytes, bytearray)) or "APIC" in str(key) or key == "covr":
                    text = f"<{len(bytes(value) if isinstance(value, (bytes, bytearray)) else b'')} bytes>"
                if len(text) > 200:
                    text = text[:197] + "..."
                print(f"    {str(key):<28} {text}")
            for frame in getattr(audio.tags, "getall", lambda _x: [])("APIC"):
                print(f"    {'APIC (cover)':<28} {len(frame.data)} bytes, {frame.mime}")
        print("    " + "-" * 66)
        parsed = read_tags(f)
        for field_name in FIELDS:
            val = getattr(parsed, field_name)
            if val:
                text = str(val)
                print(f"    parsed.{field_name:<20} {text[:120]}")
        if parsed.cover:
            print(f"    parsed.cover{'':<15} {len(parsed.cover)} bytes {parsed.cover_mime}")
    print("")
    return 0


def do_doctor(root: Path, cfg: Dict[str, Any], books: Sequence[Book], limit: int = 10) -> int:
    """Explain exactly what the tool sees. Writes nothing."""
    out = print
    out("")
    out("=" * 72)
    out(f"{PROGRAM} {__version__} - doctor")
    out("=" * 72)

    out("")
    out("CONFIG")
    out(f"  loaded from      : {CONFIG_SOURCE}")
    out(f"  working directory: {Path.cwd()}")
    out(f"  library          : {root}")
    out(f"  provider_order   : {', '.join(cfg['provider_order'])}")
    out(f"  match_threshold  : {cfg['match_threshold']}")
    out(f"  network          : {cfg['network']}")
    if "openaudible" not in cfg["provider_order"]:
        out("  !! 'openaudible' is NOT in provider_order - it will never be consulted")

    out("")
    out("OPTIONAL LIBRARIES")
    out(f"  rapidfuzz (matching) : {'yes' if HAVE_RAPIDFUZZ else 'NO - using difflib'}")
    out(f"  Pillow (cover resize): {'yes' if HAVE_PIL else 'NO - covers embedded as-is'}")
    out(f"  PyYAML (yaml config) : {'yes' if HAVE_YAML else 'NO - json config only'}")
    if HAVE_CERTIFI:
        out(f"  certifi (TLS roots)  : yes -> {certifi.where()}")
    else:
        out("  certifi (TLS roots)  : NO - using the system store; install it if you "
            "see CERTIFICATE_VERIFY_FAILED")
    if cfg["ca_bundle"]:
        out(f"  ca_bundle            : {cfg['ca_bundle']}")
    if not cfg["ssl_verify"]:
        out("  ssl_verify           : FALSE - certificates are not being checked")

    out("")
    out("OPENAUDIBLE")
    prov = OpenAudibleProvider(cfg)
    for candidate in prov._json_paths():
        out(f"  {'FOUND  ' if candidate.is_file() else 'missing'}  {candidate}")
    prov._load()
    if not prov._index:
        out("  -> no library loaded. Set 'openaudible_json' to the exact path of books.json.")
    else:
        for src, count in prov.sources:
            out(f"  -> merged {count} entries from {src}")
        out(f"  -> {len(prov._index)} unique book(s) after merge")
        cov = prov.coverage()
        total = len(prov._index)
        out("")
        out("  FIELD COVERAGE (what this library can actually supply)")
        absent = []
        for fname, count in cov.items():
            flag = "ok " if count == total else ("-- " if count == 0 else "?? ")
            out(f"    {flag} {fname:<18} {count}/{total}")
            if count == 0:
                absent.append(fname)
        if absent:
            out("")
            out("  !! This JSON has no " + ", ".join(absent) + ".")
            out("     Those tags CANNOT come from OpenAudible with this file.")
            out("     Fix: export the full library from OpenAudible")
            out("     (File > Export, or the Books table's export button) and add its")
            out("     path to 'openaudible_json' - multiple paths are merged.")
            out("     Or enable the network providers to fill the gaps instead.")
        covers = sum(1 for e in prov._index[:limit]
                     if prov._cover_for(e, str(e.get('asin') or '')) is not None)
        out("")
        out("  COVER ART")
        roots = prov._art_roots()
        if roots:
            for r in roots:
                out(f"    searching {r}")
        else:
            out("    no art directory found - set 'openaudible_art_dir'")
        out(f"    {prov.art_files} image file(s) indexed")
        out(f"    matched for {covers}/{min(limit, total)} sampled book(s)")

    out("")
    out("AUDIBLE CATALOG (no account or API key required)")
    region = str(cfg["audible_region"] or "us").lower()
    out(f"  region  : {region} -> {AUDIBLE_DOMAINS.get(region, AUDIBLE_DOMAINS['us'])}")
    if "audible" not in cfg["provider_order"]:
        out("  !! 'audible' is NOT in provider_order - it will never be consulted")
    elif not cfg["network"]:
        out("  network disabled (--no-network or config) - skipped")
    else:
        probe_title, probe_author = "Prelude to Foundation", None
        if books:
            ex = read_book_tags(books[0])
            hint = Meta(title=ex.album or ex.title, author=ex.albumartist or ex.author,
                        rel_path="/".join(books[0].rel_parts))
            probe_title = Provider.clean_hint_title(hint) or probe_title
            probe_author = hint.author
        out(f"  probing : title={probe_title!r} author={probe_author!r}")
        ok, message = AudibleProvider(cfg).probe(probe_title, probe_author)
        out(f"  {'OK' if ok else 'FAILED'}: {message}")
        if not ok:
            if "CERTIFICATE_VERIFY_FAILED" in message or "SSLError" in message:
                out("")
                out("  TLS trust problem, not an Audible problem. In order:")
                out("    1) py -m pip install certifi        (then re-run doctor)")
                out("    2) if you are behind a TLS-inspecting proxy/AV, export its root")
                out("       certificate to a .pem and set:  ca_bundle: \"C:/path/root.pem\"")
                out("    3) last resort, unverified:         ssl_verify: false")
            else:
                out("  Check outbound HTTPS/proxy. The catalog endpoint is")
                out("  unauthenticated; a 403 usually means rate limiting - retry later.")

    audible = None
    if "audible" in cfg["provider_order"] and cfg["network"]:
        audible = AudibleProvider(cfg)

    out("")
    out(f"LIBRARY ({len(books)} book folder(s), {sum(len(b.files) for b in books)} file(s))")
    if audible is not None:
        out(f"  (querying Audible for each of the {min(limit, len(books))} sampled books)")
    matched = 0
    for b in books[:limit]:
        existing = read_book_tags(b)
        rel = "/".join(b.rel_parts)
        hint = Meta(title=existing.album or existing.title,
                    author=existing.albumartist or existing.author,
                    asin=existing.asin, rel_path=rel)
        out("")
        out(f"  {rel or b.path.name}")
        out(f"    existing album : {existing.album or '-'}")
        out(f"    existing artist: {existing.author or '-'}")
        if audible is not None:
            try:
                am = audible.lookup(hint, want_cover=False)
            except Exception as exc:  # noqa: BLE001
                am = None
                out(f"    AUDIBLE error: {exc}")
            if am:
                out(f"    AUDIBLE  : {am.title} / {am.narrator} / {am.publisher} / "
                    f"{am.year} / {am.series} #{am.series_index} / {am.asin}")
            else:
                out("    AUDIBLE  : no confident match")
        if prov._index:
            entry, score, how = prov._find(hint)
            floor = cfg["match_threshold"]
            if how == "title":
                floor = max(floor, cfg["title_only_threshold"])
            if entry and score >= floor:
                matched += 1
                out(f"    OPENAUD  : via {how} ({score:.0f}) {entry.get('title')} / "
                    f"{entry.get('narrated_by')} / {entry.get('publisher')} / "
                    f"{entry.get('release_date')}")
            else:
                out(f"    NO MATCH (best {score:.0f} via {how}, floor {floor:.0f}"
                    f"{', candidate: ' + str(entry.get('title')) if entry else ''})")
                out(f"    path key tried: {prov._path_key(rel)!r}")
        else:
            out("    (OpenAudible not loaded - nothing to match against)")

    if prov._index:
        out("")
        out(f"  {matched}/{min(limit, len(books))} sampled book(s) would match OpenAudible")
    out("")
    return 0


# ==========================================================================
# CLI
# ==========================================================================

LOOKALIKES = {"\u2013": "en dash", "\u2014": "em dash", "\u2018": "curly quote",
              "\u2019": "curly apostrophe", "\u201c": "curly quote",
              "\u201d": "curly quote", "\u00a0": "non-breaking space"}


def diagnose_path(path: Path) -> List[str]:
    """Explain why a path is unusable instead of just saying it is."""
    notes: List[str] = []
    raw = str(path)
    if path.is_file():
        notes.append("that is a FILE, not a folder - point at its parent folder")
    for ch, name in LOOKALIKES.items():
        if ch in raw:
            notes.append(f"contains a {name} ({ch!r}) - if you typed it by hand, "
                         f"the real folder may use a plain character instead")
    if raw != raw.strip():
        notes.append("has leading or trailing whitespace")

    parent = path.parent
    if not parent.is_dir():
        notes.append(f"the parent folder does not exist either: {parent}")
        return notes

    try:
        entries = sorted(p.name for p in parent.iterdir() if p.is_dir())
    except OSError as exc:
        notes.append(f"cannot list {parent}: {exc}")
        return notes

    notes.append(f"the parent EXISTS and holds {len(entries)} folder(s)")
    target = path.name
    close = difflib.get_close_matches(target, entries, n=5, cutoff=0.4) if entries else []
    lowered = {e.lower(): e for e in entries}
    if target.lower() in lowered:
        notes.append(f"case differs - the real name is {lowered[target.lower()]!r}")
    if close:
        notes.append("did you mean one of these?")
        notes.extend(f"    {c}" for c in close)
    elif entries:
        notes.append("folders present:")
        notes.extend(f"    {e}" for e in entries[:10])
        if len(entries) > 10:
            notes.append(f"    ... and {len(entries) - 10} more")
    return notes


def resolve_library(args, cfg) -> Path:
    lib = args.library or cfg["library"]
    if not lib:
        raise SystemExit("no library path given (argument or config 'library')")
    path = Path(str(lib).strip().strip('"')).expanduser()
    if not path.is_dir():
        lines = [f"library path is not a directory: {path}"]
        lines += ["  " + n for n in diagnose_path(path)]
        raise SystemExit("\n".join(lines))
    return path


def cover_mode_from_args(args) -> str:
    if getattr(args, "remove_cover", False):
        return "remove"
    if getattr(args, "replace_cover", False):
        return "replace"
    if getattr(args, "keep_cover", False):
        return "keep"
    return "auto"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog=PROGRAM,
        description="Organise, identify, tag, verify and report on an audiobook library.")
    p.add_argument("--version", action="version", version=f"{PROGRAM} {__version__}")
    p.add_argument("-c", "--config", help="path to YAML/JSON config file")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    p.add_argument("-j", "--workers", type=int, help="parallel workers (default: CPU count)")
    p.add_argument("--no-network", action="store_true", help="local providers only")
    p.add_argument("-o", "--option", action="append", metavar="KEY=VALUE",
                   help="override any config key, e.g. -o ask_below=95 "
                        "-o audible_region=uk (repeatable)")
    p.add_argument("-y", "--yes", action="store_true",
                   help="never prompt; accept the best match (use for scheduled tasks)")
    p.add_argument("--debug-data", action="store_true",
                   help="log every provider response and dump the raw JSON under logs/payloads/")
    p.add_argument("-p", "--providers", metavar="LIST",
                   help="override provider_order, e.g. --providers audible,existing,folder")

    sub = p.add_subparsers(dest="command", required=True)

    def common(sp, library=True):
        if library:
            sp.add_argument("library", nargs="?", help="library root (or set in config)")
        sp.add_argument("-n", "--dry-run", action="store_true", help="change nothing")
        return sp

    sp = common(sub.add_parser("tag", help="identify and write tags"))
    sp.add_argument("--plex", action="store_true", help="Plex-friendly field mapping")
    sp.add_argument("--force", action="store_true", help="overwrite existing values")
    sp.add_argument("--only-missing", action="store_true", help="skip fully tagged books")
    sp.add_argument("--renumber", action="store_true",
                    help="rewrite track numbers 1..N in file order, even without --force")
    sp.add_argument("--ask-asin", action="store_true",
                    help="prompt for an ASIN when a book matches below 'ask_below' "
                         "(default 100%%; forces single-threaded operation)")
    sp.add_argument("--no-preserve-mtime", action="store_true",
                    help="let tag writes update each file's modified time "
                         "(by default the original timestamps are restored)")
    sp.add_argument("--overwrite-fields", metavar="LIST",
                    help="overwrite only these fields even without --force, e.g. "
                         "--overwrite-fields title,comment,album  (see README for names)")
    sp.add_argument("--chapter-titles", action="store_true",
                    help="set each file's title from its filename instead of the "
                         "book title (off by default: it makes files disagree)")
    sp.add_argument("--manual", action="store_true",
                    help="prompt for every book regardless of match score "
                         "(implies --ask-asin)")
    sp.add_argument("--replace-cover", action="store_true")
    sp.add_argument("--keep-cover", action="store_true")
    sp.add_argument("--remove-cover", action="store_true")
    sp.add_argument("--write-cover-file", action="store_true", help="also save cover.jpg in the folder")
    sp.add_argument("--no-backup", action="store_true")
    sp.add_argument("--report", default="html,csv,json", help="report formats, or 'none'")

    common(sub.add_parser("verify", help="check the library, change nothing")) \
        .add_argument("--report", default="html,csv", help="report formats, or 'none'")

    common(sub.add_parser("report", help="inventory report without lookups")) \
        .add_argument("--report", default="html,csv,json")

    sp = common(sub.add_parser("cover", help="fetch and embed covers only"))
    sp.add_argument("--replace-cover", action="store_true")
    sp.add_argument("--write-cover-file", action="store_true")
    sp.add_argument("--no-backup", action="store_true")

    sp = common(sub.add_parser("match", help="show what would be matched, no writes"))
    sp.add_argument("--report", default="html,csv")

    sp = common(sub.add_parser("normalize", help="rewrite existing tags consistently, no lookups"))
    sp.add_argument("--force", action="store_true")
    sp.add_argument("--no-backup", action="store_true")

    sub.add_parser("menu", help="interactive menu (also the default when run "
                                "with no arguments)")

    sub.add_parser("fields", help="list field names and the tags they write")

    sp = sub.add_parser("search", help="query Audible directly and show what each "
                                       "search strategy returns; writes nothing")
    sp.add_argument("title", help="title or phrase to search for")
    sp.add_argument("--author", help="optional author to narrow the search")
    sp.add_argument("--raw", action="store_true", help="dump the first raw result")

    sp = sub.add_parser("inspect", help="dump every raw tag frame in a file or "
                                        "folder; writes nothing")
    sp.add_argument("target", help="file or folder to dump")
    sp.add_argument("--limit", type=int, default=0, help="stop after N files")
    sp.add_argument("--parsed-only", action="store_true",
                    help="show only how the tool interprets the tags")

    sp = sub.add_parser("doctor",
                        help="diagnose config, providers and matching; writes nothing")
    sp.add_argument("library", nargs="?", help="library root (or set in config)")
    sp.add_argument("--limit", type=int, default=10, help="how many books to sample")
    sp.add_argument("--scan", nargs="*", metavar="PATH",
                    help="extra directories to search with --find-json")
    sp.add_argument("--find-json", action="store_true",
                    help="search the disk for OpenAudible library JSON files and "
                         "report which fields each one actually contains")

    common(sub.add_parser("organize", help="move folders into Author/Series/Book layout"))
    common(sub.add_parser("rename", help="rename track files consistently"))

    sp = sub.add_parser("rollback", help="restore tags from a backup snapshot")
    sp.add_argument("snapshot", nargs="?",
                    help="snapshot directory, name, or file (default: most recent)")
    sp.add_argument("-l", "--list", action="store_true",
                    help="list available snapshots and exit")
    sp.add_argument("-n", "--dry-run", action="store_true")
    return p


# ==========================================================================
# interactive menu
# ==========================================================================

MENU: Dict[str, Any] = {
    "library": "",
    "config": None,
    # tag behaviour
    "plex": True, "force": False, "renumber": False, "only_missing": False,
    "overwrite_fields": "",
    "write_cover_file": False, "no_backup": False, "cover_mode": "auto",
    # matching and prompting
    "ask_asin": True, "manual": False, "yes": False,
    "ask_below": 100, "match_threshold": 82, "title_only_threshold": 90,
    # providers
    "providers": ["audible", "openaudible", "existing", "folder"],
    # network and output
    "no_network": False, "debug_data": False, "workers": 0,
    "verbose": False, "quiet": False, "audible_region": "us",
    "genre": "Audiobook",
    "comment_source": "summary",   # summary | series | both | none
    "series_frames": "both",       # txxx | movement | both
    "strip_series_from_title": True,
    "preserve_mtime": True,        # keep each file's original timestamps
    "organize_template": "{author}/{series}/Book {index2} - {title}",
    "organize_template_no_series": "{author}/{title}",
    "rename_template": "{track2} - {title}",
    # TITLE tag for multi-file books; Plex shows it as the chapter name.
    # Empty = every file carries the book title. e.g. "Chapter {track}"
    "chapter_title_template": "",
    # Visible ALBUM tag. Default is the book title alone, with the series kept
    # in the sort tag. Use "{series} {index2} - {title}" to show it instead.
    "album_template": "{title}", "cover_size": 1000, "audible_genre": False,
    "report": "html,csv,json",
    # session
    "dry_run_done": set(),
}

ALL_PROVIDERS = ["audible", "openaudible", "existing", "openlibrary",
                 "google", "musicbrainz", "folder"]
COVER_MODES = ["auto", "replace", "keep", "remove"]
REPORT_FORMATS = ["html", "csv", "json"]


def _ask(prompt: str, default: str = "") -> str:
    try:
        return input(prompt).strip() or default
    except (EOFError, KeyboardInterrupt):
        return ""


def _ask_choice(prompt: str) -> Optional[str]:
    """Menu prompt. Returns None only on EOF/Ctrl-C - a bare Enter returns ''
    so it can redraw the menu instead of exiting."""
    try:
        return input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        return None


def _onoff(value: bool) -> str:
    return "ON " if value else "off"


def _toggle(key: str) -> None:
    MENU[key] = not MENU[key]
    MENU["dirty"] = True


def _global_args() -> List[str]:
    """Everything that goes before the subcommand."""
    out: List[str] = []
    if MENU["config"]:
        out += ["-c", str(MENU["config"])]
    if MENU["providers"]:
        out += ["-p", ",".join(MENU["providers"])]
    if MENU["workers"]:
        out += ["-j", str(MENU["workers"])]
    if MENU["verbose"]:
        out.append("-v")
    if MENU["quiet"]:
        out.append("-q")
    if MENU["yes"]:
        out.append("-y")
    if MENU["no_network"]:
        out.append("--no-network")
    if MENU["debug_data"]:
        out.append("--debug-data")
    for key in ("ask_below", "match_threshold", "title_only_threshold",
                "audible_region", "genre", "cover_size", "comment_source",
                "series_frames"):
        out += ["-o", f"{key}={MENU[key]}"]
    if MENU["chapter_title_template"]:
        out += ["-o", f"chapter_title_template={MENU['chapter_title_template']}"]
    if MENU["album_template"] and MENU["album_template"] != "{title}":
        out += ["-o", f"album_template={MENU['album_template']}"]
    out += ["-o", f"audible_genre={'true' if MENU['audible_genre'] else 'false'}"]
    return out


def _tag_args(dry_run: bool = False, manual: bool = False) -> List[str]:
    out: List[str] = []
    if dry_run:
        out.append("--dry-run")
    if MENU["plex"]:
        out.append("--plex")
    if MENU["force"]:
        out.append("--force")
    if MENU["renumber"]:
        out.append("--renumber")
    if MENU["only_missing"]:
        out.append("--only-missing")
    if MENU["overwrite_fields"]:
        out += ["--overwrite-fields", MENU["overwrite_fields"]]
    if not MENU["preserve_mtime"]:
        out.append("--no-preserve-mtime")
    if MENU["write_cover_file"]:
        out.append("--write-cover-file")
    if MENU["no_backup"]:
        out.append("--no-backup")
    if MENU["cover_mode"] == "replace":
        out.append("--replace-cover")
    elif MENU["cover_mode"] == "keep":
        out.append("--keep-cover")
    elif MENU["cover_mode"] == "remove":
        out.append("--remove-cover")
    if manual:
        out.append("--manual")
    elif MENU["ask_asin"]:
        out.append("--ask-asin")
    out += ["--report", MENU["report"] or "none"]
    return out


def _state_key() -> str:
    return MENU["library"] + "|" + " ".join(_tag_args() + _global_args())


def _quote(arg: str) -> str:
    """Quote for display so the echoed line can be pasted into a shell."""
    text = str(arg)
    if not text:
        return '""'
    if re.search(r"[\s\"&()\[\]{}^=;!'+,`~|<>]", text):
        return '"' + text.replace('"', '\\"') + '"'
    return text


def _run(argv: List[str], remember_dry_run: bool = False) -> None:
    print("")
    print("  $ " + PROGRAM + " " + " ".join(_quote(a) for a in argv))
    print("")
    try:
        main(argv)
    except SystemExit as exc:
        if exc.code:
            print(f"  (exited: {exc.code})")
    except Exception as exc:  # noqa: BLE001
        print(f"  ERROR: {exc}")
    if remember_dry_run:
        MENU["dry_run_done"].add(_state_key())
    _ask("\n  Press Enter to return to the menu. ")


# -------------------------------------------------------------------- menus

def menu_tag_options() -> None:
    while True:
        print("")
        print("  TAG OPTIONS")
        print(f"   1. [{_onoff(MENU['plex'])}] Plex field mapping (--plex)")
        print(f"   2. [{_onoff(MENU['force'])}] Overwrite populated tags (--force)")
        print(f"   3. [{_onoff(MENU['renumber'])}] Rewrite track numbers 1..N (--renumber)")
        print(f"   4. [{_onoff(MENU['only_missing'])}] Skip fully tagged books (--only-missing)")
        print(f"   5. [{_onoff(MENU['write_cover_file'])}] Also save cover.jpg in each folder")
        print(f"   6. [{_onoff(MENU['no_backup'])}] Disable rollback snapshots (--no-backup)")
        print(f"   7. cover art mode: {MENU['cover_mode']}  (auto/replace/keep/remove)")
        print(f"   8. genre written: {MENU['genre']}")
        print(f"   9. cover size: {MENU['cover_size']} px")
        print(f"  10. [{_onoff(MENU['audible_genre'])}] Use Audible's genre instead of the flat one")
        print(f"  11. overwrite only these fields: {MENU['overwrite_fields'] or '(none)'}")
        print(f"  12. comment contains: {MENU['comment_source']}"
              "  (summary/series/both/none)")
        print(f"  13. [{_onoff(MENU['preserve_mtime'])}] Keep original file dates")
        print(f"  14. series written to: {MENU['series_frames']}"
              "  (movement/txxx/both)")
        print(f"  15. chapter title (multi-file books): "
              f"{MENU['chapter_title_template'] or '(book title on every file)'}")
        print(f"  16. album tag: {MENU['album_template']}"
              "   (sort tag always carries the series)")
        print("   0. Back")
        choice = _ask_choice("  > ")
        if choice is None or choice in ("0", ""):
            return
        if choice == "1":
            _toggle("plex")
        elif choice == "2":
            _toggle("force")
        elif choice == "3":
            _toggle("renumber")
        elif choice == "4":
            _toggle("only_missing")
        elif choice == "5":
            _toggle("write_cover_file")
        elif choice == "6":
            _toggle("no_backup")
        elif choice == "7":
            i = COVER_MODES.index(MENU["cover_mode"])
            MENU["cover_mode"] = COVER_MODES[(i + 1) % len(COVER_MODES)]
        elif choice == "8":
            MENU["genre"] = _ask("  Genre: ", MENU["genre"])
        elif choice == "9":
            val = _ask("  Cover size in px: ", str(MENU["cover_size"]))
            if val.isdigit():
                MENU["cover_size"] = int(val)
        elif choice == "10":
            _toggle("audible_genre")
        elif choice == "11":
            print("  Field names (see the 'fields' command for the full mapping):")
            print(f"    {', '.join(FIELDS)}")
            print("  Note: 'author' = Artist, 'albumartist' = Album Artist - separate tags.")
            raw = _ask("  Comma separated (blank for none): ", "").strip()
            fields = [x.strip() for x in raw.split(",") if x.strip()]
            unknown = [f for f in fields if f not in FIELDS]
            if unknown:
                print(f"  Not field names, ignored: {', '.join(unknown)}")
            MENU["overwrite_fields"] = ",".join(f for f in fields if f in FIELDS)
            if MENU["overwrite_fields"] and MENU["force"]:
                print("  NOTE: --force is ON, which overwrites everything and makes")
                print("        this list irrelevant. Turn it off with option 2.")
            MENU["dirty"] = True
        elif choice == "12":
            val = _ask("  summary / series / both / none: ", MENU["comment_source"])
            if val in ("summary", "series", "both", "none"):
                MENU["comment_source"] = val
                MENU["dirty"] = True
        elif choice == "13":
            _toggle("preserve_mtime")
        elif choice == "15":
            term = _ask("  Title or phrase: ").strip('"')
            if term:
                who = _ask("  Author (Enter to skip): ").strip('"')
                args = g + ["search", term] + (["--author", who] if who else [])
                _run(args)
        elif choice == "14":
            val = _ask("  movement / txxx / both: ", MENU["series_frames"])
            if val in ("movement", "txxx", "both"):
                MENU["series_frames"] = val
                MENU["dirty"] = True
        elif choice == "15":
            print("  Plex shows the TITLE tag as the chapter name.")
            print("  Fields: {track} {track2} {total} {title} {series} {index} {author}")
            print('  Examples: "Chapter {track}"   "{title} - Part {track2}"'
                  '   "{title} ({track}/{total})"')
            print("  Blank means every file carries the book title.")
            MENU["chapter_title_template"] = _ask("  Template: ", "").strip()
            MENU["dirty"] = True
        elif choice == "16":
            print("  Fields: {title} {series} {index} {index2} {author} {year}")
            print('  "{title}" keeps series grouping in the sort tag (recommended)')
            print('  "{series} {index2} - {title}" shows it in the album itself')
            MENU["album_template"] = _ask("  Template: ", MENU["album_template"]).strip() \
                or "{title}"
            MENU["dirty"] = True


def menu_matching() -> None:
    while True:
        print("")
        print("  MATCHING AND PROMPTS")
        print(f"   1. [{_onoff(MENU['ask_asin'])}] Prompt for an ASIN below the threshold (--ask-asin)")
        print(f"   2. [{_onoff(MENU['manual'])}] Prompt on EVERY book (--manual)")
        print(f"   3. [{_onoff(MENU['yes'])}] Never prompt (-y, for scheduled runs)")
        print(f"   4. ask_below            : {MENU['ask_below']}  (prompt under this score)")
        print(f"   5. match_threshold      : {MENU['match_threshold']}  (minimum to accept a match)")
        print(f"   6. title_only_threshold : {MENU['title_only_threshold']}  (stricter, title-only matches)")
        print("   0. Back")
        choice = _ask_choice("  > ")
        if choice is None or choice in ("0", ""):
            return
        if choice == "1":
            _toggle("ask_asin")
        elif choice == "2":
            _toggle("manual")
        elif choice == "3":
            _toggle("yes")
        elif choice in ("4", "5", "6"):
            key = {"4": "ask_below", "5": "match_threshold",
                   "6": "title_only_threshold"}[choice]
            val = _ask(f"  {key} (0-100): ", str(MENU[key]))
            try:
                MENU[key] = max(0, min(100, int(float(val))))
            except ValueError:
                print("  Not a number.")


def menu_providers() -> None:
    while True:
        print("")
        print("  PROVIDERS  (order is precedence: first to supply a field wins)")
        for i, name in enumerate(MENU["providers"], start=1):
            print(f"   {i}. {name}")
        unused = [x for x in ALL_PROVIDERS if x not in MENU["providers"]]
        if unused:
            print(f"      not in use: {', '.join(unused)}")
        print("")
        print("   a NAME   add a provider        r NAME   remove one")
        print("   u N      move entry N up       d N      move entry N down")
        print("   p        presets               0        Back")
        raw = _ask_choice("  > ")
        if raw is None or raw in ("0", ""):
            return
        parts = raw.split()
        verb = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""
        if verb == "a" and arg in ALL_PROVIDERS and arg not in MENU["providers"]:
            MENU["providers"].append(arg)
        elif verb == "r" and arg in MENU["providers"]:
            MENU["providers"].remove(arg)
        elif verb in ("u", "d") and arg.isdigit():
            i = int(arg) - 1
            j = i - 1 if verb == "u" else i + 1
            if 0 <= i < len(MENU["providers"]) and 0 <= j < len(MENU["providers"]):
                MENU["providers"][i], MENU["providers"][j] = (
                    MENU["providers"][j], MENU["providers"][i])
        elif verb == "p":
            print("   1. Audible only          [audible, existing, folder]")
            print("   2. Audible + OpenAudible [audible, openaudible, existing, folder]")
            print("   3. Offline only          [openaudible, existing, folder]")
            print("   4. Everything            all providers")
            pick = _ask("  > ")
            presets = {
                "1": ["audible", "existing", "folder"],
                "2": ["audible", "openaudible", "existing", "folder"],
                "3": ["openaudible", "existing", "folder"],
                "4": list(ALL_PROVIDERS),
            }
            if pick in presets:
                MENU["providers"] = presets[pick]
        else:
            print("  Unrecognised.")


def menu_output() -> None:
    while True:
        active = MENU["report"].split(",") if MENU["report"] != "none" else []
        print("")
        print("  NETWORK AND OUTPUT")
        print(f"   1. [{_onoff(not MENU['no_network'])}] Network lookups enabled")
        print(f"   2. [{_onoff(MENU['debug_data'])}] Debug: log and dump every provider response")
        print(f"   3. [{_onoff(MENU['verbose'])}] Verbose console output (-v)")
        print(f"   4. [{_onoff(MENU['quiet'])}] Quiet console output (-q)")
        print(f"   5. workers            : {MENU['workers'] or 'auto'}")
        print(f"   6. Audible region     : {MENU['audible_region']}")
        print(f"   7. report formats     : {MENU['report']}")
        for i, fmt in enumerate(REPORT_FORMATS, start=8):
            print(f"   {i}. [{_onoff(fmt in active)}] {fmt} report")
        print("   0. Back")
        choice = _ask_choice("  > ")
        if choice is None or choice in ("0", ""):
            return
        if choice == "1":
            _toggle("no_network")
        elif choice == "2":
            _toggle("debug_data")
        elif choice == "3":
            _toggle("verbose")
        elif choice == "4":
            _toggle("quiet")
        elif choice == "5":
            val = _ask("  Workers (0 = auto): ", str(MENU["workers"]))
            if val.isdigit():
                MENU["workers"] = int(val)
        elif choice == "6":
            val = _ask(f"  Region {sorted(AUDIBLE_DOMAINS)}: ", MENU["audible_region"])
            if val in AUDIBLE_DOMAINS:
                MENU["audible_region"] = val
            else:
                print("  Unknown region.")
        elif choice == "7":
            MENU["report"] = _ask("  Formats (comma separated, or none): ", MENU["report"])
        elif choice in ("8", "9", "10"):
            fmt = REPORT_FORMATS[int(choice) - 8]
            active = [f for f in active if f in REPORT_FORMATS]
            if fmt in active:
                active.remove(fmt)
            else:
                active.append(fmt)
            MENU["report"] = ",".join(f for f in REPORT_FORMATS if f in active) or "none"


def menu_config() -> None:
    while True:
        print("")
        print("  CONFIG")
        print(f"   loaded from : {CONFIG_SOURCE}")
        print(f"   override    : {MENU['config'] or '(none)'}")
        print(f"   default path: {default_config_path()}")
        print("")
        print("   1. Save current settings to the config file")
        print("   2. Use a specific config file")
        print("   3. Clear the override (use auto-discovery)")
        print("   4. Write a fresh default config file")
        print("   5. Show current settings")
        print("   0. Back")
        choice = _ask_choice("  > ")
        if choice is None or choice in ("0", ""):
            return
        if choice == "1":
            _save_menu(explicit=True)
        elif choice == "2":
            entered = _ask("  Path to config: ").strip('"')
            if entered and Path(entered).is_file():
                MENU["config"] = entered
                _load_menu_defaults(load_config(entered))
            elif entered:
                print("  Not found.")
        elif choice == "3":
            MENU["config"] = None
        elif choice == "4":
            path = default_config_path()
            if path.exists():
                if _ask(f"  {path} exists. Overwrite? (y/N) ").lower() != "y":
                    continue
                path.unlink()
            created = write_default_config(MENU["library"])
            print(f"  Wrote {created}" if created else "  Could not write config.")
        elif choice == "5":
            print("")
            print(f"  library: \"{MENU['library']}\"")
            print(f"  provider_order: [{', '.join(MENU['providers'])}]")
            for key in ("genre", "cover_size", "audible_region", "audible_genre",
                        "ask_below", "match_threshold", "title_only_threshold"):
                print(f"  {key}: {MENU[key]}")
            print(f"  network: {not MENU['no_network']}")
            print(f"  debug_data: {MENU['debug_data']}")
            _ask("\n  Press Enter. ")


def _menu_to_config() -> Dict[str, Any]:
    """Everything the menu manages, as config keys."""
    cfg = dict(DEFAULT_CONFIG)
    if MENU["config"] and Path(str(MENU["config"])).is_file():
        cfg.update(load_config(str(MENU["config"])))
    elif CONFIG_SOURCE and not CONFIG_SOURCE.startswith("built-in"):
        cfg.update(load_config(CONFIG_SOURCE))
    cfg.update({
        "library": MENU["library"],
        "provider_order": list(MENU["providers"]),
        "plex": MENU["plex"],
        "overwrite": MENU["force"],
        "renumber": MENU["renumber"],
        "only_missing": MENU["only_missing"],
        "write_cover_file": MENU["write_cover_file"],
        "no_backup": MENU["no_backup"],
        "ask_asin": MENU["ask_asin"],
        "manual": MENU["manual"],
        "cover_mode": MENU["cover_mode"],
        "overwrite_fields": MENU["overwrite_fields"],
        "report_formats": MENU["report"],
        "genre": MENU["genre"],
        "comment_source": MENU["comment_source"],
        "series_frames": MENU["series_frames"],
        "chapter_title_template": MENU["chapter_title_template"],
        "album_template": MENU["album_template"],
        "preserve_mtime": MENU["preserve_mtime"],
        "cover_size": MENU["cover_size"],
        "audible_genre": MENU["audible_genre"],
        "audible_region": MENU["audible_region"],
        "ask_below": MENU["ask_below"],
        "match_threshold": MENU["match_threshold"],
        "title_only_threshold": MENU["title_only_threshold"],
        "network": not MENU["no_network"],
        "debug_data": MENU["debug_data"],
    })
    if MENU["workers"]:
        cfg["workers"] = MENU["workers"]
    return cfg


def _save_menu(explicit: bool = False) -> None:
    target = Path(str(MENU["config"])) if MENU["config"] else None
    if target is None and not CONFIG_SOURCE.startswith("built-in"):
        target = Path(CONFIG_SOURCE)
    saved = save_config(_menu_to_config(), target)
    if saved:
        MENU["dirty"] = False
        print(f"  Settings saved to {saved}")
    elif explicit:
        print("  Could not save.")


def _load_menu_defaults(cfg: Dict[str, Any]) -> None:
    MENU["library"] = str(cfg.get("library") or MENU["library"])
    if cfg.get("provider_order"):
        MENU["providers"] = list(cfg["provider_order"])
    for key in ("ask_below", "match_threshold", "title_only_threshold",
                "audible_region", "genre", "cover_size", "audible_genre",
                "debug_data"):
        if key in cfg:
            MENU[key] = cfg[key]
    MENU["no_network"] = not cfg.get("network", True)
    MENU["force"] = bool(cfg.get("overwrite", False))
    for key, cfg_key in (("plex", "plex"), ("renumber", "renumber"),
                         ("only_missing", "only_missing"),
                         ("write_cover_file", "write_cover_file"),
                         ("no_backup", "no_backup"), ("ask_asin", "ask_asin"),
                         ("manual", "manual"), ("cover_mode", "cover_mode"),
                         ("overwrite_fields", "overwrite_fields"),
                         ("comment_source", "comment_source"),
                         ("preserve_mtime", "preserve_mtime"),
                         ("series_frames", "series_frames"),
                         ("chapter_title_template", "chapter_title_template"),
                         ("album_template", "album_template")):
        if cfg_key in cfg:
            MENU[key] = cfg[cfg_key]
    if cfg.get("report_formats"):
        MENU["report"] = cfg["report_formats"]
    if cfg.get("workers"):
        MENU["workers"] = int(cfg["workers"])
    MENU["dirty"] = False


def run_menu() -> int:
    _load_menu_defaults(load_config(None))

    while True:
        lib = MENU["library"]
        ready = bool(lib)
        dry_done = _state_key() in MENU["dry_run_done"]
        print("")
        print("=" * 74)
        print(f"  {PROGRAM} {__version__}")
        print("=" * 74)
        print(f"  library   : {lib or '(not set - press L)'}")
        print(f"  providers : {', '.join(MENU['providers'])}")
        print(f"  tag flags : {' '.join(_tag_args()) or '(none)'}")
        print(f"  dry run   : {'done for these settings' if dry_done else 'NOT yet run'}")
        print(f"  settings  : {'UNSAVED changes' if MENU['dirty'] else 'saved'}"
              f"  ({MENU['config'] or CONFIG_SOURCE})")
        print("")
        print("  ACTIONS")
        print("   1. Doctor        - config, providers, TLS, per-book matching (no writes)")
        print("   2. Tag DRY RUN   - show exactly what would change")
        print("   3. Tag WRITE     - apply tags")
        print("   4. Tag MANUAL    - prompt on every book, then write")
        print("   5. Verify        - report gaps in current tags")
        print("   6. Report        - inventory, no lookups")
        print("   7. Match         - show matches only, never writes")
        print("   8. Cover         - fetch and embed covers only")
        print("   9. Normalize     - rewrite existing tags consistently, no lookups")
        print("  10. Organize      - move folders into Author/Series/Book NN - Title")
        print("  11. Rename        - rename track files consistently")
        print("  12. Rollback      - restore tags from a snapshot")
        print("  13. Find library JSON files on disk")
        print("  14. Inspect  - dump raw tag frames for a file or folder")
        print("  15. Search   - query Audible directly and see what comes back")
        print("")
        print("  SETTINGS")
        print("   L. Library path        T. Tag options        M. Matching and prompts")
        print("   P. Providers           N. Network and output C. Config file")
        print("   Q. Quit")
        print("")
        raw = _ask_choice("  > ")
        if raw is None:                      # EOF or Ctrl-C
            return 0
        choice = raw.lower()
        if choice == "":                     # bare Enter: just redraw
            continue
        if choice in ("q", "quit", "exit"):
            if MENU["dirty"]:
                if _ask("  Save settings to the config file? (Y/n) ", "y").lower() != "n":
                    _save_menu()
            return 0
        if choice == "l":
            entered = _ask("  Library path: ").strip().strip('"')
            if entered:
                candidate = Path(entered).expanduser()
                if candidate.is_dir():
                    MENU["library"] = str(candidate)
                    MENU["dirty"] = True
                else:
                    print(f"  Not a usable folder: {candidate}")
                    for note in diagnose_path(candidate):
                        print(f"    {note}")
                    if _ask("  Use it anyway? (y/N) ", "n").lower() == "y":
                        MENU["library"] = entered
                        MENU["dirty"] = True
            continue
        if choice == "t":
            menu_tag_options(); continue
        if choice == "m":
            menu_matching(); continue
        if choice == "p":
            menu_providers(); continue
        if choice == "n":
            menu_output(); continue
        if choice == "c":
            menu_config(); continue

        if choice in ("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11") and not ready:
            print("  Set a library path first (L).")
            continue

        g = _global_args()
        if choice == "1":
            _run(g + ["doctor", lib])
        elif choice == "2":
            _run(g + ["tag", lib] + _tag_args(dry_run=True), remember_dry_run=True)
        elif choice == "3":
            if not dry_done:
                print("")
                print("  No dry run has been done with these exact settings.")
                print("  Run option 2 first, or type WRITE to proceed anyway.")
                if _ask("  > ") != "WRITE":
                    continue
            _run(g + ["tag", lib] + _tag_args())
        elif choice == "4":
            _run(g + ["tag", lib] + _tag_args(manual=True))
        elif choice == "5":
            _run(g + ["verify", lib, "--report", MENU["report"] or "none"])
        elif choice == "6":
            _run(g + ["report", lib, "--report", MENU["report"] or "none"])
        elif choice == "7":
            _run(g + ["match", lib, "--report", MENU["report"] or "none"])
        elif choice == "8":
            cover = ["--replace-cover"] if MENU["cover_mode"] == "replace" else []
            if MENU["write_cover_file"]:
                cover.append("--write-cover-file")
            if MENU["no_backup"]:
                cover.append("--no-backup")
            _run(g + ["cover", lib] + cover)
        elif choice == "9":
            norm = ["--force"] if MENU["force"] else []
            if MENU["no_backup"]:
                norm.append("--no-backup")
            _run(g + ["normalize", lib] + norm)
        elif choice == "10":
            preview = _ask("  Dry run first? (Y/n) ", "y").lower() != "n"
            _run(g + ["organize", lib] + (["--dry-run"] if preview else []))
        elif choice == "11":
            preview = _ask("  Dry run first? (Y/n) ", "y").lower() != "n"
            _run(g + ["rename", lib] + (["--dry-run"] if preview else []))
        elif choice == "12":
            snap = _ask("  Snapshot path (Enter for the most recent): ").strip('"')
            preview = _ask("  Preview only? (y/N) ", "n").lower() == "y"
            args = g + ["rollback"] + ([snap] if snap else []) + (["-n"] if preview else [])
            _run(args)
        elif choice == "15":
            term = _ask("  Title or phrase: ").strip('"')
            if term:
                who = _ask("  Author (Enter to skip): ").strip('"')
                args = g + ["search", term] + (["--author", who] if who else [])
                _run(args)
        elif choice == "14":
            target = _ask("  File or folder (Enter for the library): ").strip('"') or lib
            if target:
                lim = _ask("  Limit to how many files? (Enter for all): ")
                args = g + ["inspect", target]
                if lim.isdigit():
                    args += ["--limit", lim]
                _run(args)
        elif choice == "13":
            extra = _ask("  Extra paths to search (comma separated, Enter to skip): ")
            args = g + ["doctor", "--find-json"]
            if lib:
                args.append(lib)
            if extra:
                args += ["--scan"] + [x.strip() for x in extra.split(",") if x.strip()]
            _run(args)
        else:
            print("  Unrecognised choice.")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    cfg = load_config(args.config)
    if args.workers:
        cfg["workers"] = max(1, args.workers)
    if args.no_network:
        cfg["network"] = False
    apply_overrides(cfg, getattr(args, "option", None))
    if getattr(args, "debug_data", False):
        cfg["debug_data"] = True
        args.verbose = True
    if getattr(args, "providers", None):
        cfg["provider_order"] = [x.strip() for x in args.providers.split(",") if x.strip()]
    _SERIES_STYLE[0] = str(cfg.get("series_frames") or "both")
    setup_logging(cfg, args.verbose, args.quiet)

    if not args.config and CONFIG_SOURCE.startswith("built-in"):
        lib = getattr(args, "library", None) or cfg["library"] or ""
        created = write_default_config(lib)
        if created:
            log.warning("No config file found - wrote defaults to %s", created)
            log.warning("Edit that file (especially 'library') and it will be picked "
                        "up automatically on the next run.")
    log.debug("config: %s", {k: v for k, v in cfg.items() if k != "google_api_key"})
    if not HAVE_RAPIDFUZZ:
        log.debug("rapidfuzz not installed - using difflib for matching")

    if args.command == "menu":
        return run_menu()

    if args.command == "fields":
        return do_fields()

    if args.command == "search":
        return do_search(cfg, args.title, args.author, args.raw)

    if args.command == "inspect":
        return do_inspect(Path(args.target).expanduser(), args.limit,
                          raw=not args.parsed_only)

    if args.command == "rollback":
        if args.list:
            return list_snapshots(cfg)
        failed = do_rollback(cfg, args.snapshot, args.dry_run)
        return 1 if failed else 0

    if args.command == "doctor" and args.find_json:
        lib = args.library or cfg["library"]
        return do_find_json(cfg, Path(lib).expanduser() if lib else None,
                            getattr(args, "scan", None))

    root = resolve_library(args, cfg)
    books = scan_library(root, cfg)
    if not books:
        log.warning("no audio files found under %s", root)
        return 0

    if args.command == "doctor":
        return do_doctor(root, cfg, books, args.limit)

    cover_mode = cover_mode_from_args(args)
    if cover_mode == "auto" and cfg.get("cover_mode") in COVER_MODES:
        cover_mode = str(cfg["cover_mode"])
    fields_raw = getattr(args, "overwrite_fields", None) or cfg.get("overwrite_fields") or ""
    opts = Options(
        dry_run=getattr(args, "dry_run", False),
        force=getattr(args, "force", False) or bool(cfg["overwrite"]),
        plex=getattr(args, "plex", False) or bool(cfg["plex"]),
        cover_mode=cover_mode,
        no_backup=getattr(args, "no_backup", False) or bool(cfg["no_backup"]),
        write_cover_file=(getattr(args, "write_cover_file", False)
                          or bool(cfg["write_cover_file"])),
        only_missing=getattr(args, "only_missing", False) or bool(cfg["only_missing"]),
        renumber=getattr(args, "renumber", False) or bool(cfg["renumber"]),
        ask_asin=(getattr(args, "ask_asin", False) or getattr(args, "manual", False)
                  or bool(cfg["ask_asin"]) or bool(cfg["manual"])),
        manual=getattr(args, "manual", False) or bool(cfg["manual"]),
        chapter_titles=(getattr(args, "chapter_titles", False)
                        or bool(cfg["chapter_titles"])),
        force_fields=tuple(x.strip() for x in str(fields_raw).split(",") if x.strip()),
        preserve_mtime=(bool(cfg["preserve_mtime"])
                        and not getattr(args, "no_preserve_mtime", False)),
        non_interactive=getattr(args, "yes", False),
        ask_below=float(cfg["ask_below"]),
    )
    if opts.ask_asin and opts.non_interactive:
        log.info("--yes overrides --ask-asin/--manual: no prompts will be shown")
    if opts.ask_asin and not opts.non_interactive and cfg["workers"] != 1:
        log.info("--ask-asin: running single-threaded so prompts stay readable")
        cfg["workers"] = 1
    if opts.force_fields and "author" in opts.force_fields \
            and "albumartist" not in opts.force_fields:
        log.warning("--overwrite-fields lists 'author' (Artist / TPE1) but not "
                    "'albumartist' (Album Artist / TPE2) - the Album Artist tag "
                    "will keep its current value. Add albumartist to replace it.")
    if opts.force_fields and "title" in opts.force_fields \
            and "album" not in opts.force_fields:
        log.debug("'title' and 'album' write the same tag; listing either is enough")

    if opts.force and opts.force_fields:
        log.warning("--force overwrites EVERY field, so --overwrite-fields "
                    "(%s) has no effect. Drop --force / 'overwrite: false' "
                    "to limit writes to just those fields.",
                    ", ".join(opts.force_fields))

    template = str(cfg.get("chapter_title_template") or "")
    if template and not re.search(r"\{track2?\}", template):
        log.warning("chapter_title_template %r has no {track} or {track2}, so every "
                    "file in a book would get the same title", template)

    order = cfg["provider_order"]
    if "existing" not in order:
        log.warning("provider_order has no 'existing': tags already in your files "
                    "are ignored, so anything the other providers do not supply "
                    "stays empty and is left unchanged on disk")
    if "folder" not in order:
        log.warning("provider_order has no 'folder': books that match no provider "
                    "cannot fall back to the directory layout")

    providers = build_providers(cfg)
    backup = Backup(cfg, enabled=not opts.no_backup and not opts.dry_run)
    started = time.monotonic()

    if args.command in ("tag", "cover", "normalize", "match"):
        if args.command == "cover":
            opts.cover_mode = "replace" if getattr(args, "replace_cover", False) else "auto"
        if args.command == "normalize":
            cfg = dict(cfg, provider_order=["existing", "folder"])
            providers = {}
        if args.command == "match":
            opts.dry_run = True
        try:
            books = run_parallel(books, lambda b: tag_book(b, cfg, providers, opts, backup),
                                 cfg["workers"])
        except Interrupted as stop:
            snap = backup.flush()
            done = len(stop.done)
            log.warning("INTERRUPTED after %d book(s) - stopping cleanly", done)
            print("")
            print(f"  Interrupted after {done} book(s).")
            if snap:
                print(f"  Every change made so far is recorded in {snap.parent}")
                print(f"  Undo them with:  {PROGRAM} rollback {snap.parent.name}")
            elif opts.dry_run:
                print("  Dry run - nothing was written.")
            elif opts.no_backup:
                print("  No backup was taken (--no-backup), so there is nothing to undo.")
            return 130
        backup.flush()
    elif args.command == "verify":
        def _verify(b: Book) -> Book:
            b.existing = read_book_tags(b)
            b.final = b.existing
            b.issues = verify_book(b)
            b.status = "ok" if not b.issues else "unknown"
            return b
        books = run_parallel(books, _verify, cfg["workers"])
    elif args.command == "report":
        def _inventory(b: Book) -> Book:
            b.existing = read_book_tags(b)
            b.final = b.existing
            b.status = "ok"
            return b
        books = run_parallel(books, _inventory, cfg["workers"])
    elif args.command == "organize":
        def _prep(b: Book) -> Book:
            b.existing = read_book_tags(b)
            b.final = resolve_metadata(b, cfg, providers, opts)
            return b
        books = run_parallel(books, _prep, cfg["workers"])
        moved = do_organize(books, root, cfg, opts.dry_run)
        log.info("organize: %d folder(s) %s", moved, "planned" if opts.dry_run else "moved")
        return 0
    elif args.command == "rename":
        def _prep2(b: Book) -> Book:
            b.existing = read_book_tags(b)
            b.final = resolve_metadata(b, cfg, providers, opts)
            return b
        books = run_parallel(books, _prep2, cfg["workers"])
        renamed = do_rename(books, cfg, opts.dry_run)
        log.info("rename: %d file(s) %s", renamed, "planned" if opts.dry_run else "renamed")
        return 0

    if args.command in ("tag", "verify", "match"):
        for b in books:
            if not b.issues:
                b.issues = verify_book(b)

    dupes = find_duplicates(books)
    summary = build_summary(books, dupes)
    fmts = getattr(args, "report", "none")
    if fmts and fmts.lower() != "none":
        write_reports(books, dupes, cfg, [f.strip() for f in fmts.split(",") if f.strip()])

    elapsed = time.monotonic() - started
    print(f"\n{PROGRAM} {__version__} - {args.command}"
          f"{' (dry run)' if opts.dry_run else ''}")
    for k in ("books_processed", "books_updated", "books_ok", "books_skipped",
              "books_unknown", "books_failed", "books_with_issues",
              "books_with_notes", "books_below_100_match", "duplicate_groups"):
        print(f"  {k.replace('_', ' '):<20} {summary[k]}")
    print(f"  {'elapsed':<20} {elapsed:.1f}s")
    return 1 if summary["books_failed"] else 0


if __name__ == "__main__":
    try:
        if len(sys.argv) == 1:          # launched with no arguments -> menu
            sys.exit(run_menu())
        sys.exit(main())
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted\n")
        sys.exit(130)
    except Interrupted:
        sys.stderr.write("\ninterrupted\n")
        sys.exit(130)
