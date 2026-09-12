import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline/promises";
import {
  abortExitCode,
  CliError,
  exists,
  findRepoRoot,
  isAbortError,
  mergeSignals,
  pairingLink,
  pairingPageURL,
  requireAbsolutePath,
  signalExitCode,
  sleep,
} from "./util.ts";
import {
  acquireInstallationLock,
  atomicWriteFile,
  jobLabel,
  loadOrCreateInstallation,
  loadConfig,
  loadRuntime,
  loadSecrets,
  localBrokerURL,
  pathsFor,
  saveConfig,
  saveRuntime,
  saveSecrets,
  type LoadedInstallation,
  type Secrets,
} from "./state.ts";
import {
  binaryGeneration,
  defaultLaunchAgentsDir,
  defaultLibDir,
  FakeServiceManager,
  firstExisting,
  inspectLegacyPid,
  installBinaries,
  jobSpecFor,
  LaunchdServiceManager,
  readPidFile,
  which as whichBin,
  type InstalledBinaries,
  type JobSpec,
  type ServiceManager,
} from "./services.ts";
import {
  discoverQuickTunnelURL,
  resolveAddressMode,
  rotationNotice,
  validateNamedTunnel,
  validatePublicURL,
} from "./tunnel.ts";
import {
  observationFromJob,
  probeDaemonHealth,
  probeLocalBroker,
  probePublicRoute,
  projectStatus,
  pushObservation,
  requiredComponentsReady,
  tunnelObservation,
  type ProbeDeps,
  type StatusV2,
} from "./health.ts";

export type CLIContext = {
  stateDir: string;
  libDir: string;
  launchAgentsDir: string;
  env: NodeJS.ProcessEnv;
  now: () => Date;
  sleep: (ms: number, signal?: AbortSignal) => Promise<void>;
  fetchImpl: typeof fetch;
  manager: ServiceManager;
  stdinIsTTY: boolean;
  stdout: NodeJS.WritableStream;
  stderr: NodeJS.WritableStream;
  stdin: NodeJS.ReadableStream;
  which: (name: string) => string | null;
  repoRoot: string | null;
  platform: string;
  uid: number;
  homedir: string;
  binaries?: InstalledBinaries;
  readHealthSocket?: (path: string) => Promise<string | null>;
  buildNative?: () => void;
};

export type ParsedArgs = {
  command: string;
  positional: string[];
  flags: Map<string, string | boolean>;
};

const BOOLEAN_FLAGS = new Set([
  "help", "h", "no-watch", "watch", "check", "follow", "rotate-url",
]);
const VALUE_FLAGS = new Set([
  "tunnel-mode", "public-url", "tunnel-config",
]);
const COMMANDS = new Set([
  "setup", "up", "down", "restart", "service", "status", "logs", "pair",
  "confirm", "notify", "request", "receipt", "help",
]);

export function parseArgv(argv: string[]): ParsedArgs {
  const flags = new Map<string, string | boolean>();
  const rest: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;
    if (token === "--") {
      rest.push(...argv.slice(i + 1));
      break;
    }
    if (token.startsWith("--") || token === "-h") {
      const raw = token === "-h" ? "h" : token.slice(2);
      const eq = raw.indexOf("=");
      const name = eq >= 0 ? raw.slice(0, eq) : raw;
      if (!BOOLEAN_FLAGS.has(name) && !VALUE_FLAGS.has(name)) {
        throw new CliError(`unknown flag --${name}`, 2);
      }
      if (BOOLEAN_FLAGS.has(name)) {
        flags.set(name, true);
        continue;
      }
      const value = eq >= 0 ? raw.slice(eq + 1) : argv[++i];
      if (value == null || value.startsWith("-")) {
        throw new CliError(`--${name} requires a value`, 2);
      }
      flags.set(name, value);
      continue;
    }
    rest.push(token);
  }
  let command: string;
  let positional: string[];
  if (flags.get("help") || flags.get("h")) {
    command = "help";
    positional = rest;
  } else if (rest[0] && COMMANDS.has(rest[0])) {
    command = rest[0];
    positional = rest.slice(1);
  } else if (rest[0]) {
    throw new CliError(`unknown command ${rest[0]}`, 2);
  } else {
    command = "setup";
    positional = [];
  }
  return { command, positional, flags };
}

export function usage(): string {
  return `Usage: npx @chr33s/shell [setup|up|down|restart|service|status|logs|pair|confirm|request|notify|receipt]

  setup [--no-watch] [--tunnel-mode quick|named|external-proxy]
        [--public-url <https-url>] [--tunnel-config <absolute-path>]
        [--rotate-url]
            Ensure services, print pairing instructions. Does not opt into login startup.
            --no-watch returns after readiness. Non-TTY never waits or approves.
  up        Start or re-enable an existing configuration (no QR, no enrollment).
  down      Persist stopped intent, disable and unload owned jobs, verify shutdown.
  restart broker|daemon|tunnel|all
            Restart only the requested owned components; preserve identity.
  service install|uninstall
            Opt into (or remove) login-persistent launchd agents. Requires a stable address.
  status [--check]
            Observational JSON. --check exits 1 unless the control path is ready.
  logs [broker|daemon|tunnel] [--follow]
            Read local diagnostic logs. Exiting never affects the service.
  pair [--watch]
            Print pairing link/token/QR; optionally monitor enrollments.
  confirm <USER-CODE>
            Approve one device after printing its fingerprint.
  request, notify, receipt
            Passed through to the native adapter CLI.

Closing this CLI does not stop ready services. Use down to stop them.
Quick tunnels are development-only; named or external-proxy is required for persistence.
`;
}

export async function defaultContext(): Promise<CLIContext> {
  const home = homedir();
  const uid = process.getuid?.() ?? 0;
  const stateDir = process.env.SHELL_CONTROL_STATE_DIR || join(home, ".local/state/shell-control");
  const manager = process.env.SHELL_CONTROL_SERVICE_MANAGER === "fake"
    ? new FakeServiceManager()
    : new LaunchdServiceManager({ uid });
  return {
    stateDir,
    libDir: process.env.SHELL_CONTROL_LIB_DIR || defaultLibDir(home),
    launchAgentsDir: process.env.SHELL_CONTROL_LAUNCH_AGENTS_DIR || defaultLaunchAgentsDir(home),
    env: process.env,
    now: () => new Date(),
    sleep,
    fetchImpl: fetch,
    manager,
    stdinIsTTY: Boolean(process.stdin.isTTY),
    stdout: process.stdout,
    stderr: process.stderr,
    stdin: process.stdin,
    which: whichBin,
    repoRoot: await findRepoRoot(),
    platform: process.platform,
    uid,
    homedir: home,
  };
}

export async function main(argv: string[], ctx?: CLIContext): Promise<number> {
  const context = ctx ?? await defaultContext();
  const controller = new AbortController();
  const onSignal = (signal: NodeJS.Signals) => {
    controller.abort(signalExitCode(signal));
  };
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
  process.on("SIGHUP", onSignal);
  try {
    const parsed = parseArgv(argv);
    if (parsed.command === "help") {
      context.stdout.write(usage());
      return 0;
    }
    if (context.platform !== "darwin" && parsed.command !== "status" && parsed.command !== "help") {
      throw new CliError("macOS only — the broker and origin use CryptoKit", 1);
    }
    await dispatch(parsed, context, controller.signal);
    return 0;
  } catch (error) {
    if (controller.signal.aborted || isAbortError(error)) {
      const code = error instanceof CliError ? error.exitCode : abortExitCode(controller.signal);
      return code;
    }
    if (error instanceof CliError) {
      if (error.message !== "cancelled") {
        context.stderr.write(`@chr33s/shell: ${error.message}\n`);
      }
      return error.exitCode;
    }
    throw error;
  } finally {
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
    process.off("SIGHUP", onSignal);
  }
}

async function dispatch(parsed: ParsedArgs, ctx: CLIContext, signal: AbortSignal): Promise<void> {
  switch (parsed.command) {
    case "setup":
      await cmdSetup(ctx, parsed, signal);
      return;
    case "up":
      await cmdUp(ctx, signal);
      return;
    case "down":
      await cmdDown(ctx);
      return;
    case "restart":
      await cmdRestart(ctx, parsed.positional[0], signal);
      return;
    case "service":
      await cmdService(ctx, parsed.positional[0], signal);
      return;
    case "status":
      await cmdStatus(ctx, Boolean(parsed.flags.get("check")), signal);
      return;
    case "logs":
      await cmdLogs(ctx, parsed.positional[0], Boolean(parsed.flags.get("follow")), signal);
      return;
    case "pair":
      await cmdPair(ctx, Boolean(parsed.flags.get("watch")), signal);
      return;
    case "confirm":
      await cmdConfirm(ctx, parsed.positional[0], signal);
      return;
    case "notify":
    case "request":
    case "receipt":
      await proxyNative(ctx, [parsed.command, ...parsed.positional]);
      return;
    default:
      throw new CliError(`unknown command ${parsed.command}`, 2);
  }
}

async function cmdSetup(ctx: CLIContext, parsed: ParsedArgs, signal: AbortSignal): Promise<void> {
  const lock = await acquireInstallationLock(ctx.stateDir);
  let ready = false;
  let inst: LoadedInstallation | undefined;
  try {
    inst = await loadOrCreateInstallation(ctx.stateDir);
    applyConfigurationFlags(inst, parsed, ctx);
    await saveConfig(ctx.stateDir, inst.config);
    await reconcileIncomplete(ctx, inst);
    const created: string[] = [];
    inst.runtime.incomplete = true;
    inst.runtime.startup_generation += 1;
    inst.runtime.created = created;
    await saveRuntime(ctx.stateDir, inst.runtime);
    try {
      await ensureBinaries(ctx, inst);
      await ensureServices(ctx, inst, {
        signal,
        rotateURL: Boolean(parsed.flags.get("rotate-url")),
        created,
      });
      inst.config.desired_state = "running";
      inst.runtime.incomplete = false;
      inst.runtime.created = [];
      await saveConfig(ctx.stateDir, inst.config);
      await saveSecrets(ctx.stateDir, inst.secrets);
      await saveRuntime(ctx.stateDir, inst.runtime);
      ready = true;
    } catch (error) {
      if (!ready && isCancelled(error, signal)) {
        await rollbackCreated(ctx, inst, created);
      }
      throw error;
    }
  } finally {
    await lock.release();
  }
  if (!inst) return;
  const publicURL = inst.config.public_url || localBrokerURL(inst.config.port);
  await printPairing(ctx, publicURL, inst.secrets.pairing_token);
  if (inst.config.address_mode === "loopback") {
    ctx.stderr.write("loopback address only — physical Watch/iPhone cannot reach this host\n");
  }
  const monitor = !parsed.flags.get("no-watch");
  if (!monitor) return;
  if (!ctx.stdinIsTTY) {
    ctx.stderr.write("no TTY — not waiting for enrollment; run: npx @chr33s/shell pair --watch\n");
    ctx.stderr.write("approve a device with: npx @chr33s/shell confirm <USER-CODE>\n");
    return;
  }
  ctx.stderr.write("waiting for iPhone / Watch enrollment — type y to approve after each fingerprint. Ctrl+C stops watching (npx @chr33s/shell down to stop services)\n");
  await watchEnrollments(ctx, inst.secrets, inst.config.port, signal);
}

function applyConfigurationFlags(inst: LoadedInstallation, parsed: ParsedArgs, ctx: CLIContext): void {
  const resolved = resolveAddressMode({
    explicitMode: flagString(parsed, "tunnel-mode"),
    explicitPublicURL: flagString(parsed, "public-url"),
    envPublicURL: ctx.env.SHELL_CONTROL_PUBLIC_URL,
    stored: { address_mode: inst.config.address_mode, public_url: inst.config.public_url },
    fresh: inst.created,
  });
  const previousMode = inst.config.address_mode;
  const previousURL = inst.config.public_url;
  inst.config.address_mode = resolved.mode;
  if (resolved.publicURL) inst.config.public_url = resolved.publicURL;
  if (!inst.created && (previousMode !== inst.config.address_mode || previousURL !== inst.config.public_url)) {
    ctx.stderr.write(
      `configuration changed (${previousMode} ${previousURL || "(none)"} → ${inst.config.address_mode} ${inst.config.public_url || "(none)"}); services will be reconciled to match\n`,
    );
  }
  const tunnelConfig = flagString(parsed, "tunnel-config");
  if (tunnelConfig) {
    inst.config.tunnel_config_path = requireAbsolutePath(tunnelConfig, "--tunnel-config");
  }
  if (ctx.env.SHELL_CONTROL_PORT && inst.created) {
    const port = Number(ctx.env.SHELL_CONTROL_PORT);
    if (Number.isInteger(port) && port > 0) inst.config.port = port;
  }
}

function flagString(parsed: ParsedArgs, name: string): string | undefined {
  const value = parsed.flags.get(name);
  return typeof value === "string" ? value : undefined;
}

async function cmdUp(ctx: CLIContext, signal: AbortSignal): Promise<void> {
  const lock = await acquireInstallationLock(ctx.stateDir);
  try {
    const inst = await requireInstallation(ctx);
    inst.config.desired_state = "running";
    await saveConfig(ctx.stateDir, inst.config);
    await ensureBinaries(ctx, inst);
    await ensureServices(ctx, inst, { signal, rotateURL: false, created: [] });
    ctx.stderr.write("started\n");
  } finally {
    await lock.release();
  }
}

async function cmdDown(ctx: CLIContext): Promise<void> {
  const lock = await acquireInstallationLock(ctx.stateDir);
  try {
    const inst = await requireInstallation(ctx);
    inst.config.desired_state = "stopped";
    await saveConfig(ctx.stateDir, inst.config);
    const labels = ctx.manager.labels(inst.config.installation_id);
    for (const component of ["daemon", "tunnel", "broker"] as const) {
      const label = labels[component];
      await ctx.manager.disable(label);
      await ctx.manager.stop(label);
    }
    await verifyStopped(ctx, inst);
    ctx.stderr.write("stopped\n");
  } finally {
    await lock.release();
  }
}

async function verifyStopped(ctx: CLIContext, inst: LoadedInstallation): Promise<void> {
  const labels = ctx.manager.labels(inst.config.installation_id);
  for (const component of ["broker", "daemon", "tunnel"] as const) {
    const observed = await ctx.manager.observe(labels[component]);
    if (observed.pid != null) {
      throw new CliError(`${component} is still running after down (pid ${observed.pid})`, 1);
    }
    if (observed.loaded && observed.enabled) {
      throw new CliError(`${component} is still enabled after down`, 1);
    }
  }
}

async function cmdRestart(ctx: CLIContext, target: string | undefined, signal: AbortSignal): Promise<void> {
  if (!target || !["broker", "daemon", "tunnel", "all"].includes(target)) {
    throw new CliError("usage: npx @chr33s/shell restart broker|daemon|tunnel|all", 2);
  }
  const lock = await acquireInstallationLock(ctx.stateDir);
  try {
    const inst = await requireInstallation(ctx);
    if (inst.config.desired_state === "stopped") {
      throw new CliError("installation is stopped; run up first", 1);
    }
    const bins = await ensureBinaries(ctx, inst);
    const components = target === "all" ? (["broker", "daemon", "tunnel"] as const) : [target as "broker" | "daemon" | "tunnel"];
    for (const component of components) {
      if (component === "tunnel" && inst.config.address_mode === "quick") {
        throw new CliError("restarting a quick tunnel would replace its hostname; use setup --rotate-url", 2);
      }
      if (component === "tunnel" && inst.config.address_mode === "external-proxy") continue;
      const spec = serviceSpec(ctx, inst, bins, component);
      if (!spec) continue;
      await ctx.manager.restart(spec);
    }
    await waitUntilReady(ctx, inst, signal);
    ctx.stderr.write("restarted\n");
  } finally {
    await lock.release();
  }
}

async function cmdService(ctx: CLIContext, action: string | undefined, signal: AbortSignal): Promise<void> {
  if (action !== "install" && action !== "uninstall") {
    throw new CliError("usage: npx @chr33s/shell service install|uninstall", 2);
  }
  const lock = await acquireInstallationLock(ctx.stateDir);
  try {
    const inst = await requireInstallation(ctx);
    if (action === "install") {
      if (inst.config.address_mode === "quick" || inst.config.address_mode === "loopback") {
        throw new CliError("persistent install requires named or external-proxy mode with a stable https URL", 2);
      }
      if (!inst.config.public_url || !inst.config.public_url.startsWith("https://")) {
        throw new CliError("persistent install requires --public-url https://…", 2);
      }
      const bins = await ensureBinaries(ctx, inst);
      inst.config.persistent = true;
      await saveConfig(ctx.stateDir, inst.config);
      for (const component of ["broker", "daemon", "tunnel"] as const) {
        const spec = serviceSpec(ctx, inst, bins, component);
        if (!spec) continue;
        await ctx.manager.install(spec);
      }
      ctx.stderr.write("persistent agents installed — they resume after login, not before login\n");
      return;
    }
    inst.config.persistent = false;
    await saveConfig(ctx.stateDir, inst.config);
    const labels = ctx.manager.labels(inst.config.installation_id);
    const dummy = {
      launchAgentsDir: ctx.launchAgentsDir,
      sessionPlistDir: inst.paths.launchd,
    };
    for (const component of ["broker", "daemon", "tunnel"] as const) {
      await ctx.manager.uninstall(labels[component], dummy);
    }
    ctx.stderr.write("persistent agents removed; configuration and journals retained\n");
  } finally {
    await lock.release();
  }
  void signal;
}

async function cmdStatus(ctx: CLIContext, check: boolean, signal: AbortSignal): Promise<void> {
  const status = await collectStatus(ctx, signal);
  ctx.stdout.write(`${JSON.stringify(status, null, 2)}\n`);
  if (check && !requiredComponentsReady(status)) {
    throw new CliError("control path is not ready", 1);
  }
}

async function collectStatus(ctx: CLIContext, signal: AbortSignal): Promise<StatusV2> {
  const paths = pathsFor(ctx.stateDir);
  if (!(await exists(paths.config))) {
    const now = ctx.now().toISOString();
    const empty = { state: "stopped" as const, checked_at: now };
    return {
      schema_version: 2,
      broker: false,
      tunnel: false,
      daemon: false,
      overall: "unavailable",
      manager: ctx.manager.kind,
      persistent: false,
      desired_state: "stopped",
      public_url: null,
      components: {
        broker: empty,
        daemon: empty,
        tunnel: empty,
        public_route: empty,
        push: pushObservation(await pushConfigured(ctx, ctx.stateDir), now),
      },
    };
  }
  const config = await loadConfig(ctx.stateDir);
  const secrets = await loadSecrets(ctx.stateDir);
  const runtime = await loadRuntime(ctx.stateDir);
  if (!config || !secrets) {
    throw new CliError("installation is unreadable — repair required", 1);
  }
  const labels = ctx.manager.labels(config.installation_id);
  const now = ctx.now().toISOString();
  const [brokerJob, daemonJob, tunnelJob] = await Promise.all([
    ctx.manager.observe(labels.broker),
    ctx.manager.observe(labels.daemon),
    ctx.manager.observe(labels.tunnel),
  ]);
  const deps: ProbeDeps = {
    fetchImpl: ctx.fetchImpl,
    now: ctx.now,
    signal,
    readHealthSocket: ctx.readHealthSocket,
  };
  const local = localBrokerURL(config.port);
  const brokerReady = await probeLocalBroker(local, deps);
  let daemonReady = observationFromJob(daemonJob, now);
  if (daemonJob.pid != null) {
    daemonReady = await probeDaemonHealth(paths.healthSock, deps);
  }
  const publicRoute = config.public_url
    ? await probePublicRoute(config.public_url, deps)
    : { state: "not_configured" as const, checked_at: now, diagnostic_id: "public_route" };
  const tunnel = tunnelObservation({ mode: config.address_mode, job: tunnelJob, runtime, now });
  const status = projectStatus({
    config,
    runtime,
    manager: ctx.manager.kind,
    brokerJob: observationFromJob(brokerJob, now),
    daemonJob: observationFromJob(daemonJob, now),
    tunnelJob: tunnel,
    brokerReady,
    daemonReady,
    publicRoute,
    push: pushObservation(await pushConfigured(ctx, paths.root), now),
  });
  const text = JSON.stringify(status);
  if (text.includes(secrets.admin_secret) || text.includes(secrets.pairing_token) || text.includes(secrets.cursor_secret)) {
    throw new CliError("internal error: status leaked a secret", 1);
  }
  return status;
}

async function cmdLogs(
  ctx: CLIContext,
  component: string | undefined,
  follow: boolean,
  signal: AbortSignal,
): Promise<void> {
  const inst = await requireInstallation(ctx);
  const names = component ? [component] : ["broker", "daemon", "tunnel"];
  if (component && !["broker", "daemon", "tunnel"].includes(component)) {
    throw new CliError("usage: npx @chr33s/shell logs [broker|daemon|tunnel] [--follow]", 2);
  }
  for (const name of names) {
    for (const stream of ["err", "out"]) {
      const path = join(inst.paths.logs, `${name}.${stream}.log`);
      if (!(await exists(path))) continue;
      if (!follow) {
        ctx.stdout.write(await readFile(path, "utf8"));
      }
    }
  }
  if (!follow) return;
  const path = join(inst.paths.logs, `${names[0]}.err.log`);
  await followFile(path, ctx, signal);
}

async function pushConfigured(ctx: CLIContext, stateDir: string): Promise<boolean> {
  if (ctx.env.SHELL_CONTROL_APNS_KEY_FILE || ctx.env.SHELL_CONTROL_APNS_KEY_ID) return true;
  try {
    const raw = await readFile(join(stateDir, "broker.service.json"), "utf8");
    const parsed = JSON.parse(raw) as { apns_key_file?: string; apns_key_id?: string };
    return Boolean(parsed.apns_key_file || parsed.apns_key_id);
  } catch {
    return false;
  }
}

async function followFile(path: string, ctx: CLIContext, signal: AbortSignal): Promise<void> {
  let pos = 0;
  if (await exists(path)) {
    const st = await stat(path);
    pos = st.size;
    ctx.stdout.write(await readFile(path));
  }
  try {
    while (!signal.aborted) {
      if (await exists(path)) {
        const st = await stat(path);
        if (st.size < pos) pos = 0;
        if (st.size > pos) {
          const { open } = await import("node:fs/promises");
          const handle = await open(path, "r");
          try {
            const buf = Buffer.alloc(st.size - pos);
            await handle.read(buf, 0, buf.length, pos);
            ctx.stdout.write(buf);
            pos = st.size;
          } finally {
            await handle.close();
          }
        }
      }
      await ctx.sleep(200, signal);
    }
  } catch (error) {
    if (isCancelled(error, signal)) throw new CliError("cancelled", abortExitCode(signal));
    throw error;
  }
}

async function cmdPair(ctx: CLIContext, watch: boolean, signal: AbortSignal): Promise<void> {
  const inst = await requireInstallation(ctx);
  const publicURL = inst.config.public_url || localBrokerURL(inst.config.port);
  await printPairing(ctx, publicURL, inst.secrets.pairing_token);
  if (!watch) return;
  if (!ctx.stdinIsTTY) {
    ctx.stderr.write("no TTY — not waiting for enrollment; run: npx @chr33s/shell confirm <USER-CODE>\n");
    return;
  }
  await watchEnrollments(ctx, inst.secrets, inst.config.port, signal);
}

async function cmdConfirm(ctx: CLIContext, code: string | undefined, signal: AbortSignal): Promise<void> {
  if (!code) throw new CliError("usage: npx @chr33s/shell confirm <USER-CODE>", 2);
  const inst = await requireInstallation(ctx);
  const approved = await confirmCode(ctx, inst.secrets, inst.config.port, code, { prompt: false, signal });
  if (!approved) throw new CliError("not approved", 1);
}

async function requireInstallation(ctx: CLIContext): Promise<LoadedInstallation> {
  const paths = pathsFor(ctx.stateDir);
  if (!(await exists(paths.config))) {
    throw new CliError("no installation — run setup first", 1);
  }
  return loadOrCreateInstallation(ctx.stateDir);
}

async function reconcileIncomplete(ctx: CLIContext, inst: LoadedInstallation): Promise<void> {
  if (!inst.runtime.incomplete) return;
  ctx.stderr.write("reconciling incomplete startup from a previous invocation\n");
  await rollbackCreated(ctx, inst, inst.runtime.created);
  inst.runtime.incomplete = false;
  inst.runtime.created = [];
  await saveRuntime(ctx.stateDir, inst.runtime);
}

async function rollbackCreated(ctx: CLIContext, inst: LoadedInstallation, created: string[]): Promise<void> {
  const labels = ctx.manager.labels(inst.config.installation_id);
  for (const name of [...created].reverse()) {
    if (name === "broker" || name === "daemon" || name === "tunnel") {
      await ctx.manager.disable(labels[name]).catch(() => undefined);
      await ctx.manager.stop(labels[name]).catch(() => undefined);
    }
  }
}

async function ensureBinaries(ctx: CLIContext, inst: LoadedInstallation): Promise<InstalledBinaries> {
  if (ctx.binaries) return ctx.binaries;
  const resolved = await resolveBinaries(ctx);
  const version = ctx.env.SHELL_CONTROL_BUNDLE_VERSION || await binaryGeneration(resolved);
  const destBroker = join(ctx.libDir, version, "shell-control-broker");
  if (await exists(destBroker)) {
    const installed: InstalledBinaries = {
      version,
      broker: destBroker,
      daemon: join(ctx.libDir, version, "shell-controld"),
      cli: (await exists(join(ctx.libDir, version, "shell-control"))) ? join(ctx.libDir, version, "shell-control") : resolved.cli,
      cloudflared: (await exists(join(ctx.libDir, version, "cloudflared"))) ? join(ctx.libDir, version, "cloudflared") : resolved.cloudflared,
      directory: join(ctx.libDir, version),
    };
    inst.config.installed_binary_version = version;
    await saveConfig(ctx.stateDir, inst.config);
    return installed;
  }
  const installed = await installBinaries({
    libDir: ctx.libDir,
    version,
    sources: resolved,
  });
  inst.config.installed_binary_version = installed.version;
  await saveConfig(ctx.stateDir, inst.config);
  return installed;
}

async function resolveBinaries(ctx: CLIContext): Promise<{ broker: string; daemon: string; cli?: string; cloudflared?: string }> {
  const root = ctx.repoRoot;
  const override = ctx.env.SHELL_CONTROL_BIN;
  let broker = await firstExisting([
    override && join(override, "shell-control-broker"),
    root && join(root, "services/shell-control/.build/release/shell-control-broker"),
    join(ctx.libDir, "current/shell-control-broker"),
    ctx.which("shell-control-broker"),
  ]);
  let daemon = await firstExisting([
    override && join(override, "shell-controld"),
    root && join(root, "cmd/.build/release/shell-controld"),
    join(ctx.libDir, "current/shell-controld"),
    ctx.which("shell-controld"),
  ]);
  let cli = await firstExisting([
    override && join(override, "shell-control"),
    root && join(root, "cmd/.build/release/shell-control"),
    join(ctx.libDir, "current/shell-control"),
    ctx.which("shell-control"),
  ]);
  if (!broker || !daemon) {
    ctx.stderr.write("building native tools…\n");
    if (ctx.buildNative) ctx.buildNative();
    else buildNative(root);
    broker = await firstExisting([broker, root && join(root, "services/shell-control/.build/release/shell-control-broker")]);
    daemon = await firstExisting([daemon, root && join(root, "cmd/.build/release/shell-controld")]);
    cli = await firstExisting([cli, root && join(root, "cmd/.build/release/shell-control")]);
  }
  if (!broker || !daemon) {
    throw new CliError("could not build shell-control-broker / shell-controld — need Swift 6.2 in this checkout", 1);
  }
  const cloudflared = ctx.which("cloudflared") ?? undefined;
  return { broker, daemon, cli, cloudflared };
}

function buildNative(root: string | null): void {
  if (!root) throw new CliError("native sources not found — clone chr33s/shell and run from that checkout", 1);
  run("swift", ["build", "-c", "release", "--package-path", join(root, "services/shell-control")]);
  run("swift", ["build", "-c", "release", "--package-path", join(root, "cmd")]);
}

function run(cmd: string, args: string[]): void {
  const result = spawnSync(cmd, args, { stdio: "inherit" });
  if (result.status !== 0) throw new CliError(`${cmd} ${args.join(" ")} failed`, 1);
}

async function proxyNative(ctx: CLIContext, args: string[]): Promise<void> {
  const bins = ctx.binaries ?? await resolveBinaries(ctx);
  if (!bins.cli) throw new CliError("shell-control is not built", 1);
  const result = spawnSync(bins.cli, args, {
    stdio: "inherit",
    env: {
      ...ctx.env,
      SHELL_CONTROL_STATE_DIR: ctx.stateDir,
    },
  });
  const status = result.status ?? 1;
  if (status !== 0) throw new CliError("native CLI failed", status);
}

type EnsureOptions = {
  signal: AbortSignal;
  rotateURL: boolean;
  created: string[];
};

async function ensureServices(ctx: CLIContext, inst: LoadedInstallation, options: EnsureOptions): Promise<void> {
  await maybeAdoptLegacy(ctx, inst);
  const bins = await ensureBinaries(ctx, inst);
  if (options.rotateURL) {
    if (inst.config.address_mode !== "quick") {
      throw new CliError("--rotate-url is only valid for quick tunnels", 2);
    }
    const old = inst.config.public_url;
    await stopComponent(ctx, inst, "tunnel");
    inst.config.public_url = null;
    await startQuickTunnel(ctx, inst, bins, options);
    ctx.stderr.write(rotationNotice(old, inst.config.public_url || "") + "\n");
  } else {
    await ensureTunnel(ctx, inst, bins, options);
  }
  const initialConfigChanges = await writeServiceConfigs(ctx, inst);
  await ensureComponent(ctx, inst, bins, "broker", options, initialConfigChanges.has("broker"));
  await waitForBroker(ctx, inst, options.signal);
  await ensureOrigin(ctx, inst, options.signal);
  const provisionedConfigChanges = await writeServiceConfigs(ctx, inst);
  await ensureComponent(
    ctx,
    inst,
    bins,
    "daemon",
    options,
    initialConfigChanges.has("daemon") || provisionedConfigChanges.has("daemon"),
  );
  await waitUntilReady(ctx, inst, options.signal);
}

async function maybeAdoptLegacy(ctx: CLIContext, inst: LoadedInstallation): Promise<void> {
  const reports: string[] = [];
  for (const [file, name] of [
    [inst.paths.brokerPid, "shell-control-broker"],
    [inst.paths.daemonPid, "shell-controld"],
    [inst.paths.tunnelPid, "cloudflared"],
  ] as const) {
    const pid = await readPidFile(file);
    if (pid == null) continue;
    const report = await inspectLegacyPid(pid, name, ctx.uid);
    if (!report.verifiable) {
      reports.push(`${name} pid ${pid} is unmanaged (${report.reason})`);
      if (name === "cloudflared") inst.runtime.observations.tunnel_legacy_unmanaged = true;
      continue;
    }
    reports.push(`${name} pid ${pid} is a verifiable legacy process; not signalling it during launchd adoption`);
    if (name === "cloudflared") inst.runtime.observations.tunnel_legacy_unmanaged = true;
  }
  for (const line of reports) ctx.stderr.write(`${line}\n`);
  await saveRuntime(ctx.stateDir, inst.runtime);
}

async function ensureTunnel(
  ctx: CLIContext,
  inst: LoadedInstallation,
  bins: InstalledBinaries,
  options: EnsureOptions,
): Promise<void> {
  const mode = inst.config.address_mode;
  if (mode === "external-proxy") {
    if (!inst.config.public_url) throw new CliError("external-proxy mode requires --public-url", 2);
    validatePublicURL(inst.config.public_url, "external-proxy");
    return;
  }
  if (mode === "loopback") {
    inst.config.public_url = localBrokerURL(inst.config.port);
    return;
  }
  if (mode === "named") {
    if (!inst.config.tunnel_config_path || !inst.config.public_url) {
      throw new CliError("named mode requires --public-url and --tunnel-config", 2);
    }
    const named = await validateNamedTunnel({
      configPath: inst.config.tunnel_config_path,
      publicURL: inst.config.public_url,
      port: inst.config.port,
      uid: ctx.uid,
    });
    inst.config.tunnel_identity = named.tunnel;
    await ensureComponent(ctx, inst, bins, "tunnel", options);
    return;
  }
  // quick
  if (inst.config.public_url) {
    const labels = ctx.manager.labels(inst.config.installation_id);
    const job = await ctx.manager.observe(labels.tunnel);
    if (job.pid != null) return;
    ctx.stderr.write("quick tunnel is not running; hostname preserved. Use setup --rotate-url to replace it.\n");
    return;
  }
  await startQuickTunnel(ctx, inst, bins, options);
}

async function startQuickTunnel(
  ctx: CLIContext,
  inst: LoadedInstallation,
  bins: InstalledBinaries,
  options: EnsureOptions,
): Promise<void> {
  const cloudflared = bins.cloudflared || ctx.which("cloudflared");
  if (!cloudflared) {
    ctx.stderr.write("cloudflared not found — using http://127.0.0.1 (physical Watch/iPhone cannot reach this). brew install cloudflared\n");
    inst.config.address_mode = "loopback";
    inst.config.public_url = localBrokerURL(inst.config.port);
    return;
  }
  const generation = `gen-${inst.runtime.startup_generation}-${randomUUID()}`;
  const errLog = join(inst.paths.logs, "tunnel.err.log");
  const outLog = join(inst.paths.logs, "tunnel.out.log");
  await mkdir(inst.paths.logs, { recursive: true, mode: 0o700 });
  const marker = `\n--- generation ${generation} ---\n`;
  for (const logPath of [errLog, outLog]) {
    await appendFile(logPath, marker).catch(async () => {
      await writeFile(logPath, marker, { mode: 0o600 });
    });
  }
  inst.config.address_mode = "quick";
  const spec = jobSpecFor("tunnel", inst.config, {
    executable: cloudflared,
    arguments: ["tunnel", "--url", `http://127.0.0.1:${inst.config.port}`, "--no-autoupdate"],
    workingDirectory: inst.paths.root,
    logsDir: inst.paths.logs,
    sessionPlistDir: inst.paths.launchd,
    launchAgentsDir: ctx.launchAgentsDir,
    environment: { SHELL_CONTROL_STATE_DIR: inst.paths.root },
  });
  spec.keepAlive = false;
  spec.persistent = false;
  await recordCreatedResource(ctx, inst, options, "tunnel");
  await ctx.manager.start(spec);
  const url = await discoverQuickTunnelURL({
    logPath: errLog,
    logPaths: [errLog, outLog],
    generation,
    signal: options.signal,
    sleep: ctx.sleep,
  });
  inst.config.public_url = url;
}

async function ensureComponent(
  ctx: CLIContext,
  inst: LoadedInstallation,
  bins: InstalledBinaries,
  component: "broker" | "daemon" | "tunnel",
  options: EnsureOptions,
  forceRestart = false,
): Promise<void> {
  const spec = serviceSpec(ctx, inst, bins, component);
  if (!spec) return;
  const label = jobLabel(inst.config.installation_id, component);
  const job = await ctx.manager.observe(label);
  if (job.pid != null && job.enabled) {
    if (forceRestart) {
      await ctx.manager.restart(spec);
      return;
    }
    // This is a no-op for an unchanged registration, but lets the manager
    // reload a changed executable or ProgramArguments before health is judged.
    await ctx.manager.start(spec);
    if (component === "broker") {
      const ready = await probeLocalBroker(localBrokerURL(inst.config.port), probeDeps(ctx, options.signal));
      if (ready.state === "ready") return;
      ctx.stderr.write("broker is registered but not ready, restarting\n");
      await ctx.manager.restart(spec);
      return;
    }
    if (component === "daemon") {
      const health = await probeDaemonHealth(inst.paths.healthSock, probeDeps(ctx, options.signal));
      if (health.state === "ready" || health.state === "recovering" || ctx.manager.kind === "fake") return;
      await ctx.manager.restart(spec);
      return;
    }
    return;
  }
  await recordCreatedResource(ctx, inst, options, component);
  await ctx.manager.start(spec);
}

async function recordCreatedResource(
  ctx: CLIContext,
  inst: LoadedInstallation,
  options: EnsureOptions,
  component: "broker" | "daemon" | "tunnel",
): Promise<void> {
  if (!options.created.includes(component)) options.created.push(component);
  // Persist the intent before launch. After SIGKILL the next invocation can
  // safely stop a process this invocation may have created.
  inst.runtime.created = [...options.created];
  await saveRuntime(ctx.stateDir, inst.runtime);
}

function serviceSpec(
  ctx: CLIContext,
  inst: LoadedInstallation,
  bins: InstalledBinaries,
  component: "broker" | "daemon" | "tunnel",
): JobSpec | null {
  if (component === "tunnel") {
    if (inst.config.address_mode === "external-proxy" || inst.config.address_mode === "loopback") return null;
    if (inst.config.address_mode === "named") {
      const cloudflared = bins.cloudflared || ctx.which("cloudflared");
      if (!cloudflared || !inst.config.tunnel_config_path) {
        throw new CliError("named tunnel requires cloudflared and --tunnel-config", 2);
      }
      return jobSpecFor("tunnel", inst.config, {
        executable: cloudflared,
        arguments: ["tunnel", "--config", inst.config.tunnel_config_path, "--no-autoupdate", "run"],
        workingDirectory: inst.paths.root,
        logsDir: inst.paths.logs,
        sessionPlistDir: inst.paths.launchd,
        launchAgentsDir: ctx.launchAgentsDir,
        environment: {
          SHELL_CONTROL_STATE_DIR: inst.paths.root,
          SHELL_CONTROL_CONFIG_GENERATION: fileDigest(inst.config.tunnel_config_path),
        },
      });
    }
    const cloudflared = bins.cloudflared || ctx.which("cloudflared");
    if (!cloudflared) return null;
    return jobSpecFor("tunnel", inst.config, {
      executable: cloudflared,
      arguments: ["tunnel", "--url", `http://127.0.0.1:${inst.config.port}`, "--no-autoupdate"],
      workingDirectory: inst.paths.root,
      logsDir: inst.paths.logs,
      sessionPlistDir: inst.paths.launchd,
      launchAgentsDir: ctx.launchAgentsDir,
      environment: { SHELL_CONTROL_STATE_DIR: inst.paths.root },
    });
  }
  if (component === "broker") {
    return jobSpecFor("broker", inst.config, {
      executable: bins.broker,
      arguments: ["--config", join(inst.paths.root, "broker.service.json")],
      workingDirectory: inst.paths.root,
      logsDir: inst.paths.logs,
      sessionPlistDir: inst.paths.launchd,
      launchAgentsDir: ctx.launchAgentsDir,
      environment: { SHELL_CONTROL_STATE_DIR: inst.paths.root },
    });
  }
  return jobSpecFor("daemon", inst.config, {
    executable: bins.daemon,
    arguments: ["--config", join(inst.paths.root, "daemon.service.json")],
    workingDirectory: inst.paths.root,
    logsDir: inst.paths.logs,
    sessionPlistDir: inst.paths.launchd,
    launchAgentsDir: ctx.launchAgentsDir,
    environment: { SHELL_CONTROL_STATE_DIR: inst.paths.root },
  });
}

function fileDigest(path: string): string {
  try {
    return createHash("sha256").update(readFileSync(path)).digest("hex");
  } catch {
    return "unreadable";
  }
}

async function writeServiceConfigs(
  ctx: CLIContext,
  inst: LoadedInstallation,
): Promise<Set<"broker" | "daemon">> {
  const broker = {
    port: inst.config.port,
    bind_loopback: inst.config.bind_loopback,
    state_path: inst.paths.brokerLedger,
    state_directory: inst.paths.root,
    account_id: inst.secrets.account_id,
    admin_secret: inst.secrets.admin_secret,
    cursor_secret: inst.secrets.cursor_secret,
    public_url: inst.config.public_url || "",
    verification_uri: inst.config.public_url ? `${inst.config.public_url}/v1/oauth/confirm` : "",
    identity: "shell-control",
    apns_topics: ctx.env.SHELL_CONTROL_APNS_TOPICS || "dev.chr33s.shell.watchkitapp,dev.chr33s.shell",
    apns_key_id: ctx.env.SHELL_CONTROL_APNS_KEY_ID || "",
    apns_team_id: ctx.env.SHELL_CONTROL_APNS_TEAM_ID || "",
    apns_key_file: ctx.env.SHELL_CONTROL_APNS_KEY_FILE || "",
  };
  const daemon = {
    broker_url: localBrokerURL(inst.config.port),
    origin_id: inst.secrets.origin_id,
    origin_secret: inst.secrets.origin_secret,
    state_directory: inst.paths.root,
    socket_path: inst.paths.controlSock,
    health_socket_path: inst.paths.healthSock,
    journal_path: inst.paths.journal,
    recovery_outbox_path: inst.paths.recoveryOutbox,
  };
  const changed = new Set<"broker" | "daemon">();
  const writeIfChanged = async (component: "broker" | "daemon", path: string, value: unknown) => {
    const contents = JSON.stringify(value, null, 2) + "\n";
    let previous: string | null = null;
    try {
      previous = await readFile(path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    if (previous === contents) return;
    await atomicWriteFile(path, contents, 0o600);
    changed.add(component);
  };
  await writeIfChanged("broker", join(inst.paths.root, "broker.service.json"), broker);
  await writeIfChanged("daemon", join(inst.paths.root, "daemon.service.json"), daemon);
  return changed;
}

async function stopComponent(ctx: CLIContext, inst: LoadedInstallation, component: "broker" | "daemon" | "tunnel"): Promise<void> {
  await ctx.manager.stop(jobLabel(inst.config.installation_id, component));
}

function probeDeps(ctx: CLIContext, signal: AbortSignal): ProbeDeps {
  return { fetchImpl: ctx.fetchImpl, now: ctx.now, signal, readHealthSocket: ctx.readHealthSocket };
}

async function waitForBroker(ctx: CLIContext, inst: LoadedInstallation, signal: AbortSignal): Promise<void> {
  const url = localBrokerURL(inst.config.port);
  for (let i = 0; i < 40; i++) {
    if (signal.aborted) throw new CliError("cancelled", abortExitCode(signal));
    const ready = await probeLocalBroker(url, probeDeps(ctx, signal));
    if (ready.state === "ready") return;
    await ctx.sleep(150, signal);
  }
  throw new CliError(`broker did not become ready on 127.0.0.1:${inst.config.port}`, 1);
}

async function waitUntilReady(ctx: CLIContext, inst: LoadedInstallation, signal: AbortSignal): Promise<void> {
  await waitForBroker(ctx, inst, signal);
  if (ctx.manager.kind === "fake") {
    const labels = ctx.manager.labels(inst.config.installation_id);
    const daemon = await ctx.manager.observe(labels.daemon);
    if (daemon.pid == null) throw new CliError("daemon did not start", 1);
    return;
  }
  for (let i = 0; i < 40; i++) {
    if (signal.aborted) throw new CliError("cancelled", abortExitCode(signal));
    const health = await probeDaemonHealth(inst.paths.healthSock, probeDeps(ctx, signal));
    if (health.state === "ready") return;
    await ctx.sleep(150, signal);
  }
  throw new CliError("daemon did not become ready", 1);
}

async function ensureOrigin(ctx: CLIContext, inst: LoadedInstallation, signal: AbortSignal): Promise<void> {
  if (inst.secrets.origin_id && inst.secrets.origin_secret) return;
  const label = ctx.homedir.split("/").pop() || "mac";
  const created = await adminJSON<{ origin_id: string; origin_secret: string }>(
    ctx,
    inst.secrets,
    inst.config.port,
    "POST",
    "/v1/admin/origins",
    { label },
    signal,
  );
  inst.secrets.origin_id = created.origin_id;
  inst.secrets.origin_secret = created.origin_secret;
  await saveSecrets(ctx.stateDir, inst.secrets);
}

type PendingList = { pending?: Array<{ user_code?: string }> };
type DeviceDescription = { platform?: string; label?: string; key_fingerprint?: string };

async function watchEnrollments(ctx: CLIContext, secrets: Secrets, port: number, signal: AbortSignal): Promise<void> {
  const seen = new Set<string>();
  while (!signal.aborted) {
    try {
      const pending = await adminJSON<PendingList>(ctx, secrets, port, "GET", "/v1/admin/pending", undefined, signal);
      for (const item of pending.pending || []) {
        if (signal.aborted) return;
        const code = item.user_code;
        if (!code || seen.has(code)) continue;
        seen.add(code);
        try {
          const approved = await confirmCode(ctx, secrets, port, code, { prompt: true, signal });
          ctx.stderr.write(approved ? `enrolled ${code}\n` : `skipped ${code}\n`);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          ctx.stderr.write(`confirm ${code}: ${message}\n`);
        }
      }
    } catch (error) {
      if (isCancelled(error, signal)) throw new CliError("cancelled", abortExitCode(signal));
      const message = error instanceof Error ? error.message : String(error);
      ctx.stderr.write(`watch: ${message}\n`);
    }
    await ctx.sleep(2000, signal);
  }
  throw new CliError("cancelled", abortExitCode(signal));
}

async function confirmCode(
  ctx: CLIContext,
  secrets: Secrets,
  port: number,
  code: string,
  options: { prompt: boolean; signal: AbortSignal },
): Promise<boolean> {
  const described = await adminJSON<DeviceDescription>(
    ctx,
    secrets,
    port,
    "GET",
    `/v1/oauth/confirm?user_code=${encodeURIComponent(code)}`,
    undefined,
    options.signal,
  );
  ctx.stderr.write(
    `confirm ${code}  ${described.platform || ""} ${described.label || ""}  fingerprint ${described.key_fingerprint || "?"}\n`,
  );
  if (options.prompt) {
    if (!ctx.stdinIsTTY) {
      ctx.stderr.write("no TTY — not approving; run: npx @chr33s/shell confirm " + code + "\n");
      return false;
    }
    const answer = (await readline(ctx, "Approve this device? [y/N] ", options.signal)).trim().toLowerCase();
    if (answer !== "y" && answer !== "yes") return false;
  }
  await adminJSON(ctx, secrets, port, "POST", "/v1/oauth/confirm", { user_code: code, approve: true }, options.signal);
  return true;
}

async function readline(ctx: CLIContext, question: string, signal: AbortSignal): Promise<string> {
  const rl = createInterface({ input: ctx.stdin, output: ctx.stderr });
  rl.on("SIGINT", () => {
    // Cancellation is owned by the invocation controller.
  });
  try {
    return await rl.question(question, { signal });
  } catch (error) {
    if (!(error instanceof Error) || error.name !== "AbortError") throw error;
    throw new CliError("cancelled", abortExitCode(signal));
  } finally {
    rl.close();
  }
}

async function adminJSON<T = unknown>(
  ctx: CLIContext,
  secrets: Secrets,
  port: number,
  method: string,
  path: string,
  body: unknown,
  signal: AbortSignal,
): Promise<T> {
  const headers: Record<string, string> = {
    authorization: `Admin ${secrets.admin_secret}`,
    accept: "application/json",
    host: "127.0.0.1",
  };
  if (body) headers["content-type"] = "application/json";
  const timeout = AbortSignal.timeout(8000);
  const response = await ctx.fetchImpl(`${localBrokerURL(port)}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
    signal: mergeSignals(signal, timeout),
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

async function printPairing(ctx: CLIContext, publicURL: string, token: string): Promise<void> {
  const link = pairingLink(publicURL, token);
  const page = pairingPageURL(publicURL, token);
  ctx.stdout.write(`\nbroker  ${publicURL}\npair    ${page}\nlink    ${link}\ntoken   ${token}\n\n`);
  const tty = Boolean((ctx.stdout as NodeJS.WriteStream).isTTY);
  if (tty) {
    try {
      const qrcode = (await import("qrcode-terminal")).default;
      qrcode.generate(page, { small: true });
    } catch {
      ctx.stderr.write("(npm install to get a terminal QR)\n");
    }
  }
  ctx.stdout.write("\nOn iPhone: Settings → Control → Scan QR. The pairing code should match `token` above.\nThen Start setup; approve the fingerprint here with y.\n\n");
}

function isCancelled(error: unknown, signal: AbortSignal): boolean {
  if (signal.aborted) return true;
  return isAbortError(error);
}
