#!/usr/bin/env python3
"""Integration checks for the AutoBox client and server cleanup scripts."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLIENT = ROOT / "Client" / "client.sh"
CLEANUP = ROOT / "Server" / "autobox-cleanup.sh"
MOCK_LOG = pathlib.Path(os.environ.get("MOCK_REQUEST_LOG", ROOT / "tests" / "mock-requests.jsonl"))
GIT = pathlib.Path(r"C:\Program Files\Git")
CYGPATH = GIT / "usr" / "bin" / "cygpath.exe"
SHELLS = {
    "sh": GIT / "usr" / "bin" / "sh.exe",
    "dash": GIT / "usr" / "bin" / "dash.exe",
    "bash": GIT / "bin" / "bash.exe",
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def unix_path(path):
    if CYGPATH.exists():
        return subprocess.check_output([str(CYGPATH), "-u", str(path)], text=True).strip()
    return str(path).replace("\\", "/")


def requests():
    if not MOCK_LOG.exists():
        return []
    return [json.loads(line) for line in MOCK_LOG.read_text(encoding="utf-8").splitlines() if line]


def main():
    for name, shell in SHELLS.items():
        require(shell.exists(), "Missing required shell executable: " + name)
    curl_dir = GIT / "mingw64" / "bin"
    path_entries = [str(GIT / "usr" / "bin"), str(curl_dir), os.environ.get("PATH", "")]
    path_value = os.pathsep.join(path_entries)

    with tempfile.TemporaryDirectory(prefix="autobox-tests-") as temp_name:
        temp = pathlib.Path(temp_name)
        settings = temp / "settings.txt"
        base_settings = (
            "PVE_HOST=127.0.0.1:18006\nPVE_USER=root@pam\nPVE_TOKEN_NAME=client\n"
            "PVE_TOKEN_SECRET=SECRET-123\nPVE_NODE=\nTEMPLATE=sas-bulk:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst\n"
            "CORES=1\nMEMORY=512\nDISK=8\nSTORAGE=ssd-storage\nIP_MODE=dhcp\n"
            "BRIDGE=vmbr0\nROOT_PASSWORD=docker\nNAME_PREFIX=client\nFEATURES=nesting=1,keyctl=1\n"
            "LIFETIME_DAYS=2\nVERIFY_SSL=0\n"
        )
        settings.write_bytes(base_settings.replace("\n", "\r\n").encode("ascii"))

        def run_client(shell, answer, secret="SECRET-123", settings_text=None):
            if settings_text is not None:
                settings.write_bytes(settings_text.replace("\n", "\r\n").encode("ascii"))
            text = settings.read_text(encoding="ascii").replace("SECRET-123", secret)
            settings.write_bytes(text.replace("\n", "\r\n").encode("ascii"))
            env = os.environ.copy()
            env.update({"AUTOBOX_SETTINGS": unix_path(settings), "PATH": path_value})
            return subprocess.run(
                [str(shell), unix_path(CLIENT)], input=answer + "\n", text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=90,
            )

        before = len(requests())
        cancelled = run_client(SHELLS["sh"], "n")
        require(cancelled.returncode == 0 and "Cancelled. Nothing was created." in cancelled.stdout, "n did not cancel cleanly")
        require(len(requests()) == before, "Cancellation made an API request")
        print("PASS: cancellation creates nothing")

        missing_text = "PVE_HOST=\nPVE_TOKEN_NAME=\nPVE_TOKEN_SECRET=\n"
        missing = run_client(SHELLS["sh"], "y", settings_text=missing_text)
        require(missing.returncode != 0 and "Settings are not finished" in missing.stdout, "empty settings were not rejected:\n" + missing.stdout)
        print("PASS: missing settings validation")

        wrong = run_client(SHELLS["sh"], "y", secret="WRONG", settings_text=base_settings)
        require(wrong.returncode != 0 and "token was rejected" in wrong.stdout.lower(), "wrong token did not show a friendly hint:\n" + wrong.stdout)
        print("PASS: wrong-token friendly error")

        settings.write_bytes(base_settings.replace("\n", "\r\n").encode("ascii"))
        for name in ("sh", "dash", "bash"):
            result = run_client(SHELLS[name], "y")
            require(result.returncode == 0, name + " client failed:\n" + result.stdout)
            require("192.0.2.15" in result.stdout and "Password:  docker" in result.stdout, name + " result summary is incomplete")
            print("PASS: client under " + name + " with CRLF settings")

        auto_settings = base_settings.replace(
            "TEMPLATE=sas-bulk:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst\n", "TEMPLATE=\n"
        ).replace("STORAGE=ssd-storage\n", "STORAGE=\n")
        auto_result = run_client(SHELLS["sh"], "y", settings_text=auto_settings)
        require(auto_result.returncode == 0, "automatic template/storage selection failed:\n" + auto_result.stdout)
        print("PASS: automatic template and disk-storage selection")

        entries = requests()
        posts = [entry for entry in entries if entry["method"] == "POST" and entry["path"].split("?", 1)[0].endswith("/lxc")]
        conflicts = [entry for entry in posts if entry["status"] == 500 and entry["body"].get("vmid") == "103"]
        require(conflicts, "conflict was not exercised")
        good_posts = [entry for entry in posts if entry["status"] == 200]
        require(len(good_posts) >= 4, "expected successful creates from each shell and auto-selection case")
        params = good_posts[0]["body"]
        required = {"vmid", "hostname", "ostemplate", "cores", "memory", "swap", "rootfs", "net0", "unprivileged", "password", "start", "tags", "description", "features"}
        require(required.issubset(params), "POST missing fields: " + str(sorted(required - set(params))))
        require(params["tags"] == "autobox;exp-1900172800", "expiry tag did not use Proxmox time")
        require(params["vmid"] != "103" and any("/cluster/nextid?vmid=" in entry["path"] for entry in entries), "retry ID was not verified")
        require("Auto-deleted after" in params["description"], "description missing expiration")
        auto_params = good_posts[-1]["body"]
        require(auto_params["ostemplate"].startswith("template-store:vztmpl/"), "automatic template was not selected")
        require(auto_params["rootfs"] == "local-lvm:8", "preferred local-lvm storage was not selected")
        print("PASS: create fields, server-time expiry tag, and collision retry")

        fake_bin = temp / "bin"
        fake_bin.mkdir()
        fake_log = temp / "pct.log"
        pct = fake_bin / "pct"
        pct.write_text(
            "#!/bin/sh\n"
            "case $1 in\n"
            "  list) printf 'VMID STATUS\n101 running\n102 stopped\n103 running\n' ;;\n"
            "  config) case $2 in\n"
            "    101) printf 'tags: extra,autobox,exp-1\\n' ;;\n"
            "    102) printf 'tags: autobox,exp-9999999999\\n' ;;\n"
            "    103) printf 'tags: other;exp-1\\n' ;;\n"
            "  esac ;;\n"
            "  stop|destroy) printf '%s\\n' \"$*\" >> \"$FAKE_PCT_LOG\" ;;\n"
            "esac\n",
            encoding="ascii",
        )
        pct.chmod(0o755)
        env = os.environ.copy()
        env.update({
            "PATH": str(fake_bin) + os.pathsep + path_value,
            "FAKE_PCT_LOG": str(fake_log),
            "AUTOBOX_CLEANUP_LOG": str(temp / "cleanup.log"),
        })
        cleanup = subprocess.run([str(SHELLS["sh"]), unix_path(CLEANUP)], env=env, text=True, capture_output=True, timeout=30)
        require(cleanup.returncode == 0, "cleanup script failed: " + cleanup.stderr)
        pct_calls = fake_log.read_text(encoding="ascii").splitlines()
        require("stop 101" in pct_calls and "destroy 101 --purge" in pct_calls, "expired running container was not stopped and destroyed")
        require(not any("102" in call or "103" in call for call in pct_calls), "cleanup touched non-expired or non-AutoBox container")
        print("PASS: cleanup destroys only expired AutoBox container")

    print("All AutoBox integration checks passed.")


if __name__ == "__main__":
    main()
