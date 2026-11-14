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
        self.created = {}
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
            data = {"status": "stopped", "exitstatus": "OK"}
        elif method == "GET" and "/tasks/" in path and path.endswith("/log"):
            data = [{"t": "container created"}]
        elif method == "GET" and "/lxc/" in path and path.endswith("/interfaces"):
            data = [{"name": "lo", "inet": "127.0.0.1/8"}, {"name": "eth0", "inet": "192.0.2.15/24"}]
        else:
            status = 404
            data = {"error": "unhandled mock route: %s %s" % (method, path)}

        self.reply(status, data)
        self.record(method, self.path, form if method == "POST" else query, status)

    def do_GET(self):
        self.handle_api("GET")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        self.handle_api("POST", body)


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
