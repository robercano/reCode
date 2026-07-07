#!/usr/bin/env python3
"""PreToolUse guard: stop blanket `git add`/`git commit -a` when the worktree
contains sandbox `/dev/null` device-node masks.

Under the hardened sandbox, Claude Code bind-mounts /dev/null over sensitive
config paths (.mcp.json, .gitconfig, .claude/{launch.json,routines,...}, editor
dirs). Git cannot index a character-device node, so `git add -A` / `git add .` /
`git commit -a` abort the *whole* commit with:

    error: <path>: can only add regular files, symbolic links or git-directories
    fatal: adding files failed

Explicit path staging (`git add <path> ...`) skips the masks and works fine, so
this guard blocks only the blanket forms — and only when masks are actually
present (i.e. inside the sandbox). Outside the sandbox it is a no-op, so it never
obstructs consumers who don't run hardened.

Contract: reads the PreToolUse event JSON on stdin. Exit 0 = allow. Exit 2 =
block (stderr is shown to the agent).
"""
import json
import os
import re
import shlex
import stat as _stat
import subprocess
import sys

# Shell separators that terminate one simple command.
_SEP = re.compile(r"&&|\|\||;|\||\n")


def _segments(cmd):
    return [s.strip() for s in _SEP.split(cmd) if s.strip()]


def _tokens(segment):
    try:
        return shlex.split(segment)
    except ValueError:
        # Unbalanced quotes etc. — fall back to whitespace split.
        return segment.split()


def _short_flag_has(tok, letter):
    """True if tok is a single-dash short flag bundle containing `letter`
    (e.g. -a, -am). Excludes long options like --all / --amend."""
    return (
        tok.startswith("-")
        and not tok.startswith("--")
        and letter in tok[1:]
    )


def _is_blanket(cmd):
    for seg in _segments(cmd):
        toks = _tokens(seg)
        if "git" not in toks:
            continue
        gi = toks.index("git")
        rest = toks[gi + 1 :]
        if "add" in rest:
            args = rest[rest.index("add") + 1 :]
            for a in args:
                if a in ("-A", "--all", "."):
                    return True
                if _short_flag_has(a, "A"):  # bundled, e.g. -Av
                    return True
        if "commit" in rest:
            args = rest[rest.index("commit") + 1 :]
            for a in args:
                if a == "--all":
                    return True
                if _short_flag_has(a, "a"):  # -a, -am, -a -m  (not --amend)
                    return True
    return False


def _has_device_masks():
    """True if the worktree contains a /dev/null character-device mask.

    The sandbox bind-mounts /dev/null over sensitive config paths. Crucially, a
    directory entry's readdir `d_type` still reports the *underlying* regular
    file, so `find -type c` (and DirEntry.is_*) miss the mask — only an actual
    `stat()` follows the bind-mount and reports S_IFCHR. So we os.stat() entries
    ourselves. Masks always include repo-root dotfiles (.gitconfig, .mcp.json,
    shell rc, editor dirs) and .claude/* items, so a shallow scan of those two
    dirs is enough and stays fast on every Bash call.
    """
    try:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip() or "."
    except Exception:
        root = "."
    for d in (root, os.path.join(root, ".claude")):
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if _stat.S_ISCHR(os.stat(e.path).st_mode):
                            return True
                    except OSError:
                        continue
        except OSError:
            continue
    return False


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    cmd = (data.get("tool_input") or {}).get("command", "")
    if not cmd or "git" not in cmd:
        return 0
    if not _is_blanket(cmd):
        return 0
    if not _has_device_masks():
        return 0

    sys.stderr.write(
        "Blocked: a blanket `git add -A/./--all` or `git commit -a` will try to "
        "index this sandbox's /dev/null device-node masks (the `crw-` entries in "
        "`git status`) and abort the whole commit "
        "(`can only add regular files, symbolic links or git-directories`).\n"
        "Stage the files you actually changed, by name:\n"
        '  git add <path1> <path2> && git commit -m "..."\n'
        "The `crw-` entries are sandbox masks, not your work — ignore them. "
        "See docs/HARDENING.md -> Caveats.\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
