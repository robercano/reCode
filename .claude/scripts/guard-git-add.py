#!/usr/bin/env python3
"""PreToolUse guard, two checks in one hook:

1. Blanket `git add`/`git commit -a` when the worktree contains sandbox
   `/dev/null` device-node masks.

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

2. git STATE mutations (add/rm/mv/reset/switch/checkout <branch>/restore
   --staged) run by a WORKER session against the MAIN checkout (issue #106).

   Workers (implementer/orchestrator, isolation: worktree) must do all git
   mutation inside their OWN `.claude/worktrees/<name>` worktree — the main
   checkout is the owner's. A worker that `cd`s or `-C`s back into the main
   checkout and mutates it there races/clobbers the owner's and every sibling
   worker's git state; this is exactly the bug this deliverable closes.

   Worker detection: PRIMARY signal is the `RECODE_WORKER=1` env var, set for
   worker sessions via the `implementer`/`orchestrator` agent defs (see
   `.claude/agents/{implementer,orchestrator}.md`). CORROBORATING signal: the
   event's `cwd` already sitting under a `<main>/.claude/worktrees/<name>/...`
   path also implies a worker session even if the marker didn't propagate.
   Either signal alone is enough (`_is_worker`) — this stays robust without
   weakening the default-allow guarantee for owner sessions, which normally
   carry neither. "Main checkout" = the mutating command's EFFECTIVE git
   toplevel (honoring `cd`/`git -C` overrides in the command string) equals the
   toplevel you get by stripping a `.claude/worktrees/<name>/...` suffix off the
   session cwd (or, if the cwd carries no such suffix, the cwd's own toplevel —
   i.e. the session is already sitting in the main checkout).

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


def _git_toplevel(cwd="."):
    """`git -C <cwd> rev-parse --show-toplevel`, or "" if that fails (not a repo,
    git missing, etc). Shared by the device-mask scan and the worker guard."""
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def _has_device_masks(cwd="."):
    """True if the worktree contains a /dev/null character-device mask.

    The sandbox bind-mounts /dev/null over sensitive config paths. Crucially, a
    directory entry's readdir `d_type` still reports the *underlying* regular
    file, so `find -type c` (and DirEntry.is_*) miss the mask — only an actual
    `stat()` follows the bind-mount and reports S_IFCHR. So we os.stat() entries
    ourselves. Masks always include repo-root dotfiles (.gitconfig, .mcp.json,
    shell rc, editor dirs) and .claude/* items, so a shallow scan of those two
    dirs is enough and stays fast on every Bash call.
    """
    root = _git_toplevel(cwd) or "."
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


def _sandbox_enabled():
    """True if the Bash sandbox is enabled for this session.

    The PreToolUse hook runs *outside* the sandbox, so it cannot see the
    /dev/null device-node masks — they exist only inside the per-command bwrap
    namespace, and os.stat here reports the masked paths as absent. So instead of
    detecting the symptom (masks), detect the cause: an enabled sandbox. When it
    is on, a blanket `git add` run as a sandboxed Bash command will hit the masks
    and abort, so we block preemptively. When it is off (non-hardened consumers),
    this returns False and the guard is a no-op.
    """
    home = os.path.expanduser("~")
    pdir = os.environ.get("CLAUDE_PROJECT_DIR", ".")
    for path in (
        os.path.join(pdir, ".claude", "settings.local.json"),
        os.path.join(pdir, ".claude", "settings.json"),
        os.path.join(home, ".claude", "settings.json"),
    ):
        try:
            with open(path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        if (cfg.get("sandbox") or {}).get("enabled") is True:
            return True
    return False


# Marker env var (issue #106): set by the implementer/orchestrator agent defs
# for every worker session. See the module docstring, check 2, for the full
# primary/corroborating detection rationale.
_WORKER_ENV = "RECODE_WORKER"
_WORKTREE_SEGMENT = "/.claude/worktrees/"

# Subcommands that always mutate git state, regardless of arguments.
_MUTATING_SIMPLE = {"add", "rm", "mv", "reset", "switch"}


def _cwd_in_worktree(cwd):
    return _WORKTREE_SEGMENT in (cwd or "")


def _is_worker(cwd):
    """True if this session looks like a worker (implementer/orchestrator),
    not the owner. PRIMARY: the RECODE_WORKER=1 marker env var. CORROBORATING:
    an event cwd already under <main>/.claude/worktrees/<name>/... — enough on
    its own even if the marker didn't propagate. Either signal suffices;
    absent both, an owner session is unaffected (default allow)."""
    return os.environ.get(_WORKER_ENV) == "1" or _cwd_in_worktree(cwd)


def _main_root(cwd):
    """Resolve the MAIN checkout root implied by a session cwd. If cwd sits
    under <root>/.claude/worktrees/<name>/..., root is the prefix before that
    marker. Otherwise cwd is already (presumably) the main checkout, so its own
    git toplevel IS the root."""
    idx = (cwd or "").find(_WORKTREE_SEGMENT)
    if idx != -1:
        return cwd[:idx]
    return _git_toplevel(cwd or ".")


def _is_mutating_git(subcmd, args):
    """True if `git <subcmd> <args>` mutates repo state in a way workers must
    never do against the main checkout."""
    if subcmd in _MUTATING_SIMPLE:
        return True
    if subcmd == "restore":
        return "--staged" in args
    if subcmd == "checkout":
        # `git checkout -- <path>` (or no args) restores/lists paths, not a
        # branch switch; anything else (a branch name, -b/-B, ...) switches.
        if not args or "--" in args:
            return False
        return True
    return False


def _mutating_targets(cmd, base_cwd):
    """Yield (subcmd, effective_cwd) for every git invocation in `cmd` that is
    a state mutation, tracking `cd <dir> &&` and `git -C <dir>` overrides
    sequentially so the effective target directory is resolved correctly."""
    cwd = base_cwd
    out = []
    for seg in _segments(cmd):
        toks = _tokens(seg)
        if not toks:
            continue
        if toks[0] == "cd" and len(toks) >= 2:
            target = toks[1]
            cwd = target if target.startswith("/") else os.path.normpath(os.path.join(cwd, target))
            continue
        if "git" not in toks:
            continue
        gi = toks.index("git")
        rest = toks[gi + 1 :]
        local_cwd = cwd
        i = 0
        while i < len(rest) and rest[i].startswith("-"):
            if rest[i] == "-C" and i + 1 < len(rest):
                target = rest[i + 1]
                local_cwd = (
                    target if target.startswith("/") else os.path.normpath(os.path.join(local_cwd, target))
                )
                i += 2
                continue
            if rest[i] in ("-c", "--exec-path", "--namespace") and i + 1 < len(rest):
                i += 2
                continue
            i += 1
        subrest = rest[i:]
        if not subrest:
            continue
        subcmd, args = subrest[0], subrest[1:]
        if _is_mutating_git(subcmd, args):
            out.append((subcmd, local_cwd))
    return out


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
    cwd = data.get("cwd") or os.getcwd()

    # Best-effort, same spirit as check 1: only engage when the sandbox is
    # hardened (its masks/marker are what make either failure mode real) —
    # never obstruct non-hardened downstream consumers.
    hardened = _sandbox_enabled() or _has_device_masks(cwd)
    if not hardened:
        return 0

    # Check 1: blanket `git add -A/./--all` or `git commit -a`.
    if _is_blanket(cmd):
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

    # Check 2: worker git STATE mutations against the MAIN checkout (#106).
    if _is_worker(cwd):
        main_root = _main_root(cwd)
        if main_root:
            for subcmd, local_cwd in _mutating_targets(cmd, cwd):
                if _git_toplevel(local_cwd) == main_root:
                    sys.stderr.write(
                        f"Blocked: `git {subcmd}` targets the MAIN checkout ({main_root}), "
                        "but this is a worker session. Workers must do ALL git state "
                        "mutation inside their OWN worktree, never the main checkout — "
                        "the owner and every sibling worker share it.\n"
                        "Run this from your own worktree instead. Need a branch that's "
                        "already checked out elsewhere (e.g. shared with another "
                        "worker)? `git worktree add` it into YOUR worktree — do not "
                        "touch the main checkout to get it. A \"branch already checked "
                        "out elsewhere\" error is a RE-SCOPE signal: stop and report it "
                        "to the orchestrator, don't work around it via the main checkout.\n"
                    )
                    return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
