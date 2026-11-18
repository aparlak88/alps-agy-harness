#!/usr/bin/env python3
"""Shared deterministic core library for Alps AGY Harness hooks, CLI tools, and daemon.

This module serves as the single source of truth for command parsing, package
verification, Markdown glossary and walkthrough validation, Git code-tree
hashing, stamp freshness checks, environment diagnostics, and iOS crash
parsing across both the persistent ``harness-daemon`` sidecar and cold
fallback hook scripts.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import glob
import http.client
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import stat
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
CACHE_SCHEMA_VERSION = 1
DEFAULT_DAEMON_TIMEOUT_SEC = 0.35
DEFAULT_HEALTH_READ_MAX_AGE_SEC = 600
DEFAULT_MOBILE_CRASH_MAX_AGE_SEC = 86400

SQL_CONCAT_RE = re.compile(
    r"(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s.*(['\"]\s*\+\s*[A-Za-z0-9_$(]|\+\s*['\"])",
    re.IGNORECASE,
)
PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
EVAL_CALL_RE = re.compile(r"(?:^|[^a-zA-Z0-9_])eval\s*\(")
GLOBAL_CONSTRAINTS_RE = re.compile(r"^## Global Constraints(?:\s|$)")
WALKTHROUGH_H2_FILE_RE = re.compile(
    r"^##\s+(?:\d+\.\s+)?(?:Dosya Bazlı(?: Tam)? Değişiklik Analizi|File-by-File Change Analysis)\s*$",
    re.IGNORECASE,
)
GLOSSARY_H2_RE = re.compile(r"^## ([0-9]+\. )?(Teknik Terimler Sözlüğü|Technical Glossary)\s*$")
DOTNET_VAL_FLAGS = frozenset(
    ("--version", "-v", "--framework", "-f", "--source", "-s", "--package-directory", "--project", "--file")
)
AUDITOR_BASENAMES = frozenset(("canon-auditor.md", "security-reviewer.md", "pr-auditor.md"))
PBXPROJ_BUNDLE_RE = re.compile(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*\"?([^;\n\"]+)\"?\s*;")


def utc_now_iso() -> str:
    """Return current UTC timestamp formatted as ISO-8601 seconds with Z suffix."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_socket_path() -> Path:
    """Resolve the secure per-user AF_UNIX socket path under /tmp."""
    override = os.environ.get("HARNESS_DAEMON_SOCK", "").strip()
    if override:
        return Path(override)
    return Path(f"/tmp/agy-hd-{os.getuid()}") / "d.sock"


def default_data_dir() -> Path:
    """Resolve the persistent daemon state and log directory."""
    override = os.environ.get("HARNESS_DAEMON_DATA_DIR", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".gemini" / "antigravity" / "sidecar_data" / "alps-agy-harness-daemon"


def atomic_write_json(target_dir: Path, filename: str, data: Any) -> Path:
    """Atomically write JSON data into ``target_dir/filename`` via temp file and replace."""
    target_dir.mkdir(parents=True, exist_ok=True)
    content = data if isinstance(data, str) else json.dumps(data, ensure_ascii=False, indent=2)
    if not content.endswith("\n"):
        content += "\n"
    tmp_path = target_dir / f".{filename}.tmp.{os.getpid()}.{threading.get_ident()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp_path, target_dir / filename)
    except Exception:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except OSError:
            pass
        raise
    return target_dir / filename


def read_json_file(path: Path) -> Optional[dict[str, Any]]:
    """Safely read a JSON object from ``path``, returning None on missing or invalid input."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            parsed = json.load(fh)
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        return None


def is_harness_ignored(workspace: Path) -> bool:
    """Return True when the workspace opts out of harness enforcement via ``.harness-ignore``."""
    return (workspace / ".harness-ignore").is_file()


def _run_git(workspace: Path, args: list[str], stdin_data: Optional[str] = None) -> subprocess.CompletedProcess[str]:
    """Run a bounded git command scoped to ``workspace`` with text output."""
    cmd = ["git", "-C", str(workspace), *args]
    timeout_sec = max(1, int(os.environ.get("HARNESS_GIT_TIMEOUT_SEC", "15")))
    try:
        return subprocess.run(
            cmd,
            input=stdin_data,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args=cmd, returncode=124, stdout="", stderr="git timed out")


def ensure_harness_git_exclude(workspace: Path) -> None:
    """Idempotently add ``.harness/`` to the git repository's local info/exclude file."""
    res = _run_git(workspace, ["rev-parse", "--is-inside-work-tree"])
    if res.returncode != 0:
        return
    excl_res = _run_git(workspace, ["rev-parse", "--git-path", "info/exclude"])
    if excl_res.returncode != 0:
        return
    exclude_rel = excl_res.stdout.strip()
    if not exclude_rel:
        return
    exclude_path = Path(exclude_rel) if os.path.isabs(exclude_rel) else (workspace / exclude_rel)
    exclude_path.parent.mkdir(parents=True, exist_ok=True)
    existing = ""
    if exclude_path.is_file():
        existing = exclude_path.read_text(encoding="utf-8", errors="replace")
    lines = existing.splitlines()
    if ".harness/" not in lines:
        prefix = "" if (not existing or existing.endswith("\n")) else "\n"
        with open(exclude_path, "a", encoding="utf-8") as fh:
            fh.write(f"{prefix}.harness/\n")


def get_branch_name(workspace: Path) -> str:
    """Return active symbolic branch name or ``HEAD`` when detached."""
    res = _run_git(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"])
    branch = res.stdout.strip() if res.returncode == 0 else ""
    return branch or "HEAD"


def slugify_branch(branch: str) -> str:
    """Convert a branch name into the canonical filesystem-safe slug."""
    slug = re.sub(r"[^A-Za-z0-9]+", "-", branch).strip("-")
    return slug or "default"


def get_branch_slug(workspace: Path) -> str:
    """Return canonical branch slug or ``detached-<7-char-sha>`` for detached HEAD."""
    res = _run_git(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"])
    branch = res.stdout.strip() if res.returncode == 0 else ""
    if branch:
        return slugify_branch(branch)
    sha_res = _run_git(workspace, ["rev-parse", "--short=7", "HEAD"])
    short_sha = sha_res.stdout.strip() if sha_res.returncode == 0 else ""
    return f"detached-{short_sha}" if short_sha else "detached-unknown"


def get_head_oid(workspace: Path) -> str:
    """Return full HEAD commit SHA or ``UNBORN`` when repository has no commits."""
    res = _run_git(workspace, ["rev-parse", "--verify", "--quiet", "HEAD"])
    if res.returncode != 0:
        return "UNBORN"
    oid = res.stdout.strip()
    return oid or "UNBORN"


def get_state_dir(workspace: Path) -> Path:
    """Ensure ``.harness/state/<slug>`` exists and is excluded from git tracking."""
    slug = get_branch_slug(workspace)
    state_dir = workspace / ".harness" / "state" / slug
    state_dir.mkdir(parents=True, exist_ok=True)
    ensure_harness_git_exclude(workspace)
    return state_dir


def get_cache_dir(workspace: Path) -> Path:
    """Ensure ``.harness/cache`` exists and is excluded from git tracking."""
    cache_dir = workspace / ".harness" / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    ensure_harness_git_exclude(workspace)
    return cache_dir


def compute_code_tree_sha(workspace: Path, ref: str = "HEAD") -> str:
    """Compute deterministic git tree SHA excluding walkthroughs and parking-lot docs.

    Matches ``harness_code_tree_sha`` in ``common.sh`` byte-for-byte. Returns
    ``UNBORN`` when the target ref does not resolve.
    """
    verify = _run_git(workspace, ["rev-parse", "--verify", "--quiet", ref])
    if verify.returncode != 0:
        return "UNBORN"

    ls_res = _run_git(workspace, ["ls-tree", "-r", ref])
    if ls_res.returncode != 0:
        return "UNBORN"

    kept_lines: list[str] = []
    for line in ls_res.stdout.splitlines(keepends=True):
        tab_idx = line.find("\t")
        if tab_idx != -1:
            rel_path = line[tab_idx + 1 :].rstrip("\r\n")
            if rel_path.startswith("docs/walkthroughs/") or rel_path == "docs/parking-lot.md":
                continue
        kept_lines.append(line)

    hash_res = _run_git(workspace, ["hash-object", "--stdin"], stdin_data="".join(kept_lines))
    return hash_res.stdout.strip() if hash_res.returncode == 0 else "UNBORN"


def parse_command_segments(cmd_line: str) -> list[list[str]]:
    """Split a shell command string into argv token segments respecting quotes and wrappers."""
    if not cmd_line:
        return []

    segments: list[str] = []
    current: list[str] = []
    in_single = False
    in_double = False
    escape = False
    i = 0
    n = len(cmd_line)

    while i < n:
        c = cmd_line[i]
        if escape:
            current.append(c)
            escape = False
            i += 1
            continue
        if c == "\\" and not in_single:
            escape = True
            current.append(c)
            i += 1
            continue
        if c == "'" and not in_double:
            in_single = not in_single
            current.append(c)
            i += 1
            continue
        if c == '"' and not in_single:
            in_double = not in_double
            current.append(c)
            i += 1
            continue

        if not in_single and not in_double:
            if c in ("&", "|") and i + 1 < n and cmd_line[i + 1] == c:
                seg = "".join(current).strip()
                if seg:
                    segments.append(seg)
                current = []
                i += 2
                continue
            if c in (";", "\n", "|", "&", "(", ")"):
                seg = "".join(current).strip()
                if seg:
                    segments.append(seg)
                current = []
                i += 1
                continue
        current.append(c)
        i += 1

    tail = "".join(current).strip()
    if tail:
        segments.append(tail)

    result: list[list[str]] = []
    for seg in segments:
        try:
            tokens = shlex.split(seg)
        except Exception:
            tokens = seg.split()
        if not tokens:
            continue

        idx = 0
        while idx < len(tokens):
            tok = tokens[idx]
            if "=" in tok and tok.split("=", 1)[0].isidentifier():
                idx += 1
                continue
            if tok == "sudo":
                idx += 1
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-u", "-g", "-h", "-p", "-U"):
                        idx += 2
                    else:
                        idx += 1
                continue
            if tok == "env":
                idx += 1
                while idx < len(tokens):
                    if tokens[idx].startswith("-"):
                        idx += 1
                    elif "=" in tokens[idx] and tokens[idx].split("=", 1)[0].isidentifier():
                        idx += 1
                    else:
                        break
                continue
            if tok in ("nohup", "time", "builtin", "command"):
                idx += 1
                continue
            break

        cleaned = tokens[idx:]
        if cleaned:
            result.append(cleaned)
    return result


def extract_install_packages(tokens: list[str]) -> list[str]:
    """Extract normalized package names from npm, pnpm, yarn, dotnet, uv, or cargo install segments."""
    if not tokens:
        return []

    exe = os.path.basename(tokens[0])
    pkgs: list[str] = []

    if exe == "npm" and len(tokens) > 1 and tokens[1] in ("install", "i", "add"):
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t in ("--prefix", "-w", "--workspace", "--registry", "--cache", "--tag"):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1
    elif exe == "pnpm" and len(tokens) > 1 and tokens[1] in ("add", "install", "i"):
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t in ("--dir", "-C", "-w", "--filter"):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1
    elif exe == "yarn" and len(tokens) > 1 and tokens[1] == "add":
        for t in tokens[2:]:
            if not t.startswith("-"):
                pkgs.append(t)
    elif exe == "dotnet":
        start_idx: Optional[int] = None
        if len(tokens) > 2 and tokens[1] == "add" and "package" in tokens[2:]:
            start_idx = tokens.index("package", 2) + 1
        elif len(tokens) > 2 and tokens[1] == "package" and tokens[2] == "add":
            start_idx = 3
        if start_idx is not None:
            i = start_idx
            while i < len(tokens):
                t = tokens[i]
                if t in DOTNET_VAL_FLAGS:
                    i += 2
                elif t.startswith("-"):
                    i += 1
                else:
                    pkgs.append(t)
                    break
    elif exe in ("uv", "cargo") and len(tokens) > 1 and tokens[1] == "add":
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t in ("--features", "-F", "-p", "--package", "--target", "--optional", "--python"):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1

    cleaned: list[str] = []
    for raw_pkg in pkgs:
        pkg = raw_pkg.strip().strip("'\"")
        if not pkg or pkg.startswith((".", "/", "~", "http:", "https:", "git:", "git+")):
            continue
        if pkg.startswith("@"):
            cleaned.append("@" + pkg[1:].split("@", 1)[0])
        else:
            cleaned.append(pkg.split("@", 1)[0])
    return cleaned


def extract_global_constraints_section(text: str) -> str:
    """Return the concatenated body of all ``## Global Constraints`` sections in a spec."""
    in_sec = False
    sec_lines: list[str] = []
    for line in text.splitlines(keepends=True):
        if GLOBAL_CONSTRAINTS_RE.match(line):
            in_sec = True
            continue
        if in_sec and line.startswith("## "):
            in_sec = False
        if in_sec:
            sec_lines.append(line)
    return "".join(sec_lines)


def build_spec_package_index(workspace: Path, existing_index: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    """Build or refresh the mtime-keyed cache of ``## Global Constraints`` sections in spec files."""
    specs_dir = workspace / "docs" / "superpowers" / "specs"
    prev_specs = existing_index.get("specs", {}) if isinstance(existing_index, dict) else {}
    specs: dict[str, Any] = {}

    if specs_dir.is_dir():
        for spec_path in sorted(specs_dir.glob("*.md")):
            if not spec_path.is_file():
                continue
            rel = f"docs/superpowers/specs/{spec_path.name}"
            try:
                st = spec_path.stat()
            except OSError:
                continue
            mtime_ns = st.st_mtime_ns
            size = st.st_size
            prev = prev_specs.get(rel)
            if isinstance(prev, dict) and prev.get("mtimeNs") == mtime_ns and prev.get("size") == size:
                specs[rel] = prev
            else:
                raw_text = spec_path.read_text(encoding="utf-8", errors="ignore")
                section = extract_global_constraints_section(raw_text)
                specs[rel] = {
                    "mtimeNs": mtime_ns,
                    "size": size,
                    "sectionText": section,
                }

    return {
        "schemaVersion": CACHE_SCHEMA_VERSION,
        "updatedAt": utc_now_iso(),
        "specs": specs,
    }


def has_glossary_section(text: str) -> bool:
    """Return True if Markdown ends with a non-empty Technical Glossary / Teknik Terimler Sözlüğü H2 section."""
    if not text:
        return False

    in_fence = False
    fence_len = 0
    has_h2 = False
    last_h2_is_glossary = False
    seen_sep = False
    data_after_sep = False
    has_bullet_or_row = False

    for raw_line in text.split("\n"):
        line = raw_line.rstrip("\r")
        if in_fence:
            m_close = re.match(r"^[ \t]*(`{3,})[ \t]*$", line)
            if m_close and len(m_close.group(1)) >= fence_len:
                in_fence = False
                fence_len = 0
            continue

        m_open = re.match(r"^[ \t]*(`{3,})", line)
        if m_open:
            in_fence = True
            fence_len = len(m_open.group(1))
            continue

        if line.startswith("## "):
            has_h2 = True
            seen_sep = False
            data_after_sep = False
            has_bullet_or_row = False
            last_h2_is_glossary = bool(GLOSSARY_H2_RE.match(line))
        elif last_h2_is_glossary:
            if re.match(r"^\|[ \t:|-]+\|[ \t]*$", line):
                seen_sep = True
            elif seen_sep:
                if line.startswith("|") and not re.match(r"^\|[ \t]*$", line):
                    data_after_sep = True
            else:
                if re.match(r"^[ \t]*[-*][ \t]+\*\*[^*]+\*\*", line) or re.match(r"^\|[^-]", line):
                    has_bullet_or_row = True

    if not (has_h2 and last_h2_is_glossary):
        return False
    return data_after_sep if seen_sep else has_bullet_or_row


def validate_walkthrough(wt_text: str, diff_files: list[str]) -> tuple[bool, str]:
    """Validate walkthrough Mermaid count, placeholders, and 100% per-file Ne/Neden coverage."""
    if not wt_text:
        return False, "walkthrough file in docs/walkthroughs/*.md is empty."

    lines = [l.rstrip("\r") for l in wt_text.split("\n")]
    in_fence = False
    fence_len = 0
    mermaid_count = 0
    has_file_h2 = False
    in_file_h2 = False
    file_sec_lines: list[tuple[bool, str]] = []
    non_fence_lines: list[str] = []

    for line in lines:
        stripped = line.lstrip(" \t")
        if in_fence:
            m_close = re.match(r"^(`{3,})[ \t]*$", stripped)
            if m_close and len(m_close.group(1)) >= fence_len:
                in_fence = False
                fence_len = 0
            if in_file_h2:
                file_sec_lines.append((True, line))
            continue

        m_open = re.match(r"^(`{3,})(.*)$", stripped)
        if m_open:
            in_fence = True
            fence_len = len(m_open.group(1))
            info = m_open.group(2).strip().lower()
            if info == "mermaid" or info.startswith("mermaid "):
                mermaid_count += 1
            if in_file_h2:
                file_sec_lines.append((True, line))
            continue

        non_fence_lines.append(line)

        if line.startswith("## "):
            if WALKTHROUGH_H2_FILE_RE.match(line):
                has_file_h2 = True
                in_file_h2 = True
                continue
            if in_file_h2:
                in_file_h2 = False

        if in_file_h2:
            file_sec_lines.append((False, line))

    if mermaid_count < 2:
        return (
            False,
            f"walkthrough in docs/walkthroughs/*.md must contain at least 2 Mermaid diagrams (```mermaid); found {mermaid_count}.",
        )

    def strip_inline_code(s: str) -> str:
        return re.sub(r"`[^`]*`", "", s)

    for line in non_fence_lines:
        plain = strip_inline_code(line)
        if line.startswith("#") and "[Özellik / Düzeltme Başlığı]" in plain:
            return False, 'walkthrough contains unedited template placeholder "[Özellik / Düzeltme Başlığı]".'
        if line.startswith("###") and (
            "[ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ]" in plain
            or "`<dosya/tam/yolu>`" in line
            or "<dosya-yolu>" in plain
        ):
            return (
                False,
                'walkthrough contains unedited per-file template placeholder (e.g. "[ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ]" or "<dosya/tam/yolu>").',
            )
        for marker in (
            "[Gerçek problemi ve kök bağlamı açıklayın",
            "[Eklenen veya değiştirilen sınıfları, metod imzalarını",
            "[Bu dosyadaki değişikliği zorunlu kılan iş kuralını",
        ):
            if marker in plain:
                return False, f"walkthrough contains unedited template placeholder: {marker}..."

    if not has_file_h2:
        return (
            False,
            'walkthrough in docs/walkthroughs/*.md is missing mandatory "## Dosya Bazlı Değişiklik Analizi" (or "## File-by-File Change Analysis") section.',
        )

    required_files: list[str] = []
    seen: set[str] = set()
    for raw in diff_files:
        f = raw.strip()
        if not f or f.startswith("docs/walkthroughs/") or f == "docs/parking-lot.md":
            continue
        if f not in seen:
            seen.add(f)
            required_files.append(f)

    section_non_fence_text = "\n".join(l for is_f, l in file_sec_lines if not is_f)
    if not required_files:
        if len(re.sub(r"\s+", "", section_non_fence_text)) < 15:
            return False, 'walkthrough "## Dosya Bazlı Değişiklik Analizi" section cannot be empty.'
        return True, ""

    h3_blocks: list[tuple[str, list[tuple[bool, str]]]] = []
    cur_header: Optional[str] = None
    cur_lines: list[tuple[bool, str]] = []
    for is_f, l in file_sec_lines:
        if not is_f and re.match(r"^###[ \t]+", l):
            if cur_header is not None:
                h3_blocks.append((cur_header, cur_lines))
            cur_header = l
            cur_lines = []
        elif cur_header is not None:
            cur_lines.append((is_f, l))
    if cur_header is not None:
        h3_blocks.append((cur_header, cur_lines))

    section_full_text = "\n".join(l for _, l in file_sec_lines)
    missing_files: list[str] = []
    missing_h3_files: list[str] = []
    file_to_block: dict[str, tuple[str, list[tuple[bool, str]]]] = {}

    for rf in required_files:
        pat = re.compile(r"(?<![A-Za-z0-9_./-])" + re.escape(rf) + r"(?![A-Za-z0-9_./-])")
        matched_blocks = [(hdr, blines) for hdr, blines in h3_blocks if pat.search(hdr)]
        if matched_blocks:
            file_to_block[rf] = matched_blocks[0]
        elif not pat.search(section_full_text):
            missing_files.append(rf)
        else:
            missing_h3_files.append(rf)

    if missing_files:
        return (
            False,
            'walkthrough "## Dosya Bazlı Değişiklik Analizi" is missing per-file analysis for: '
            + ", ".join(missing_files)
            + ". Every created, modified, or deleted file in git diff must be documented.",
        )

    if missing_h3_files:
        return (
            False,
            'walkthrough "## Dosya Bazlı Değişiklik Analizi" is too shallow for: '
            + ", ".join(missing_h3_files)
            + '. Each file must have its own dedicated "### `<path>` — [ÜRETİLDİ|GÜNCELLENDİ|SİLİNDİ]" subsection instead of one-line summary bullets.',
        )

    what_label = (
        r"(?:Ne\s+(?:Değişti|Üretildi|Silindi|Eklendi)"
        r"(?:\s*/\s*(?:Ne\s+)?(?:Değişti|Üretildi|Silindi|Eklendi))*"
        r"|What\s+(?:Changed|Was\s+(?:Added|Created|Updated|Removed|Deleted)))"
    )
    why_label = (
        r"(?:Neden\s+(?:Değişti|Üretildi|Silindi|Eklendi)"
        r"(?:\s*/\s*(?:Neden\s+)?(?:Değişti|Üretildi|Silindi|Eklendi))*"
        r"|Why\s+(?:It\s+)?(?:Changed|Was\s+(?:Added|Created|Updated|Removed|Deleted)|Added|Created|Removed|Deleted)|Why)"
    )
    what_re = re.compile(
        r"^[ \t]*(?:[-*+]|\d+\.|#{4,6})?[ \t]*\*{0,2}" + what_label + r"[ \t]*\??[ \t]*\*{0,2}[ \t]*:?[ \t]*\*{0,2}",
        re.IGNORECASE | re.MULTILINE,
    )
    why_re = re.compile(
        r"^[ \t]*(?:[-*+]|\d+\.|#{4,6})?[ \t]*\*{0,2}" + why_label + r"[ \t]*\??[ \t]*\*{0,2}[ \t]*:?[ \t]*\*{0,2}",
        re.IGNORECASE | re.MULTILINE,
    )

    shallow_files: list[str] = []
    for rf in required_files:
        _, blines = file_to_block[rf]
        masked_block = "\n".join((" " * len(l) if is_f else l) for is_f, l in blines)
        w_matches = list(what_re.finditer(masked_block))
        y_matches = list(why_re.finditer(masked_block))
        if not w_matches or not y_matches:
            shallow_files.append(f"{rf} (missing Ne/What or Neden/Why label)")
            continue

        bounds = sorted(
            set([len(masked_block)] + [m.start() for m in w_matches] + [m.start() for m in y_matches])
        )

        def next_bound(pos: int) -> int:
            for b in bounds:
                if b > pos:
                    return b
            return len(masked_block)

        w_body = masked_block[w_matches[0].end() : next_bound(w_matches[0].start())]
        y_body = masked_block[y_matches[0].end() : next_bound(y_matches[0].start())]
        w_clean = re.sub(r"[`*_>#\-\s]+", " ", w_body).strip()
        y_clean = re.sub(r"[`*_>#\-\s]+", " ", y_body).strip()
        if len(w_clean) < 25 or len(y_clean) < 25:
            shallow_files.append(f"{rf} (stub/one-word prose < 25 chars)")

    if shallow_files:
        return (
            False,
            'walkthrough "## Dosya Bazlı Değişiklik Analizi" has shallow per-file documentation for: '
            + ", ".join(shallow_files)
            + '. Provide concrete multi-sentence "Ne Değişti / Ne Üretildi" and "Neden Değişti / Neden Üretildi" explanations.',
        )
    return True, ""


def build_doc_validation_cache(workspace: Path, existing_cache: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    """Pre-validate README and docs/*.md glossary status keyed by file mtimeNs and size."""
    prev_docs = existing_cache.get("docs", {}) if isinstance(existing_cache, dict) else {}
    docs_map: dict[str, Any] = {}

    candidates: list[tuple[str, Path]] = []
    readme = workspace / "README.md"
    if readme.is_file():
        candidates.append(("README.md", readme))
    docs_root = workspace / "docs"
    if docs_root.is_dir():
        for p in sorted(docs_root.rglob("*.md")):
            if not p.is_file():
                continue
            rel = p.relative_to(workspace).as_posix()
            if rel in ("docs/canon/glossary.md", "docs/parking-lot.md"):
                continue
            candidates.append((rel, p))

    base_ref = _resolve_base_branch(workspace)
    head_oid = get_head_oid(workspace)
    merge_base = ""
    diff_key = ""
    all_diff: list[str] = []
    if base_ref and head_oid != "UNBORN":
        mb_res = _run_git(workspace, ["merge-base", base_ref, "HEAD"])
        merge_base = mb_res.stdout.strip() if mb_res.returncode == 0 else base_ref
        diff_key = f"{merge_base}..{head_oid}"
        diff_res = _run_git(workspace, ["diff", "--name-only", diff_key])
        if diff_res.returncode == 0:
            all_diff = [line for line in diff_res.stdout.splitlines() if line.strip()]

    for rel, path in candidates:
        try:
            st = path.stat()
        except OSError:
            continue
        mtime_ns = st.st_mtime_ns
        size = st.st_size
        prev = prev_docs.get(rel)
        is_wt = rel.startswith("docs/walkthroughs/")
        if (
            isinstance(prev, dict)
            and prev.get("mtimeNs") == mtime_ns
            and prev.get("size") == size
            and (not is_wt or prev.get("diffKey") == diff_key)
        ):
            docs_map[rel] = prev
            continue

        content = path.read_text(encoding="utf-8", errors="ignore")
        entry: dict[str, Any] = {
            "mtimeNs": mtime_ns,
            "size": size,
            "hasGlossary": has_glossary_section(content),
        }
        if is_wt and diff_key:
            wt_ok, wt_err = validate_walkthrough(content, all_diff)
            entry["diffKey"] = diff_key
            entry["walkthroughValid"] = wt_ok
            entry["walkthroughError"] = wt_err
        docs_map[rel] = entry

    return {
        "schemaVersion": CACHE_SCHEMA_VERSION,
        "updatedAt": utc_now_iso(),
        "docs": docs_map,
    }


def _evaluate_stamp_status(stamp_data: Optional[dict[str, Any]], current_sha: str, require_zero_findings: bool = False) -> tuple[str, str]:
    """Return ``(status, stamp_sha)`` where status is ``fresh|stale|fail|missing``."""
    if not isinstance(stamp_data, dict):
        return "missing", ""
    verdict = str(stamp_data.get("verdict", ""))
    stamp_sha = str(stamp_data.get("codeTreeSha", ""))
    if verdict != "PASS":
        return "fail", stamp_sha
    if require_zero_findings and (stamp_data.get("criticalCount") != 0 or stamp_data.get("importantCount") != 0):
        return "fail", stamp_sha
    if current_sha == "UNBORN" or stamp_sha != current_sha:
        return "stale", stamp_sha
    return "fresh", stamp_sha


def compute_tree_and_stamp_state(workspace: Path, existing_cache: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    """Compute branch, HEAD OID, codeTreeSha, and PR stamp freshness.

    Reuses ``existing_cache["codeTreeSha"]`` strictly when ``existing_cache``
    was computed for the exact same live ``headOid``.
    """
    branch = get_branch_name(workspace)
    slug = get_branch_slug(workspace)
    head_oid = get_head_oid(workspace)

    if (
        isinstance(existing_cache, dict)
        and existing_cache.get("headOid") == head_oid
        and isinstance(existing_cache.get("codeTreeSha"), str)
        and existing_cache.get("codeTreeSha")
    ):
        code_sha = existing_cache["codeTreeSha"]
    else:
        code_sha = compute_code_tree_sha(workspace)

    state_dir = workspace / ".harness" / "state" / slug
    canon_data = read_json_file(state_dir / "canon-pass.json")
    sec_data = read_json_file(state_dir / "security-pass.json")
    pending_data = read_json_file(state_dir / "pr-audit-pending.json")

    canon_status, canon_sha = _evaluate_stamp_status(canon_data, code_sha, require_zero_findings=False)
    sec_status, sec_sha = _evaluate_stamp_status(sec_data, code_sha, require_zero_findings=True)

    return {
        "schemaVersion": CACHE_SCHEMA_VERSION,
        "computedAt": utc_now_iso(),
        "headOid": head_oid,
        "branch": branch,
        "slug": slug,
        "codeTreeSha": code_sha,
        "canonStampStatus": canon_status,
        "canonStampValid": canon_status == "fresh",
        "canonStampSha": canon_sha,
        "securityStampStatus": sec_status,
        "securityStampValid": sec_status == "fresh",
        "securityStampSha": sec_sha,
        "prAuditPending": isinstance(pending_data, dict),
    }


def verify_pr_stamps(workspace: Path) -> tuple[bool, str]:
    """Verify canon-pass.json and security-pass.json against live HEAD codeTreeSha."""
    live_head = get_head_oid(workspace)
    if live_head == "UNBORN":
        return False, "Error: verify-pr-stamps failed: repository HEAD is UNBORN (no commits found)"

    current_sha = compute_code_tree_sha(workspace)

    if current_sha == "UNBORN":
        return False, "Error: verify-pr-stamps failed: repository HEAD is UNBORN (no commits found)"

    state_dir = get_state_dir(workspace)
    canon_file = state_dir / "canon-pass.json"
    security_file = state_dir / "security-pass.json"

    if not canon_file.is_file():
        return False, f"Error: verify-pr-stamps failed: missing canon stamp ({canon_file})"
    if not security_file.is_file():
        return False, f"Error: verify-pr-stamps failed: missing security stamp ({security_file})"

    canon_data = read_json_file(canon_file) or {}
    canon_verdict = str(canon_data.get("verdict", ""))
    canon_sha = str(canon_data.get("codeTreeSha", ""))
    if canon_verdict != "PASS":
        return False, f"Error: verify-pr-stamps failed: canon-pass.json verdict is '{canon_verdict}' (expected PASS)"
    if canon_sha != current_sha:
        return (
            False,
            f"Error: verify-pr-stamps failed: canon-pass.json codeTreeSha ({canon_sha}) does not match current HEAD codeTreeSha ({current_sha})",
        )

    sec_data = read_json_file(security_file) or {}
    sec_verdict = str(sec_data.get("verdict", ""))
    sec_sha = str(sec_data.get("codeTreeSha", ""))
    if sec_verdict != "PASS":
        return False, f"Error: verify-pr-stamps failed: security-pass.json verdict is '{sec_verdict}' (expected PASS)"
    if sec_data.get("criticalCount") != 0 or sec_data.get("importantCount") != 0:
        return False, "Error: verify-pr-stamps failed: security-pass.json has non-zero criticalCount or importantCount"
    if sec_sha != current_sha:
        return (
            False,
            f"Error: verify-pr-stamps failed: security-pass.json codeTreeSha ({sec_sha}) does not match current HEAD codeTreeSha ({current_sha})",
        )

    return True, ""


def classify_parent_model(raw: str) -> str:
    """Classify parent modelName into canonical routing family."""
    trimmed = re.sub(r"\s+", "", raw or "")
    if not trimmed:
        return "unset"
    norm = (raw or "").lower()
    if "orchestrator" in norm or norm == "auto":
        return "orchestrator"
    if "carbon" in norm:
        return "carbon"
    if "argon" in norm:
        if norm.endswith("-low") or "(low)" in norm or " low" in norm:
            return "argon_low"
        return "argon"
    if "hydrogen" in norm:
        return "hydrogen"
    if any(tok in norm for tok in ("claude", "opus", "sonnet")):
        return "claude"
    if "flash" in norm or "gpt-oss" in norm:
        return "flash"
    return "custom"


def _resolve_base_branch(workspace: Path) -> str:
    """Resolve base integration branch matching pre-command-guard Gate 4 order."""
    for candidate in ("origin/main", "origin/master", "refs/heads/main", "refs/heads/master"):
        res = _run_git(workspace, ["rev-parse", "--verify", "--quiet", candidate])
        if res.returncode == 0:
            if candidate == "refs/heads/main":
                return "main"
            if candidate == "refs/heads/master":
                return "master"
            return candidate
    return ""


def _resolve_rel_path(workspace: Path, raw_path: str) -> tuple[str, bool]:
    """Resolve hook target path relative to ``workspace``.

    Returns ``(rel_path, is_external)``. Paths outside ``workspace`` or
    escaping via ``..`` return ``("", True)``.
    """
    target_path = os.path.normpath(os.path.expanduser(raw_path))
    ws_root = os.path.normpath(str(workspace))
    try:
        real_ws = os.path.realpath(ws_root) if os.path.isdir(ws_root) else ws_root
    except OSError:
        real_ws = ws_root

    if target_path.startswith("/"):
        try:
            real_target = os.path.realpath(target_path)
        except OSError:
            real_target = target_path
        if real_ws and real_target.startswith(real_ws + "/"):
            rel_path = real_target[len(real_ws) + 1 :]
        elif target_path.startswith(ws_root + "/"):
            rel_path = target_path[len(ws_root) + 1 :]
        elif real_target == real_ws or target_path == ws_root:
            rel_path = ""
        else:
            return "", True
    else:
        rel_norm = os.path.normpath(target_path)
        if rel_norm == ".." or rel_norm.startswith("../"):
            return "", True
        joined = os.path.join(real_ws or ws_root, "" if rel_norm == "." else rel_norm)
        try:
            real_joined = os.path.realpath(joined)
        except OSError:
            real_joined = joined
        if real_ws and real_joined.startswith(real_ws + "/"):
            rel_path = real_joined[len(real_ws) + 1 :]
        elif real_joined == real_ws:
            rel_path = ""
        else:
            return "", True

    while rel_path.startswith("./"):
        rel_path = rel_path[2:]
    return rel_path, False


def evaluate_pre_edit(workspace: Path, hook_input: dict[str, Any]) -> dict[str, Any]:
    """Evaluate write_file / edit_file PreToolUse rules deterministically."""
    if is_harness_ignored(workspace):
        return {"decision": "allow"}

    tool_call = hook_input.get("toolCall") if isinstance(hook_input.get("toolCall"), dict) else {}
    tool_name = str(tool_call.get("name") or "")
    args = tool_call.get("args") if isinstance(tool_call.get("args"), dict) else {}
    file_path = str(args.get("Path") or "")

    if tool_name not in ("write_file", "edit_file") or not file_path:
        return {"decision": "allow"}

    rel_path, is_external = _resolve_rel_path(workspace, file_path)
    if is_external:
        return {"decision": "allow"}

    if rel_path == ".superpowers" or rel_path.startswith(".superpowers/") or rel_path == ".harness" or rel_path.startswith(".harness/"):
        return {"decision": "allow"}

    # Rule 1: main/master lock when HEAD exists
    branch = get_branch_name(workspace)
    if branch in ("main", "master") and get_head_oid(workspace) != "UNBORN":
        if not (rel_path.startswith("docs/superpowers/specs/") or rel_path.startswith("docs/canon/")):
            return {
                "decision": "deny",
                "reason": (
                    f"Direct writes to workspace file '{rel_path}' are locked on branch '{branch}'. "
                    "Feature development must occur in a feature branch or worktree "
                    "(only docs/superpowers/specs/* and docs/canon/* may be drafted on main/master)."
                ),
            }

    append_val = args.get("Append", False)
    is_append = str(append_val).lower() == "true" if not isinstance(append_val, bool) else append_val
    content = str(args.get("Content") or "")
    replacement = str(args.get("Replacement") or "")

    # Rule 2: Technical Glossary gate on documentation creation
    if tool_name == "write_file" and not is_append:
        is_doc = (rel_path == "README.md") or (rel_path.startswith("docs/") and rel_path.endswith(".md"))
        if rel_path in ("docs/canon/glossary.md", "docs/parking-lot.md"):
            is_doc = False
        if is_doc and not has_glossary_section(content):
            return {
                "decision": "deny",
                "reason": f"Documentation file '{rel_path}' must end with a non-empty '## Teknik Terimler Sözlüğü' or '## Technical Glossary' table or section.",
            }

    # Rule 3: Dangerous patterns in production code
    if rel_path.startswith("docs/") or rel_path.startswith("tests/") or rel_path == "README.md":
        return {"decision": "allow"}

    text_to_check = content if tool_name == "write_file" else replacement

    if PRIVATE_KEY_RE.search(text_to_check):
        return {"decision": "deny", "reason": "Plain private key detected in code; secrets must never be committed."}
    if EVAL_CALL_RE.search(text_to_check):
        return {"decision": "deny", "reason": "Dangerous eval() function call detected in production code."}
    if "dangerouslySetInnerHTML" in text_to_check:
        return {"decision": "deny", "reason": "dangerouslySetInnerHTML detected; potential XSS vulnerability."}
    if SQL_CONCAT_RE.search(text_to_check):
        return {"decision": "deny", "reason": "Raw SQL string concatenation detected; use parameterized queries."}
    if "bypassSecurityTrust" in text_to_check:
        return {
            "decision": "force_ask",
            "reason": "Angular bypassSecurityTrust pattern detected; requires explicit confirmation.",
        }

    return {"decision": "allow"}


def _extract_git_subcommand(seg: list[str]) -> str:
    """Extract the git subcommand skipping global options taking arguments."""
    skip_next = False
    for tok in seg[1:]:
        if skip_next:
            skip_next = False
            continue
        if tok in ("-C", "-c", "--git-dir", "--work-tree"):
            skip_next = True
            continue
        if tok.startswith("-"):
            continue
        return tok
    return ""


def _check_pkg_in_specs_with_index(workspace: Path, pkg: str, spec_index: Optional[dict[str, Any]] = None) -> bool:
    """Verify package declaration in spec ``## Global Constraints`` checking mtime before trusting cache."""
    specs_dir = workspace / "docs" / "superpowers" / "specs"
    if not specs_dir.is_dir():
        return False

    pat = re.compile(r"(?:^|[^A-Za-z0-9_./@-])" + re.escape(pkg) + r"(?:$|@[0-9^~>=<]|[^A-Za-z0-9_./@-])")
    cached_specs = spec_index.get("specs", {}) if isinstance(spec_index, dict) else {}

    for spec_path in sorted(specs_dir.glob("*.md")):
        if not spec_path.is_file():
            continue
        rel = f"docs/superpowers/specs/{spec_path.name}"
        cached = cached_specs.get(rel)
        section = ""
        try:
            st = spec_path.stat()
            if isinstance(cached, dict) and cached.get("mtimeNs") == st.st_mtime_ns and cached.get("size") == st.st_size:
                section = str(cached.get("sectionText") or "")
            else:
                section = extract_global_constraints_section(spec_path.read_text(encoding="utf-8", errors="ignore"))
        except OSError:
            continue
        if section and pat.search(section):
            return True
    return False


def evaluate_pre_command(
    workspace: Path,
    hook_input: dict[str, Any],
    spec_index: Optional[dict[str, Any]] = None,
    doc_cache: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """Evaluate all 4 PreToolUse command gates deterministically."""
    if is_harness_ignored(workspace):
        return {"decision": "allow"}

    tool_call = hook_input.get("toolCall") if isinstance(hook_input.get("toolCall"), dict) else {}
    if str(tool_call.get("name") or "") != "run_command":
        return {"decision": "allow"}

    args = tool_call.get("args") if isinstance(tool_call.get("args"), dict) else {}
    cmd_line = str(args.get("CommandLine") or "")
    if not cmd_line:
        return {"decision": "allow"}

    segments = parse_command_segments(cmd_line)
    if not segments:
        return {"decision": "allow"}

    active_branch = get_branch_name(workspace)
    rem_res = _run_git(workspace, ["remote"])
    remotes = rem_res.stdout.strip() if rem_res.returncode == 0 else ""
    state_dir = get_state_dir(workspace)

    for seg in segments:
        if not seg:
            continue
        exe_base = os.path.basename(seg[0])

        # Gate 1: Infinite mobile log stream block
        if exe_base == "adb" and "logcat" in seg:
            has_d = any(tok == "-d" or re.match(r"^-[a-zA-Z]*d[a-zA-Z]*$", tok) for tok in seg)
            if not has_d:
                return {
                    "decision": "deny",
                    "reason": "Infinite mobile log stream blocked: 'adb logcat' without '-d' runs indefinitely. Use 'adb logcat -d' for snapshots or use scripts/mobile-logs.sh.",
                }
        elif exe_base == "simctl" or (exe_base == "xcrun" and "simctl" in seg):
            log_idx = seg.index("log") if "log" in seg else None
            stream_idx = seg.index("stream") if "stream" in seg else None
            if log_idx is not None and stream_idx is not None and log_idx < stream_idx:
                has_bound = any(re.match(r"^--(timeout|last)(=.*)?$", tok) for tok in seg)
                if not has_bound:
                    return {
                        "decision": "deny",
                        "reason": "Infinite mobile log stream blocked: 'simctl log stream' without '--timeout' or '--last' runs indefinitely. Bound the stream or use scripts/mobile-logs.sh.",
                    }

        # Gate 2: PR-only main/master guard
        if exe_base == "git":
            git_subcmd = _extract_git_subcommand(seg)
            if git_subcmd == "push":
                push_idx = seg.index("push") if "push" in seg else -1
                if push_idx >= 0:
                    pos = [t for t in seg[push_idx + 1 :] if not t.startswith("-")]
                    targets_main = "ok"
                    if len(pos) == 0:
                        targets_main = "bare"
                    elif len(pos) == 1:
                        targets_main = "remote_only"
                    else:
                        for refspec in pos[1:]:
                            dest = refspec.split(":", 1)[1] if ":" in refspec else refspec
                            dest = re.sub(r"^refs/heads/", "", dest)
                            if dest in ("main", "master"):
                                targets_main = "targets_main"
                                break

                    if remotes:
                        if targets_main == "targets_main":
                            return {
                                "decision": "deny",
                                "reason": "Direct push to main/master is blocked. Pull requests are required for main/master.",
                            }
                        if targets_main in ("bare", "remote_only") and active_branch in ("main", "master"):
                            return {
                                "decision": "deny",
                                "reason": "Direct push to main/master is blocked. Pull requests are required for main/master.",
                            }
            elif git_subcmd == "merge" and active_branch in ("main", "master"):
                if "--ff-only" not in seg:
                    if remotes:
                        return {
                            "decision": "deny",
                            "reason": "Direct git merge into main/master is blocked when a remote is configured. Pull requests are required.",
                        }
                    merge_idx = seg.index("merge") if "merge" in seg else -1
                    pos = [t for t in seg[merge_idx + 1 :] if not t.startswith("-")] if merge_idx >= 0 else []
                    target_branch = pos[0] if pos else ""
                    if target_branch:
                        mb_res = _run_git(workspace, ["merge-base", "HEAD", target_branch])
                        merge_base = mb_res.stdout.strip() if mb_res.returncode == 0 else "HEAD"
                        diff_res = _run_git(workspace, ["diff", "--name-only", "--diff-filter=ACMR", f"{merge_base}..{target_branch}"])
                        all_res = _run_git(workspace, ["diff", "--name-only", f"{merge_base}..{target_branch}"])
                        diff_files = [l for l in diff_res.stdout.splitlines() if l.strip()]
                        all_merge_diff = [l for l in all_res.stdout.splitlines() if l.strip()]

                        walkthrough_found = False
                        has_any_wt = False
                        wt_err = ""
                        for f in diff_files:
                            if f.startswith("docs/walkthroughs/") and f.endswith(".md"):
                                has_any_wt = True
                                show_res = _run_git(workspace, ["show", f"{target_branch}:{f}"])
                                wt_content = show_res.stdout if show_res.returncode == 0 else ""
                                ok, err = validate_walkthrough(wt_content, all_merge_diff)
                                if ok:
                                    walkthrough_found = True
                                    break
                                wt_err = err
                        if not walkthrough_found:
                            if not has_any_wt:
                                return {
                                    "decision": "deny",
                                    "reason": "Local merge into main requires a walkthrough in docs/walkthroughs/*.md covering every changed file.",
                                }
                            return {"decision": "deny", "reason": f"Local merge into main blocked: {wt_err}"}

                        for f in diff_files:
                            if f in ("docs/canon/glossary.md", "docs/parking-lot.md"):
                                continue
                            if f == "README.md" or (f.startswith("docs/") and f.endswith(".md")):
                                show_doc = _run_git(workspace, ["show", f"{target_branch}:{f}"])
                                doc_content = show_doc.stdout if show_doc.returncode == 0 else ""
                                if not has_glossary_section(doc_content):
                                    return {
                                        "decision": "deny",
                                        "reason": f"Local merge documentation file '{f}' is missing a valid Technical Glossary section",
                                    }

                        target_slug = slugify_branch(target_branch)
                        target_state_dir = workspace / ".harness" / "state" / target_slug
                        target_tree_sha = compute_code_tree_sha(workspace, target_branch)

                        canon_path = target_state_dir / "canon-pass.json"
                        sec_path = target_state_dir / "security-pass.json"
                        if not canon_path.is_file() or not sec_path.is_file():
                            return {
                                "decision": "deny",
                                "reason": f"Local merge requires valid canon-pass.json and security-pass.json under .harness/state/{target_slug}",
                            }

                        canon_data = read_json_file(canon_path) or {}
                        sec_data = read_json_file(sec_path) or {}
                        if (
                            canon_data.get("verdict") != "PASS"
                            or canon_data.get("codeTreeSha") != target_tree_sha
                            or sec_data.get("verdict") != "PASS"
                            or sec_data.get("codeTreeSha") != target_tree_sha
                        ):
                            return {
                                "decision": "deny",
                                "reason": f"Local merge stamps for '{target_branch}' do not match target branch codeTreeSha ({target_tree_sha}) or verdict is not PASS",
                            }

        # Gate 3: Package install verification
        pkgs = extract_install_packages(seg)
        if pkgs:
            verified_data = read_json_file(state_dir / "context7-verified.json") or {}
            verified_pkgs = verified_data.get("packages") if isinstance(verified_data.get("packages"), dict) else {}
            unverified: list[str] = []
            for pkg in pkgs:
                if verified_pkgs.get(pkg) is not None:
                    continue
                if _check_pkg_in_specs_with_index(workspace, pkg, spec_index=spec_index):
                    continue
                unverified.append(pkg)
            if unverified:
                return {
                    "decision": "deny",
                    "reason": (
                        f"Package install blocked: unverified package(s): {' '.join(unverified)}. "
                        "Verify versions using dependency-versions / context7 before installing. "
                        "Run: stamp-gate.sh context7 --package <pkg> --version <ver> --source <locked|greenfield-latest>"
                    ),
                }

        # Gate 4: 5-point hard PR gate (gh pr create)
        if exe_base == "gh":
            pr_idx = seg.index("pr") if "pr" in seg else None
            create_idx = seg.index("create") if "create" in seg else None
            if pr_idx is not None and create_idx is not None and create_idx == pr_idx + 1:
                base = _resolve_base_branch(workspace)
                if not base:
                    return {
                        "decision": "deny",
                        "reason": "PR creation blocked: cannot resolve base branch (origin/main, origin/master, main, master)",
                    }
                if active_branch in ("main", "master"):
                    return {
                        "decision": "deny",
                        "reason": "PR creation blocked: pull requests cannot be opened from main/master branch",
                    }
                st_res = _run_git(workspace, ["status", "--porcelain"])
                if st_res.stdout.strip():
                    return {
                        "decision": "deny",
                        "reason": "PR creation blocked: working tree is dirty. Commit or stash all changes before creating PR.",
                    }

                mb_res = _run_git(workspace, ["merge-base", base, "HEAD"])
                merge_base = mb_res.stdout.strip() if mb_res.returncode == 0 else base
                diff_key = f"{merge_base}..{get_head_oid(workspace)}"
                diff_res = _run_git(workspace, ["diff", "--name-only", "--diff-filter=ACMR", f"{merge_base}..HEAD"])
                all_res = _run_git(workspace, ["diff", "--name-only", f"{merge_base}..HEAD"])
                diff_files = [l for l in diff_res.stdout.splitlines() if l.strip()]
                all_diff = [l for l in all_res.stdout.splitlines() if l.strip()]

                walkthrough_found = False
                has_any_wt = False
                wt_err = ""
                cached_docs = doc_cache.get("docs", {}) if isinstance(doc_cache, dict) else {}

                for f in diff_files:
                    if f.startswith("docs/walkthroughs/") and f.endswith(".md"):
                        has_any_wt = True
                        wt_path = workspace / f
                        if wt_path.is_file():
                            try:
                                fst = wt_path.stat()
                                c_entry = cached_docs.get(f)
                                if (
                                    isinstance(c_entry, dict)
                                    and c_entry.get("mtimeNs") == fst.st_mtime_ns
                                    and c_entry.get("size") == fst.st_size
                                    and c_entry.get("diffKey") == diff_key
                                ):
                                    ok = bool(c_entry.get("walkthroughValid"))
                                    err = str(c_entry.get("walkthroughError") or "")
                                else:
                                    ok, err = validate_walkthrough(
                                        wt_path.read_text(encoding="utf-8", errors="ignore"), all_diff
                                    )
                            except OSError:
                                ok, err = False, "Unable to read walkthrough file."
                            if ok:
                                walkthrough_found = True
                                break
                            wt_err = err

                if not walkthrough_found:
                    if not has_any_wt:
                        return {
                            "decision": "deny",
                            "reason": "PR creation blocked: missing walkthrough. PR diff must include at least one docs/walkthroughs/*.md file.",
                        }
                    return {"decision": "deny", "reason": f"PR creation blocked: {wt_err}"}

                for f in diff_files:
                    if f in ("docs/canon/glossary.md", "docs/parking-lot.md"):
                        continue
                    if f == "README.md" or (f.startswith("docs/") and f.endswith(".md")):
                        doc_path = workspace / f
                        if doc_path.is_file():
                            try:
                                fst = doc_path.stat()
                                c_entry = cached_docs.get(f)
                                if (
                                    isinstance(c_entry, dict)
                                    and c_entry.get("mtimeNs") == fst.st_mtime_ns
                                    and c_entry.get("size") == fst.st_size
                                    and "hasGlossary" in c_entry
                                ):
                                    ok_glossary = bool(c_entry["hasGlossary"])
                                else:
                                    ok_glossary = has_glossary_section(
                                        doc_path.read_text(encoding="utf-8", errors="ignore")
                                    )
                            except OSError:
                                ok_glossary = False
                            if not ok_glossary:
                                return {
                                    "decision": "deny",
                                    "reason": f"PR creation blocked: documentation file '{f}' is missing a valid Technical Glossary / Teknik Terimler Sözlüğü section.",
                                }

                stamps_ok, verify_err = verify_pr_stamps(workspace)
                if not stamps_ok:
                    return {
                        "decision": "deny",
                        "reason": f"PR creation blocked: PR stamps verification failed: {verify_err}",
                    }

                canon_data = read_json_file(state_dir / "canon-pass.json") or {}
                allowed_files = canon_data.get("allowedFiles")
                if isinstance(allowed_files, list) and len(allowed_files) > 0:
                    allowed_set = set(str(x) for x in allowed_files)
                    base_diff_res = _run_git(workspace, ["diff", "--name-only", f"{base}..HEAD"])
                    for f in [l for l in base_diff_res.stdout.splitlines() if l.strip()]:
                        if (
                            f.startswith("docs/superpowers/")
                            or f.startswith("docs/canon/")
                            or f.startswith("docs/walkthroughs/")
                            or f == "docs/parking-lot.md"
                        ):
                            continue
                        if f not in allowed_set:
                            return {
                                "decision": "deny",
                                "reason": f"PR creation blocked: file '{f}' is not in allowedFiles list in canon-pass.json and not an allowed documentation path.",
                            }

    return {"decision": "allow"}


def run_sync_graphify(workspace: Path) -> int:
    """Run incremental graphify update synchronously and log to ``.harness/logs/graphify-hook.log``."""
    graphify_out = workspace / "graphify-out"
    if not graphify_out.is_dir():
        return 0
    log_dir = workspace / ".harness" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "graphify-hook.log"

    local_py = graphify_out / ".graphify_python"
    if local_py.is_file() and os.access(local_py, os.X_OK):
        cmd = [str(local_py), "-m", "graphify", "--update", "--no-viz"]
    else:
        graphify_bin = os.environ.get("HARNESS_GRAPHIFY_BIN", "graphify")
        cmd = [graphify_bin, "--update", "--no-viz"]

    timeout_sec = max(1, int(os.environ.get("HARNESS_GRAPHIFY_TIMEOUT_SEC", "120")))
    try:
        with open(log_file, "a", encoding="utf-8") as lf:
            proc = subprocess.run(cmd, cwd=str(workspace), stdout=lf, stderr=subprocess.STDOUT, timeout=timeout_sec)
        return proc.returncode
    except Exception as exc:
        try:
            with open(log_file, "a", encoding="utf-8") as lf:
                lf.write(f"graphify invocation failed: {exc}\n")
        except OSError:
            pass
        return 1


def evaluate_post_command(
    workspace: Path,
    hook_input: dict[str, Any],
    on_graphify_trigger: Optional[Callable[[Path, str], None]] = None,
) -> dict[str, Any]:
    """Handle PostToolUse automation: set pr-audit-pending and trigger/queue graphify updates."""
    if is_harness_ignored(workspace):
        return {}

    tool_call = hook_input.get("toolCall") if isinstance(hook_input.get("toolCall"), dict) else {}
    if str(tool_call.get("name") or "") != "run_command":
        return {}

    has_error = hook_input.get("error")
    if not has_error and isinstance(hook_input.get("toolOutput"), dict):
        has_error = hook_input["toolOutput"].get("error")
    if not has_error:
        has_error = hook_input.get("toolError")
    if has_error:
        return {}

    args = tool_call.get("args") if isinstance(tool_call.get("args"), dict) else {}
    cmd_line = str(args.get("CommandLine") or "")
    if not cmd_line:
        return {}

    segments = parse_command_segments(cmd_line)
    if not segments:
        return {}

    active_branch = get_branch_name(workspace)
    trigger_fn = on_graphify_trigger or (lambda ws, _reason: run_sync_graphify(ws))

    for seg in segments:
        if not seg:
            continue
        exe_base = os.path.basename(seg[0])

        if exe_base == "gh":
            pr_idx = seg.index("pr") if "pr" in seg else None
            create_idx = seg.index("create") if "create" in seg else None
            if pr_idx is not None and create_idx is not None and create_idx == pr_idx + 1:
                tool_output = hook_input.get("toolOutput")
                if isinstance(tool_output, dict):
                    if "output" in tool_output and tool_output["output"] is not None:
                        raw_out = str(tool_output["output"])
                    else:
                        raw_out = json.dumps(tool_output)
                elif tool_output is not None:
                    raw_out = str(tool_output)
                else:
                    raw_out = str(hook_input.get("output") or "")
                m_url = re.search(r"https?://[^ ]+/pull/[0-9]+", raw_out)
                pr_url = m_url.group(0) if m_url else raw_out.replace("\n", "").rstrip()
                state_dir = get_state_dir(workspace)
                atomic_write_json(
                    state_dir,
                    "pr-audit-pending.json",
                    {"prUrl": pr_url, "stopRetries": 0, "auditDispatched": False},
                )

            merge_idx = seg.index("merge") if "merge" in seg else None
            if pr_idx is not None and merge_idx is not None and merge_idx == pr_idx + 1:
                trigger_fn(workspace, "gh_pr_merge")

        elif exe_base == "git":
            git_subcmd = _extract_git_subcommand(seg)
            if active_branch in ("main", "master") and git_subcmd in ("merge", "pull"):
                trigger_fn(workspace, f"git_{git_subcmd}")

    return {}


def detect_mobile_workspace(workspace: Path) -> tuple[bool, bool]:
    """Single-pass pruned walk detecting iOS and Android project files in ``workspace``."""
    has_ios = False
    has_android = False
    skip_dirs = {".git", ".harness", "node_modules", ".worktrees", "__pycache__"}

    for root, dirs, files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for d in dirs:
            if d.endswith(".xcodeproj") or d.endswith(".xcworkspace"):
                has_ios = True
        for f in files:
            if f in ("Podfile", "Package.swift"):
                has_ios = True
            elif f in ("build.gradle", "build.gradle.kts", "AndroidManifest.xml"):
                has_android = True
        if has_ios and has_android:
            break
    return has_ios, has_android


def extract_ios_bundle_identifiers(workspace: Path) -> list[str]:
    """Extract literal bundle IDs and app names from Xcode project and Info.plist files."""
    candidates: list[str] = []
    seen: set[str] = set()
    skip_dirs = {".git", ".harness", "node_modules", ".worktrees", "Pods", "DerivedData"}

    def add_candidate(val: str) -> None:
        cleaned = val.strip()
        if not cleaned or "$(" in cleaned or "${" in cleaned:
            return
        if cleaned not in seen:
            seen.add(cleaned)
            candidates.append(cleaned)

    for root, dirs, files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for d in dirs:
            if d.endswith(".xcodeproj"):
                pbx = Path(root) / d / "project.pbxproj"
                if pbx.is_file():
                    try:
                        text = pbx.read_text(encoding="utf-8", errors="ignore")
                        for match in PBXPROJ_BUNDLE_RE.finditer(text):
                            add_candidate(match.group(1))
                    except OSError:
                        pass
        for f in files:
            if f == "Info.plist":
                plist_path = Path(root) / f
                try:
                    with open(plist_path, "rb") as fh:
                        plist = plistlib.load(fh)
                    if isinstance(plist, dict):
                        for key in ("CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName"):
                            v = plist.get(key)
                            if isinstance(v, str):
                                add_candidate(v)
                except Exception:
                    pass
    return candidates


def _matches_any_bundle_id(report_path: Path, identifiers: list[str]) -> bool:
    """Return True if ``report_path`` filename or header matches any identifier."""
    base_low = report_path.name.lower()
    head: Optional[str] = None
    for ident in identifiers:
        app_name = ident.split(".")[-1]
        if ident.lower() in base_low or app_name.lower() in base_low:
            return True
        if head is None:
            try:
                with open(report_path, "r", errors="replace") as fp:
                    head = fp.read(2048)
            except Exception:
                head = ""
        if ident in head or app_name in head:
            return True
    return False


def parse_ios_crash_report(
    diag_dir: Path,
    bundle_id: str = "",
    candidate_ids: Optional[list[str]] = None,
    allow_unmatched_fallback: bool = True,
) -> dict[str, Any]:
    """Find and summarize the newest matching ``.ips`` or ``.crash`` report in ``diag_dir``."""
    empty_res: dict[str, Any] = {
        "found": False,
        "reportName": "",
        "reportPath": "",
        "mtimeNs": 0,
        "lines": [],
    }
    if not diag_dir.is_dir():
        return empty_res

    files = list(diag_dir.glob("*.ips")) + list(diag_dir.glob("*.crash"))
    if not files:
        return empty_res

    try:
        files.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
    except OSError:
        return empty_res

    match_ids: list[str] = []
    if bundle_id:
        match_ids.append(bundle_id)
    if candidate_ids:
        for cid in candidate_ids:
            if cid and cid not in match_ids:
                match_ids.append(cid)

    target_file: Optional[Path] = None
    if match_ids:
        for fp in files:
            if _matches_any_bundle_id(fp, match_ids):
                target_file = fp
                break
        if target_file is None and allow_unmatched_fallback:
            target_file = files[0]
    elif allow_unmatched_fallback:
        target_file = files[0]

    if target_file is None:
        return empty_res

    try:
        st = target_file.stat()
        raw_content = target_file.read_text(errors="replace")
    except Exception:
        return empty_res

    out_lines: list[str] = [f"=== CRASH REPORT ({target_file.name}) ==="]
    lines = raw_content.splitlines()
    header: dict[str, Any] = {}
    body: Optional[dict[str, Any]] = None

    if lines and lines[0].strip().startswith("{"):
        try:
            parsed_hdr = json.loads(lines[0])
            if isinstance(parsed_hdr, dict):
                header = parsed_hdr
        except Exception:
            pass

    if len(lines) > 1 and lines[1].strip().startswith("{"):
        try:
            parsed_body = json.loads("\n".join(lines[1:]))
            if isinstance(parsed_body, dict):
                body = parsed_body
        except Exception:
            pass

    if body is None:
        try:
            parsed_all = json.loads(raw_content)
            if isinstance(parsed_all, dict):
                body = parsed_all
        except Exception:
            pass

    if body is not None:
        proc = header.get("app_name") or body.get("procName") or body.get("process")
        bid = header.get("bundleID") or body.get("bundleID")
        if proc:
            out_lines.append(f"Process: {proc}")
        if bid:
            out_lines.append(f"Bundle ID: {bid}")

        exc = body.get("exception", {})
        if isinstance(exc, dict):
            exc_type = exc.get("type", "")
            exc_signal = exc.get("signal", "")
            if exc_type or exc_signal:
                out_lines.append(f"Exception: {exc_type} ({exc_signal})")

        term = body.get("termination", {})
        if isinstance(term, dict):
            ns = term.get("namespace", "")
            code = term.get("code", "")
            ind = term.get("indicator", "")
            out_lines.append(f"Termination: {ns} code={code} {ind}".strip())

        threads = body.get("threads", [])
        crashed_thread = None
        if isinstance(threads, list):
            for t in threads:
                if isinstance(t, dict) and t.get("triggered", False):
                    crashed_thread = t
                    break
            if not crashed_thread and threads:
                crashed_thread = threads[0]

        if isinstance(crashed_thread, dict):
            t_id = crashed_thread.get("id") or crashed_thread.get("name") or "0"
            out_lines.append(f"Crashed Thread: {t_id}")
            frames = crashed_thread.get("frames", [])
            if isinstance(frames, list):
                for i, fr in enumerate(frames[:25]):
                    if not isinstance(fr, dict):
                        continue
                    offset = fr.get("imageOffset", 0)
                    sym = fr.get("symbol") or fr.get("binary") or f"0x{offset:x}"
                    loc = fr.get("symbolLocation")
                    loc_str = f" + {loc}" if loc is not None else ""
                    out_lines.append(f"  #{i:02d} {sym}{loc_str}")
    else:
        for line in lines[:80]:
            if any(line.startswith(k) for k in ("Process:", "Identifier:", "Exception", "Termination", "Thread ")) or "Crashed:" in line:
                out_lines.append(line)

    return {
        "found": True,
        "reportName": target_file.name,
        "reportPath": str(target_file),
        "mtimeNs": st.st_mtime_ns,
        "lines": out_lines,
    }


def _extract_yaml_frontmatter(path: Path) -> Optional[str]:
    """Return YAML frontmatter block text if ``path`` begins with ``---`` delimiters."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return "\n".join(lines[1:idx])
    return None


def _parse_frontmatter_tools(fm: str) -> list[str]:
    """Parse ``tools:`` inline array or YAML list items from subagent frontmatter."""
    tools: list[str] = []
    fm_lines = fm.splitlines()
    for i, line in enumerate(fm_lines):
        m_inline = re.match(r"^\s*tools:\s*\[(.*?)\]\s*(?:#.*)?$", line)
        if m_inline:
            tools.extend(item.strip().strip("\"'") for item in m_inline.group(1).split(",") if item.strip())
            break
        if re.match(r"^\s*tools:\s*(?:#.*)?$", line):
            j = i + 1
            while j < len(fm_lines):
                stripped_item = re.sub(r"\s+#.*$", "", fm_lines[j])
                m_item = re.match(r"^\s*-\s*(.+?)\s*$", stripped_item)
                if m_item:
                    tools.append(m_item.group(1).strip().strip("\"'"))
                    j += 1
                elif not fm_lines[j].strip() or fm_lines[j].lstrip().startswith("#"):
                    j += 1
                else:
                    break
            break
    return tools


def is_safe_socket_path(sock: Path) -> bool:
    """Verify socket and parent dir are non-symlinks, UID-owned, and 0700-restricted."""
    try:
        sock_dir = sock.parent
        dir_st = os.lstat(sock_dir)
        if stat.S_ISLNK(dir_st.st_mode) or not stat.S_ISDIR(dir_st.st_mode):
            return False
        if dir_st.st_uid != os.getuid() or (stat.S_IMODE(dir_st.st_mode) & 0o077) != 0:
            return False

        sock_st = os.lstat(sock)
        if stat.S_ISLNK(sock_st.st_mode) or not stat.S_ISSOCK(sock_st.st_mode):
            return False
        if sock_st.st_uid != os.getuid():
            return False
        return True
    except OSError:
        return False


def probe_daemon_health(sock_path: Optional[Path] = None, timeout_sec: float = DEFAULT_DAEMON_TIMEOUT_SEC) -> tuple[bool, Optional[dict[str, Any]]]:
    """Query ``GET /health`` over the Unix domain socket if present, safe, and non-disabled."""
    if os.environ.get("HARNESS_DISABLE_DAEMON") == "1":
        return False, None
    sock = sock_path or default_socket_path()
    if not is_safe_socket_path(sock):
        return False, None

    conn = None
    try:
        class _UnixConn(http.client.HTTPConnection):
            def connect(self) -> None:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(timeout_sec)
                s.connect(str(sock))
                self.sock = s

        conn = _UnixConn("localhost", timeout=timeout_sec)
        conn.request("GET", "/health")
        resp = conn.getresponse()
        if resp.status != 200:
            return False, None
        data = json.loads(resp.read().decode("utf-8"))
        if isinstance(data, dict) and data.get("status") == "ok":
            return True, data
        return False, None
    except Exception:
        return False, None
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def run_doctor_checks(
    workspace: Path,
    config_dir: Optional[Path] = None,
    typesafe_key_file: Optional[Path] = None,
    gh_bin: Optional[str] = None,
    xcrun_bin: Optional[str] = None,
    adb_bin: Optional[str] = None,
    harness_root: Optional[Path] = None,
    env_key_present: Optional[bool] = None,
    scrub_env: bool = True,
    probe_daemon: bool = True,
) -> dict[str, Any]:
    """Run all environment, plugin, MCP, zero-secret-leakage key, LSP, mobile, and daemon checks."""
    cfg_dir = config_dir or Path(os.environ.get("HARNESS_CONFIG_DIR") or (Path.home() / ".gemini" / "config"))
    key_file = typesafe_key_file or Path(os.environ.get("HARNESS_TYPESAFE_KEY_FILE") or (Path.home() / ".config" / "typesafe" / "key"))
    gh_cmd = gh_bin or os.environ.get("HARNESS_GH_BIN") or "gh"
    xcrun_cmd = xcrun_bin or os.environ.get("HARNESS_XCRUN_BIN") or "xcrun"
    adb_cmd = adb_bin or os.environ.get("HARNESS_ADB_BIN") or "adb"
    h_root = harness_root or PLUGIN_ROOT

    raw_env_key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    has_env_key = bool(raw_env_key) and not (raw_env_key.startswith("<") and raw_env_key.endswith(">"))
    if env_key_present is not None:
        has_env_key = has_env_key or bool(env_key_present)
    del raw_env_key
    if scrub_env and "TYPESAFE_API_KEY" in os.environ:
        os.environ["TYPESAFE_API_KEY"] = ""

    checks: list[dict[str, Any]] = []

    def add_check(
        name: str,
        group: str,
        status: str,
        message: str,
        fix: Optional[str] = None,
        extra: Optional[dict[str, Any]] = None,
    ) -> None:
        if fix:
            fix_clean = fix.strip()
            fix = fix_clean if fix_clean.startswith("Fix:") else f"Fix: {fix_clean}"
        c: dict[str, Any] = {
            "name": name,
            "group": group,
            "status": status,
            "message": message,
            "fix": fix,
        }
        if extra:
            c.update(extra)
        checks.append(c)

    def _safe_cmd_run(cmd: list[str], timeout_sec: float = 10.0) -> Optional[subprocess.CompletedProcess[str]]:
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
        except Exception:
            return None

    # 1. CLI Tools & GitHub Auth
    if shutil.which("git"):
        res = _safe_cmd_run(["git", "--version"])
        add_check("git", "cli", "OK" if res else "FAIL", res.stdout.strip() if res else "git --version timed out")
    else:
        add_check("git", "cli", "FAIL", "git is not installed", "brew install git")

    if shutil.which("jq"):
        res = _safe_cmd_run(["jq", "--version"])
        add_check("jq", "cli", "OK" if res else "FAIL", f"jq {res.stdout.strip()}" if res else "jq --version timed out")
    else:
        add_check("jq", "cli", "FAIL", "jq is not installed", "brew install jq")

    node_path = shutil.which("node")
    if node_path:
        res = _safe_cmd_run([node_path, "-v"])
        v = res.stdout.strip() if res else ""
        try:
            major = int(v.lstrip("v").split(".")[0])
            if major >= 20:
                add_check("node", "cli", "OK", f"Node.js {v} (>= 20)")
            else:
                add_check("node", "cli", "FAIL", f"Node.js version {v} is older than required 20", "brew install node")
        except Exception:
            add_check("node", "cli", "FAIL", f"Could not parse Node.js version from {v}", "brew install node")
    else:
        add_check("node", "cli", "FAIL", "node is not installed", "brew install node")

    if shutil.which("python3"):
        res = _safe_cmd_run(["python3", "--version"])
        add_check("python3", "cli", "OK" if res else "FAIL", res.stdout.strip() if res else "python3 --version timed out")
    else:
        add_check("python3", "cli", "FAIL", "python3 is not installed", "brew install python")

    if shutil.which("uv"):
        res = _safe_cmd_run(["uv", "--version"])
        add_check("uv", "cli", "OK" if res else "FAIL", res.stdout.strip() if res else "uv --version timed out")
    else:
        add_check("uv", "cli", "FAIL", "uv is not installed", "curl -LsSf https://astral.sh/uv/install.sh | sh")

    gh_path = shutil.which(gh_cmd) or (gh_cmd if os.path.isabs(gh_cmd) and os.path.isfile(gh_cmd) else None)
    if gh_path:
        res = _safe_cmd_run([gh_path, "auth", "status"])
        if res is not None and res.returncode == 0:
            add_check("gh_auth", "cli", "OK", "GitHub CLI authenticated")
        else:
            add_check("gh_auth", "cli", "FAIL", "GitHub CLI not authenticated", "gh auth login")
    else:
        add_check("gh_auth", "cli", "FAIL", f"GitHub CLI ({gh_cmd}) not installed", "brew install gh")

    # 2. Plugin Dependencies
    def check_plugin(name: str) -> bool:
        if (cfg_dir / "plugins" / name).is_dir() or (workspace / ".agents" / "plugins" / name).is_dir():
            return True
        for base in (cfg_dir, workspace / ".agents"):
            for fn in ("plugins.json", "config.json"):
                fp = base / fn
                if fp.is_file():
                    try:
                        data = json.loads(fp.read_text(errors="replace"))
                        if isinstance(data, dict):
                            plugins_val = data.get("plugins")
                            if isinstance(plugins_val, dict) and name in plugins_val:
                                return True
                            if isinstance(plugins_val, list):
                                for p in plugins_val:
                                    if (isinstance(p, dict) and p.get("name") == name) or p == name:
                                        return True
                        elif isinstance(data, list) and name in data:
                            return True
                    except Exception:
                        pass
        return False

    plugins_to_check = [
        ("superpowers", "superpowers framework plugin", "git clone https://github.com/obra/superpowers.git ~/.gemini/config/plugins/superpowers"),
        ("firebase", "firebase marketplace plugin", "agy plugin install firebase"),
        ("postman", "postman marketplace plugin", "agy plugin install postman"),
        ("chrome-devtools-plugin", "chrome-devtools-plugin marketplace plugin", "agy plugin install chrome-devtools-plugin"),
    ]
    for p_name, p_desc, p_fix in plugins_to_check:
        if check_plugin(p_name):
            add_check(p_name, "plugins", "OK", f"Plugin {p_name} is installed")
        else:
            add_check(p_name, "plugins", "FAIL", f"Plugin {p_name} is missing ({p_desc})", f"Fix: {p_fix}")

    # 2b. Subagent frontmatter validation
    agent_dirs = [
        h_root / "agents",
        workspace / "agents",
        workspace / ".agents" / "agents",
    ]
    agent_dirs.extend(Path(p) for p in glob.glob(str(workspace / ".agents" / "plugins" / "*" / "agents")))
    agent_dirs.extend(Path(p) for p in glob.glob(str(cfg_dir / "plugins" / "*" / "agents")))

    seen_agent_files: set[str] = set()
    subagent_errors: list[str] = []
    checked_agent_count = 0

    for adir in agent_dirs:
        if not adir.is_dir():
            continue
        for fp in sorted(adir.glob("*.md")):
            real_fp = os.path.realpath(fp)
            if real_fp in seen_agent_files:
                continue
            seen_agent_files.add(real_fp)
            fm = _extract_yaml_frontmatter(fp)
            if fm is None:
                continue
            checked_agent_count += 1
            tools_list = _parse_frontmatter_tools(fm)
            if "call_mcp_tool" in tools_list:
                subagent_errors.append(f"{fp}: invalid builtin tool 'call_mcp_tool' in tools")
            if fp.name in AUDITOR_BASENAMES:
                if not re.search(r"^\s*inheritMcp:\s*true(?:\s+#.*)?\s*$", fm, re.MULTILINE):
                    subagent_errors.append(f"{fp}: missing 'inheritMcp: true' for MCP inheritance")

    if subagent_errors:
        add_check(
            "subagent_frontmatter",
            "plugins",
            "FAIL",
            "Invalid subagent frontmatter: " + "; ".join(subagent_errors),
            "Fix: Set inheritMcp: true and remove call_mcp_tool from tools: in agents/*.md frontmatter",
        )
    else:
        add_check(
            "subagent_frontmatter",
            "plugins",
            "OK",
            f"Validated {checked_agent_count} subagent definition(s) (inheritMcp: true, zero invalid call_mcp_tool)",
        )

    # 3. 8 Mandatory Global MCP Servers
    mcp_file = cfg_dir / "mcp_config.json"
    mcp_servers: dict[str, Any] = {}
    if mcp_file.is_file():
        try:
            mcp_data = json.loads(mcp_file.read_text(errors="replace"))
            if isinstance(mcp_data, dict) and isinstance(mcp_data.get("mcpServers"), dict):
                mcp_servers = mcp_data["mcpServers"]
        except Exception:
            pass

    mandatory_mcps = [
        ("jev", "Add jev to ~/.gemini/config/mcp_config.json with jev-mcp binary or command"),
        ("context7", "Add context7 to ~/.gemini/config/mcp_config.json: npx -y @upstash/context7-mcp"),
        ("csharp-lsp", "Add csharp-lsp to ~/.gemini/config/mcp_config.json"),
        ("typescript-lsp", "Add typescript-lsp to ~/.gemini/config/mcp_config.json"),
        ("playwright", "Add playwright to ~/.gemini/config/mcp_config.json: npx -y @playwright/mcp"),
        ("graphify", "Add graphify to ~/.gemini/config/mcp_config.json"),
        ("revenuecat", "Add revenuecat to ~/.gemini/config/mcp_config.json"),
        ("filesystem", "Add filesystem to ~/.gemini/config/mcp_config.json: npx -y @modelcontextprotocol/server-filesystem"),
    ]
    for mcp_name, mcp_fix in mandatory_mcps:
        if mcp_name in mcp_servers:
            add_check(mcp_name, "mcp", "OK", f"MCP server {mcp_name} configured")
        else:
            add_check(mcp_name, "mcp", "FAIL", f"Mandatory MCP server {mcp_name} missing from mcp_config.json", f"Fix: {mcp_fix}")

    # 4. Zero-Secret-Leakage TYPESAFE_API_KEY Readiness
    has_file_key = False
    if key_file.is_file():
        try:
            has_file_key = bool(key_file.read_text(errors="replace").strip())
        except Exception:
            pass

    has_mcp_key = False
    jev_cfg = mcp_servers.get("jev", {})
    if isinstance(jev_cfg, dict):
        jev_env = jev_cfg.get("env", {})
        if isinstance(jev_env, dict):
            raw_key_val = str(jev_env.get("TYPESAFE_API_KEY", "")).strip()
            if raw_key_val and not (raw_key_val.startswith("<") and raw_key_val.endswith(">")):
                has_mcp_key = True
            del raw_key_val
        cmd = str(jev_cfg.get("command", "")).strip()
        args_list = jev_cfg.get("args", [])
        all_cmd_str = f"{cmd} {' '.join(str(a) for a in args_list)}" if isinstance(args_list, list) else cmd
        is_custom_script = cmd.endswith(".sh") and os.path.isfile(os.path.expanduser(cmd))
        is_keychain = ("keychain" in all_cmd_str.lower()) or ("security find-generic-password" in all_cmd_str.lower())
        if is_custom_script or is_keychain:
            has_mcp_key = True

    key_present = has_env_key or has_file_key or has_mcp_key
    if key_present:
        add_check("typesafe_api_key", "security", "OK", "TYPESAFE_API_KEY is present", extra={"key_status": "present"})
    else:
        add_check(
            "typesafe_api_key",
            "security",
            "FAIL",
            "TYPESAFE_API_KEY is missing",
            fix='Fix: export TYPESAFE_API_KEY="<key>" or store in ~/.config/typesafe/key',
            extra={"key_status": "missing"},
        )

    # 5. LSP, Graphify & Platform-Sensitive Mobile Tools
    if shutil.which("csharp-ls"):
        add_check("csharp-ls", "lsp", "OK", "csharp-ls is installed")
    else:
        add_check("csharp-ls", "lsp", "WARN", "csharp-ls not found in PATH", "Fix: dotnet tool install -g csharp-ls")

    if shutil.which("csharp-lsp-mcp"):
        add_check("csharp-lsp-mcp", "lsp", "OK", "csharp-lsp-mcp is installed")
    else:
        add_check("csharp-lsp-mcp", "lsp", "WARN", "csharp-lsp-mcp not found in PATH", "Fix: npm install -g @alps/csharp-lsp-mcp")

    if shutil.which("graphify") or ("graphify" in mcp_servers):
        add_check("graphify", "lsp", "OK", "graphify is available")
    else:
        add_check("graphify", "lsp", "WARN", "graphify not found in PATH", "Fix: uv tool install graphifyy")

    has_ios, has_android = detect_mobile_workspace(workspace)

    xcrun_found = bool(shutil.which(xcrun_cmd) or (os.path.isabs(xcrun_cmd) and os.path.isfile(xcrun_cmd)))
    if has_ios:
        if xcrun_found:
            add_check("xcrun", "mobile", "OK", "xcrun available for iOS simulator")
        else:
            add_check("xcrun", "mobile", "FAIL", "xcrun missing in iOS workspace", "Fix: xcode-select --install")
    else:
        if xcrun_found:
            add_check("xcrun", "mobile", "OK", "xcrun available")
        else:
            add_check("xcrun", "mobile", "WARN", "xcrun missing (not an iOS workspace)")

    adb_found = bool(shutil.which(adb_cmd) or (os.path.isabs(adb_cmd) and os.path.isfile(adb_cmd)))
    if has_android:
        if adb_found:
            add_check("adb", "mobile", "OK", "adb available for Android emulator")
        else:
            add_check("adb", "mobile", "FAIL", "adb missing in Android workspace", "Fix: brew install android-platform-tools")
    else:
        if adb_found:
            add_check("adb", "mobile", "OK", "adb available")
        else:
            add_check("adb", "mobile", "WARN", "adb missing (not an Android workspace)")

    # 6. Active Workspace Health & Harness Daemon
    if is_harness_ignored(workspace):
        add_check("install_mode", "workspace", "INFO", ".harness-ignore active (harness disabled for this workspace)")
    elif (workspace / ".agents" / "plugins").is_dir() or (workspace / ".agents" / "plugins.json").is_file():
        add_check("install_mode", "workspace", "OK", "Project-level plugin installed")
    elif (cfg_dir / "plugins" / "alps-agy-harness").is_dir():
        add_check("install_mode", "workspace", "OK", "Global plugin active")
    else:
        add_check("install_mode", "workspace", "INFO", "Standalone workspace")

    git_dir = workspace / ".git"
    if git_dir.exists():
        res = _run_git(workspace, ["check-ignore", "-q", ".harness/"])
        is_git_ignored = res.returncode == 0
        if not is_git_ignored:
            for ef in (git_dir / "info" / "exclude", workspace / ".gitignore"):
                if ef.is_file():
                    try:
                        if ".harness/" in ef.read_text(errors="replace"):
                            is_git_ignored = True
                            break
                    except Exception:
                        pass
        if is_git_ignored:
            add_check("git_exclude", "workspace", "OK", ".harness/ is git-ignored")
        else:
            add_check("git_exclude", "workspace", "WARN", ".harness/ not ignored in git", "Fix: add .harness/ to .git/info/exclude")
    else:
        add_check("git_exclude", "workspace", "INFO", "Not a git repository")

    canon_docs = [
        workspace / "docs" / "canon" / "glossary.md",
        workspace / "docs" / "canon" / "flows.md",
        workspace / "docs" / "canon" / "lessons.md",
    ]
    if all(p.is_file() for p in canon_docs):
        add_check("canon_docs", "workspace", "OK", "docs/canon/{glossary,flows,lessons}.md present")
    else:
        add_check("canon_docs", "workspace", "WARN", "Target project canon uninitialized", "Fix: Create docs/canon/{glossary,flows,lessons}.md")

    if (workspace / "graphify-out" / "graph.json").is_file():
        add_check("graphify_graph", "workspace", "OK", "graphify-out/graph.json present")
    else:
        add_check("graphify_graph", "workspace", "WARN", "graphify-out/graph.json uninitialized", "Fix: run graphify on project root")

    # Sidecar daemon manifest & live socket check
    sidecar_dir = h_root / "sidecars" / "harness-daemon"
    sidecar_manifest = sidecar_dir / "sidecar.json"
    sidecar_script = sidecar_dir / "daemon.py"
    manifest_data = read_json_file(sidecar_manifest)
    if (
        isinstance(manifest_data, dict)
        and manifest_data.get("command") == "python3"
        and manifest_data.get("args") == ["daemon.py"]
        and manifest_data.get("restart_policy") == "always"
        and sidecar_script.is_file()
    ):
        if probe_daemon:
            alive, health = probe_daemon_health()
            if alive and health:
                add_check(
                    "harness_daemon",
                    "workspace",
                    "OK",
                    f"harness-daemon sidecar running (pid: {health.get('pid')}, activeWorkspaces: {health.get('activeWorkspaces')})",
                )
            else:
                add_check(
                    "harness_daemon",
                    "workspace",
                    "INFO",
                    "harness-daemon manifest valid (not running; cold fallback active)",
                )
        else:
            add_check("harness_daemon", "workspace", "OK", "harness-daemon sidecar active")
    else:
        add_check(
            "harness_daemon",
            "workspace",
            "FAIL",
            f"harness-daemon sidecar manifest or script invalid/missing at {sidecar_dir}",
            f"Fix: restore {sidecar_manifest} and {sidecar_script}",
        )

    total = len(checks)
    ok_count = sum(1 for c in checks if c["status"] == "OK")
    warn_count = sum(1 for c in checks if c["status"] == "WARN")
    info_count = sum(1 for c in checks if c["status"] == "INFO")
    fail_count = sum(1 for c in checks if c["status"] == "FAIL")

    return {
        "healthy": fail_count == 0,
        "summary": {
            "total": total,
            "ok": ok_count,
            "warn": warn_count,
            "info": info_count,
            "fail": fail_count,
        },
        "checks": checks,
    }


def build_health_cache_summary(doctor_result: dict[str, Any]) -> dict[str, Any]:
    """Extract compact, zero-secret environment health summary for ``.harness/cache/health.json``."""
    checks = doctor_result.get("checks", [])
    failing = [
        {"name": c["name"], "message": c["message"], "fix": c.get("fix")}
        for c in checks
        if c.get("status") == "FAIL"
    ]
    warnings = [
        {"name": c["name"], "message": c["message"]}
        for c in checks
        if c.get("status") == "WARN"
    ]
    key_status = "missing"
    for c in checks:
        if c.get("name") == "typesafe_api_key":
            key_status = str(c.get("key_status") or "missing")
            break
    return {
        "schemaVersion": CACHE_SCHEMA_VERSION,
        "checkedAt": utc_now_iso(),
        "epoch": int(time.time()),
        "healthy": bool(doctor_result.get("healthy", False)),
        "summary": doctor_result.get("summary", {}),
        "failingChecks": failing,
        "warningChecks": warnings,
        "keyStatus": key_status,
    }


def format_doctor_text(doctor_result: dict[str, Any], workspace: Path, config_dir: Path) -> str:
    """Format doctor diagnostic checks into the standard human-readable report."""
    group_labels = {
        "cli": "1. CLI Tools & GitHub Authentication",
        "plugins": "2. Plugin Dependencies",
        "mcp": "3. Mandatory Global MCP Servers",
        "security": "4. Zero-Secret TYPESAFE_API_KEY Readiness",
        "lsp": "5. LSP & Graphify Tools",
        "mobile": "6. Mobile Platform Tools",
        "workspace": "7. Active Workspace Health",
    }
    sym_map = {"OK": "[OK]  ", "WARN": "[WARN]", "INFO": "[INFO]", "FAIL": "[FAIL]"}
    lines: list[str] = [
        "==================================================",
        " Alps AGY Harness - Environment & Setup Doctor",
        "==================================================",
        f"Workspace:  {workspace}",
        f"Config Dir: {config_dir}",
        "",
    ]
    current_group: Optional[str] = None
    for c in doctor_result.get("checks", []):
        g = str(c.get("group", ""))
        if g != current_group:
            current_group = g
            lines.append(f"\n--- {group_labels.get(g, g.upper())} ---")
        lines.append(f"  {sym_map.get(c.get('status', ''), '[????]')} {c.get('name')}: {c.get('message')}")
        fix = c.get("fix")
        if fix:
            fix_str = fix if str(fix).startswith("Fix:") else f"Fix: {fix}"
            lines.append(f"         {fix_str}")

    s = doctor_result.get("summary", {})
    lines.append("\n==================================================")
    lines.append(
        f"Summary: {s.get('total', 0)} checks ({s.get('ok', 0)} OK, {s.get('warn', 0)} WARN, {s.get('info', 0)} INFO, {s.get('fail', 0)} FAIL)"
    )
    if doctor_result.get("healthy"):
        lines.append("✅ Result: ALL MANDATORY CHECKS HEALTHY")
    else:
        lines.append("❌ Result: ACTION REQUIRED — MANDATORY CHECKS FAILED")
    lines.append("==================================================")
    return "\n".join(lines)


def _load_fresh_cache_json(workspace: Path, filename: str, max_age_sec: Optional[int] = None) -> Optional[dict[str, Any]]:
    """Read ``.harness/cache/<filename>`` if present and within optional file mtime age."""
    path = workspace / ".harness" / "cache" / filename
    if not path.is_file():
        return None
    if max_age_sec is not None:
        try:
            age = time.time() - path.stat().st_mtime
            if age > max_age_sec:
                return None
        except OSError:
            return None
    return read_json_file(path)


def build_session_start_payload(
    workspace: Path,
    hook_input: dict[str, Any],
    missing_bins: Optional[list[str]] = None,
    health_cache: Optional[dict[str, Any]] = None,
    tree_state: Optional[dict[str, Any]] = None,
    graphify_status: Optional[dict[str, Any]] = None,
    mobile_crashes: Optional[dict[str, Any]] = None,
    max_crash_age_sec: Optional[int] = None,
) -> dict[str, Any]:
    """Build SessionStart ``injectSteps`` JSON payload enriched with fresh background cache telemetry."""
    if is_harness_ignored(workspace):
        return {}

    branch = get_branch_name(workspace)
    parent_model = str(hook_input.get("modelName") or "")
    parent_family = classify_parent_model(parent_model)
    parent_model_display = parent_model or "unspecified"

    canon_glossary = "present" if (workspace / "docs" / "canon" / "glossary.md").is_file() else "missing"
    canon_flows = "present" if (workspace / "docs" / "canon" / "flows.md").is_file() else "missing"
    canon_lessons = "present" if (workspace / "docs" / "canon" / "lessons.md").is_file() else "missing"
    graphify_present = "present" if (workspace / "graphify-out" / "graph.json").is_file() else "missing"

    if missing_bins is None:
        raw_bins = os.environ.get("HARNESS_CHECK_BINS", "gh jq")
        missing_bins = [b for b in raw_bins.split() if b and not shutil.which(b)]

    lines = [
        "[Alps AGY Harness - Active Session Context]",
        f"- Active Git Branch: {branch}",
        f"- Active Session Model: {parent_model_display} (family: {parent_family})",
        "- Canon Status:",
        f"  - glossary.md: {canon_glossary}",
        f"  - flows.md: {canon_flows}",
        f"  - lessons.md: {canon_lessons}",
        f"- Graphify Status: {graphify_present} (graphify-out/graph.json)",
        "- Protocols:",
        "  - Use jev_classify, jev_check, and jev_ask for intent, architecture trade-offs, and verification.",
        "  - Parent-aware Gemini 4 / Orchestrator subagent routing is enforced by pre-subagent-guard.sh (never downgrades Carbon/Orchestrator/Argon-High audits; escalates Hydrogen/Flash audits to Argon via pro).",
        "  - Wrap high-output shell commands with scripts/run-quiet.sh.",
        "  - All documentation must conclude with a ## Teknik Terimler Sözlüğü or ## Technical Glossary section.",
    ]

    if missing_bins:
        lines.append(
            f"[WARNING] Missing required tool(s): {' '.join(missing_bins)}. Run scripts/harness-doctor.sh to diagnose and resolve environment prerequisites."
        )

    # Read fallback disk caches if caller did not supply pre-loaded dictionaries
    if health_cache is None:
        health_cache = _load_fresh_cache_json(workspace, "health.json", max_age_sec=DEFAULT_HEALTH_READ_MAX_AGE_SEC)
    if tree_state is None:
        tree_state = _load_fresh_cache_json(workspace, "tree-state.json")
    if graphify_status is None:
        graphify_status = _load_fresh_cache_json(workspace, "graphify-status.json")
    if mobile_crashes is None:
        mobile_crashes = _load_fresh_cache_json(workspace, "mobile-crashes.json")

    if isinstance(health_cache, dict) and not health_cache.get("healthy", True):
        epoch = health_cache.get("epoch")
        is_fresh = not isinstance(epoch, (int, float)) or (time.time() - epoch) <= DEFAULT_HEALTH_READ_MAX_AGE_SEC
        if is_fresh:
            failing = health_cache.get("failingChecks") or []
            names = ", ".join(str(c.get("name")) for c in failing if isinstance(c, dict) and c.get("name"))
            if names:
                lines.append(
                    f"[DAEMON HEALTH WARNING] Cached harness-doctor failures detected ({names}). Run scripts/harness-doctor.sh for exact Fix commands."
                )

    live_head = get_head_oid(workspace)
    if isinstance(tree_state, dict) and tree_state.get("headOid") == live_head:
        stale_stamps: list[str] = []
        if tree_state.get("canonStampStatus") == "stale":
            stale_stamps.append("canon-pass")
        if tree_state.get("securityStampStatus") == "stale":
            stale_stamps.append("security-pass")
        if stale_stamps:
            lines.append(
                f"[DAEMON STAMP NOTICE] Stale PR stamp(s) for current HEAD ({', '.join(stale_stamps)}). Re-run pre-pr-readiness audits before gh pr create."
            )
        if tree_state.get("prAuditPending"):
            lines.append("[DAEMON PR NOTICE] Post-PR audit is still pending (pr-audit-pending.json active); run review-pr.")

    if isinstance(graphify_status, dict):
        g_state = str(graphify_status.get("state") or "")
        if g_state in ("queued", "running"):
            lines.append(f"[DAEMON GRAPHIFY] Background graphify update is currently {g_state}.")
        elif g_state == "failed":
            lines.append(
                f"[DAEMON GRAPHIFY WARNING] Last background graphify update failed (exit: {graphify_status.get('exitCode')}); see .harness/logs/graphify-hook.log."
            )

    crash_age_limit = (
        max_crash_age_sec
        if max_crash_age_sec is not None
        else int(os.environ.get("HARNESS_MOBILE_CRASH_MAX_AGE_SEC", str(DEFAULT_MOBILE_CRASH_MAX_AGE_SEC)))
    )
    if isinstance(mobile_crashes, dict) and mobile_crashes.get("latestMtimeNs"):
        try:
            age_sec = time.time() - (int(mobile_crashes["latestMtimeNs"]) / 1_000_000_000.0)
            if 0 <= age_sec <= crash_age_limit or age_sec < 0:
                report_name = str(mobile_crashes.get("latestReportName") or "crash.ips")
                summary_preview = "; ".join(str(x) for x in (mobile_crashes.get("summaryLines") or [])[:4])
                lines.append(f"[DAEMON MOBILE CRASH] Recent iOS crash detected ({report_name}): {summary_preview}")
        except Exception:
            pass

    return {"injectSteps": [{"systemMessage": {"systemMessage": "\n".join(lines)}}]}


def _read_stdin_json() -> dict[str, Any]:
    """Read hook JSON payload from stdin, returning empty dict on TTY or invalid input."""
    if sys.stdin.isatty():
        return {}
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


def _resolve_workspace_arg(explicit_ws: Optional[str], payload: dict[str, Any]) -> Path:
    """Resolve workspace path from CLI flag, hook payload workspacePaths[0], or cwd."""
    if explicit_ws:
        return Path(explicit_ws)
    ws_list = payload.get("workspacePaths")
    if isinstance(ws_list, list) and ws_list and isinstance(ws_list[0], str) and ws_list[0]:
        return Path(ws_list[0])
    return Path.cwd()


def main(argv: Optional[list[str]] = None) -> int:
    """CLI entrypoint shared by fallback hook scripts and utilities."""
    import argparse

    parser = argparse.ArgumentParser(description="Alps AGY Harness shared deterministic core CLI.")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_seg = sub.add_parser("parse-segments")
    p_seg.add_argument("--cmd", default="")

    p_wt = sub.add_parser("validate-walkthrough")
    p_wt.add_argument("--wt-file", default="")
    p_wt.add_argument("--diff-file", default="")

    for hook_sub in ("eval-pre-command", "eval-pre-edit", "eval-post-command", "eval-session-start"):
        ph = sub.add_parser(hook_sub)
        ph.add_argument("--workspace", default="")

    p_doc = sub.add_parser("doctor")
    p_doc.add_argument("--workspace", default=".")
    p_doc.add_argument("--json", action="store_true")

    p_ios = sub.add_parser("parse-ios-crash")
    p_ios.add_argument("--diag-dir", required=True)
    p_ios.add_argument("--bundle-id", default="")

    args = parser.parse_args(argv)

    if args.subcommand == "parse-segments":
        cmd_str = args.cmd if args.cmd else ("" if sys.stdin.isatty() else sys.stdin.read())
        print(json.dumps(parse_command_segments(cmd_str)))
        return 0

    if args.subcommand == "validate-walkthrough":
        wt_text = Path(args.wt_file).read_text(encoding="utf-8", errors="ignore") if args.wt_file else os.environ.get("WT_TEXT", "")
        diff_raw = Path(args.diff_file).read_text(encoding="utf-8", errors="ignore") if args.diff_file else os.environ.get("DIFF_FILES_RAW", "")
        ok, err = validate_walkthrough(wt_text, diff_raw.splitlines())
        if not ok:
            print(err)
            return 1
        return 0

    if args.subcommand == "eval-pre-edit":
        payload = _read_stdin_json()
        ws = _resolve_workspace_arg(args.workspace or None, payload)
        print(json.dumps(evaluate_pre_edit(ws, payload)))
        return 0

    if args.subcommand == "eval-pre-command":
        payload = _read_stdin_json()
        ws = _resolve_workspace_arg(args.workspace or None, payload)
        print(json.dumps(evaluate_pre_command(ws, payload)))
        return 0

    if args.subcommand == "eval-post-command":
        payload = _read_stdin_json()
        ws = _resolve_workspace_arg(args.workspace or None, payload)
        print(json.dumps(evaluate_post_command(ws, payload)))
        return 0

    if args.subcommand == "eval-session-start":
        payload = _read_stdin_json()
        ws = _resolve_workspace_arg(args.workspace or None, payload)
        print(json.dumps(build_session_start_payload(ws, payload)))
        return 0

    if args.subcommand == "doctor":
        ws = Path(args.workspace)
        cfg_dir = Path(os.environ.get("HARNESS_CONFIG_DIR") or (Path.home() / ".gemini" / "config"))
        res = run_doctor_checks(ws, config_dir=cfg_dir)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(format_doctor_text(res, ws, cfg_dir))
        return 0 if res.get("healthy") else 1

    if args.subcommand == "parse-ios-crash":
        res = parse_ios_crash_report(Path(args.diag_dir), bundle_id=args.bundle_id, allow_unmatched_fallback=True)
        for line in res.get("lines", []):
            print(line)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
