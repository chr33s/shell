"""Run live hybrid-key/certificate tests against an OpenSSH build directory.

Usage: python3 scripts/test-openssh-hybrid.py /path/to/openssh-build
Requires ssh, ssh-keygen, sshd, sshd-auth, and sshd-session.
Use --cipher aes128-ctr or aes256-ctr and --mac to force an ETM combination.
Creates temporary test credentials, binds only loopback, and stops sshd on exit.
Both the canonical and pre-September-2026 vendored formats are supported.
"""
import argparse
import getpass
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binaries", type=Path)
    parser.add_argument("--cipher", default="aes256-gcm@openssh.com",
                        choices=["aes256-gcm@openssh.com", "aes128-ctr", "aes256-ctr"])
    parser.add_argument("--mac", default="hmac-sha2-256-etm@openssh.com",
                        choices=["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com"])
    args = parser.parse_args()
    binaries = args.binaries.resolve()
    repo = Path(__file__).resolve().parents[1]
    names = subprocess.check_output([str(binaries / "ssh"), "-Q", "key"], text=True).splitlines()
    ciphers = subprocess.check_output([str(binaries / "ssh"), "-Q", "cipher"], text=True).splitlines()
    if args.cipher not in ciphers:
        raise SystemExit(f"This OpenSSH build does not support {args.cipher}")
    legacy = "ssh-mldsa44-ed25519" not in names
    algorithm = "ssh-mldsa44-ed25519@openssh.com" if legacy else "ssh-mldsa44-ed25519"
    certificate = "ssh-mldsa44-ed25519-cert-v01@openssh.com" if legacy else "ssh-mldsa44-ed25519-cert"
    if algorithm not in names:
        raise SystemExit("This OpenSSH build does not support hybrid ML-DSA-44 + Ed25519")
    with tempfile.TemporaryDirectory(prefix="citadel-openssh-") as directory:
        fixtures = Path(directory)
        def keygen(*args):
            subprocess.run([str(binaries / "ssh-keygen"), "-q", *args], check=True)
        keygen("-t", "mldsa44-ed25519", "-N", "", "-f", str(fixtures / "key"))
        keygen("-t", "ed25519", "-N", "", "-f", str(fixtures / "ca"))
        shutil.copyfile(fixtures / "ca.pub", fixtures / "key-ca.pub")
        keygen("-s", str(fixtures / "ca"), "-I", "test-user", "-n", getpass.getuser(),
               "-V", "-1h:+1h", str(fixtures / "key.pub"))
        shutil.copyfile(fixtures / "key-cert.pub", fixtures / "key-user-cert.pub")
        keygen("-s", str(fixtures / "ca"), "-I", "test-host", "-h", "-n", "localhost",
               "-V", "-1h:+1h", str(fixtures / "key.pub"))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        config = fixtures / "sshd_config"
        config.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {fixtures}/key
HostCertificate {fixtures}/key-cert.pub
HostKeyAlgorithms {certificate},{algorithm}
PubkeyAcceptedAlgorithms {certificate},{algorithm}
AuthorizedKeysFile {fixtures}/key.pub
TrustedUserCAKeys {fixtures}/ca.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile {fixtures}/sshd.pid
SshdAuthPath {binaries}/sshd-auth
SshdSessionPath {binaries}/sshd-session
Ciphers {args.cipher}
MACs {args.mac}
RekeyLimit 16K
LogLevel DEBUG1
""")
        with (fixtures / "sshd.log").open("w+") as log:
            server = subprocess.Popen([str(binaries / "sshd"), "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while True:
                    if server.poll() is not None:
                        raise RuntimeError("sshd exited during startup")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise RuntimeError("sshd did not start")
                        time.sleep(0.05)
                env = dict(os.environ, OPENSSH_INTEROP_PORT=str(port),
                           OPENSSH_INTEROP_LEGACY="1" if legacy else "0",
                           OPENSSH_INTEROP_FIXTURES=str(fixtures), OPENSSH_INTEROP_USERNAME=getpass.getuser())
                result = subprocess.run(["swift", "test", "--filter", "OpenSSHHybridInteropTests"],
                                        cwd=repo, env=env, timeout=180)
                if result.returncode:
                    raise RuntimeError("Hybrid interoperability tests failed")
                log.seek(0)
                diagnostics = log.read()
                expected_mac = "<implicit>" if "gcm" in args.cipher else args.mac
                for direction in ["client->server", "server->client"]:
                    negotiated = f"{direction} cipher: {args.cipher} MAC: {expected_mac}"
                    if negotiated not in diagnostics:
                        raise RuntimeError(f"Missing negotiation confirmation: {negotiated}")
                print(f"Verified {args.cipher} / {expected_mac} in both directions", flush=True)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
                log.seek(0)
                print(log.read())


if __name__ == "__main__":
    main()
