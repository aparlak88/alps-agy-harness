#!/usr/bin/env bash
# Alps AGY Harness - Environment & Setup Diagnostics (harness-doctor.sh)
# Usage: harness-doctor.sh [--workspace <dir>] [--json]
set -euo pipefail

workspace=""
json_mode=false

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --json)
      json_mode=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$workspace" ]; then
  workspace="$PWD"
fi

config_dir="${HARNESS_CONFIG_DIR:-$HOME/.gemini/config}"
typesafe_key_file="${HARNESS_TYPESAFE_KEY_FILE:-$HOME/.config/typesafe/key}"
gh_bin="${HARNESS_GH_BIN:-gh}"
xcrun_bin="${HARNESS_XCRUN_BIN:-xcrun}"
adb_bin="${HARNESS_ADB_BIN:-adb}"

python3 -c '
import os, sys, json, shutil, subprocess, fnmatch

workspace = sys.argv[1]
config_dir = sys.argv[2]
typesafe_key_file = sys.argv[3]
gh_bin = sys.argv[4]
xcrun_bin = sys.argv[5]
adb_bin = sys.argv[6]
json_mode = (sys.argv[7] == "true")

# Zero-secret-leakage check: do not store the key value anywhere
raw_env_key = os.environ.get("TYPESAFE_API_KEY", "").strip()
has_env_key = bool(raw_env_key) and not (raw_env_key.startswith("<") and raw_env_key.endswith(">"))
del raw_env_key
if "TYPESAFE_API_KEY" in os.environ:
    # Scrub from python process environment to prevent accidental string inspection
    os.environ["TYPESAFE_API_KEY"] = ""

checks = []

def add_check(name, group, status, message, fix=None, extra=None):
    if fix:
        fix_clean = fix.strip()
        if not fix_clean.startswith("Fix:"):
            fix = f"Fix: {fix_clean}"
        else:
            fix = fix_clean
    c = {
        "name": name,
        "group": group,
        "status": status,
        "message": message,
        "fix": fix
    }
    if extra:
        c.update(extra)
    checks.append(c)

# -------------------------------------------------------------
# 1. CLI Tools & GitHub Auth
# -------------------------------------------------------------
# git
if shutil.which("git"):
    v = subprocess.run(["git", "--version"], capture_output=True, text=True).stdout.strip()
    add_check("git", "cli", "OK", v)
else:
    add_check("git", "cli", "FAIL", "git is not installed", "brew install git")

# jq
if shutil.which("jq"):
    v = subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip()
    add_check("jq", "cli", "OK", f"jq {v}")
else:
    add_check("jq", "cli", "FAIL", "jq is not installed", "brew install jq")

# node >= 20
node_path = shutil.which("node")
if node_path:
    v = subprocess.run([node_path, "-v"], capture_output=True, text=True).stdout.strip()
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

# python3
if shutil.which("python3"):
    v = subprocess.run(["python3", "--version"], capture_output=True, text=True).stdout.strip()
    add_check("python3", "cli", "OK", v)
else:
    add_check("python3", "cli", "FAIL", "python3 is not installed", "brew install python")

# uv
if shutil.which("uv"):
    v = subprocess.run(["uv", "--version"], capture_output=True, text=True).stdout.strip()
    add_check("uv", "cli", "OK", v)
else:
    add_check("uv", "cli", "FAIL", "uv is not installed", "curl -LsSf https://astral.sh/uv/install.sh | sh")

# gh auth
gh_path = shutil.which(gh_bin) or (gh_bin if os.path.isabs(gh_bin) and os.path.isfile(gh_bin) else None)
if gh_path:
    res = subprocess.run([gh_path, "auth", "status"], capture_output=True, text=True)
    if res.returncode == 0:
        add_check("gh_auth", "cli", "OK", "GitHub CLI authenticated")
    else:
        add_check("gh_auth", "cli", "FAIL", "GitHub CLI not authenticated", "gh auth login")
else:
    add_check("gh_auth", "cli", "FAIL", f"GitHub CLI ({gh_bin}) not installed", "brew install gh")

# -------------------------------------------------------------
# 2. Plugin Dependencies (superpowers, firebase, postman, chrome-devtools-plugin)
# -------------------------------------------------------------
def check_plugin(name):
    # Dir in config_dir/plugins or workspace/.agents/plugins
    if os.path.isdir(os.path.join(config_dir, "plugins", name)):
        return True
    if os.path.isdir(os.path.join(workspace, ".agents", "plugins", name)):
        return True
    
    # Check JSON files
    for base in [config_dir, os.path.join(workspace, ".agents")]:
        for fn in ["plugins.json", "config.json"]:
            fp = os.path.join(base, fn)
            if os.path.isfile(fp):
                try:
                    with open(fp, "r", errors="replace") as f:
                        data = json.load(f)
                    if isinstance(data, dict):
                        if name in data.get("plugins", {}):
                            return True
                        plist = data.get("plugins", [])
                        if isinstance(plist, list):
                            for p in plist:
                                if isinstance(p, dict) and p.get("name") == name:
                                    return True
                                elif p == name:
                                    return True
                    elif isinstance(data, list):
                        if name in data:
                            return True
                except Exception:
                    pass
    return False

plugins_to_check = [
    ("superpowers", "superpowers framework plugin", "git clone https://github.com/obra/superpowers.git ~/.gemini/config/plugins/superpowers"),
    ("firebase", "firebase marketplace plugin", "agy plugin install firebase"),
    ("postman", "postman marketplace plugin", "agy plugin install postman"),
    ("chrome-devtools-plugin", "chrome-devtools-plugin marketplace plugin", "agy plugin install chrome-devtools-plugin")
]

for p_name, p_desc, p_fix in plugins_to_check:
    if check_plugin(p_name):
        add_check(p_name, "plugins", "OK", f"Plugin {p_name} is installed")
    else:
        add_check(p_name, "plugins", "FAIL", f"Plugin {p_name} is missing ({p_desc})", f"Fix: {p_fix}")

# -------------------------------------------------------------
# 3. 8 Mandatory Global MCP Servers
# -------------------------------------------------------------
mcp_file = os.path.join(config_dir, "mcp_config.json")
mcp_servers = {}
if os.path.isfile(mcp_file):
    try:
        with open(mcp_file, "r", errors="replace") as f:
            mcp_data = json.load(f)
        if isinstance(mcp_data, dict):
            mcp_servers = mcp_data.get("mcpServers", {})
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
    ("filesystem", "Add filesystem to ~/.gemini/config/mcp_config.json: npx -y @modelcontextprotocol/server-filesystem")
]

for mcp_name, mcp_fix in mandatory_mcps:
    if mcp_name in mcp_servers:
        add_check(mcp_name, "mcp", "OK", f"MCP server {mcp_name} configured")
    else:
        add_check(mcp_name, "mcp", "FAIL", f"Mandatory MCP server {mcp_name} missing from mcp_config.json", f"Fix: {mcp_fix}")

# -------------------------------------------------------------
# 4. Zero-Secret-Leakage TYPESAFE_API_KEY Readiness (Review Focus #5)
# -------------------------------------------------------------
has_file_key = False
if os.path.isfile(typesafe_key_file):
    try:
        with open(typesafe_key_file, "r", errors="replace") as f:
            has_file_key = bool(f.read().strip())
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
    all_cmd_str = cmd + " " + " ".join(str(a) for a in args_list) if isinstance(args_list, list) else cmd

    is_custom_script = cmd.endswith(".sh") and os.path.isfile(os.path.expanduser(cmd))
    is_keychain = ("keychain" in all_cmd_str.lower()) or ("security find-generic-password" in all_cmd_str.lower())

    if is_custom_script or is_keychain:
        has_mcp_key = True

key_present = has_env_key or has_file_key or has_mcp_key
if key_present:
    add_check("typesafe_api_key", "security", "OK", "TYPESAFE_API_KEY is present", extra={"key_status": "present"})
else:
    add_check("typesafe_api_key", "security", "FAIL", "TYPESAFE_API_KEY is missing",
              fix="Fix: export TYPESAFE_API_KEY=\"<key>\" or store in ~/.config/typesafe/key",
              extra={"key_status": "missing"})

# -------------------------------------------------------------
# 5. LSP, Graphify & Platform-Sensitive Mobile Tools
# -------------------------------------------------------------
# csharp-ls
if shutil.which("csharp-ls"):
    add_check("csharp-ls", "lsp", "OK", "csharp-ls is installed")
else:
    add_check("csharp-ls", "lsp", "WARN", "csharp-ls not found in PATH", "Fix: dotnet tool install -g csharp-ls")

# csharp-lsp-mcp
if shutil.which("csharp-lsp-mcp"):
    add_check("csharp-lsp-mcp", "lsp", "OK", "csharp-lsp-mcp is installed")
else:
    add_check("csharp-lsp-mcp", "lsp", "WARN", "csharp-lsp-mcp not found in PATH", "Fix: npm install -g @alps/csharp-lsp-mcp")

# graphify
if shutil.which("graphify") or ("graphify" in mcp_servers):
    add_check("graphify", "lsp", "OK", "graphify is available")
else:
    add_check("graphify", "lsp", "WARN", "graphify not found in PATH", "Fix: uv tool install graphifyy")

# iOS project check
has_ios = False
for root, dirs, files in os.walk(workspace):
    if ".git" in root or ".harness" in root:
        continue
    for d in dirs:
        if d.endswith(".xcodeproj") or d.endswith(".xcworkspace"):
            has_ios = True
            break
    for f in files:
        if f in ["Podfile", "Package.swift"]:
            has_ios = True
            break
    if has_ios:
        break

xcrun_found = bool(shutil.which(xcrun_bin) or (os.path.isabs(xcrun_bin) and os.path.isfile(xcrun_bin)))
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

# Android project check
has_android = False
for root, dirs, files in os.walk(workspace):
    if ".git" in root or ".harness" in root:
        continue
    for f in files:
        if f in ["build.gradle", "build.gradle.kts", "AndroidManifest.xml"]:
            has_android = True
            break
    if has_android:
        break

adb_found = bool(shutil.which(adb_bin) or (os.path.isabs(adb_bin) and os.path.isfile(adb_bin)))
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

# -------------------------------------------------------------
# 6. Active Workspace Health
# -------------------------------------------------------------
# Install mode
if os.path.isfile(os.path.join(workspace, ".harness-ignore")):
    add_check("install_mode", "workspace", "INFO", ".harness-ignore active (harness disabled for this workspace)")
elif os.path.isdir(os.path.join(workspace, ".agents", "plugins")) or os.path.isfile(os.path.join(workspace, ".agents", "plugins.json")):
    add_check("install_mode", "workspace", "OK", "Project-level plugin installed")
elif os.path.isdir(os.path.join(config_dir, "plugins", "alps-agy-harness")):
    add_check("install_mode", "workspace", "OK", "Global plugin active")
else:
    add_check("install_mode", "workspace", "INFO", "Standalone workspace")

# .harness/ git-ignore check
git_dir = os.path.join(workspace, ".git")
if os.path.exists(git_dir):
    res = subprocess.run(["git", "-C", workspace, "check-ignore", "-q", ".harness/"], capture_output=True)
    is_ignored = (res.returncode == 0)
    if not is_ignored:
        for ef in [os.path.join(git_dir, "info", "exclude"), os.path.join(workspace, ".gitignore")]:
            if os.path.isfile(ef):
                try:
                    with open(ef, "r", errors="replace") as f:
                        if ".harness/" in f.read():
                            is_ignored = True
                            break
                except Exception:
                    pass
    if is_ignored:
        add_check("git_exclude", "workspace", "OK", ".harness/ is git-ignored")
    else:
        add_check("git_exclude", "workspace", "WARN", ".harness/ not ignored in git", "Fix: add .harness/ to .git/info/exclude")
else:
    add_check("git_exclude", "workspace", "INFO", "Not a git repository")

# Canon docs
canon_docs = [
    os.path.join(workspace, "docs", "canon", "glossary.md"),
    os.path.join(workspace, "docs", "canon", "flows.md"),
    os.path.join(workspace, "docs", "canon", "lessons.md")
]
if all(os.path.isfile(p) for p in canon_docs):
    add_check("canon_docs", "workspace", "OK", "docs/canon/{glossary,flows,lessons}.md present")
else:
    add_check("canon_docs", "workspace", "WARN", "Target project canon uninitialized", "Fix: Create docs/canon/{glossary,flows,lessons}.md")

# Graphify graph
graph_file = os.path.join(workspace, "graphify-out", "graph.json")
if os.path.isfile(graph_file):
    add_check("graphify_graph", "workspace", "OK", "graphify-out/graph.json present")
else:
    add_check("graphify_graph", "workspace", "WARN", "graphify-out/graph.json uninitialized", "Fix: run graphify on project root")

# -------------------------------------------------------------
# Results & Exit Code
# -------------------------------------------------------------
total = len(checks)
ok_count = sum(1 for c in checks if c["status"] == "OK")
warn_count = sum(1 for c in checks if c["status"] == "WARN")
info_count = sum(1 for c in checks if c["status"] == "INFO")
fail_count = sum(1 for c in checks if c["status"] == "FAIL")

healthy = (fail_count == 0)

if json_mode:
    output_obj = {
        "healthy": healthy,
        "summary": {
            "total": total,
            "ok": ok_count,
            "warn": warn_count,
            "info": info_count,
            "fail": fail_count
        },
        "checks": checks
    }
    print(json.dumps(output_obj, indent=2))
else:
    print("==================================================")
    print(" Alps AGY Harness - Environment & Setup Doctor")
    print("==================================================")
    print(f"Workspace:  {workspace}")
    print(f"Config Dir: {config_dir}")
    print("")

    group_labels = {
        "cli": "1. CLI Tools & GitHub Authentication",
        "plugins": "2. Plugin Dependencies",
        "mcp": "3. Mandatory Global MCP Servers",
        "security": "4. Zero-Secret TYPESAFE_API_KEY Readiness",
        "lsp": "5. LSP & Graphify Tools",
        "mobile": "6. Mobile Platform Tools",
        "workspace": "7. Active Workspace Health"
    }

    current_group = None
    for c in checks:
        g = c["group"]
        if g != current_group:
            current_group = g
            print(f"\n--- {group_labels.get(g, g.upper())} ---")
        
        status_sym = {
            "OK": "[OK]  ",
            "WARN": "[WARN]",
            "INFO": "[INFO]",
            "FAIL": "[FAIL]"
        }.get(c["status"], "[????]")
        
        c_name = c["name"]
        c_msg = c["message"]
        c_fix = c["fix"]
        print(f"  {status_sym} {c_name}: {c_msg}")
        if c_fix:
            fix_str = c_fix if c_fix.startswith("Fix:") else f"Fix: {c_fix}"
            print(f"         {fix_str}")

    print("\n==================================================")
    print(f"Summary: {total} checks ({ok_count} OK, {warn_count} WARN, {info_count} INFO, {fail_count} FAIL)")
    if healthy:
        print("✅ Result: ALL MANDATORY CHECKS HEALTHY")
    else:
        print("❌ Result: ACTION REQUIRED — MANDATORY CHECKS FAILED")
    print("==================================================")

sys.exit(0 if healthy else 1)
' "$workspace" "$config_dir" "$typesafe_key_file" "$gh_bin" "$xcrun_bin" "$adb_bin" "$json_mode"
