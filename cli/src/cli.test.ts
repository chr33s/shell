import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { describe, it } from "node:test";
import { main, parseArgv, usage, type CLIContext } from "./cli.ts";
import { FakeServiceManager } from "./services.ts";
import { loadOrCreateInstallation, loadRuntime, loadSecrets, saveSecrets } from "./state.ts";
import { CliError } from "./util.ts";

function capabilitiesBody(): string {
  return JSON.stringify({
    protocol_versions: ["shell-control/1"],
    service_identity: "shell-control",
    command_types: [],
    operation_schemas: [],
    required_features: [],
    limits: {},
    server_time: "2026-09-12T00:00:00Z",
  });
}

function fakeFetch(): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (url.includes("/v1/capabilities")) {
      return new Response(capabilitiesBody(), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
    }
    if (url.includes("/v1/admin/origins") && (init?.method || "GET") === "POST") {
      return new Response(JSON.stringify({ origin_id: "33333333-3333-4333-8333-333333333333", origin_secret: "origin-secret" }), { status: 201 });
    }
    if (url.includes("/v1/admin/pending")) {
      return new Response(JSON.stringify({ pending: [] }), { status: 200 });
    }
    if (url.includes("/v1/admin/health")) {
      return new Response(JSON.stringify({ state: "ready", store_loaded: true }), { status: 200 });
    }
    if (url.includes("/v1/oauth/confirm") && (init?.method || "GET") === "GET") {
      return new Response(JSON.stringify({ platform: "watchOS", label: "Watch", key_fingerprint: "aa:bb" }), { status: 200 });
    }
    if (url.includes("/v1/oauth/confirm")) {
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }
    return new Response("missing", { status: 404 });
  }) as typeof fetch;
}

async function testContext(overrides: Partial<CLIContext> = {}): Promise<CLIContext> {
  const stateDir = overrides.stateDir ?? await mkdtemp(join(tmpdir(), "shell-cli-"));
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const chunks: Buffer[] = [];
  const errChunks: Buffer[] = [];
  stdout.on("data", (c) => chunks.push(c));
  stderr.on("data", (c) => errChunks.push(c));
  const ctx: CLIContext = {
    stateDir,
    libDir: join(stateDir, "lib"),
    launchAgentsDir: join(stateDir, "LaunchAgents"),
    env: { ...overrides.env },
    now: () => new Date("2026-09-12T00:00:00Z"),
    sleep: async () => undefined,
    fetchImpl: fakeFetch(),
    manager: new FakeServiceManager(),
    stdinIsTTY: false,
    stdout,
    stderr,
    stdin: new PassThrough(),
    which: () => null,
    repoRoot: null,
    platform: "darwin",
    uid: process.getuid?.() ?? 501,
    homedir: stateDir,
    binaries: {
      version: "test",
      broker: process.execPath,
      daemon: process.execPath,
      cli: process.execPath,
      cloudflared: undefined,
      directory: stateDir,
    },
    ...overrides,
  };
  Object.assign(ctx, { _stdout: () => Buffer.concat(chunks).toString("utf8"), _stderr: () => Buffer.concat(errChunks).toString("utf8") });
  return ctx;
}

describe("parseArgv", () => {
  it("defaults to setup and rejects unknown flags", () => {
    assert.equal(parseArgv([]).command, "setup");
    assert.equal(parseArgv(["--no-watch"]).command, "setup");
    assert.equal(parseArgv(["--help"]).command, "help");
    assert.throws(() => parseArgv(["--explode"]), CliError);
    assert.throws(() => parseArgv(["frobnicate"]), /unknown command/);
  });

  it("parses value flags", () => {
    const parsed = parseArgv(["setup", "--tunnel-mode", "named", "--public-url", "https://control.example.com"]);
    assert.equal(parsed.flags.get("tunnel-mode"), "named");
    assert.equal(parsed.flags.get("public-url"), "https://control.example.com");
  });
});

describe("help", () => {
  it("is side-effect-free", async () => {
    const ctx = await testContext();
    const code = await main(["--help"], ctx);
    assert.equal(code, 0);
    assert.match(usage(), /service install/);
  });
});

describe("setup --no-watch", () => {
  it("completes and leaves the fake services running", async () => {
    const ctx = await testContext();
    const code = await main(["setup", "--no-watch"], ctx);
    assert.equal(code, 0);
    const inst = await loadOrCreateInstallation(ctx.stateDir);
    const labels = ctx.manager.labels(inst.config.installation_id);
    const broker = await ctx.manager.observe(labels.broker);
    const daemon = await ctx.manager.observe(labels.daemon);
    assert.ok(broker.pid);
    assert.ok(daemon.pid);
    assert.equal(inst.config.address_mode, "loopback");
    const secrets = await loadSecrets(ctx.stateDir);
    assert.ok(secrets?.account_id);
  });

  it("reuses healthy matching services on a second run", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const inst = await loadOrCreateInstallation(ctx.stateDir);
    const labels = ctx.manager.labels(inst.config.installation_id);
    const firstBroker = await ctx.manager.observe(labels.broker);
    const firstDaemon = await ctx.manager.observe(labels.daemon);
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const secondBroker = await ctx.manager.observe(labels.broker);
    const secondDaemon = await ctx.manager.observe(labels.daemon);
    assert.equal(secondBroker.pid, firstBroker.pid);
    assert.equal(secondDaemon.pid, firstDaemon.pid);
    const again = await loadOrCreateInstallation(ctx.stateDir);
    assert.equal(again.secrets.account_id, inst.secrets.account_id);
    assert.equal(again.config.public_url, inst.config.public_url);
  });

  it("restarts the broker when its service configuration changes", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const inst = await loadOrCreateInstallation(ctx.stateDir);
    const label = ctx.manager.labels(inst.config.installation_id).broker;
    const before = await ctx.manager.observe(label);
    assert.equal(await main([
      "setup",
      "--no-watch",
      "--public-url",
      "https://control.example.com",
    ], ctx), 0);
    const after = await ctx.manager.observe(label);
    assert.notEqual(after.pid, before.pid);
  });

  it("persists created resources before a failed startup can be interrupted", async () => {
    const normalFetch = fakeFetch();
    const ctx = await testContext({
      fetchImpl: (async (input: string | URL | Request, init?: RequestInit) => {
        if (String(input).includes("/v1/admin/origins")) {
          return new Response("unavailable", { status: 503 });
        }
        return normalFetch(input, init);
      }) as typeof fetch,
    });
    await assert.rejects(() => main(["setup", "--no-watch"], ctx), /503/);
    const runtime = await loadRuntime(ctx.stateDir);
    assert.equal(runtime.incomplete, true);
    assert.deepEqual(runtime.created, ["broker"]);
  });
});

describe("logs", () => {
  it("does not truncate live logs", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const inst = await loadOrCreateInstallation(ctx.stateDir);
    const log = join(inst.paths.logs, "broker.err.log");
    const { mkdir, writeFile, readFile, stat } = await import("node:fs/promises");
    await mkdir(inst.paths.logs, { recursive: true });
    await writeFile(log, "keep-this-output\n");
    const before = (await stat(log)).size;
    const stdout = new PassThrough();
    let text = "";
    stdout.on("data", (c) => { text += c; });
    assert.equal(await main(["logs", "broker"], { ...ctx, stdout }), 0);
    assert.equal((await stat(log)).size, before);
    assert.equal(await readFile(log, "utf8"), "keep-this-output\n");
    assert.match(text, /keep-this-output/);
  });
});

describe("status", () => {
  it("is read-only and redacts secrets", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const before = await loadSecrets(ctx.stateDir);
    const stdout = new PassThrough();
    let text = "";
    stdout.on("data", (c) => { text += c; });
    const statusCtx = { ...ctx, stdout };
    const code = await main(["status"], statusCtx);
    assert.equal(code, 0);
    const after = await loadSecrets(ctx.stateDir);
    assert.equal(after?.admin_secret, before?.admin_secret);
    assert.doesNotMatch(text, /pairing_token/);
    assert.doesNotMatch(text, new RegExp(before!.admin_secret));
    assert.match(text, /"schema_version": 2/);
  });

  it("--check fails when required components are not ready", async () => {
    const ctx = await testContext();
    const code = await main(["status", "--check"], ctx);
    assert.equal(code, 1);
  });
});

describe("down and up", () => {
  it("stays down until up", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    assert.equal(await main(["down"], ctx), 0);
    const inst = await loadOrCreateInstallation(ctx.stateDir);
    assert.equal(inst.config.desired_state, "stopped");
    const labels = ctx.manager.labels(inst.config.installation_id);
    assert.equal((await ctx.manager.observe(labels.broker)).pid, null);
    const secrets = await loadSecrets(ctx.stateDir);
    assert.ok(secrets?.admin_secret);
    assert.equal(await main(["up"], ctx), 0);
    const after = await loadOrCreateInstallation(ctx.stateDir);
    assert.equal(after.config.desired_state, "running");
    assert.ok((await ctx.manager.observe(labels.broker)).pid);
  });
});

describe("service install", () => {
  it("rejects quick/loopback persistence", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const code = await main(["service", "install"], ctx);
    assert.equal(code, 2);
  });

  it("accepts named mode with a stable URL", async () => {
    const dir = await mkdtemp(join(tmpdir(), "shell-named-"));
    const creds = join(dir, "creds.json");
    const yaml = join(dir, "tunnel.yml");
    await writeFile(creds, "{}", { mode: 0o600 });
    await writeFile(yaml, `tunnel: named-1\ncredentials-file: ${creds}\ningress:\n  - hostname: control.example.com\n    service: http://127.0.0.1:8443\n`);
    const ctx = await testContext({
      stateDir: dir,
      which: (name) => name === "cloudflared" ? process.execPath : null,
      binaries: {
        version: "test",
        broker: process.execPath,
        daemon: process.execPath,
        cli: process.execPath,
        cloudflared: process.execPath,
        directory: dir,
      },
    });
    const code = await main([
      "setup", "--no-watch",
      "--tunnel-mode", "named",
      "--public-url", "https://control.example.com",
      "--tunnel-config", yaml,
    ], ctx);
    assert.equal(code, 0);
    assert.equal(await main(["service", "install"], ctx), 0);
    const inst = await loadOrCreateInstallation(dir);
    assert.equal(inst.config.persistent, true);
  });
});

describe("pair and confirm", () => {
  it("prints the token from pair, not status", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const secrets = await loadSecrets(ctx.stateDir);
    const stdout = new PassThrough();
    let text = "";
    stdout.on("data", (c) => { text += c; });
    assert.equal(await main(["pair"], { ...ctx, stdout }), 0);
    assert.match(text, new RegExp(secrets!.pairing_token));
  });
});

describe("restart quick tunnel", () => {
  it("refuses silent URL replacement", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const inst = await loadOrCreateInstallation(ctx.stateDir);
    inst.config.address_mode = "quick";
    inst.config.public_url = "https://abc.trycloudflare.com";
    const { saveConfig } = await import("./state.ts");
    await saveConfig(ctx.stateDir, inst.config);
    const code = await main(["restart", "tunnel"], ctx);
    assert.equal(code, 2);
  });
});

describe("cancellation", () => {
  it("returns 130 when the invocation is aborted after readiness during watch", async () => {
    const ctx = await testContext({ stdinIsTTY: true });
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    ctx.sleep = async (_ms, signal) => {
      if (signal) throw new CliError("cancelled", 130);
    };
    const code = await main(["pair", "--watch"], ctx);
    assert.equal(code, 130);
  });
});

describe("corrupt configuration", () => {
  it("reports repair rather than regenerating credentials", async () => {
    const ctx = await testContext();
    assert.equal(await main(["setup", "--no-watch"], ctx), 0);
    const secrets = await loadSecrets(ctx.stateDir);
    await writeFile(join(ctx.stateDir, "secrets.json"), "{not json", { mode: 0o600 });
    const code = await main(["status"], ctx);
    assert.equal(code, 1);
    await writeFile(join(ctx.stateDir, "secrets.json"), JSON.stringify(secrets, null, 2), { mode: 0o600 });
    await saveSecrets(ctx.stateDir, secrets!);
  });
});
