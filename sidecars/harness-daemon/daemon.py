#!/usr/bin/env python3
"""Alps AGY Harness background daemon sidecar (``harness-daemon``).

Provides warm HTTP-over-Unix-Domain-Socket hook evaluation, atomic
``.harness/cache/*.json`` pre-computation, single-flight debounced async
``graphify`` updates, and conditional iOS crash watching with zero third-party
dependencies.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import fcntl
import http.server
import json
import os
import signal
import socket
import socketserver
import stat
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Optional

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = PLUGIN_ROOT / "scripts" / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

import harness_core  # noqa: E402

MAX_REQUEST_BYTES = 2 * 1024 * 1024
LOG_MAX_BYTES = 1024 * 1024
MACOS_UNIX_PATH_MAX = 103


class DaemonLogger:
    """Thread-safe size-rotating logger that never persists secret values."""

    def __init__(self, log_path: Path) -> None:
        self._path = log_path
        self._lock = threading.Lock()
        self._path.parent.mkdir(parents=True, exist_ok=True)

    def log(self, level: str, msg: str) -> None:
        """Append a timestamped log entry, rotating ``daemon.log`` at 1 MiB."""
        line = f"{harness_core.utc_now_iso()} [{level}] {msg}\n"
        with self._lock:
            try:
                if self._path.is_file() and self._path.stat().st_size >= LOG_MAX_BYTES:
                    backup = self._path.with_suffix(".log.1")
                    if backup.exists():
                        backup.unlink()
                    os.replace(self._path, backup)
                with open(self._path, "a", encoding="utf-8") as fh:
                    fh.write(line)
            except OSError:
                pass


_PATH_SYNC_LOCK = threading.Lock()
_PATH_SYNC_DONE = False


def enrich_fast_fallback_path() -> None:
    """Append standard local tool directories to ``PATH`` synchronously without shell spawning."""
    if os.environ.get("HARNESS_SKIP_SHELL_PATH_SYNC") == "1":
        return

    current_path = os.environ.get("PATH", "")
    parts = [p for p in current_path.split(os.pathsep) if p]
    seen = set(parts)

    fallback_dirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        str(Path.home() / ".local" / "bin"),
        str(Path.home() / ".dotnet" / "tools"),
    ]
    for candidate in fallback_dirs:
        if candidate not in seen and os.path.isdir(candidate):
            seen.add(candidate)
            parts.append(candidate)

    os.environ["PATH"] = os.pathsep.join(parts)


def ensure_startup_path_enriched() -> None:
    """Once-guarded login-shell ``PATH`` merge executed asynchronously after socket bind."""
    global _PATH_SYNC_DONE
    if _PATH_SYNC_DONE or os.environ.get("HARNESS_SKIP_SHELL_PATH_SYNC") == "1":
        return

    with _PATH_SYNC_LOCK:
        if _PATH_SYNC_DONE:
            return
        enrich_fast_fallback_path()
        current_path = os.environ.get("PATH", "")
        parts = [p for p in current_path.split(os.pathsep) if p]
        seen = set(parts)

        shell_bin = os.environ.get("SHELL") or "/bin/zsh"
        shell_parts: list[str] = []
        if os.path.isabs(shell_bin) and os.access(shell_bin, os.X_OK):
            try:
                proc = subprocess.run(
                    [shell_bin, "-lc", 'printf "%s" "$PATH"'],
                    capture_output=True,
                    text=True,
                    timeout=2.0,
                )
                if proc.returncode == 0 and proc.stdout:
                    shell_parts = [p for p in proc.stdout.strip().split(os.pathsep) if p]
            except Exception:
                pass

        for candidate in shell_parts:
            if candidate not in seen and os.path.isdir(candidate):
                seen.add(candidate)
                parts.append(candidate)

        os.environ["PATH"] = os.pathsep.join(parts)
        _PATH_SYNC_DONE = True


def enrich_startup_path() -> None:
    """Merge login-shell PATH into ``os.environ['PATH']`` for macOS GUI sidecars."""
    ensure_startup_path_enriched()


def validate_and_prepare_socket_dir(sock_path: Path) -> None:
    """Validate socket path length, real-dir status, UID ownership, and 0700 mode."""
    sock_bytes = len(str(sock_path).encode("utf-8"))
    if sys.platform == "darwin" and sock_bytes > MACOS_UNIX_PATH_MAX:
        raise ValueError(
            f"AF_UNIX socket path exceeds macOS {MACOS_UNIX_PATH_MAX}-byte sun_path limit ({sock_bytes} bytes): {sock_path}"
        )

    sock_dir = sock_path.parent
    if sock_dir.exists() or sock_dir.is_symlink():
        if sock_dir.is_symlink():
            raise PermissionError(f"Refusing symlink socket directory: {sock_dir}")
        st = sock_dir.lstat()
        if st.st_uid != os.getuid():
            raise PermissionError(f"Socket directory {sock_dir} is not owned by UID {os.getuid()}")
        if not sock_dir.is_dir():
            raise NotADirectoryError(f"Socket parent is not a directory: {sock_dir}")
        os.chmod(sock_dir, 0o700)
    else:
        sock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(sock_dir, 0o700)
        st = sock_dir.lstat()
        if (
            not stat.S_ISDIR(st.st_mode)
            or stat.S_ISLNK(st.st_mode)
            or st.st_uid != os.getuid()
            or (stat.S_IMODE(st.st_mode) & 0o077) != 0
        ):
            raise PermissionError(f"Unsafe permissions or owner on socket directory: {sock_dir}")


class HarnessDaemonState:
    """Thread-safe coordinator for workspace registry, caches, watchers, and graphify queue."""

    def __init__(self, data_dir: Path, logger: DaemonLogger, startup_env_key_present: bool) -> None:
        self.data_dir = data_dir
        self.logger = logger
        self.started_at = time.time()
        self.startup_env_key_present = startup_env_key_present
        self.stop_event = threading.Event()
        self.wake_event = threading.Event()

        self._lock = threading.RLock()
        self._workspaces: dict[str, dict[str, Any]] = {}
        self._caches: dict[str, dict[str, Any]] = {}
        self._dirty_workspaces: set[str] = set()
        self._graphify_queue: dict[str, dict[str, Any]] = {}
        self._quota_resume_inflight: set[str] = set()
        self._watcher_cycles: int = 0

        self.poll_interval_sec = max(0.05, float(os.environ.get("HARNESS_DAEMON_POLL_INTERVAL_SEC", "1.5")))
        self.workspace_ttl_sec = max(0.1, float(os.environ.get("HARNESS_DAEMON_WORKSPACE_TTL_SEC", "1800")))
        self.health_ttl_sec = max(1.0, float(os.environ.get("HARNESS_HEALTH_TTL_SEC", "300")))
        self.graphify_debounce_sec = max(0.0, float(os.environ.get("HARNESS_GRAPHIFY_DEBOUNCE_SEC", "3.0")))

        self._load_registry()

    def _registry_path(self) -> Path:
        return self.data_dir / "workspaces.json"

    def _load_registry(self) -> None:
        raw = harness_core.read_json_file(self._registry_path())
        if not isinstance(raw, dict):
            return
        entries = raw.get("workspaces")
        if not isinstance(entries, dict):
            return
        now = time.time()
        for ws_str, meta in entries.items():
            if not isinstance(meta, dict):
                continue
            ws_path = Path(ws_str)
            last_seen = float(meta.get("lastSeenAt", 0))
            has_quota_wait = ws_path.is_dir() and harness_core.has_active_swarm_quota_wait(ws_path)
            if ((now - last_seen) > self.workspace_ttl_sec and not has_quota_wait) or not ws_path.is_dir() or harness_core.is_harness_ignored(ws_path):
                continue
            self._workspaces[ws_str] = {
                "registeredAt": float(meta.get("registeredAt", last_seen or now)),
                "lastSeenAt": last_seen or now,
                "envKeyHint": meta.get("envKeyHint"),
            }
            self._dirty_workspaces.add(ws_str)

    def _persist_registry_locked(self) -> None:
        serializable = {
            ws: {
                "registeredAt": meta.get("registeredAt", 0),
                "lastSeenAt": meta.get("lastSeenAt", 0),
                "envKeyHint": meta.get("envKeyHint"),
            }
            for ws, meta in self._workspaces.items()
        }
        try:
            harness_core.atomic_write_json(self.data_dir, "workspaces.json", {"workspaces": serializable})
        except Exception as exc:
            self.logger.log("WARN", f"Failed to persist workspaces.json: {exc}")

    def register_workspace(
        self,
        raw_workspace: str,
        env_key_hint: Optional[bool] = None,
        warm_now: bool = False,
    ) -> tuple[Optional[Path], bool]:
        """Register or refresh ``raw_workspace``. Returns ``(real_path, is_ignored)``."""
        if not raw_workspace:
            return None, False
        try:
            ws_path = Path(os.path.realpath(os.path.expanduser(raw_workspace)))
        except OSError:
            return None, False

        if not ws_path.is_dir():
            return ws_path, False

        ws_key = str(ws_path)
        if harness_core.is_harness_ignored(ws_path):
            with self._lock:
                if ws_key in self._workspaces:
                    self._workspaces.pop(ws_key, None)
                    self._caches.pop(ws_key, None)
                    self._graphify_queue.pop(ws_key, None)
                    self._persist_registry_locked()
            return ws_path, True

        now = time.time()
        with self._lock:
            is_new = ws_key not in self._workspaces
            meta = self._workspaces.setdefault(
                ws_key,
                {"registeredAt": now, "lastSeenAt": now, "envKeyHint": None},
            )
            meta["lastSeenAt"] = now
            if env_key_hint is not None:
                meta["envKeyHint"] = bool(env_key_hint)
            self._dirty_workspaces.add(ws_key)
            if is_new or env_key_hint is not None:
                self._persist_registry_locked()

        if warm_now:
            self.refresh_workspace(ws_path, force_health=False)
        else:
            self.wake_event.set()
        return ws_path, False

    def mark_dirty(self, ws_path: Path) -> None:
        """Schedule an immediate background cache refresh for ``ws_path``."""
        ws_key = str(ws_path)
        with self._lock:
            if ws_key in self._workspaces:
                self._dirty_workspaces.add(ws_key)
        self.wake_event.set()

    def active_workspace_count(self) -> int:
        """Return count of currently registered active workspaces."""
        with self._lock:
            return len(self._workspaces)

    def queue_depth(self) -> int:
        """Return count of pending or active graphify jobs across workspaces."""
        with self._lock:
            return sum(1 for item in self._graphify_queue.values() if item.get("queued") or item.get("running"))

    def watcher_cycle_count(self) -> int:
        """Return total completed ``watcher_loop`` iterations."""
        with self._lock:
            return self._watcher_cycles

    def active_quota_wait_count(self) -> int:
        """Return count of registered workspaces with an active Swarm quota wait."""
        with self._lock:
            ws_keys = list(self._workspaces.keys())
        return sum(1 for k in ws_keys if harness_core.has_active_swarm_quota_wait(Path(k)))

    def notify_swarm_quota_wait(self, ws_path: Path) -> dict[str, Any]:
        """Mark workspace active for Swarm quota watchdog and wake the watcher loop."""
        reg_ws, ignored = self.register_workspace(str(ws_path), warm_now=False)
        if ignored or reg_ws is None:
            return {}
        self.mark_dirty(reg_ws)
        return harness_core.get_swarm_quota_state(reg_ws)

    def _run_swarm_quota_resume(self, ws_key: str) -> None:
        """Invoke ``agy --conversation`` via ``harness_core.attempt_swarm_quota_resume`` in background."""
        resumed = False
        should_wake = True
        try:
            ensure_startup_path_enriched()
            res = harness_core.attempt_swarm_quota_resume(Path(ws_key))
            status = str(res.get("status") or "unknown")
            resumed = status == "resumed"
            should_wake = status != "resuming"
            self.logger.log("INFO", f"Swarm quota resume probe for {ws_key}: status={status} attempt={res.get('attemptCount', 0)}")
        except Exception as exc:
            self.logger.log("WARN", f"Swarm quota resume error for {ws_key}: {exc}")
        finally:
            with self._lock:
                self._quota_resume_inflight.discard(ws_key)
                if resumed and ws_key in self._workspaces:
                    self._workspaces[ws_key]["lastSeenAt"] = time.time()
                    self._persist_registry_locked()
            if should_wake:
                self.wake_event.set()

    def get_caches(self, ws_path: Path, allow_disk_hydration: bool = True) -> dict[str, Any]:
        """Return shallow copy of in-memory caches for ``ws_path``, optionally hydrating missing keys."""
        ws_key = str(ws_path)
        with self._lock:
            entry = dict(self._caches.get(ws_key, {}))
        if not allow_disk_hydration:
            return entry
        cache_files = {
            "health": "health.json",
            "treeState": "tree-state.json",
            "specPackages": "spec-packages.json",
            "docValidation": "doc-validation.json",
            "graphifyStatus": "graphify-status.json",
            "mobileCrashes": "mobile-crashes.json",
        }
        cache_dir = ws_path / ".harness" / "cache"
        for key, filename in cache_files.items():
            if entry.get(key) is None:
                entry[key] = harness_core.read_json_file(cache_dir / filename)
        return entry

    def enqueue_graphify(self, ws_path: Path, reason: str) -> None:
        """Enqueue a debounced single-flight async graphify update for ``ws_path``."""
        if harness_core.is_harness_ignored(ws_path) or not (ws_path / "graphify-out").is_dir():
            return
        ws_key = str(ws_path)
        now = time.time()
        due_at = now + self.graphify_debounce_sec

        with self._lock:
            job = self._graphify_queue.get(ws_key)
            if job is None:
                job = {
                    "queued": True,
                    "running": False,
                    "rerunPending": False,
                    "queuedAt": harness_core.utc_now_iso(),
                    "dueAt": due_at,
                    "reason": reason,
                }
                self._graphify_queue[ws_key] = job
            elif job.get("running"):
                job["rerunPending"] = True
                job["reason"] = reason
            else:
                job["queued"] = True
                job["dueAt"] = due_at
                job["reason"] = reason

            status_payload = {
                "schemaVersion": harness_core.CACHE_SCHEMA_VERSION,
                "state": "running" if job.get("running") else "queued",
                "reason": reason,
                "lastHeadSha": harness_core.get_head_oid(ws_path),
                "queuedAt": job.get("queuedAt"),
                "logPath": ".harness/logs/graphify-hook.log",
            }
            self._caches.setdefault(ws_key, {})["graphifyStatus"] = status_payload

        try:
            cache_dir = harness_core.get_cache_dir(ws_path)
            harness_core.atomic_write_json(cache_dir, "graphify-status.json", status_payload)
        except OSError:
            pass
        self.wake_event.set()

    def _resolve_git_dirs(self, ws_path: Path) -> tuple[Optional[Path], Optional[Path]]:
        """Resolve per-worktree git_dir and shared git_common_dir without spawning git."""
        dot_git = ws_path / ".git"
        if dot_git.is_dir():
            return dot_git, dot_git
        if dot_git.is_file():
            try:
                raw = dot_git.read_text(encoding="utf-8", errors="ignore")
                for line in raw.splitlines():
                    if line.startswith("gitdir:"):
                        gd_raw = line.split(":", 1)[1].strip()
                        git_dir = Path(gd_raw) if os.path.isabs(gd_raw) else (ws_path / gd_raw).resolve()
                        if not git_dir.is_dir():
                            return None, None
                        common_file = git_dir / "commondir"
                        if common_file.is_file():
                            cd_raw = common_file.read_text(encoding="utf-8", errors="ignore").strip()
                            common_dir = Path(cd_raw) if os.path.isabs(cd_raw) else (git_dir / cd_raw).resolve()
                            return git_dir, common_dir
                        return git_dir, git_dir
            except OSError:
                return None, None
        return None, None

    def _signature_for_workspace(self, ws_path: Path, is_ios: bool) -> dict[str, Any]:
        """Compute lightweight mtime signature across watched workspace paths."""
        git_dir, common_dir = self._resolve_git_dirs(ws_path)
        git_mtimes: dict[str, int] = {}
        if git_dir is not None:
            for rel, base_dir in (("HEAD", git_dir), ("index", git_dir), ("packed-refs", common_dir or git_dir)):
                p = base_dir / rel
                if p.is_file():
                    try:
                        git_mtimes[rel] = p.stat().st_mtime_ns
                    except OSError:
                        pass
            head_file = git_dir / "HEAD"
            if head_file.is_file():
                try:
                    head_txt = head_file.read_text(encoding="utf-8", errors="ignore").strip()
                    if head_txt.startswith("ref:"):
                        ref_rel = head_txt.split(":", 1)[1].strip()
                        ref_base = common_dir or git_dir
                        ref_p = ref_base / ref_rel
                        if not ref_p.is_file():
                            ref_p = git_dir / ref_rel
                        if ref_p.is_file():
                            git_mtimes[ref_rel] = ref_p.stat().st_mtime_ns
                except OSError:
                    pass

        slug = harness_core.get_branch_slug(ws_path)
        state_mtimes: dict[str, int] = {}
        state_dir = ws_path / ".harness" / "state" / slug
        for fn in ("canon-pass.json", "security-pass.json", "tdd-pass.json", "ui-pass.json", "pr-audit-pending.json"):
            p = state_dir / fn
            if p.is_file():
                try:
                    state_mtimes[fn] = p.stat().st_mtime_ns
                except OSError:
                    pass

        spec_mtimes: dict[str, tuple[int, int]] = {}
        specs_dir = ws_path / "docs" / "superpowers" / "specs"
        if specs_dir.is_dir():
            for sp in sorted(specs_dir.glob("*.md")):
                try:
                    st = sp.stat()
                    spec_mtimes[sp.name] = (st.st_mtime_ns, st.st_size)
                except OSError:
                    pass

        doc_mtimes: dict[str, tuple[int, int]] = {}
        readme = ws_path / "README.md"
        if readme.is_file():
            try:
                st = readme.stat()
                doc_mtimes["README.md"] = (st.st_mtime_ns, st.st_size)
            except OSError:
                pass
        docs_dir = ws_path / "docs"
        if docs_dir.is_dir():
            for dp in sorted(docs_dir.rglob("*.md")):
                try:
                    st = dp.stat()
                    doc_mtimes[dp.relative_to(ws_path).as_posix()] = (st.st_mtime_ns, st.st_size)
                except OSError:
                    pass

        cfg_dir = Path(os.environ.get("HARNESS_CONFIG_DIR") or (Path.home() / ".gemini" / "config"))
        key_file = Path(os.environ.get("HARNESS_TYPESAFE_KEY_FILE") or (Path.home() / ".config" / "typesafe" / "key"))
        cfg_mtimes: dict[str, int] = {}
        for cp in (
            cfg_dir / "mcp_config.json",
            cfg_dir / "config.json",
            cfg_dir / "plugins.json",
            cfg_dir / "skills" / "impeccable" / "SKILL.md",
            ws_path / ".agent" / "skills" / "impeccable" / "SKILL.md",
            ws_path / ".agents" / "skills" / "impeccable" / "SKILL.md",
            key_file,
        ):
            if cp.is_file():
                try:
                    cfg_mtimes[str(cp)] = cp.stat().st_mtime_ns
                except OSError:
                    pass

        diag_mtime = 0
        if is_ios:
            diag_dir = Path(os.environ.get("HARNESS_DIAG_REPORTS_DIR") or (Path.home() / "Library" / "Logs" / "DiagnosticReports"))
            if diag_dir.is_dir():
                try:
                    diag_mtime = max(
                        (p.stat().st_mtime_ns for p in [*diag_dir.glob("*.ips"), *diag_dir.glob("*.crash")]),
                        default=0,
                    )
                except OSError:
                    diag_mtime = 0

        return {
            "git": git_mtimes,
            "state": state_mtimes,
            "specs": spec_mtimes,
            "docs": doc_mtimes,
            "cfg": cfg_mtimes,
            "diagMtime": diag_mtime,
        }

    def refresh_workspace(self, ws_path: Path, force_health: bool = False) -> None:
        """Incrementally refresh stale workspace caches and detect HEAD transitions."""
        if not ws_path.is_dir() or harness_core.is_harness_ignored(ws_path):
            return

        ws_key = str(ws_path)
        with self._lock:
            ws_meta = self._workspaces.get(ws_key)
            if ws_meta is None:
                return
            env_hint = ws_meta.get("envKeyHint")
            cache_entry = self._caches.setdefault(ws_key, {})
            prev_sig = cache_entry.get("_sig", {})
            prev_head = cache_entry.get("_lastHeadOid")
            last_mobile_check = float(cache_entry.get("_lastMobileDetect", 0))

        now = time.time()
        if (now - last_mobile_check) >= 120.0 or "_hasIos" not in cache_entry:
            has_ios, _ = harness_core.detect_mobile_workspace(ws_path)
            with self._lock:
                c = self._caches.setdefault(ws_key, {})
                c["_hasIos"] = has_ios
                c["_lastMobileDetect"] = now
        else:
            has_ios = bool(cache_entry.get("_hasIos"))

        sig = self._signature_for_workspace(ws_path, is_ios=has_ios)
        cache_dir = harness_core.get_cache_dir(ws_path)

        # 1. Tree state & HEAD change detection
        tree_file_missing = not (cache_dir / "tree-state.json").is_file()
        if tree_file_missing or sig["git"] != prev_sig.get("git") or sig["state"] != prev_sig.get("state"):
            prev_tree = cache_entry.get("treeState")
            new_tree = harness_core.compute_tree_and_stamp_state(ws_path, existing_cache=prev_tree)
            harness_core.atomic_write_json(cache_dir, "tree-state.json", new_tree)
            with self._lock:
                c = self._caches.setdefault(ws_key, {})
                c["treeState"] = new_tree
                new_head = new_tree.get("headOid")
                c["_lastHeadOid"] = new_head
            if prev_head and new_head and prev_head != new_head and (ws_path / "graphify-out").is_dir():
                self.enqueue_graphify(ws_path, "git_head_changed")

        # 2. Spec package index
        spec_file_missing = not (cache_dir / "spec-packages.json").is_file()
        if spec_file_missing or sig["specs"] != prev_sig.get("specs"):
            prev_spec = cache_entry.get("specPackages")
            new_spec = harness_core.build_spec_package_index(ws_path, existing_index=prev_spec)
            harness_core.atomic_write_json(cache_dir, "spec-packages.json", new_spec)
            with self._lock:
                self._caches.setdefault(ws_key, {})["specPackages"] = new_spec

        # 3. Doc validation cache
        doc_file_missing = not (cache_dir / "doc-validation.json").is_file()
        if doc_file_missing or sig["docs"] != prev_sig.get("docs") or sig["git"] != prev_sig.get("git"):
            prev_doc = cache_entry.get("docValidation")
            new_doc = harness_core.build_doc_validation_cache(ws_path, existing_cache=prev_doc)
            harness_core.atomic_write_json(cache_dir, "doc-validation.json", new_doc)
            with self._lock:
                self._caches.setdefault(ws_key, {})["docValidation"] = new_doc

        # 4. Doctor health cache (TTL + config mtimes; never writes secret values)
        prev_health = cache_entry.get("health")
        health_epoch = float(prev_health.get("epoch", 0)) if isinstance(prev_health, dict) else 0.0
        health_expired = (now - health_epoch) >= self.health_ttl_sec
        if force_health or prev_health is None or health_expired or sig["cfg"] != prev_sig.get("cfg"):
            ensure_startup_path_enriched()
            effective_env_key = bool(env_hint) if env_hint is not None else self.startup_env_key_present
            doctor_res = harness_core.run_doctor_checks(
                ws_path,
                env_key_present=effective_env_key,
                scrub_env=False,
                probe_daemon=False,
            )
            health_summary = harness_core.build_health_cache_summary(doctor_res)
            harness_core.atomic_write_json(cache_dir, "health.json", health_summary)
            with self._lock:
                self._caches.setdefault(ws_key, {})["health"] = health_summary

        # 5. Conditional iOS crash watcher (never writes anything on Android-only or non-mobile repos)
        if has_ios:
            diag_override = bool(os.environ.get("HARNESS_DIAG_REPORTS_DIR", "").strip())
            diag_dir = Path(os.environ.get("HARNESS_DIAG_REPORTS_DIR") or (Path.home() / "Library" / "Logs" / "DiagnosticReports"))
            prev_crash = cache_entry.get("mobileCrashes") or harness_core.read_json_file(cache_dir / "mobile-crashes.json")
            if prev_sig.get("diagMtime") != sig["diagMtime"] or prev_crash is None:
                bundle_ids = harness_core.extract_ios_bundle_identifiers(ws_path)
                allow_fallback = diag_override or (len(bundle_ids) == 0)
                parsed = harness_core.parse_ios_crash_report(
                    diag_dir,
                    candidate_ids=bundle_ids,
                    allow_unmatched_fallback=allow_fallback,
                )
                if parsed.get("found"):
                    crash_payload = {
                        "schemaVersion": harness_core.CACHE_SCHEMA_VERSION,
                        "platform": "ios",
                        "updatedAt": harness_core.utc_now_iso(),
                        "latestReportName": parsed["reportName"],
                        "latestMtimeNs": parsed["mtimeNs"],
                        "summaryLines": parsed["lines"],
                    }
                    harness_core.atomic_write_json(cache_dir, "mobile-crashes.json", crash_payload)
                    with self._lock:
                        self._caches.setdefault(ws_key, {})["mobileCrashes"] = crash_payload

        with self._lock:
            self._caches.setdefault(ws_key, {})["_sig"] = sig
            self._dirty_workspaces.discard(ws_key)

    def _run_graphify_job(self, ws_key: str, reason: str) -> None:
        """Execute a single-flight incremental graphify run and update ``graphify-status.json``."""
        ws_path = Path(ws_key)
        started_at = harness_core.utc_now_iso()
        t0 = time.monotonic()

        running_status = {
            "schemaVersion": harness_core.CACHE_SCHEMA_VERSION,
            "state": "running",
            "reason": reason,
            "lastHeadSha": harness_core.get_head_oid(ws_path),
            "startedAt": started_at,
            "logPath": ".harness/logs/graphify-hook.log",
        }
        with self._lock:
            self._caches.setdefault(ws_key, {})["graphifyStatus"] = running_status
        try:
            harness_core.atomic_write_json(harness_core.get_cache_dir(ws_path), "graphify-status.json", running_status)
        except OSError:
            pass

        ensure_startup_path_enriched()
        rc = harness_core.run_sync_graphify(ws_path)
        duration_ms = int((time.monotonic() - t0) * 1000)
        finished_status = {
            "schemaVersion": harness_core.CACHE_SCHEMA_VERSION,
            "state": "succeeded" if rc == 0 else "failed",
            "reason": reason,
            "lastHeadSha": harness_core.get_head_oid(ws_path),
            "startedAt": started_at,
            "finishedAt": harness_core.utc_now_iso(),
            "durationMs": duration_ms,
            "exitCode": rc,
            "logPath": ".harness/logs/graphify-hook.log",
        }

        with self._lock:
            job = self._graphify_queue.get(ws_key)
            self._caches.setdefault(ws_key, {})["graphifyStatus"] = finished_status
            if job is not None:
                job["running"] = False
                if job.get("rerunPending"):
                    job["rerunPending"] = False
                    job["queued"] = True
                    job["dueAt"] = time.time() + self.graphify_debounce_sec
                else:
                    job["queued"] = False

        try:
            harness_core.atomic_write_json(harness_core.get_cache_dir(ws_path), "graphify-status.json", finished_status)
        except OSError:
            pass

    def watcher_loop(self) -> None:
        """Background loop performing TTL eviction, mtime polling, and graphify dispatch."""
        ensure_startup_path_enriched()
        while not self.stop_event.is_set():
            now = time.time()
            to_refresh: list[str] = []
            due_graphify: list[tuple[str, str]] = []
            evicted = False

            with self._lock:
                for ws_key in list(self._workspaces.keys()):
                    ws_path = Path(ws_key)
                    meta = self._workspaces[ws_key]
                    has_quota_wait = ws_path.is_dir() and harness_core.has_active_swarm_quota_wait(ws_path)
                    if (
                        ((now - float(meta.get("lastSeenAt", 0))) > self.workspace_ttl_sec and not has_quota_wait)
                        or not ws_path.is_dir()
                        or harness_core.is_harness_ignored(ws_path)
                    ):
                        self._workspaces.pop(ws_key, None)
                        self._caches.pop(ws_key, None)
                        self._graphify_queue.pop(ws_key, None)
                        self._dirty_workspaces.discard(ws_key)
                        evicted = True
                    else:
                        to_refresh.append(ws_key)

                if evicted:
                    self._persist_registry_locked()

                for ws_key, job in list(self._graphify_queue.items()):
                    if job.get("queued") and not job.get("running") and float(job.get("dueAt", 0)) <= now:
                        job["queued"] = False
                        job["running"] = True
                        due_graphify.append((ws_key, str(job.get("reason", "queued"))))

                due_quota_resumes: list[str] = []
                soonest_probe_delta: Optional[float] = None
                stale_threshold = harness_core._stale_resuming_threshold_sec()
                for ws_key in to_refresh:
                    if ws_key in self._quota_resume_inflight:
                        continue
                    try:
                        q_state = harness_core.get_swarm_quota_state(Path(ws_key))
                        q_status = str(q_state.get("status") or "")
                        if q_status == "waiting":
                            next_probe = harness_core._safe_float(q_state.get("nextProbeEpoch"), 0.0)
                            if next_probe <= now:
                                self._quota_resume_inflight.add(ws_key)
                                due_quota_resumes.append(ws_key)
                            else:
                                delta = next_probe - now
                                if soonest_probe_delta is None or delta < soonest_probe_delta:
                                    soonest_probe_delta = delta
                        elif q_status == "resuming":
                            started_ep = harness_core._safe_float(q_state.get("resumingStartedAtEpoch"), 0.0)
                            if started_ep <= 0 or (now - started_ep) >= stale_threshold:
                                self._quota_resume_inflight.add(ws_key)
                                due_quota_resumes.append(ws_key)
                            else:
                                delta = max(0.05, stale_threshold - (now - started_ep))
                                if soonest_probe_delta is None or delta < soonest_probe_delta:
                                    soonest_probe_delta = delta
                    except Exception as exc:
                        self.logger.log("WARN", f"Malformed quota state for {ws_key}: {exc}")

                dirty_snapshot = set(self._dirty_workspaces)

            for ws_key in due_quota_resumes:
                qt = threading.Thread(
                    target=self._run_swarm_quota_resume,
                    args=(ws_key,),
                    name=f"quota-{os.path.basename(ws_key)}",
                    daemon=True,
                )
                qt.start()

            for ws_key, reason in due_graphify:
                t = threading.Thread(
                    target=self._run_graphify_job,
                    args=(ws_key, reason),
                    name=f"graphify-{os.path.basename(ws_key)}",
                    daemon=True,
                )
                t.start()

            # Prioritize explicitly dirty workspaces first
            ordered_refresh = sorted(to_refresh, key=lambda k: (0 if k in dirty_snapshot else 1))
            for ws_key in ordered_refresh:
                if self.stop_event.is_set():
                    break
                try:
                    self.refresh_workspace(Path(ws_key))
                except Exception as exc:
                    self.logger.log("WARN", f"Refresh error for {ws_key}: {exc}")

            with self._lock:
                self._watcher_cycles += 1
            wait_timeout = (
                self.poll_interval_sec
                if soonest_probe_delta is None
                else min(self.poll_interval_sec, max(0.05, soonest_probe_delta))
            )
            self.wake_event.wait(timeout=wait_timeout)
            self.wake_event.clear()


class ThreadingUnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Multi-threaded HTTP server listening on a private 0600 AF_UNIX socket."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: str, handler_cls: type[http.server.BaseHTTPRequestHandler], state: HarnessDaemonState) -> None:
        self.harness_state = state
        super().__init__(server_address, handler_cls)

    def server_bind(self) -> None:
        old_umask = os.umask(0o177)
        try:
            super().server_bind()
        finally:
            os.umask(old_umask)
        os.chmod(self.server_address, 0o600)


class DaemonRequestHandler(http.server.BaseHTTPRequestHandler):
    """HTTP/JSON request handler implementing the daemon hook and event API."""

    protocol_version = "HTTP/1.1"

    def setup(self) -> None:
        """Bind a bounded per-connection socket timeout before parsing HTTP headers."""
        super().setup()
        try:
            self.connection.settimeout(5.0)
        except Exception:
            pass

    def address_string(self) -> str:
        """Return static local identifier because UnixStreamServer omits TCP client tuples."""
        return "unix-local"

    def log_message(self, format: str, *args: Any) -> None:
        """Suppress noisy BaseHTTPRequestHandler stderr logging."""
        return

    def _send_json(self, status_code: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> tuple[Optional[dict[str, Any]], int]:
        try:
            content_len = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None, 400
        if content_len > MAX_REQUEST_BYTES:
            return None, 413
        raw = self.rfile.read(content_len) if content_len > 0 else b"{}"
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception:
            return None, 400
        if not isinstance(parsed, dict):
            return None, 400
        return parsed, 200

    def _extract_workspace(self, body: dict[str, Any]) -> str:
        ws = body.get("workspace")
        if isinstance(ws, str) and ws:
            return ws
        ws_paths = body.get("workspacePaths")
        if isinstance(ws_paths, list) and ws_paths and isinstance(ws_paths[0], str):
            return ws_paths[0]
        return ""

    def do_GET(self) -> None:
        state: HarnessDaemonState = self.server.harness_state  # type: ignore[attr-defined]
        if self.path == "/health":
            self._send_json(
                200,
                {
                    "status": "ok",
                    "pid": os.getpid(),
                    "uptimeSec": round(time.time() - state.started_at, 2),
                    "activeWorkspaces": state.active_workspace_count(),
                    "queueDepth": state.queue_depth(),
                    "quotaWaits": state.active_quota_wait_count(),
                    "watcherCycles": state.watcher_cycle_count(),
                },
            )
            return
        self._send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        state: HarnessDaemonState = self.server.harness_state  # type: ignore[attr-defined]
        body, status_err = self._read_json_body()
        if body is None:
            self._send_json(status_err, {"error": "invalid_request"})
            return

        raw_ws = self._extract_workspace(body)
        if not raw_ws:
            self._send_json(400, {"error": "missing_workspace"})
            return

        if self.path == "/hook/session-start":
            raw_hint = body.get("envKeyPresent")
            env_hint = raw_hint if isinstance(raw_hint, bool) else None
            ws_path, ignored = state.register_workspace(raw_ws, env_key_hint=env_hint, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {})
                return
            raw_missing = body.get("missingBins")
            missing_bins = [str(b) for b in raw_missing] if isinstance(raw_missing, list) else None
            caches = state.get_caches(ws_path)
            resp = harness_core.build_session_start_payload(
                ws_path,
                body,
                missing_bins=missing_bins,
                health_cache=caches.get("health"),
                tree_state=caches.get("treeState"),
                graphify_status=caches.get("graphifyStatus"),
                mobile_crashes=caches.get("mobileCrashes"),
            )
            state.mark_dirty(ws_path)
            self._send_json(200, resp)
            return

        if self.path == "/hook/pre-command":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {"decision": "allow"})
                return
            caches = state.get_caches(ws_path, allow_disk_hydration=False)

            def _get_worktree_caches(target_ws: Path) -> dict[str, Any]:
                reg_ws, wt_ignored = state.register_workspace(str(target_ws), warm_now=False)
                if wt_ignored or reg_ws is None:
                    return {}
                return state.get_caches(reg_ws, allow_disk_hydration=False)

            resp = harness_core.evaluate_pre_command(
                ws_path,
                body,
                spec_index=caches.get("specPackages"),
                doc_cache=caches.get("docValidation"),
                worktree_cache_getter=_get_worktree_caches,
            )
            self._send_json(200, resp)
            return

        if self.path == "/hook/pre-edit":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {"decision": "allow"})
                return
            resolved_ws_holder = [ws_path]

            def _on_wt_resolved(wt: Path) -> None:
                reg_wt, _ = state.register_workspace(str(wt), warm_now=False)
                if reg_wt is not None:
                    resolved_ws_holder[0] = reg_wt

            resp = harness_core.evaluate_pre_edit(
                ws_path,
                body,
                on_worktree_resolved=_on_wt_resolved,
            )
            if resp.get("decision") == "allow":
                state.mark_dirty(resolved_ws_holder[0])
            self._send_json(200, resp)
            return

        if self.path == "/hook/post-command":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {})
                return

            def _on_wt_touched(wt: Path) -> None:
                reg_wt, wt_ign = state.register_workspace(str(wt), warm_now=False)
                if not wt_ign and reg_wt is not None:
                    state.mark_dirty(reg_wt)

            def _on_graphify(wt: Path, reason: str) -> None:
                reg_wt, wt_ign = state.register_workspace(str(wt), warm_now=False)
                if not wt_ign and reg_wt is not None:
                    state.enqueue_graphify(reg_wt, reason)

            resp = harness_core.evaluate_post_command(
                ws_path,
                body,
                on_graphify_trigger=_on_graphify,
                on_worktree_touched=_on_wt_touched,
            )
            state.mark_dirty(ws_path)
            self._send_json(200, resp)
            return

        if self.path == "/hook/pre-subagent":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {"decision": "allow"})
                return
            resp = harness_core.evaluate_pre_subagent(ws_path, body)
            self._send_json(200, resp)
            return

        if self.path == "/hook/stop-gate":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {})
                return
            resp = harness_core.evaluate_stop_gate(
                ws_path,
                body,
                on_swarm_quota_wait=lambda wt: state.notify_swarm_quota_wait(wt),
            )
            self._send_json(200, resp)
            return

        if self.path == "/event/swarm-quota-wait":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {"armed": False, "ignored": True})
                return
            q_state = state.notify_swarm_quota_wait(ws_path)
            self._send_json(
                202,
                {
                    "armed": str(q_state.get("status") or "") in ("waiting", "resuming"),
                    "status": q_state.get("status") or "",
                    "nextProbeEpoch": q_state.get("nextProbeEpoch"),
                },
            )
            return

        if self.path == "/event/graphify":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=False)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            if ignored:
                self._send_json(200, {"queued": False, "ignored": True})
                return
            reason = str(body.get("reason") or "manual_event")
            state.enqueue_graphify(ws_path, reason)
            self._send_json(202, {"queued": True, "state": "pending"})
            return

        if self.path == "/event/workspace-touch":
            ws_path, ignored = state.register_workspace(raw_ws, warm_now=True)
            if ws_path is None:
                self._send_json(400, {"error": "invalid_workspace"})
                return
            self._send_json(200, {"registered": not ignored, "ignored": ignored})
            return

        self._send_json(404, {"error": "not_found"})


def run_daemon() -> int:
    """Initialize environment security, acquire singleton lock, and run daemon server."""
    raw_key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    startup_env_key_present = bool(raw_key) and not (raw_key.startswith("<") and raw_key.endswith(">"))
    del raw_key
    if "TYPESAFE_API_KEY" in os.environ:
        os.environ["TYPESAFE_API_KEY"] = ""

    enrich_fast_fallback_path()

    data_dir = harness_core.default_data_dir()
    data_dir.mkdir(parents=True, exist_ok=True)
    logger = DaemonLogger(data_dir / "daemon.log")

    sock_path = harness_core.default_socket_path()
    try:
        validate_and_prepare_socket_dir(sock_path)
    except Exception as exc:
        logger.log("ERROR", f"Socket security validation failed: {exc}")
        print(f"harness-daemon error: {exc}", file=sys.stderr)
        return 1

    stop_signal = threading.Event()

    def _handle_sig(_signum: int, _frame: Any) -> None:
        stop_signal.set()

    signal.signal(signal.SIGTERM, _handle_sig)
    signal.signal(signal.SIGINT, _handle_sig)

    lock_path = data_dir / "daemon.lock"
    lock_fd = open(lock_path, "a+", encoding="utf-8")
    standby_interval = max(0.1, float(os.environ.get("HARNESS_DAEMON_STANDBY_INTERVAL_SEC", "5.0")))

    # Passive standby loop when another instance holds the advisory lock prevents
    # restart_policy: "always" respawn storms while preserving automatic failover.
    acquired = False
    while not stop_signal.is_set():
        try:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
            break
        except BlockingIOError:
            if os.environ.get("HARNESS_DAEMON_EXIT_ON_LOCK_BUSY") == "1":
                logger.log("INFO", "Another harness-daemon holds lock; auto-start helper exiting cleanly.")
                lock_fd.close()
                return 0
            alive, _ = harness_core.probe_daemon_health(sock_path)
            if alive:
                logger.log("INFO", "Another healthy harness-daemon holds lock; waiting in passive standby.")
            stop_signal.wait(timeout=standby_interval)

    if not acquired or stop_signal.is_set():
        lock_fd.close()
        return 0

    # Re-validate socket directory immediately after lock acquisition to close standby TOCTOU
    try:
        validate_and_prepare_socket_dir(sock_path)
    except Exception as exc:
        logger.log("ERROR", f"Post-lock socket security validation failed: {exc}")
        lock_fd.close()
        return 1

    # Stale socket recovery once advisory lock is held
    if sock_path.exists() or sock_path.is_symlink():
        if sock_path.is_symlink():
            logger.log("ERROR", f"Refusing symlink socket at {sock_path}")
            lock_fd.close()
            return 1
        try:
            sock_st = sock_path.lstat()
            if sock_st.st_uid != os.getuid():
                logger.log("ERROR", f"Refusing socket not owned by UID {os.getuid()}: {sock_path}")
                lock_fd.close()
                return 1
        except OSError as exc:
            logger.log("ERROR", f"Cannot stat socket {sock_path}: {exc}")
            lock_fd.close()
            return 1
        alive, _ = harness_core.probe_daemon_health(sock_path)
        if alive:
            logger.log("ERROR", f"Socket {sock_path} is already served by an active process after lock acquisition; exiting cleanly.")
            lock_fd.close()
            return 1
        try:
            sock_path.unlink()
            logger.log("INFO", f"Removed stale Unix socket at {sock_path}")
        except OSError as exc:
            logger.log("ERROR", f"Cannot unlink stale socket {sock_path}: {exc}")
            lock_fd.close()
            return 1

    pid_path = sock_path.parent / "d.pid"
    state = HarnessDaemonState(data_dir=data_dir, logger=logger, startup_env_key_present=startup_env_key_present)
    server = ThreadingUnixHTTPServer(str(sock_path), DaemonRequestHandler, state)

    try:
        with open(pid_path, "w", encoding="utf-8") as pf:
            pf.write(f"{os.getpid()}\n")
        os.chmod(pid_path, 0o600)
    except OSError:
        pass

    watcher_thread = threading.Thread(target=state.watcher_loop, name="harness-watcher", daemon=True)
    server_thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.25}, name="harness-http", daemon=True)
    watcher_thread.start()
    server_thread.start()
    logger.log("INFO", f"Started harness-daemon pid={os.getpid()} sock={sock_path}")

    while not stop_signal.is_set():
        stop_signal.wait(timeout=0.5)

    logger.log("INFO", "Shutting down harness-daemon gracefully.")
    state.stop_event.set()
    state.wake_event.set()
    try:
        server.shutdown()
        server.server_close()
    except Exception:
        pass
    watcher_thread.join(timeout=2.0)

    for cleanup_path in (sock_path, pid_path):
        try:
            if cleanup_path.exists():
                cleanup_path.unlink()
        except OSError:
            pass
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
        lock_fd.close()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(run_daemon())
