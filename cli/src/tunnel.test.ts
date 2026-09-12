import assert from "node:assert/strict";
import { appendFile, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  classifyPublicFailure,
  discoverQuickTunnelURL,
  parseTunnelConfig,
  resolveAddressMode,
  serviceTargetsLoopback,
  validatePublicURL,
} from "./tunnel.ts";
import { CliError } from "./util.ts";

describe("discoverQuickTunnelURL", () => {
  it("joins a fragmented current-generation URL and ignores a stale one", async () => {
    const dir = await mkdtemp(join(tmpdir(), "shell-tunnel-"));
    const log = join(dir, "tunnel.err.log");
    await writeFile(log, "--- generation old ---\nhttps://stale-name.trycloudflare.com\n");
    const ac = new AbortController();
    const pending = discoverQuickTunnelURL({
      logPath: log,
      generation: "generation current",
      signal: ac.signal,
      timeoutMs: 2000,
    });
    await new Promise((r) => setTimeout(r, 30));
    await appendFile(log, "--- generation current ---\nhttps://abc-");
    await new Promise((r) => setTimeout(r, 30));
    await appendFile(log, "def.trycloudflare.com extra\n");
    assert.equal(await pending, "https://abc-def.trycloudflare.com");
  });

  it("times out when the current generation never prints a URL", async () => {
    const dir = await mkdtemp(join(tmpdir(), "shell-tunnel-"));
    const log = join(dir, "missing.log");
    await writeFile(log, "--- generation current ---\nwaiting\n");
    const ac = new AbortController();
    await assert.rejects(
      () => discoverQuickTunnelURL({ logPath: log, generation: "generation current", signal: ac.signal, timeoutMs: 80 }),
      /did not print/,
    );
  });
});

describe("public failure classification", () => {
  it("does not treat 502, 530, DNS, or TLS as permission to rotate", () => {
    assert.equal(classifyPublicFailure(undefined, 530).category, "tunnel_disconnected");
    assert.equal(classifyPublicFailure(undefined, 502).category, "upstream_error");
    assert.equal(classifyPublicFailure({ code: "ENOTFOUND", message: "dns" }).category, "dns_timeout");
    assert.equal(classifyPublicFailure({ message: "certificate verify failed", name: "Error" }).category, "tls_failure");
  });
});

describe("named tunnel config", () => {
  it("parses identity, credentials, and ingress", () => {
    const parsed = parseTunnelConfig(`
tunnel: 11111111-1111-4111-8111-111111111111
credentials-file: /tmp/creds.json
ingress:
  - hostname: control.example.com
    service: http://127.0.0.1:8443
  - service: http_status:404
`);
    assert.equal(parsed.tunnel, "11111111-1111-4111-8111-111111111111");
    assert.equal(parsed.credentialsFile, "/tmp/creds.json");
    assert.equal(parsed.ingress[0]?.hostname, "control.example.com");
    assert.equal(serviceTargetsLoopback("http://127.0.0.1:8443", 8443), true);
    assert.equal(serviceTargetsLoopback("http://10.0.0.2:8443", 8443), false);
  });
});

describe("resolveAddressMode", () => {
  it("maps a fresh SHELL_CONTROL_PUBLIC_URL to external-proxy unless a mode is selected", () => {
    const resolved = resolveAddressMode({
      envPublicURL: "https://control.example.com",
      fresh: true,
    });
    assert.equal(resolved.mode, "external-proxy");
    assert.equal(resolved.publicURL, "https://control.example.com");
    assert.equal(resolved.fromEnv, true);
  });

  it("refuses a conflicting env override on an existing installation", () => {
    assert.throws(
      () => resolveAddressMode({
        envPublicURL: "https://other.example.com",
        stored: { address_mode: "named", public_url: "https://control.example.com" },
        fresh: false,
      }),
      /conflicts with the stored installation/,
    );
  });

  it("lets explicit flags take precedence", () => {
    const resolved = resolveAddressMode({
      explicitMode: "named",
      explicitPublicURL: "https://control.example.com",
      envPublicURL: "https://other.example.com",
      stored: { address_mode: "quick", public_url: "https://old.trycloudflare.com" },
      fresh: false,
    });
    assert.equal(resolved.mode, "named");
    assert.equal(resolved.publicURL, "https://control.example.com");
  });
});

describe("validatePublicURL", () => {
  it("rejects a quick hostname for named mode", () => {
    assert.throws(() => validatePublicURL("https://abc.trycloudflare.com", "named"), CliError);
  });
});
