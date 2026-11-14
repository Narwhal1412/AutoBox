#!/usr/bin/env python3
"""Small local HTTPS API mock for the AutoBox clients."""
import argparse
import http.server
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, unquote, urlparse

TOKEN = "PVEAPIToken=root@pam!client=SECRET-123"
DEFAULT_TIME = int(os.environ.get("MOCK_TIME", "1900000000"))
REQUEST_LOG = os.environ.get("MOCK_REQUEST_LOG", "")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.conflict = os.environ.get("MOCK_CONFLICT") == "1"
        self.conflict_done = False
        self.vm_conflict = os.environ.get("MOCK_VM_CONFLICT") == "1"
        self.vm_conflict_done = False
        self.created = {}
        self.vms = {}
        self.agent_calls = {}
        self.task_polls = {}
        self.occupied = set()
        self.requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "AutoBoxMock/1.0"

    def log_message(self, _format, *_args):
        return

    def reply(self, status, data):
        payload = json.dumps({"data": data}, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def record(self, method, path, body, status):
        if isinstance(body, dict):
            body = {key: (value[0] if isinstance(value, list) and len(value) == 1 else value) for key, value in body.items()}
        entry = {"method": method, "path": path, "body": body, "status": status}
        with self.server.state.lock:
            self.server.state.requests.append(entry)
            if REQUEST_LOG:
                with open(REQUEST_LOG, "a", encoding="utf-8") as output:
                    output.write(json.dumps(entry, separators=(",", ":")) + "\n")
        print(json.dumps(entry, separators=(",", ":")), flush=True)

    def authorized(self):
        return self.headers.get("Authorization") == TOKEN

    def handle_api(self, method, body=""):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        form = parse_qs(body, keep_blank_values=True)
        self.path = parsed.path + (("?" + parsed.query) if parsed.query else "")

        if not self.authorized():
            self.reply(401, None)
            self.record(method, self.path, form, 401)
            return

        state = self.server.state
        status = 200
        if method == "GET" and path == "/api2/json/nodes":
            data = [{"node": "pve"}]
        elif method == "GET" and path == "/api2/json/nodes/pve/status":
            data = {"time": DEFAULT_TIME}
        elif method == "GET" and path == "/api2/json/nodes/pve/storage":
            content = query.get("content", [""])[0]
            if content == "vztmpl":
                data = [{"storage": "template-store", "content": "vztmpl"}]
            else:
                data = [
                    {"storage": "local-lvm", "content": "rootdir"},
                    {"storage": "ssd-storage", "content": "rootdir"},
                ]
        elif method == "GET" and path.startswith("/api2/json/nodes/pve/storage/") and path.endswith("/content"):
            store = path.split("/")[-2]
            data = [{"volid": store + ":vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"}]
        elif method == "GET" and "/qemu/" in path and path.endswith("/config"):
            vmid = int(path.split("/")[-2])
            if vmid == 9000:
                data = {"template": 1, "scsi0": "local-lvm:vm-9000-disk-0,size=8G", "net0": "virtio,bridge=vmbr0", "tags": "template-base"}
            elif vmid in state.vms:
                data = state.vms[vmid]
            else:
                data = {"template": 0, "scsi0": "local-lvm:vm-%d-disk-0,size=8G" % vmid}
        elif method == "GET" and path == "/api2/json/cluster/nextid":
            if "vmid" not in query:
                candidate = 103
                while candidate in state.occupied:
                    candidate += 1
                data = candidate
            else:
                candidate = int(query["vmid"][0])
                while candidate in state.occupied:
                    candidate += 1
                data = candidate
        elif method == "GET" and "/qemu/" in path and path.endswith("/agent/network-get-interfaces"):
            vmid = int(path.split("/")[-3])
            count = state.agent_calls.get(vmid, 0) + 1
            state.agent_calls[vmid] = count
            if count == 1:
                status = 500
                data = {"error": "guest agent is not ready"}
            elif count == 2:
                data = {"result": []}
            else:
                data = {"result": [
                    {"name": "lo", "ip-addresses": [{"ip-address": "127.0.0.1", "ip-address-type": "ipv4"}]},
                    {"name": "ens18", "ip-addresses": [
                        {"ip-address": "192.0.2.30", "ip-address-type": "ipv4"},
                        {"ip-address": "2001:db8::30", "ip-address-type": "ipv6"},
                    ]},
                ]}
        elif method == "POST" and "/qemu/" in path and path.endswith("/clone"):
            params = {key: values[0] for key, values in form.items()}
            vmid = int(params.get("newid", "0"))
            if state.vm_conflict and not state.vm_conflict_done:
                state.vm_conflict_done = True
                state.occupied.add(vmid)
                status = 500
                payload = json.dumps({"data": None, "errors": {"newid": "CT %d already exists" % vmid}}, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.record(method, self.path, params, status)
                return
            if vmid in state.occupied:
                status = 500
                payload = json.dumps({"data": None, "errors": {"newid": "CT %d already exists" % vmid}}, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.record(method, self.path, params, status)
                return
            state.occupied.add(vmid)
            target_storage = params.get("storage", "local-lvm")
            state.vms[vmid] = {"template": 0, "scsi0": "%s:vm-%d-disk-0,size=8G" % (target_storage, vmid),
                               "net0": "virtio,bridge=vmbr0", "tags": "template-base", "name": params.get("name", "")}
            data = "UPID:pve:00000000:00000000:00000000:qmclone:%d:root@pam:" % vmid
        elif method == "PUT" and "/qemu/" in path and path.endswith("/config"):
            params = {key: values[0] for key, values in form.items()}
            vmid = int(path.split("/")[-2])
            state.vms.setdefault(vmid, {}).update(params)
            data = None
        elif method == "PUT" and "/qemu/" in path and path.endswith("/resize"):
            data = "UPID:pve:00000000:00000000:00000000:qmresize:%s:root@pam:" % path.split("/")[-2]
        elif method == "POST" and "/qemu/" in path and path.endswith("/status/start"):
            data = "UPID:pve:00000000:00000000:00000000:qmstart:%s:root@pam:" % path.split("/")[-3]
        elif method == "POST" and path == "/api2/json/nodes/pve/lxc":
            params = {key: values[0] for key, values in form.items()}
            vmid = int(params.get("vmid", "0"))
            if state.conflict and not state.conflict_done and vmid == 103:
                state.conflict_done = True
                state.occupied.add(103)
                status = 500
                payload = json.dumps({"data": None, "errors": {"vmid": "CT 103 already exists"}}, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.record(method, self.path, params, status)
                return
            if vmid in state.occupied:
                status = 500
                payload = json.dumps({"data": None, "errors": {"vmid": "CT %s already exists" % vmid}}, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.record(method, self.path, params, status)
                return
            state.occupied.add(vmid)
            state.created[vmid] = params
            data = "UPID:pve:00000000:00000000:00000000:vzcreate:%d:root@pam:" % vmid
        elif method == "GET" and "/tasks/" in path and path.endswith("/status"):
            task_id = path.split("/tasks/", 1)[1].split("/", 1)[0]
            task_parts = task_id.split(":")
            task_kind = next((part for part in task_parts if part in ("qmclone", "qmstart")), "")
            task_vmid = 0
            if task_kind and task_parts.index(task_kind) + 1 < len(task_parts):
                try:
                    task_vmid = int(task_parts[task_parts.index(task_kind) + 1])
                except ValueError:
                    task_vmid = 0
            vm_name = state.vms.get(task_vmid, {}).get("name", "")
            delayed = (task_kind == "qmclone" and vm_name.startswith("slowclone")) or (task_kind == "qmstart" and vm_name.startswith("slowstart"))
            polls = state.task_polls.get(task_id, 0) + 1
            state.task_polls[task_id] = polls
            if delayed and polls <= 2:
                data = {"status": "running"}
            else:
                data = {"status": "stopped", "exitstatus": "OK"}
        elif method == "GET" and "/tasks/" in path and path.endswith("/log"):
            data = [{"t": "container created"}]
        elif method == "GET" and "/lxc/" in path and path.endswith("/interfaces"):
            data = [{"name": "lo", "inet": "127.0.0.1/8"}, {"name": "eth0", "inet": "192.0.2.15/24"}]
        else:
            status = 404
            data = {"error": "unhandled mock route: %s %s" % (method, path)}

        self.reply(status, data)
        self.record(method, self.path, form if method in ("POST", "PUT") else query, status)

    def do_GET(self):
        self.handle_api("GET")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        self.handle_api("POST", body)

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        self.handle_api("PUT", body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18006)
    args = parser.parse_args()
    openssl = shutil.which("openssl")
    if not openssl:
        raise SystemExit("openssl is required to generate the local self-signed certificate")
    with tempfile.TemporaryDirectory(prefix="autobox-mock-") as temp_dir:
        cert = os.path.join(temp_dir, "cert.pem")
        key = os.path.join(temp_dir, "key.pem")
        subprocess.run([
            openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", key, "-out", cert, "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        server.state = State()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        print("AutoBox mock listening at https://127.0.0.1:%d" % args.port, flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()


if __name__ == "__main__":
    main()
