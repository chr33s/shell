import { randomBytes, randomUUID } from "node:crypto";
import { createConnection, createServer, type Server } from "node:net";
import { chmod, copyFile, lstat, mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { assertSafePath, CliError, exists, makePairingToken } from "./util.ts";

export const CONFIG_SCHEMA_VERSION = 1;
export const SECRETS_MODE = 0o600;
export const STATE_DIR_MODE = 0o700;
export const LOG_MAX_BYTES = 10 * 1024 * 1024;
export const LOG_SEGMENTS = 3;

export type AddressMode = "quick" | "named" | "external-proxy" | "loopback";
export type DesiredState = "running" | "stopped";
export type ManagerKind = "launchd" | "detached";
export type ComponentName = "broker" | "daemon" | "tunnel";

export type InstallationConfig = {
  schema_version: number;
  installation_id: string;
  desired_state: DesiredState;
  persistent: boolean;
  port: number;
  address_mode: AddressMode;
  public_url: string | null;
  tunnel_identity: string | null;
  tunnel_config_path: string | null;
  installed_binary_version: string | null;
  bind_loopback: boolean;
};

export type Secrets = {
  account_id: string;
  admin_secret: string;
  cursor_secret: string;
  pairing_token: string;
  origin_id: string | null;
  origin_secret: string | null;
};

export type RuntimeState = {
  schema_version: number;
  startup_generation: number;
  incomplete: boolean;
  created: string[];
  manager: ManagerKind;
  observations: {
    broker_pid: number | null;
    daemon_pid: number | null;
    tunnel_pid: number | null;
    tunnel_legacy_unmanaged: boolean;
  };
};

export type InstallationPaths = {
  root: string;
  config: string;
  secrets: string;
  runtime: string;
  setupEnv: string;
  brokerLedger: string;
  journal: string;
  recoveryOutbox: string;
  launchd: string;
  logs: string;
  lockSock: string;
  brokerLock: string;
  daemonLock: string;
  controlSock: string;
  healthSock: string;
  brokerPid: string;
  daemonPid: string;
  tunnelPid: string;
};

export function pathsFor(stateDir: string): InstallationPaths {
  return {
    root: stateDir,
    config: join(stateDir, "config.json"),
    secrets: join(stateDir, "secrets.json"),
    runtime: join(stateDir, "runtime.json"),
    setupEnv: join(stateDir, "setup.env"),
    brokerLedger: join(stateDir, "broker.json"),
    journal: join(stateDir, "dispatch-journal.ndjson"),
    recoveryOutbox: join(stateDir, "recovery-outbox.ndjson"),
    launchd: join(stateDir, "launchd"),
    logs: join(stateDir, "logs"),
    lockSock: join(stateDir, "install.lock.sock"),
    brokerLock: join(stateDir, "broker.lock"),
    daemonLock: join(stateDir, "daemon.lock"),
    controlSock: join(stateDir, "control.sock"),
    healthSock: join(stateDir, "health.sock"),
    brokerPid: join(stateDir, "broker.pid"),
    daemonPid: join(stateDir, "daemon.pid"),
    tunnelPid: join(stateDir, "tunnel.pid"),
  };
}

export function defaultConfig(overrides: Partial<InstallationConfig> = {}): InstallationConfig {
  return {
    schema_version: CONFIG_SCHEMA_VERSION,
    installation_id: randomUUID(),
    desired_state: "running",
    persistent: false,
    port: 8443,
    address_mode: "quick",
    public_url: null,
    tunnel_identity: null,
    tunnel_config_path: null,
    installed_binary_version: null,
    bind_loopback: true,
    ...overrides,
  };
}

export function emptyRuntime(manager: ManagerKind = "launchd"): RuntimeState {
  return {
    schema_version: CONFIG_SCHEMA_VERSION,
    startup_generation: 0,
    incomplete: false,
    created: [],
    manager,
    observations: {
      broker_pid: null,
      daemon_pid: null,
      tunnel_pid: null,
      tunnel_legacy_unmanaged: false,
    },
  };
}

export function newSecrets(): Secrets {
  return {
    account_id: randomUUID(),
    admin_secret: randomBytes(32).toString("hex"),
    cursor_secret: randomBytes(32).toString("hex"),
    pairing_token: makePairingToken(),
    origin_id: null,
    origin_secret: null,
  };
}

export type InstallationLock = {
  release(): Promise<void>;
};

/// Exclusive installation lock. A Unix-domain socket bind is the OS primitive:
/// a live holder occupies the name, and a dead holder leaves a stale inode
/// that connect() proves is unused.
export async function acquireInstallationLock(
  stateDir: string,
  options: { wait?: boolean; timeoutMs?: number } = {},
): Promise<InstallationLock> {
  const wait = options.wait !== false;
  const timeoutMs = options.timeoutMs ?? 30_000;
  await ensureStateDir(stateDir);
  const sock = join(stateDir, "install.lock.sock");
  const deadline = Date.now() + timeoutMs;
  while (true) {
    try {
      return await bindLockSocket(sock);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== "EADDRINUSE" && code !== "EEXIST") throw error;
      if (await lockHolderAlive(sock)) {
        if (!wait || Date.now() >= deadline) {
          throw new CliError("another management command holds the installation lock", 1);
        }
        await delay(50);
        continue;
      }
      await unlink(sock).catch(() => undefined);
    }
  }
}

async function bindLockSocket(path: string): Promise<InstallationLock> {
  const server: Server = createServer();
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error) => {
      server.off("error", onError);
      reject(error);
    };
    server.on("error", onError);
    server.listen({ path, exclusive: true }, () => {
      server.off("error", onError);
      resolve();
    });
  });
  return {
    async release() {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await unlink(path).catch(() => undefined);
    },
  };
}

async function lockHolderAlive(path: string): Promise<boolean> {
  return await new Promise<boolean>((resolve) => {
    const conn = createConnection({ path });
    const done = (alive: boolean) => {
      conn.removeAllListeners();
      conn.destroy();
      resolve(alive);
    };
    conn.once("connect", () => done(true));
    conn.once("error", () => done(false));
  });
}

export async function ensureStateDir(stateDir: string): Promise<void> {
  if (await exists(stateDir)) {
    await assertSafePath(stateDir, "directory");
  }
  await mkdir(stateDir, { recursive: true, mode: STATE_DIR_MODE });
  await chmod(stateDir, STATE_DIR_MODE);
  await assertSafePath(stateDir, "directory");
  const paths = pathsFor(stateDir);
  await mkdir(paths.logs, { recursive: true, mode: STATE_DIR_MODE });
  await mkdir(paths.launchd, { recursive: true, mode: STATE_DIR_MODE });
  await chmod(paths.logs, STATE_DIR_MODE);
  await chmod(paths.launchd, STATE_DIR_MODE);
}

export async function atomicWriteFile(path: string, data: string | Buffer, mode = SECRETS_MODE): Promise<void> {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: STATE_DIR_MODE });
  const tmp = `${path}.tmp-${process.pid}-${randomBytes(8).toString("hex")}`;
  const handle = await open(tmp, "wx", mode);
  try {
    await handle.writeFile(data);
    await handle.sync();
    await handle.close();
    await rename(tmp, path);
    await chmod(path, mode);
    try {
      const dirfd = await open(directory, "r");
      try {
        await dirfd.sync();
      } finally {
        await dirfd.close();
      }
    } catch {
      // Directory fsync is best-effort on filesystems that refuse it.
    }
  } catch (error) {
    await handle.close().catch(() => undefined);
    await unlink(tmp).catch(() => undefined);
    throw error;
  }
}

export async function loadConfig(stateDir: string): Promise<InstallationConfig | null> {
  const path = pathsFor(stateDir).config;
  if (!(await exists(path))) return null;
  await assertSafePath(path, "file");
  const parsed = parseJSON(await readFile(path, "utf8"), "config.json");
  return validateConfig(parsed);
}

export async function loadSecrets(stateDir: string): Promise<Secrets | null> {
  const path = pathsFor(stateDir).secrets;
  if (!(await exists(path))) return null;
  await assertSafePath(path, "file");
  const parsed = parseJSON(await readFile(path, "utf8"), "secrets.json");
  return validateSecrets(parsed);
}

export async function loadRuntime(stateDir: string): Promise<RuntimeState> {
  const path = pathsFor(stateDir).runtime;
  if (!(await exists(path))) return emptyRuntime();
  await assertSafePath(path, "file");
  const parsed = parseJSON(await readFile(path, "utf8"), "runtime.json");
  return validateRuntime(parsed);
}

export async function saveConfig(stateDir: string, config: InstallationConfig): Promise<void> {
  await atomicWriteFile(pathsFor(stateDir).config, JSON.stringify(config, null, 2) + "\n", SECRETS_MODE);
}

export async function saveSecrets(stateDir: string, secrets: Secrets): Promise<void> {
  await atomicWriteFile(pathsFor(stateDir).secrets, JSON.stringify(secrets, null, 2) + "\n", SECRETS_MODE);
}

export async function saveRuntime(stateDir: string, runtime: RuntimeState): Promise<void> {
  await atomicWriteFile(pathsFor(stateDir).runtime, JSON.stringify(runtime, null, 2) + "\n", 0o600);
}

export type LoadedInstallation = {
  paths: InstallationPaths;
  config: InstallationConfig;
  secrets: Secrets;
  runtime: RuntimeState;
  created: boolean;
};

/// Load an existing installation or create a fresh one. An existing
/// installation with missing/corrupt credentials is a repair error.
export async function loadOrCreateInstallation(stateDir: string): Promise<LoadedInstallation> {
  await ensureStateDir(stateDir);
  const paths = pathsFor(stateDir);
  const existing = await detectExisting(paths);
  if (!existing) {
    const config = defaultConfig();
    const secrets = newSecrets();
    const runtime = emptyRuntime();
    await saveConfig(stateDir, config);
    await saveSecrets(stateDir, secrets);
    await saveRuntime(stateDir, runtime);
    return { paths, config, secrets, runtime, created: true };
  }

  if (await exists(paths.setupEnv) && !(await exists(paths.config))) {
    const migrated = await migrateLegacy(stateDir);
    return { paths, ...migrated, created: false };
  }

  const config = await loadConfig(stateDir);
  const secrets = await loadSecrets(stateDir);
  if (!config || !secrets) {
    throw new CliError(
      "existing installation is missing config.json or secrets.json — repair required, refusing to mint a new account",
      1,
    );
  }
  const runtime = await loadRuntime(stateDir);
  return { paths, config, secrets, runtime, created: false };
}

async function detectExisting(paths: InstallationPaths): Promise<boolean> {
  return (
    (await exists(paths.config)) ||
    (await exists(paths.secrets)) ||
    (await exists(paths.setupEnv)) ||
    (await exists(paths.brokerLedger))
  );
}

export async function migrateLegacy(stateDir: string): Promise<{
  config: InstallationConfig;
  secrets: Secrets;
  runtime: RuntimeState;
}> {
  const paths = pathsFor(stateDir);
  const env = await readSetupEnv(paths.setupEnv);
  if (!env.SHELL_CONTROL_ACCOUNT_ID || !env.SHELL_CONTROL_ADMIN_SECRET || !env.SHELL_CONTROL_CURSOR_SECRET) {
    throw new CliError(
      "legacy setup.env is missing account credentials — repair required, refusing to mint a new account",
      1,
    );
  }
  const backupDir = join(stateDir, "backups");
  await mkdir(backupDir, { recursive: true, mode: STATE_DIR_MODE });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await copyFile(paths.setupEnv, join(backupDir, `setup.env.${stamp}`));

  const publicURL = env.SHELL_CONTROL_PUBLIC_URL?.replace(/\/$/, "") || null;
  const mode: AddressMode = publicURL
    ? publicURL.includes("trycloudflare.com")
      ? "quick"
      : publicURL.startsWith("http://") && isLoopbackURL(publicURL)
        ? "loopback"
        : "external-proxy"
    : "loopback";

  const config = defaultConfig({
    address_mode: mode,
    public_url: publicURL,
    port: Number(env.SHELL_CONTROL_PORT || 8443) || 8443,
  });
  const secrets: Secrets = {
    account_id: env.SHELL_CONTROL_ACCOUNT_ID,
    admin_secret: env.SHELL_CONTROL_ADMIN_SECRET,
    cursor_secret: env.SHELL_CONTROL_CURSOR_SECRET,
    pairing_token: env.SHELL_CONTROL_PAIRING_TOKEN || makePairingToken(),
    origin_id: env.SHELL_CONTROL_ORIGIN_ID || null,
    origin_secret: env.SHELL_CONTROL_ORIGIN_SECRET || null,
  };
  const runtime = emptyRuntime();
  runtime.observations.tunnel_legacy_unmanaged = await exists(paths.tunnelPid);
  await saveConfig(stateDir, config);
  await saveSecrets(stateDir, secrets);
  await saveRuntime(stateDir, runtime);
  return { config, secrets, runtime };
}

export async function readSetupEnv(path: string): Promise<Record<string, string>> {
  await assertSafePath(path, "file");
  const text = await readFile(path, "utf8");
  const env: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const cut = line.indexOf("=");
    if (cut <= 0) continue;
    const key = line.slice(0, cut);
    if (!/^[A-Z][A-Z0-9_]*$/.test(key)) continue;
    env[key] = line.slice(cut + 1);
  }
  return env;
}

function isLoopbackURL(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost" || parsed.hostname === "::1";
  } catch {
    return false;
  }
}

function parseJSON(text: string, label: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new CliError(`${label} is malformed JSON — repair required`, 1);
  }
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new CliError(`${label} is not an object — repair required`, 1);
  }
  return value as Record<string, unknown>;
}

function requireString(obj: Record<string, unknown>, key: string, label: string): string {
  const value = obj[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new CliError(`${label} is missing ${key} — repair required`, 1);
  }
  return value;
}

function optionalString(obj: Record<string, unknown>, key: string): string | null {
  const value = obj[key];
  if (value == null) return null;
  if (typeof value !== "string") {
    throw new CliError(`${key} must be a string or null`, 1);
  }
  return value.length === 0 ? null : value;
}

function validateConfig(obj: Record<string, unknown>): InstallationConfig {
  const mode = obj.address_mode;
  if (mode !== "quick" && mode !== "named" && mode !== "external-proxy" && mode !== "loopback") {
    throw new CliError("config.json address_mode is invalid — repair required", 1);
  }
  const desired = obj.desired_state;
  if (desired !== "running" && desired !== "stopped") {
    throw new CliError("config.json desired_state is invalid — repair required", 1);
  }
  const port = obj.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new CliError("config.json port is invalid — repair required", 1);
  }
  return {
    schema_version: typeof obj.schema_version === "number" ? obj.schema_version : CONFIG_SCHEMA_VERSION,
    installation_id: requireString(obj, "installation_id", "config.json"),
    desired_state: desired,
    persistent: Boolean(obj.persistent),
    port,
    address_mode: mode,
    public_url: optionalString(obj, "public_url"),
    tunnel_identity: optionalString(obj, "tunnel_identity"),
    tunnel_config_path: optionalString(obj, "tunnel_config_path"),
    installed_binary_version: optionalString(obj, "installed_binary_version"),
    bind_loopback: obj.bind_loopback !== false,
  };
}

function validateSecrets(obj: Record<string, unknown>): Secrets {
  return {
    account_id: requireString(obj, "account_id", "secrets.json"),
    admin_secret: requireString(obj, "admin_secret", "secrets.json"),
    cursor_secret: requireString(obj, "cursor_secret", "secrets.json"),
    pairing_token: requireString(obj, "pairing_token", "secrets.json"),
    origin_id: optionalString(obj, "origin_id"),
    origin_secret: optionalString(obj, "origin_secret"),
  };
}

function validateRuntime(obj: Record<string, unknown>): RuntimeState {
  const observations = (obj.observations ?? {}) as Record<string, unknown>;
  const created = Array.isArray(obj.created) ? obj.created.filter((v): v is string => typeof v === "string") : [];
  return {
    schema_version: typeof obj.schema_version === "number" ? obj.schema_version : CONFIG_SCHEMA_VERSION,
    startup_generation: typeof obj.startup_generation === "number" ? obj.startup_generation : 0,
    incomplete: Boolean(obj.incomplete),
    created,
    manager: obj.manager === "detached" ? "detached" : "launchd",
    observations: {
      broker_pid: typeof observations.broker_pid === "number" ? observations.broker_pid : null,
      daemon_pid: typeof observations.daemon_pid === "number" ? observations.daemon_pid : null,
      tunnel_pid: typeof observations.tunnel_pid === "number" ? observations.tunnel_pid : null,
      tunnel_legacy_unmanaged: Boolean(observations.tunnel_legacy_unmanaged),
    },
  };
}

export async function rotateLogFile(path: string, maxBytes = LOG_MAX_BYTES, segments = LOG_SEGMENTS): Promise<boolean> {
  if (!(await exists(path))) return false;
  const st = await lstat(path);
  if (st.isSymbolicLink() || !st.isFile()) return false;
  if (st.size < maxBytes) return false;
  for (let i = segments; i >= 1; i--) {
    const from = i === 1 ? path : `${path}.${i - 1}`;
    const to = `${path}.${i}`;
    if (i === segments && (await exists(to))) await unlink(to).catch(() => undefined);
    if (i === 1) {
      const handle = await open(path, "r");
      try {
        const data = await handle.readFile();
        await atomicWriteFile(to, data, 0o600);
      } finally {
        await handle.close();
      }
      const trunc = await open(path, "r+");
      try {
        await trunc.truncate(0);
        await trunc.sync();
      } finally {
        await trunc.close();
      }
    } else if (await exists(from)) {
      await rename(from, to);
    }
  }
  return true;
}

export async function rotateInstallationLogs(stateDir: string): Promise<void> {
  const logs = pathsFor(stateDir).logs;
  if (!(await exists(logs))) return;
  const { readdir } = await import("node:fs/promises");
  for (const name of await readdir(logs)) {
    if (!name.endsWith(".log")) continue;
    await rotateLogFile(join(logs, name));
  }
}

export function jobLabel(installationId: string, component: ComponentName): string {
  return `dev.chr33s.shell.control.${installationId}.${component}`;
}

export function localBrokerURL(port: number): string {
  return `http://127.0.0.1:${port}`;
}
