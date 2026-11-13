#!/usr/bin/env python3
"""The test channel of Founderizer for Windows (README.md in this folder, "The test channel"): a small HTTPS server on
this Mac that answers `GET /releases/windows?arch=...` as our channel does (windows-app-release-design.md, section 3)
with a manifest that a TEST key signed, and serves the build's zip. The VM reaches it at 10.0.2.2 (QEMU's address of
this Mac's own 127.0.0.1); it listens on 127.0.0.1 only, so it serves nothing to the private network or the LAN.

Only a build with the proofs' switch reads it, from the proofs' variables (FOUNDERIZER_UPDATE_CHANNEL, _KEY, _PIN);
a release build holds neither its address nor its key. The test key is made here, in the channel's own folder (outside
any repository, the user's only), and is never a release key.

    test_channel.py setup  --folder DIR                 make the test key and the TLS certificate once; print the
                                                        proofs' variables
    test_channel.py offer  --folder DIR --zip FILE --version V --build N --arch A [--slot A] [--tamper what] [--cut]
    test_channel.py none   --folder DIR [--slot A]      offer nothing for that kind of PC (404)
    test_channel.py serve  --folder DIR [--port P]      serve until stopped; each request is a line of requests.log

--tamper: "signature" (one bit of the signature changed), "sha256" (the checksum of other bytes, signed). --slot: the
kind of PC whose read gets this manifest (the "other arch" refusal offers an x64 build to an arm64 PC). --cut: the next
download of this zip stops after half of its bytes, once.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import shutil
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, REPO)
import releases  # noqa: E402  the hub's own Ed25519 (releases.sign, releases.verify_signature)

HOST_FOR_THE_VM = "10.0.2.2"
DEFAULT_PORT = 58443


def windows_text(build):
    """The bytes that a Windows build's signature covers (app/vectors/make_vectors.py, windows_text)."""
    return "\n".join(["founderizer-windows-1", build["version"], str(build["build"]), build["arch"], build["url"],
                      build["sha256"], str(build["size"]), build.get("minimum") or "", build.get("notes") or "",
                      "true" if build["hold"] else "false"]) + "\n"


def private_file(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def setup(folder):
    os.makedirs(os.path.join(folder, "files"), mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    seed_path = os.path.join(folder, "test-seed")
    if not os.path.exists(seed_path):
        private_file(seed_path, os.urandom(32))
    cert, key = os.path.join(folder, "cert.pem"), os.path.join(folder, "key.pem")
    if not os.path.exists(cert):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                        "-keyout", key, "-out", cert, "-days", "30", "-subj", "/CN=founderizer-test-channel",
                        "-addext", f"subjectAltName=IP:{HOST_FOR_THE_VM}"], check=True, capture_output=True)
        os.chmod(key, 0o600)
    with open(seed_path, "rb") as f:
        public = base64.b64encode(releases.public_key(f.read())).decode()
    with open(cert) as f:
        pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(f.read())).hexdigest()
    return {"FOUNDERIZER_UPDATE_KEY": public, "FOUNDERIZER_UPDATE_PIN": pin}


def channel(port):
    return f"https://{HOST_FOR_THE_VM}:{port}"


def offer(folder, zip_path, version, build, arch, slot, tamper, cut, port):
    with open(os.path.join(folder, "test-seed"), "rb") as f:
        seed = f.read()
    name = os.path.basename(zip_path)
    target = os.path.join(folder, "files", name)
    if os.path.abspath(zip_path) != os.path.abspath(target):
        shutil.copyfile(zip_path, target)
    with open(target, "rb") as f:
        data = f.read()
    manifest = {"version": version, "build": build, "arch": arch, "url": f"{channel(port)}/files/{name}",
                "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "minimum": "10.0.22000",
                "notes": "", "hold": False}
    if tamper == "sha256":
        manifest["sha256"] = hashlib.sha256(b"other bytes than the zip's").hexdigest()
    signature = bytearray(releases.sign(seed, windows_text(manifest).encode()))
    if tamper == "signature":
        signature[10] ^= 0x01
    manifest["signature"] = base64.b64encode(bytes(signature)).decode()
    private_file(os.path.join(folder, f"offer-{slot}.json"), json.dumps(manifest, indent=1).encode())
    cut_flag = os.path.join(folder, f"cut-{name}")
    if cut:
        private_file(cut_flag, b"")
    elif os.path.exists(cut_flag):
        os.remove(cut_flag)
    return manifest


class Handler(http.server.BaseHTTPRequestHandler):
    folder = ""

    def log_message(self, *args):
        pass

    def note(self, status, sent, extra=""):
        line = f"{time.time():.3f} {self.command} {self.path} {status} {sent}{extra}\n"
        with open(os.path.join(self.folder, "requests.log"), "a") as f:
            f.write(line)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/releases/windows":
            arch = (urllib.parse.parse_qs(url.query).get("arch") or [""])[0]
            path = os.path.join(self.folder, f"offer-{arch}.json") if arch in ("x64", "arm64") else ""
            if not path or not os.path.exists(path):
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return self.note(404, 0)
            with open(path, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return self.note(200, len(body), f" build {json.loads(body)['build']}")
        if url.path.startswith("/files/"):
            name = os.path.basename(url.path)
            path = os.path.join(self.folder, "files", name)
            if not name.endswith(".zip") or not os.path.exists(path):
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return self.note(404, 0)
            size = os.path.getsize(path)
            cut_flag = os.path.join(self.folder, f"cut-{name}")
            cut = os.path.exists(cut_flag)
            if cut:
                os.remove(cut_flag)
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            limit = size // 2 if cut else size
            sent = 0
            with open(path, "rb") as f:
                while sent < limit:
                    chunk = f.read(min(1 << 16, limit - sent))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    sent += len(chunk)
            self.note(200, sent, f" of {size}" + (", stopped in the middle" if cut else ""))
            if cut:
                self.wfile.flush()
                self.close_connection = True
                self.connection.shutdown(2)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.note(404, 0)


def serve(folder, port):
    Handler.folder = folder
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(folder, "cert.pem"), os.path.join(folder, "key.pem"))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(json.dumps({"channel": channel(port), "listens": f"127.0.0.1:{port}", "folder": folder}), flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        server.shutdown()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["setup", "offer", "none", "serve"])
    parser.add_argument("--folder", required=True)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--zip")
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--arch", choices=["x64", "arm64"])
    parser.add_argument("--slot", choices=["x64", "arm64"])
    parser.add_argument("--tamper", choices=["signature", "sha256"])
    parser.add_argument("--cut", action="store_true")
    a = parser.parse_args()
    folder = os.path.abspath(a.folder)
    if a.command == "setup":
        print(json.dumps(dict(setup(folder), FOUNDERIZER_UPDATE_CHANNEL=channel(a.port)), indent=1))
    elif a.command == "offer":
        if not (a.zip and a.version and a.build and a.arch):
            parser.error("offer needs --zip, --version, --build and --arch")
        m = offer(folder, a.zip, a.version, a.build, a.arch, a.slot or a.arch, a.tamper, a.cut, a.port)
        print(json.dumps({k: m[k] for k in ("version", "build", "arch", "sha256", "size")}))
    elif a.command == "none":
        path = os.path.join(folder, f"offer-{a.slot or 'arm64'}.json")
        if os.path.exists(path):
            os.remove(path)
    else:
        serve(folder, a.port)


if __name__ == "__main__":
    main()
