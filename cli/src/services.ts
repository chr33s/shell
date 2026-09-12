import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, copyFile, mkdir, open, readFile, readdir, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { CliError, exists, sleep } from "./util.ts";
import { jobLabel, type ComponentName, type InstallationConfig } from "./state.ts";

export type Component = ComponentName;

export type JobObservation = {
  label: string;
  registered: boolean;
  loaded: boolean;
  enabled: boolean;
  pid: number | null;
  lastExit: number | null;
  error?: string;
};

export type JobSpec = {
  component: Component;
  installationId: string;
  executable: string;
  arguments: string[];
  workingDirectory: string;
  stdoutPath: string;
  stderrPath: string;
  environment: Record<string, string>;
  keepAlive: boolean;
  throttleInterval: number;
  persistent: boolean;
  launchAgentsDir: string;
  sessionPlistDir: string;
};

export type CommandResult = { status: number; stdout: string; stderr: string };
export type CommandRunner = (command: string, args: string[]) => Promise<CommandResult>;

export interface ServiceManager {
  readonly kind: "launchd" | "detached" | "fake";
  labels(installationId: string): Record<Component, string>;
  install(spec: JobSpec): Promise<void>;
  uninstall(label: string, spec: Pick<JobSpec, "launchAgentsDir" | "sessionPlistDir">): Promise<void>;
  start(spec: JobSpec): Promise<void>;
  stop(label: string): Promise<void>;
  restart(spec: JobSpec): Promise<void>;
  enable(label: string): Promise<void>;
  disable(label: string): Promise<void>;
  observe(label: string): Promise<JobObservation>;
}

export function defaultLaunchctlRunner(): CommandRunner {
  return async (command, args) => {
    const result = spawnSync(command, args, { encoding: "utf8" });
    return {
      status: result.status ?? 1,
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  };
}

export class LaunchdServiceManager implements ServiceManager {
  readonly kind = "launchd" as const;
  private readonly launchctl: string;
  private readonly uid: number;
  private readonly run: CommandRunner;

  constructor(options: { uid: number; launchctl?: string; run?: CommandRunner }) {
    this.uid = options.uid;
    this.launchctl = options.launchctl ?? "/bin/launchctl";
    this.run = options.run ?? defaultLaunchctlRunner();
  }

  labels(installationId: string): Record<Component, string> {
    return {
      broker: jobLabel(installationId, "broker"),
      daemon: jobLabel(installationId, "daemon"),
      tunnel: jobLabel(installationId, "tunnel"),
    };
  }

  domain(): string {
    return `gui/${this.uid}`;
  }

  target(label: string): string {
    return `${this.domain()}/${label}`;
  }

  async install(spec: JobSpec): Promise<void> {
    const domain = this.domain();
    const probe = await this.run(this.launchctl, ["print", domain]);
    if (probe.status !== 0) {
      throw new CliError(
        `launchd gui/${this.uid} domain is unavailable — log in graphically; refusing to escalate to a system domain`,
        1,
      );
    }
    const label = jobLabel(spec.installationId, spec.component);
    const plist = renderLaunchdPlist(spec);
    const sessionPath = join(spec.sessionPlistDir, `${label}.plist`);
    await mkdir(dirname(sessionPath), { recursive: true, mode: 0o700 });
    const previous = (await exists(sessionPath)) ? await readFile(sessionPath, "utf8") : null;
    const sessionChanged = previous !== plist;
    if (sessionChanged) await writeFile(sessionPath, plist, { mode: 0o600 });

    let persistentPath: string | undefined;
    if (spec.persistent) {
      if (!spec.keepAlive) {
        throw new CliError("quick tunnels are not eligible for persistent installation", 2);
      }
      await mkdir(spec.launchAgentsDir, { recursive: true, mode: 0o755 });
      persistentPath = join(spec.launchAgentsDir, `${label}.plist`);
      const persistentPrevious = (await exists(persistentPath)) ? await readFile(persistentPath, "utf8") : null;
      if (persistentPrevious !== plist) {
        await writeFile(persistentPath, plist, { mode: 0o644 });
      }
    }

    const before = await this.observe(label);
    if (before.loaded && before.pid != null && !sessionChanged) {
      // Installing an unchanged running session job for future login must not
      // itself restart that job.
      return;
    }
    if (before.loaded && sessionChanged) {
      // launchd does not reload ProgramArguments from a plist that changed on
      // disk. Remove the old registration before bootstrapping the new spec.
      await this.stop(label);
    }
    if (!before.loaded || sessionChanged) {
      const bootPath = spec.persistent && persistentPath ? persistentPath : sessionPath;
      const boot = await this.run(this.launchctl, ["bootstrap", domain, bootPath]);
      if (boot.status !== 0 && !/already bootstrapped|Input\/output error/i.test(boot.stderr + boot.stdout)) {
        throw new CliError(`launchctl bootstrap failed: ${boot.stderr.trim() || boot.stdout.trim()}`, 1);
      }
    }
  }

  async uninstall(label: string, spec: Pick<JobSpec, "launchAgentsDir" | "sessionPlistDir">): Promise<void> {
    await this.disable(label);
    await this.stop(label);
    await unlink(join(spec.sessionPlistDir, `${label}.plist`)).catch(() => undefined);
    await unlink(join(spec.launchAgentsDir, `${label}.plist`)).catch(() => undefined);
  }

  async start(spec: JobSpec): Promise<void> {
    const label = jobLabel(spec.installationId, spec.component);
    await this.enable(label);
    await this.install(spec);
    const observed = await this.observe(label);
    if (observed.pid != null) return;
    const kick = await this.run(this.launchctl, ["kickstart", "-p", this.target(label)]);
    if (kick.status !== 0) {
      const again = await this.observe(label);
      if (again.pid == null) {
        throw new CliError(`failed to start ${label}: ${kick.stderr.trim() || kick.stdout.trim()}`, 1);
      }
    }
  }

  async stop(label: string): Promise<void> {
    const bootout = await this.run(this.launchctl, ["bootout", this.target(label)]);
    if (bootout.status === 0) return;
    const text = `${bootout.stderr} ${bootout.stdout}`;
    if (/No such process|Could not find|not found|113|5: Input/i.test(text)) return;
    throw new CliError(`failed to stop ${label}: ${text.trim()}`, 1);
  }

  async restart(spec: JobSpec): Promise<void> {
    const label = jobLabel(spec.installationId, spec.component);
    // Bootstrapping is what makes launchd consume an updated plist. A bare
    // kickstart would restart the old in-memory ProgramArguments.
    await this.stop(label);
    await this.start(spec);
  }

  async enable(label: string): Promise<void> {
    await this.run(this.launchctl, ["enable", this.target(label)]);
  }

  async disable(label: string): Promise<void> {
    await this.run(this.launchctl, ["disable", this.target(label)]);
  }

  async observe(label: string): Promise<JobObservation> {
    const printed = await this.run(this.launchctl, ["print", this.target(label)]);
    if (printed.status !== 0) {
      return {
        label,
        registered: false,
        loaded: false,
        enabled: true,
        pid: null,
        lastExit: null,
        error: (printed.stderr || printed.stdout).trim() || "not loaded",
      };
    }
    const text = printed.stdout;
    const pidMatch = text.match(/^\s*pid\s*=\s*(\d+)/m);
    const stateMatch = text.match(/^\s*state\s*=\s*(\S+)/m);
    const lastExitMatch = text.match(/last exit code\s*=\s*(-?\d+)/i);
    const disabled = /disabled\s*=\s*1|runs = disabled/i.test(text);
    const pid = pidMatch ? Number(pidMatch[1]) : null;
    return {
      label,
      registered: true,
      loaded: true,
      enabled: !disabled,
      pid: pid && pid > 0 ? pid : null,
      lastExit: lastExitMatch ? Number(lastExitMatch[1]) : null,
      error: stateMatch && stateMatch[1] !== "running" ? stateMatch[1] : undefined,
    };
  }
}

export function renderLaunchdPlist(spec: JobSpec): string {
  const label = jobLabel(spec.installationId, spec.component);
  const args = [spec.executable, ...spec.arguments].map(plistString);
  const envEntries = Object.entries(spec.environment)
    .map(([key, value]) => `      <key>${escapeXml(key)}</key>\n      ${plistString(value)}`)
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  ${plistString(label)}
  <key>ProgramArguments</key>
  <array>
${args.map((a) => `    ${a}`).join("\n")}
  </array>
  <key>WorkingDirectory</key>
  ${plistString(spec.workingDirectory)}
  <key>StandardInPath</key>
  ${plistString("/dev/null")}
  <key>StandardOutPath</key>
  ${plistString(spec.stdoutPath)}
  <key>StandardErrorPath</key>
  ${plistString(spec.stderrPath)}
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  ${spec.keepAlive ? "<true/>" : "<false/>"}
  <key>ThrottleInterval</key>
  <integer>${Math.max(10, spec.throttleInterval)}</integer>
  <key>EnvironmentVariables</key>
  <dict>
${envEntries}
  </dict>
</dict>
</plist>
`;
}

function plistString(value: string): string {
  return `<string>${escapeXml(value)}</string>`;
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export class FakeServiceManager implements ServiceManager {
  readonly kind = "fake" as const;
  readonly jobs = new Map<string, {
    spec: JobSpec;
    loaded: boolean;
    enabled: boolean;
    pid: number | null;
    lastExit: number | null;
  }>();
  nextPid = 1000;
  stopped = new Set<string>();

  labels(installationId: string): Record<Component, string> {
    return {
      broker: jobLabel(installationId, "broker"),
      daemon: jobLabel(installationId, "daemon"),
      tunnel: jobLabel(installationId, "tunnel"),
    };
  }

  async install(spec: JobSpec): Promise<void> {
    const label = jobLabel(spec.installationId, spec.component);
    const existing = this.jobs.get(label);
    if (existing?.loaded && existing.pid != null) {
      existing.spec = spec;
      return;
    }
    this.jobs.set(label, {
      spec,
      loaded: true,
      enabled: true,
      pid: this.nextPid++,
      lastExit: null,
    });
  }

  async uninstall(label: string, _spec?: Pick<JobSpec, "launchAgentsDir" | "sessionPlistDir">): Promise<void> {
    this.jobs.delete(label);
    this.stopped.add(label);
  }

  async start(spec: JobSpec): Promise<void> {
    const label = jobLabel(spec.installationId, spec.component);
    this.stopped.delete(label);
    const existing = this.jobs.get(label);
    if (existing?.loaded && existing.pid != null && existing.enabled) return;
    this.jobs.set(label, {
      spec,
      loaded: true,
      enabled: true,
      pid: this.nextPid++,
      lastExit: null,
    });
  }

  async stop(label: string): Promise<void> {
    const job = this.jobs.get(label);
    if (job) {
      job.loaded = false;
      job.pid = null;
      job.lastExit = 0;
    }
    this.stopped.add(label);
  }

  async restart(spec: JobSpec): Promise<void> {
    const label = jobLabel(spec.installationId, spec.component);
    const job = this.jobs.get(label);
    if (job) {
      job.pid = this.nextPid++;
      job.loaded = true;
      job.enabled = true;
      job.spec = spec;
    } else {
      await this.start(spec);
    }
  }

  async enable(label: string): Promise<void> {
    const job = this.jobs.get(label);
    if (job) job.enabled = true;
    this.stopped.delete(label);
  }

  async disable(label: string): Promise<void> {
    const job = this.jobs.get(label);
    if (job) job.enabled = false;
  }

  async observe(label: string): Promise<JobObservation> {
    const job = this.jobs.get(label);
    if (!job) {
      return { label, registered: false, loaded: false, enabled: !this.stopped.has(label), pid: null, lastExit: null };
    }
    return {
      label,
      registered: true,
      loaded: job.loaded,
      enabled: job.enabled,
      pid: job.pid,
      lastExit: job.lastExit,
    };
  }
}

export type SpawnedService = {
  pid: number;
  waitForExit: Promise<number | null>;
  process: ChildProcess;
};

export async function spawnDetached(spec: {
  executable: string;
  args: string[];
  env: NodeJS.ProcessEnv;
  cwd: string;
  stdoutPath: string;
  stderrPath: string;
}): Promise<SpawnedService> {
  await mkdir(dirname(spec.stdoutPath), { recursive: true, mode: 0o700 });
  const stdout = await open(spec.stdoutPath, "a", 0o600);
  const stderr = spec.stderrPath === spec.stdoutPath ? stdout : await open(spec.stderrPath, "a", 0o600);
  try {
    const child = spawn(spec.executable, spec.args, {
      env: spec.env,
      cwd: spec.cwd,
      stdio: ["ignore", stdout.fd, stderr.fd],
      detached: true,
    });
    const spawnError = new Promise<Error>((resolve) => {
      child.once("error", resolve);
    });
    child.unref();
    await stdout.close();
    if (stderr !== stdout) await stderr.close();
    if (child.pid == null) {
      const err = await Promise.race([
        spawnError,
        sleep(20).then(() => new Error("spawn produced no pid")),
      ]);
      throw new CliError(`spawn failed: ${err instanceof Error ? err.message : String(err)}`, 1);
    }
    const waitForExit = new Promise<number | null>((resolve) => {
      child.once("exit", (code) => resolve(code));
      child.once("error", () => resolve(null));
    });
    return { pid: child.pid, waitForExit, process: child };
  } catch (error) {
    await stdout.close().catch(() => undefined);
    if (stderr !== stdout) await stderr.close().catch(() => undefined);
    throw error;
  }
}

export type LegacyProcessReport = {
  pid: number;
  verifiable: boolean;
  uid?: number;
  command?: string;
  reason?: string;
};

export async function inspectLegacyPid(
  pid: number,
  expectedName: string,
  uid: number,
  runner: CommandRunner = defaultLaunchctlRunner(),
): Promise<LegacyProcessReport> {
  if (!Number.isInteger(pid) || pid <= 0) {
    return { pid, verifiable: false, reason: "invalid pid" };
  }
  const ps = await runner("/bin/ps", ["-p", String(pid), "-o", "uid=,command="]);
  if (ps.status !== 0 || !ps.stdout.trim()) {
    return { pid, verifiable: false, reason: "process not found" };
  }
  const line = ps.stdout.trim();
  const match = line.match(/^\s*(\d+)\s+(.*)$/);
  if (!match) return { pid, verifiable: false, reason: "unreadable ps output" };
  const procUid = Number(match[1]);
  const command = match[2] ?? "";
  if (procUid !== uid) {
    return { pid, verifiable: false, uid: procUid, command, reason: "different user" };
  }
  const base = basename(command.split(" ")[0] ?? "");
  if (!command.includes(expectedName) && base !== expectedName) {
    return { pid, verifiable: false, uid: procUid, command, reason: "executable path does not match" };
  }
  return { pid, verifiable: true, uid: procUid, command };
}

export async function signalVerifiedPid(pid: number, signal: NodeJS.Signals = "SIGTERM"): Promise<void> {
  try {
    process.kill(pid, signal);
  } catch {
    // already gone
  }
}

export async function readPidFile(path: string): Promise<number | null> {
  if (!(await exists(path))) return null;
  const text = (await readFile(path, "utf8")).trim();
  const pid = Number(text);
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

export type InstalledBinaries = {
  version: string;
  broker: string;
  daemon: string;
  cli: string | undefined;
  cloudflared: string | undefined;
  directory: string;
};

export async function binaryGeneration(
  sources: { broker: string; daemon: string },
  packageVersion = "0.1.0",
): Promise<string> {
  const hash = createHash("sha256");
  hash.update(await readFile(sources.broker));
  hash.update(await readFile(sources.daemon));
  return `${packageVersion}-${hash.digest("hex").slice(0, 12)}`;
}

export async function installBinaries(options: {
  libDir: string;
  version: string;
  sources: { broker: string; daemon: string; cli?: string; cloudflared?: string };
}): Promise<InstalledBinaries> {
  const dest = join(options.libDir, options.version);
  await mkdir(dest, { recursive: true, mode: 0o755 });
  const copy = async (source: string | undefined, name: string): Promise<string | undefined> => {
    if (!source) return undefined;
    const target = join(dest, name);
    if (await exists(target)) return target;
    await copyFile(source, target);
    await chmod(target, 0o755);
    return target;
  };
  const broker = await copy(options.sources.broker, "shell-control-broker");
  const daemon = await copy(options.sources.daemon, "shell-controld");
  const cli = await copy(options.sources.cli, "shell-control");
  const cloudflared = await copy(options.sources.cloudflared, "cloudflared");
  if (!broker || !daemon) {
    throw new CliError("failed to install broker/daemon binaries", 1);
  }
  const current = join(options.libDir, "current");
  await unlink(current).catch(() => undefined);
  await symlink(dest, current);
  return { version: options.version, broker, daemon, cli, cloudflared, directory: dest };
}

export async function previousBinaryVersion(libDir: string, current: string): Promise<string | null> {
  if (!(await exists(libDir))) return null;
  const entries = await readdir(libDir);
  const versions = entries.filter((name) => name !== "current" && name !== current);
  return versions.sort().at(-1) ?? null;
}

export async function removeInstalledVersion(libDir: string, version: string): Promise<void> {
  await rm(join(libDir, version), { recursive: true, force: true });
}

export function which(name: string): string | null {
  const result = spawnSync("which", [name], { encoding: "utf8" });
  if (result.status !== 0) return null;
  const path = result.stdout.trim();
  return path || null;
}

export async function firstExisting(paths: Array<string | undefined | null | false>): Promise<string | undefined> {
  for (const path of paths) {
    if (typeof path === "string" && (await exists(path))) return path;
  }
  return undefined;
}

export function jobSpecFor(
  component: Component,
  config: InstallationConfig,
  options: {
    executable: string;
    arguments: string[];
    workingDirectory: string;
    logsDir: string;
    sessionPlistDir: string;
    launchAgentsDir: string;
    environment?: Record<string, string>;
  },
): JobSpec {
  const keepAlive = component === "tunnel" ? config.address_mode === "named" : true;
  return {
    component,
    installationId: config.installation_id,
    executable: options.executable,
    arguments: options.arguments,
    workingDirectory: options.workingDirectory,
    stdoutPath: join(options.logsDir, `${component}.out.log`),
    stderrPath: join(options.logsDir, `${component}.err.log`),
    environment: options.environment ?? {},
    keepAlive,
    throttleInterval: 10,
    persistent: config.persistent && keepAlive,
    launchAgentsDir: options.launchAgentsDir,
    sessionPlistDir: options.sessionPlistDir,
  };
}

export function defaultLaunchAgentsDir(home = homedir()): string {
  return join(home, "Library/LaunchAgents");
}

export function defaultLibDir(home = homedir()): string {
  return join(home, ".local/lib/chr33s-shell");
}
