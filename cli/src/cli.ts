import { spawn, spawnSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { exists, findRepoRoot, makePairingToken, pairingLink, pairingPageURL } from "./util.ts";

const ROOT = await findRepoRoot();
const STATE = join(homedir(), ".local/state/shell-control");
const ENV_FILE = join(STATE, "setup.env");
const BROKER_PID = join(STATE, "broker.pid");
const TUNNEL_PID = join(STATE, "tunnel.pid");
const DAEMON_PID = join(STATE, "daemon.pid");
const PORT = Number(process.env.SHELL_CONTROL_PORT || 8443);
const LOCAL = `http://127.0.0.1:${PORT}`;

type SetupEnv = {
  SHELL_CONTROL_ACCOUNT_ID: string;
  SHELL_CONTROL_ADMIN_SECRET: string;
  SHELL_CONTROL_CURSOR_SECRET: string;
  SHELL_CONTROL_PAIRING_TOKEN: string;
  SHELL_CONTROL_PUBLIC_URL?: string;
  SHELL_CONTROL_VERIFICATION_URI?: string;
  SHELL_CONTROL_ORIGIN_ID?: string;
  SHELL_CONTROL_ORIGIN_SECRET?: string;
};

type Binaries = {
  broker: string;
  daemon: string;
  cli: string | undefined;
};

type StopFlag = { value: boolean };

type PendingList = { pending?: Array<{ user_code?: string }> };

type DeviceDescription = {
  platform?: string;
  label?: string;
  key_fingerprint?: string;
};

type OriginCredentials = {
  origin_id: string;
  origin_secret: string;
};

export async function main(argv: string[]): Promise<void> {
  // Match the help flags BEFORE the dash guard below: routing every
  // dash-prefixed argument to `setup` made the `--help` / `-h` cases dead, so
  // asking for usage instead built the sources, opened a tunnel and blocked.
  const first = argv[0] ?? "";
  const command = first === "-h" || first === "--help"
    ? "help"
    : first && !first.startsWith("-") ? first : "setup";
  const rest = argv[0] === command ? argv.slice(1) : argv;
  switch (command) {
    case "setup":
      await setup();
      break;
    case "down":
      await down();
      break;
    case "status":
      await status();
      break;
    case "confirm":
      await confirmOnce(rest[0]);
      break;
    case "notify":
    case "request":
    case "receipt":
      await proxyNative([command, ...rest]);
      break;
    case "help":
      usage();
      break;
    default:
      fail(`unknown command ${command}`);
  }
}

function usage(): void {
  process.stdout.write(`Usage: npx @chr33s/shell [setup|down|status|confirm <code>|request|notify|receipt]

  setup     Start broker, HTTPS tunnel, origin daemon, print a pairing QR.
            Pending devices are listed; type y to approve after the fingerprint.
  down      Stop broker, tunnel, and origin daemon
  status    Show pids and the public broker URL
  confirm   Approve one device code after printing its fingerprint
  request, notify, receipt
            Passed through to the native adapter CLI

Run from a chr33s/shell checkout (or npx github:chr33s/shell). Native tools
are built with Swift on first run. cloudflared is required for a public URL.
`);
}

async function setup(): Promise<void> {
  if (process.platform !== "darwin") fail("macOS only — the broker and origin use CryptoKit");
  if (!ROOT) {
    fail("native sources not found — clone chr33s/shell and run from that checkout (npx github:chr33s/shell also works)");
  }
  await mkdir(STATE, { recursive: true, mode: 0o700 });
  const env = await loadEnv();
  if (!env.SHELL_CONTROL_PAIRING_TOKEN) env.SHELL_CONTROL_PAIRING_TOKEN = makePairingToken();
  await writeEnv(env);
  const bins = await resolveBinaries();
  await reapStale(env);
  const publicURL = await ensureTunnel(env);
  env.SHELL_CONTROL_PUBLIC_URL = publicURL;
  env.SHELL_CONTROL_VERIFICATION_URI = `${publicURL}/v1/oauth/confirm`;
  await writeEnv(env);
  await ensureBroker(bins.broker, env);
  const origin = await ensureOrigin(env);
  env.SHELL_CONTROL_ORIGIN_ID = origin.origin_id;
  env.SHELL_CONTROL_ORIGIN_SECRET = origin.origin_secret;
  await writeEnv(env);
  await ensureDaemon(bins.daemon, env, publicURL);
  await printPairing(publicURL, env.SHELL_CONTROL_PAIRING_TOKEN);
  process.stderr.write("waiting for iPhone / Watch enrollment — type y to approve after each fingerprint. Ctrl+C stops watching (npx @chr33s/shell down to stop services)\n");
  const stop = listenSignals();
  await watchEnrollments(env, stop);
}

async function reapStale(env: SetupEnv): Promise<void> {
  if (await pidAlive(BROKER_PID) && !(await brokerUp())) {
    process.stderr.write("stale broker pid, restarting\n");
    await killPidFile(BROKER_PID);
  }
  const publicURL = env.SHELL_CONTROL_PUBLIC_URL;
  if (await pidAlive(TUNNEL_PID) && publicURL && !(await tunnelUp(publicURL))) {
    process.stderr.write("stale tunnel URL, restarting cloudflared\n");
    await killPidFile(TUNNEL_PID);
    delete env.SHELL_CONTROL_PUBLIC_URL;
  }
}

async function down(): Promise<void> {
  await killPidFile(DAEMON_PID);
  await killPidFile(TUNNEL_PID);
  await killPidFile(BROKER_PID);
  process.stderr.write("stopped\n");
}

async function status(): Promise<void> {
  const env: Partial<SetupEnv> = (await exists(ENV_FILE)) ? await loadEnv() : {};
  const [broker, tunnel, daemon] = await Promise.all([
    pidAlive(BROKER_PID),
    pidAlive(TUNNEL_PID),
    pidAlive(DAEMON_PID),
  ]);
  process.stdout.write(`${JSON.stringify({
    broker,
    tunnel,
    daemon,
    public_url: env.SHELL_CONTROL_PUBLIC_URL || null,
    origin_id: env.SHELL_CONTROL_ORIGIN_ID || null,
    pairing_token: env.SHELL_CONTROL_PAIRING_TOKEN || null,
  }, null, 2)}\n`);
}

async function confirmOnce(code: string | undefined): Promise<void> {
  if (!code) fail("usage: npx @chr33s/shell confirm <USER-CODE>");
  const env = await loadEnv();
  await confirmCode(env, code, { prompt: false });
}

/// The approval prompt abort, while one is open. Ctrl+C has to abort it: the
/// stop flag is only read between polls, so a signal arriving while the prompt
/// was open set the flag and then waited forever on an answer that was never
/// coming — despite the "Ctrl+C stops watching" line above. (Bare rl.close()
/// never settles readline/promises' question(), hence AbortController.)
let activePrompt: { abort(): void } | null = null;
const stopFlag: StopFlag = { value: false };

function listenSignals(): StopFlag {
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      stopFlag.value = true;
      activePrompt?.abort();
      activePrompt = null;
    });
  }
  return stopFlag;
}

async function watchEnrollments(env: SetupEnv, stop: StopFlag): Promise<void> {
  const seen = new Set<string>();
  while (!stop.value) {
    try {
      const pending = await adminJSON<PendingList>(env, "GET", "/v1/admin/pending");
      for (const item of pending.pending || []) {
        if (stop.value) return;
        const code = item.user_code;
        if (!code || seen.has(code)) continue;
        // Record the code before acting on it, and contain the failure here:
        // a grant that expired between the poll and the describe threw out of
        // the loop, skipping the rest of the batch and leaving the code
        // unrecorded, so the same error repeated every two seconds forever.
        seen.add(code);
        try {
          const approved = await confirmCode(env, code, { prompt: true });
          process.stderr.write(approved ? `enrolled ${code}\n` : `skipped ${code}\n`);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          process.stderr.write(`confirm ${code}: ${message}\n`);
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      process.stderr.write(`watch: ${message}\n`);
    }
    await sleep(2000);
  }
}

async function confirmCode(env: SetupEnv, code: string, { prompt }: { prompt: boolean }): Promise<boolean> {
  const described = await adminJSON<DeviceDescription>(env, "GET", `/v1/oauth/confirm?user_code=${encodeURIComponent(code)}`);
  process.stderr.write(
    `confirm ${code}  ${described.platform || ""} ${described.label || ""}  fingerprint ${described.key_fingerprint || "?"}\n`
  );
  if (prompt) {
    if (!process.stdin.isTTY) {
      process.stderr.write("no TTY — not approving; run: npx @chr33s/shell confirm " + code + "\n");
      return false;
    }
    const answer = (await readline("Approve this device? [y/N] ")).trim().toLowerCase();
    if (answer !== "y" && answer !== "yes") return false;
  }
  await adminJSON(env, "POST", "/v1/oauth/confirm", { user_code: code, approve: true });
  return true;
}

async function readline(question: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  const ac = new AbortController();
  activePrompt = ac;
  // A terminal readline swallows Ctrl+C rather than letting it reach the
  // process handler, so mark the stop here as well.
  rl.on("SIGINT", () => {
    stopFlag.value = true;
    ac.abort();
  });
  try {
    return await rl.question(question, { signal: ac.signal });
  } catch (error) {
    // Only an abort by listenSignals or the rl SIGINT above settles as empty,
    // which reads as "not approved", matching the answered-with-nothing case.
    // Anything else is a real readline failure and has to surface rather than
    // be disguised as a declined approval.
    if (!(error instanceof Error) || error.name !== "AbortError") throw error;
    return "";
  } finally {
    activePrompt = null;
    rl.close();
  }
}

async function ensureOrigin(env: SetupEnv): Promise<OriginCredentials> {
  if (env.SHELL_CONTROL_ORIGIN_ID && env.SHELL_CONTROL_ORIGIN_SECRET) {
    return { origin_id: env.SHELL_CONTROL_ORIGIN_ID, origin_secret: env.SHELL_CONTROL_ORIGIN_SECRET };
  }
  const label = homedir().split("/").pop() || "mac";
  return adminJSON<OriginCredentials>(env, "POST", "/v1/admin/origins", { label });
}

async function adminJSON<T = unknown>(env: SetupEnv, method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = {
    authorization: `Admin ${env.SHELL_CONTROL_ADMIN_SECRET}`,
    accept: "application/json",
    host: "127.0.0.1",
  };
  if (body) headers["content-type"] = "application/json";
  const response = await fetch(`${LOCAL}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${method} ${path} → ${response.status} ${text.slice(0, 200)}`);
  }
  try {
    return JSON.parse(text) as T;
  } catch {
    return {} as T;
  }
}

async function ensureBroker(brokerBin: string, env: SetupEnv): Promise<void> {
  if (await pidAlive(BROKER_PID)) await killPidFile(BROKER_PID);
  const child = spawn(brokerBin, [], {
    env: {
      ...process.env,
      SHELL_CONTROL_PORT: String(PORT),
      SHELL_CONTROL_STATE: join(STATE, "broker.json"),
      SHELL_CONTROL_ACCOUNT_ID: env.SHELL_CONTROL_ACCOUNT_ID,
      SHELL_CONTROL_ADMIN_SECRET: env.SHELL_CONTROL_ADMIN_SECRET,
      SHELL_CONTROL_CURSOR_SECRET: env.SHELL_CONTROL_CURSOR_SECRET,
      SHELL_CONTROL_VERIFICATION_URI: env.SHELL_CONTROL_VERIFICATION_URI,
      SHELL_CONTROL_PUBLIC_URL: env.SHELL_CONTROL_PUBLIC_URL || "",
      SHELL_CONTROL_APNS_TOPICS: "dev.chr33s.shell.watchkitapp,dev.chr33s.shell",
      SHELL_CONTROL_IDENTITY: "shell-control",
    },
    stdio: ["ignore", "ignore", "inherit"],
    detached: true,
  });
  child.unref();
  if (child.pid == null) fail("broker spawn failed");
  await writeFile(BROKER_PID, String(child.pid));
  for (let i = 0; i < 40; i++) {
    if (await brokerUp()) return;
    await sleep(150);
  }
  fail("broker did not become ready on 127.0.0.1:" + PORT);
}

async function brokerUp(): Promise<boolean> {
  return urlUp(`${LOCAL}/v1/capabilities`);
}

/// Whether the quick tunnel itself is still ours, judged WITHOUT requiring the
/// broker behind it: cloudflared answers 502 on its own while the broker is
/// down or restarting, and Cloudflare returns 530 (error 1033) only once no
/// tunnel is registered for the hostname. Asking the broker instead conflated
/// the two and tore down a healthy tunnel whenever the broker had crashed —
/// and the replacement gets a fresh random *.trycloudflare.com name, which
/// strands every already-enrolled iPhone and Watch on a dead host.
async function tunnelUp(publicURL: string): Promise<boolean> {
  try {
    const response = await fetch(`${publicURL}/v1/capabilities`, { signal: AbortSignal.timeout(4000) });
    return response.status !== 530;
  } catch {
    return false;
  }
}

async function urlUp(url: string): Promise<boolean> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(4000) });
    return response.ok;
  } catch {
    return false;
  }
}

async function ensureDaemon(daemonBin: string, env: SetupEnv, publicURL: string): Promise<void> {
  if (await pidAlive(DAEMON_PID)) await killPidFile(DAEMON_PID);
  const child = spawn(daemonBin, [], {
    env: {
      ...process.env,
      SHELL_CONTROL_BROKER_URL: publicURL,
      SHELL_CONTROL_ORIGIN_ID: env.SHELL_CONTROL_ORIGIN_ID,
      SHELL_CONTROL_ORIGIN_SECRET: env.SHELL_CONTROL_ORIGIN_SECRET,
      SHELL_CONTROL_STATE_DIR: STATE,
    },
    stdio: ["ignore", "ignore", "inherit"],
    detached: true,
  });
  child.unref();
  if (child.pid == null) fail("daemon spawn failed");
  await writeFile(DAEMON_PID, String(child.pid));
}

async function ensureTunnel(env: SetupEnv): Promise<string> {
  if (process.env.SHELL_CONTROL_PUBLIC_URL) {
    return process.env.SHELL_CONTROL_PUBLIC_URL.replace(/\/$/, "");
  }
  const cloudflared = which("cloudflared");
  if (!cloudflared) {
    process.stderr.write("cloudflared not found — using http://127.0.0.1 (physical Watch/iPhone cannot reach this). brew install cloudflared\n");
    return `http://127.0.0.1:${PORT}`;
  }
  if (await pidAlive(TUNNEL_PID) && env.SHELL_CONTROL_PUBLIC_URL && await tunnelUp(env.SHELL_CONTROL_PUBLIC_URL)) {
    return env.SHELL_CONTROL_PUBLIC_URL;
  }
  if (await pidAlive(TUNNEL_PID)) await killPidFile(TUNNEL_PID);
  process.stderr.write("starting cloudflared quick tunnel…\n");
  const log = join(tmpdir(), "shell-cloudflared.log");
  const out = createWriteStream(log);
  const child = spawn(cloudflared, ["tunnel", "--url", `http://127.0.0.1:${PORT}`, "--no-autoupdate"], {
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.unref();
  if (child.pid == null) fail("cloudflared spawn failed");
  await writeFile(TUNNEL_PID, String(child.pid));
  let found = "";
  const onData = (chunk: Buffer | string) => {
    out.write(chunk);
    const match = String(chunk).match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
    if (match && !found) found = match[0];
  };
  child.stdout?.on("data", onData);
  child.stderr?.on("data", onData);
  const deadline = Date.now() + 30_000;
  while (!found && Date.now() < deadline) await sleep(200);
  if (!found) fail(`cloudflared did not print a trycloudflare URL (log: ${log})`);
  return found;
}

async function printPairing(publicURL: string, token: string): Promise<void> {
  const link = pairingLink(publicURL, token);
  const page = pairingPageURL(publicURL, token);
  process.stdout.write(`\nbroker  ${publicURL}\npair    ${page}\nlink    ${link}\ntoken   ${token}\n\n`);
  try {
    const qrcode = (await import("qrcode-terminal")).default;
    qrcode.generate(page, { small: true });
  } catch {
    process.stderr.write("(npm install to get a terminal QR)\n");
  }
  process.stdout.write("\nOn iPhone: Settings → Control → Scan QR. The pairing code should match `token` above.\nThen Start setup; approve the fingerprint here with y.\n\n");
}

async function resolveBinaries(): Promise<Binaries> {
  if (!ROOT) fail("native sources not found — clone chr33s/shell and run from that checkout");
  const override = process.env.SHELL_CONTROL_BIN;
  let broker = await firstExisting([
    override && join(override, "shell-control-broker"),
    join(ROOT, "services/shell-control/.build/release/shell-control-broker"),
    join(homedir(), ".local/lib/chr33s-shell/shell-control-broker"),
    which("shell-control-broker"),
  ]);
  let daemon = await firstExisting([
    override && join(override, "shell-controld"),
    join(ROOT, "cmd/.build/release/shell-controld"),
    join(homedir(), ".local/lib/chr33s-shell/shell-controld"),
    which("shell-controld"),
  ]);
  let cli = await firstExisting([
    override && join(override, "shell-control"),
    join(ROOT, "cmd/.build/release/shell-control"),
    join(homedir(), ".local/lib/chr33s-shell/shell-control"),
    which("shell-control"),
  ]);
  if (!broker || !daemon) {
    process.stderr.write("building native tools…\n");
    buildNative();
    broker = await firstExisting([broker, join(ROOT, "services/shell-control/.build/release/shell-control-broker")]);
    daemon = await firstExisting([daemon, join(ROOT, "cmd/.build/release/shell-controld")]);
    cli = await firstExisting([cli, join(ROOT, "cmd/.build/release/shell-control")]);
  }
  if (!broker || !daemon) {
    fail("could not build shell-control-broker / shell-controld — need Swift 6.2 in this checkout");
  }
  return { broker, daemon, cli };
}

function buildNative(): void {
  if (!ROOT) fail("native sources not found");
  run("swift", ["build", "-c", "release", "--package-path", join(ROOT, "services/shell-control")]);
  run("swift", ["build", "-c", "release", "--package-path", join(ROOT, "cmd")]);
}

async function proxyNative(args: string[]): Promise<void> {
  const bins = await resolveBinaries();
  if (!bins.cli) fail("shell-control is not built");
  const result = spawnSync(bins.cli, args, { stdio: "inherit", env: process.env });
  process.exit(result.status ?? 1);
}

function run(cmd: string, args: string[]): void {
  const result = spawnSync(cmd, args, { stdio: "inherit" });
  if (result.status !== 0) fail(`${cmd} ${args.join(" ")} failed`);
}

async function loadEnv(): Promise<SetupEnv> {
  if (!(await exists(ENV_FILE))) {
    const env: SetupEnv = {
      SHELL_CONTROL_ACCOUNT_ID: randomUUID(),
      SHELL_CONTROL_ADMIN_SECRET: randomBytes(32).toString("hex"),
      SHELL_CONTROL_CURSOR_SECRET: randomBytes(32).toString("hex"),
      SHELL_CONTROL_PAIRING_TOKEN: makePairingToken(),
    };
    await writeEnv(env);
    return env;
  }
  const env: Record<string, string> = {};
  for (const line of (await readFile(ENV_FILE, "utf8")).split("\n")) {
    const cut = line.indexOf("=");
    if (cut <= 0) continue;
    env[line.slice(0, cut)] = line.slice(cut + 1);
  }
  if (!env.SHELL_CONTROL_ACCOUNT_ID) env.SHELL_CONTROL_ACCOUNT_ID = randomUUID();
  if (!env.SHELL_CONTROL_ADMIN_SECRET) env.SHELL_CONTROL_ADMIN_SECRET = randomBytes(32).toString("hex");
  if (!env.SHELL_CONTROL_CURSOR_SECRET) env.SHELL_CONTROL_CURSOR_SECRET = randomBytes(32).toString("hex");
  if (!env.SHELL_CONTROL_PAIRING_TOKEN) env.SHELL_CONTROL_PAIRING_TOKEN = makePairingToken();
  return env as SetupEnv;
}

async function writeEnv(env: SetupEnv): Promise<void> {
  await mkdir(STATE, { recursive: true, mode: 0o700 });
  await writeFile(ENV_FILE, Object.entries(env).map(([k, v]) => `${k}=${v}`).join("\n") + "\n", { mode: 0o600 });
}

async function pidAlive(file: string): Promise<boolean> {
  if (!(await exists(file))) return false;
  const pid = Number((await readFile(file, "utf8")).trim());
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function killPidFile(file: string): Promise<void> {
  if (!(await exists(file))) return;
  const pid = Number((await readFile(file, "utf8")).trim());
  if (!pid) return;
  try { process.kill(-pid, "SIGTERM"); } catch {
    try { process.kill(pid, "SIGTERM"); } catch { /* already gone */ }
  }
  try { await unlink(file); } catch { /* ignore */ }
}

async function firstExisting(paths: Array<string | undefined | null | false>): Promise<string | undefined> {
  for (const path of paths) {
    if (typeof path === "string" && (await exists(path))) return path;
  }
  return undefined;
}

function which(name: string): string | null {
  const result = spawnSync("which", [name], { encoding: "utf8" });
  if (result.status !== 0) return null;
  return result.stdout.trim();
}

function fail(message: string): never {
  process.stderr.write(`@chr33s/shell: ${message}\n`);
  process.exit(1);
}
