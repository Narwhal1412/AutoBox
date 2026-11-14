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
CLIENT_VM = ROOT / "Client" / "client-vm.sh"
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
    if MOCK_LOG.exists():
        MOCK_LOG.unlink()
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
            "LIFETIME_DAYS=2\nVERIFY_SSL=0\nVM_TEMPLATE_ID=9000\nVM_NAME_PREFIX=vm\n"
            "VM_CORES=2\nVM_MEMORY=2048\nVM_DISK_GB=16\nVM_STORAGE=fast-storage\n"
            "VM_USER=root\nVM_PASSWORD=docker\nVM_IP_MODE=dhcp\nVM_BRIDGE=vmbr9\n"
            "VM_GUEST_OS=linux\nVM_CLONE_MODE=full\nVM_CLONE_TIMEOUT=1800\n"
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

        def run_vm(shell, answer, settings_text=None):
            if settings_text is not None:
                settings.write_bytes(settings_text.replace("\n", "\r\n").encode("ascii"))
            env = os.environ.copy()
            env.update({"AUTOBOX_SETTINGS": unix_path(settings), "PATH": path_value})
            return subprocess.run(
                [str(shell), unix_path(CLIENT_VM)], input=answer + "\n", text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=180,
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

        vm_missing_text = base_settings.replace("VM_TEMPLATE_ID=9000\n", "VM_TEMPLATE_ID=\n")
        vm_missing = run_vm(SHELLS["sh"], "y", settings_text=vm_missing_text)
        require(vm_missing.returncode != 0 and "VM_TEMPLATE_ID" in vm_missing.stdout and "Settings are not finished" in vm_missing.stdout,
            "unfinished VM template setting was not identified:\n" + vm_missing.stdout)
        vm_non_template_text = base_settings.replace("VM_TEMPLATE_ID=9000\n", "VM_TEMPLATE_ID=9999\n")
        vm_non_template = run_vm(SHELLS["sh"], "y", settings_text=vm_non_template_text)
        require(vm_non_template.returncode != 0 and "VM_TEMPLATE_ID 9999 is not a Proxmox VM template" in vm_non_template.stdout,
            "non-template VMID did not show a friendly error:\n" + vm_non_template.stdout)
        print("PASS: unfinished and non-template VMID validation")

        settings.write_bytes(base_settings.replace("\n", "\r\n").encode("ascii"))
        for name in ("sh", "dash", "bash"):
            result = run_vm(SHELLS[name], "y")
            require(result.returncode == 0, name + " VM client failed:\n" + result.stdout)
            require("192.0.2.30" in result.stdout and "Password:" in result.stdout,
                name + " VM result summary is incomplete")
            print("PASS: VM client under " + name + " with CRLF settings")

        windows_settings = base_settings.replace("VM_GUEST_OS=linux\n", "VM_GUEST_OS=windows\n").replace(
            "VM_CLONE_MODE=full\n", "VM_CLONE_MODE=linked\n"
        ).replace("VM_DISK_GB=16\n", "VM_DISK_GB=4\n")
        windows_result = run_vm(SHELLS["sh"], "y", settings_text=windows_settings)
        require(windows_result.returncode == 0 and "credentials must already exist inside the template" in windows_result.stdout,
                "Windows guest mode did not complete or show the credentials note:\n" + windows_result.stdout)

        entries = requests()
        clones = [entry for entry in entries if entry["method"] == "POST" and entry["path"].endswith("/clone")]
        clone_conflicts = [entry for entry in clones if entry["status"] == 500]
        successful_clones = [entry for entry in clones if entry["status"] == 200]
        require(clone_conflicts and len(successful_clones) >= 4, "VM clone collision/retry was not exercised")
        clone_params = successful_clones[0]["body"]
        require({"newid", "name", "full", "storage"}.issubset(clone_params), "clone POST fields are incomplete")
        require(clone_params["full"] == "1" and clone_params["storage"] == "fast-storage", "full clone/storage fields are incorrect")
        linked_clone = successful_clones[-1]["body"]
        require(linked_clone["full"] == "0", "linked clone did not send full=0")
        config_puts = [entry for entry in entries if entry["method"] == "PUT" and entry["path"].endswith("/config")]
        require(len(config_puts) >= 3, "VM configuration PUT requests were missing")
        config_params = config_puts[0]["body"]
        require(config_params["tags"] == "autobox;exp-1900172800" and config_params["cipassword"] == "docker",
            "VM config PUT tags/password are incorrect")
        require(config_params["cores"] == "2" and config_params["memory"] == "2048" and config_params["agent"] == "1",
            "VM config PUT resource/agent fields are incorrect")
        require(config_params["ipconfig0"] == "ip=dhcp" and config_params["net0"] == "virtio,bridge=vmbr9",
            "VM config PUT network fields are incorrect")
        windows_vmid = linked_clone["newid"]
        windows_config = next(entry["body"] for entry in config_puts if entry["path"].endswith("/qemu/%s/config" % windows_vmid))
        require(not ({"ciuser", "cipassword", "ipconfig0"} & set(windows_config)),
            "Windows config PUT unexpectedly contains cloud-init fields")
        require(windows_config["tags"] == "autobox;exp-1900172800" and windows_config["description"].startswith("AutoBox temporary VM."),
            "Windows config PUT is missing the expiry tag/description")
        require(all(entry["path"].split("/")[-2] != "9000" for entry in config_puts), "template VM was modified")
        resize_puts = [entry for entry in entries if entry["method"] == "PUT" and entry["path"].endswith("/resize")]
        require(len(resize_puts) >= 3 and resize_puts[0]["body"] == {"disk": "scsi0", "size": "16G"},
            "VM disk resize request is incorrect")
        require("smaller than the template disk" in windows_result.stdout, "smaller requested disk did not produce a warning")
        starts = [entry for entry in entries if entry["method"] == "POST" and entry["path"].endswith("/status/start")]
        require(len(starts) >= 3, "VM start was not requested")
        agent_calls = [entry for entry in entries if entry["path"].endswith("/agent/network-get-interfaces")]
        require(len(agent_calls) >= 9 and [entry["status"] for entry in agent_calls[:3]] == [500, 200, 200],
            "guest-agent error/empty/retry sequence was not exercised")
        require(any("/cluster/nextid?vmid=" in entry["path"] for entry in entries), "VM collision candidate ID was not verified")
        print("PASS: VM clone, config tags/password, resize, start, guest-agent retry, and collision retry")

        vm_shell_source = CLIENT_VM.read_text(encoding="ascii")
        vm_ps_source = (ROOT / "Client" / "client-vm.ps1").read_text(encoding="ascii")
        require('VM_CLONE_TIMEOUT=1800\n' in base_settings and '"$W_ELAPSED" -lt "$VM_CLONE_TIMEOUT"' in vm_shell_source,
            "shell VM task wait does not use the 1800-second setting")
        require("AddSeconds($script:CloneTimeout)" in vm_ps_source, "PowerShell VM task wait does not use VM_CLONE_TIMEOUT")

        slow_clone_settings = base_settings.replace("VM_NAME_PREFIX=vm\n", "VM_NAME_PREFIX=slowclone\n").replace(
            "VM_CLONE_TIMEOUT=1800\n", "VM_CLONE_TIMEOUT=3\n"
        )
        slow_clone = run_vm(SHELLS["sh"], "y", settings_text=slow_clone_settings)
        require(slow_clone.returncode != 0 and "timed out waiting" in slow_clone.stdout.lower() and
            "Cloning a large disk can take several minutes..." in slow_clone.stdout and "minutes...." in slow_clone.stdout,
            "clone task did not honor the configured timeout/show progress:\n" + slow_clone.stdout)

        slow_start_settings = base_settings.replace("VM_NAME_PREFIX=vm\n", "VM_NAME_PREFIX=slowstart\n").replace(
            "VM_CLONE_TIMEOUT=1800\n", "VM_CLONE_TIMEOUT=3\n"
        )
        slow_start = run_vm(SHELLS["sh"], "y", settings_text=slow_start_settings)
        require(slow_start.returncode != 0 and "timed out waiting" in slow_start.stdout.lower() and
            "Starting VM..." in slow_start.stdout and "Starting VM...." in slow_start.stdout,
            "start task did not honor the configured timeout/show progress:\n" + slow_start.stdout)
        print("PASS: clone/start timeout setting and progress messages")

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
        fake_qm_log = temp / "qm.log"
        qm = fake_bin / "qm"
        qm.write_text(
            "#!/bin/sh\n"
            "case $1 in\n"
            "  list) printf 'VMID NAME STATUS\\n201 expired running\\n202 future running\\n203 untagged running\\n204 template stopped\\n' ;;\n"
            "  config) case $2 in\n"
            "    201) printf 'tags: autobox;exp-1\\n' ;;\n"
            "    202) printf 'tags: autobox;exp-9999999999\\n' ;;\n"
            "    203) printf 'tags: other;exp-1\\n' ;;\n"
            "    204) printf 'template: 1\\ntags: autobox;exp-1\\n' ;;\n"
            "  esac ;;\n"
            "  stop|destroy) printf '%s\\n' \"$*\" >> \"$FAKE_QM_LOG\" ;;\n"
            "esac\n",
            encoding="ascii",
        )
        qm.chmod(0o755)
        env = os.environ.copy()
        env.update({
            "PATH": str(fake_bin) + os.pathsep + path_value,
            "FAKE_PCT_LOG": str(fake_log),
            "FAKE_QM_LOG": str(fake_qm_log),
            "AUTOBOX_CLEANUP_LOG": str(temp / "cleanup.log"),
        })
        cleanup = subprocess.run([str(SHELLS["sh"]), unix_path(CLEANUP)], env=env, text=True, capture_output=True, timeout=30)
        require(cleanup.returncode == 0, "cleanup script failed: " + cleanup.stderr)
        pct_calls = fake_log.read_text(encoding="ascii").splitlines()
        require("stop 101" in pct_calls and "destroy 101 --purge" in pct_calls, "expired running container was not stopped and destroyed")
        require(not any("102" in call or "103" in call for call in pct_calls), "cleanup touched non-expired or non-AutoBox container")
        qm_calls = fake_qm_log.read_text(encoding="ascii").splitlines()
        require("stop 201" in qm_calls and "destroy 201 --purge --destroy-unreferenced-disks 1" in qm_calls,
            "expired running AutoBox VM was not stopped and destroyed")
        require(not any(any(vm_id in call.split() for vm_id in ("202", "203", "204")) for call in qm_calls),
            "cleanup touched non-expired, untagged, or template VM")
        print("PASS: cleanup preserves container behavior and destroys only expired tagged VM")

    print("All AutoBox integration checks passed.")


if __name__ == "__main__":
    main()
