# git-history-scrubber

Removes text from a GitHub repository's **entire history**: a name, an email address or a leaked secret, in
every file version of every commit on every branch and tag. Optionally it also covers commit messages. It
runs [git-filter-repo](https://github.com/newren/git-filter-repo) `--sensitive-data-removal --replace-text`
in a hardened Docker container. A scan, a verification and a preview come before anything is pushed, and the
original history is always saved as a git bundle you can restore.

It's installed and managed by one self-contained, menu-driven installer (`git-history-scrubber-installer.sh`),
on the same pattern as `docker-base-install.sh`, switch-dashboard and gmail-filter-editor.

Author: netgeek1 & Claude (Anthropic)

## Why not the website

GitHub's web UI can't rewrite history: editing a file only adds a new commit, and every old version stays
reachable. A rewrite needs git-filter-repo and a force-push. This tool packages that with the safety rails.

## Install

```sh
sudo ./git-history-scrubber-installer.sh            # menu; choose 1) Full install
```

The installer:

1. Checks the OS (Ubuntu/Debian, amd64/arm64) and installs missing prerequisites.
2. Installs Docker CE if missing.
3. Creates the **`gitscrub`** system account (nologin, not in the docker group).
4. Builds the image (pinned `python:3.13-slim-bookworm` plus `git-filter-repo 2.47.0`) and runs the tool's self-test.
5. Asks for the repository, a GitHub token and your first rule.
6. Installs itself as **`/usr/local/sbin/git-history-scrubber`**.

### GitHub token

Push and restore need a **fine-grained personal access token**. Create one at github.com → Settings → Developer
settings → Fine-grained tokens. Give it *Repository access* = only the repositories you will scrub, and
*Permissions → Contents* = **Read and write**. It's stored in an encrypted vault (`systemd-creds`, TPM-bound
where available, or OpenSSL with a root-only key). Git receives it through `GIT_ASKPASS` from the environment,
so it never appears in a URL, the command line, `ps` or a log. Scanning a public repo needs no token.

## Rules

Rules live in `/etc/git-history-scrubber/replacements.txt` (0600), one per line in git-filter-repo format:

```
Old Name & Claude (Anthropic)==>netgeek1 & Claude (Anthropic)
Old Name==>netgeek1
regex:old\.name@example\.(com|net)==>netgeek1@users.noreply.github.com
some-secret-value                       # no ==> : replaced with ***REMOVED***
```

- **Literal rules are case-sensitive.** The scan also reports case-insensitive *near misses* that a rule
  won't change, so you can add a rule for `old name` if needed.
- Put the longer, more specific rule first.
- Binary files are skipped (git-filter-repo leaves them alone).
- Author/committer names and emails on commits are **not** changed by `--replace-text`. The scan lists any
  that match a rule.

Manage rules from the menu (**R**: add, delete, edit in `$EDITOR`) or with `--rules`, `--add-rule` and `--edit-rules`.

## Workflow

| Step | Menu | CLI | Touches GitHub? |
|---|---|---|---|
| 1. Scan every branch, tag and commit message | S | `--scan` | read only |
| 2. Rewrite a local mirror; verify **0** matches remain | W | `--rewrite` | read only |
| 3. Review the diff of what changes | P | `--preview [--all]` | no |
| 4. Bundle the original, **force-push** branches + tags | 7 | `--push` (type `FORCE-PUSH`) | **writes** |
| Undo: push a bundle back | 9 | `--restore BUNDLE` (type `RESTORE`) | **writes** |

Push refuses to run if:
- there is no verified rewrite;
- the rules changed since the rewrite;
- **anyone pushed to the repository since the rewrite** (it re-checks every ref first);
- there is no token.

After pushing, it confirms that the remote's branches and tags match the rewrite exactly.

After a push:

- **Delete and re-clone every other copy** of the repository (other machines, Docker hosts). Never pull or
  merge into an old clone, or the old history comes back.
- Close or merge open pull requests first. Diffs of closed pull requests stop displaying after a rewrite.
- GitHub keeps old commits reachable by their direct URL until it garbage-collects them. GitHub Support can
  purge cached views, but only for data they consider sensitive.
- Forks and clones made by other people keep the old history.

Example for `netgeek1/scripts`:

```sh
sudo git-history-scrubber --set REPO_URL https://github.com/netgeek1/scripts
sudo git-history-scrubber --add-rule            # Old Name  ==>  netgeek1
sudo git-history-scrubber --scan
sudo git-history-scrubber --rewrite && sudo git-history-scrubber --preview
sudo git-history-scrubber --push
```

Use `--repo URL` to work on another repository for one run without changing the setting.

## Backups

`push` always writes `<BACKUP_DIR>/<host>__<owner>__<repo>-<date>-pre-push.bundle` first. `--backup` writes
one on demand. The 10 newest per repository are kept (`BACKUP_KEEP`). Bundles hold the *original*, unscrubbed
history, so keep them private. To inspect one: `git clone --mirror FILE.bundle`.

## Menu

```
 Setup     1) Full install / reconfigure   2) Settings (repository, token, paths, container)   R) Rules
 Scrub     S) Scan   W) Rewrite   P) Preview   7) Push
 Maint.    B) Backup bundle   9) Restore   C) Clean work area   3) Apply   4) Rebuild
           8) Status   L) Run logs   U) Uninstall   T) Dry-run   X) Self-test   0) Quit
```

## Settings

`sudo git-history-scrubber --show-config` lists every key with help text. Change one with `--set KEY VALUE`.

| Key | Default | Meaning |
|---|---|---|
| `REPO_URL` | (none) | `https://github.com/OWNER/REPO`; credentials in the URL are rejected |
| `REWRITE_MESSAGES` | `yes` | Also apply the rules to commit messages |
| `WORK_DIR` | `/opt/git-history-scrubber/work` | Mirror clones (original + rewritten) |
| `BACKUP_DIR` / `BACKUP_KEEP` | `/var/backups/git-history-scrubber` / `10` | Bundles |
| `BASE_IMAGE` / `FILTER_REPO_VERSION` | `python:3.13-slim-bookworm` / `2.47.0` | Image pins |
| `MEM_LIMIT` | `1g` | Raise for very large repositories |
| `SECRETS_BACKEND` | `auto` | `systemd-creds` (TPM) or `openssl` |

## Container hardening

Each step is a one-shot `docker run --rm`: read-only root filesystem, 64 MB `/tmp` tmpfs, all capabilities
dropped, `no-new-privileges`, running as the `gitscrub` account with only `WORK_DIR`, `BACKUP_DIR` and a
read-only copy of the rules mounted. The rules copy is deleted after every run.

## Files

| Path | Contents |
|---|---|
| `/etc/git-history-scrubber/git-history-scrubber.conf` | Settings (0600) |
| `/etc/git-history-scrubber/replacements.txt` | Rules (0600) |
| `/etc/git-history-scrubber/secrets.enc` | Encrypted vault (GitHub token) |
| `/opt/git-history-scrubber/src/` | Build context |
| `<WORK_DIR>/<repo>/original.git`, `rewritten.git`, `.verified.json` | Work area (`--clean` empties it) |
| `<BACKUP_DIR>/*.bundle` | Original histories |
| `/var/log/git-history-scrubber/installer-*.log` | Run logs (20 kept) |

## License

MIT
