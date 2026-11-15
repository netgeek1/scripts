# Changelog

All notable changes, newest first. Two components are versioned separately:

- **installer**: `SCRIPT_VERSION` in `git-history-scrubber-installer.sh`
- **app**: `__version__` in `app/scrub.py`, which is also the image tag

Versions follow `MAJOR.MINOR.PATCH`.

## installer v1.0.0 / app v1.0.0 — 2026-11-15 — first release

### Installer 1.0.0
- Self-contained, menu-driven installer on the standard pattern (docker-base-install.sh / switch-dashboard /
  gmail-filter-editor). The app source is embedded as a checksummed payload, and `--build-standalone`
  regenerates it.
- Preflight checks (Ubuntu/Debian, amd64/arm64, bash 4.4+); installs missing prerequisites and Docker CE.
- `gitscrub` service account (nologin, not in the docker group). Each step runs as a one-shot hardened
  `docker run --rm`: read-only root, all capabilities dropped, `no-new-privileges`, memory limit.
- GitHub fine-grained token kept in an encrypted vault (`systemd-creds`/TPM or OpenSSL). It is passed as
  `-e GH_TOKEN` from the environment, so it never appears in argv, a URL or a log.
- Rules file in git-filter-repo `--replace-text` format, with validation and add/delete/edit from the menu. A
  read-only copy is staged for each run and deleted afterwards.
- Workflow actions: scan, rewrite, preview, push (keyword `FORCE-PUSH`), backup, restore (keyword
  `RESTORE`), clean. `--repo URL` runs once against another repository.
- Settings model with validation (`--show-config`, `--set`); `REPO_URL` must be https with no credentials.
- Dry-run, typed confirmations, run logs (20 kept), lock file.
- Self-test: 25 checks, including "the token never appears in the docker command line".

### App 1.0.0 (scrub.py)
- `scan`: every distinct file version in all branches and tags, commit messages, and author/committer
  identities. Also reports case-insensitive near misses a rule won't change. `--json` for scripting.
- `rewrite`: two fresh mirror clones, `git-filter-repo --sensitive-data-removal --replace-text` (plus
  `--replace-message` when `REWRITE_MESSAGES=yes`), then a re-scan that must find 0 matches. Writes a
  verification marker tied to the repository, the rules (SHA-256) and the original refs.
- `preview`: unified diff of the files that change at the tip of the default branch, or of every branch.
- `push`: refuses unless the rewrite is verified, the rules are unchanged and the remote refs still match
  what was rewritten. Writes a git bundle of the original first, force-pushes branches and tags only
  (`refs/pull/*` is read-only on GitHub), then checks the remote matches the rewrite.
- `restore`: force-push a bundle back and verify. `backup`: bundle on demand; keeps the newest `SCRUB_KEEP`.
- 6 end-to-end tests against a local remote: full scan → rewrite → push → restore cycle, refusal when the
  remote moved or the rules changed, URL validation, nothing-to-do.
