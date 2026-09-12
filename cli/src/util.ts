import { access, lstat } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

export class CliError extends Error {
  readonly exitCode: number;
  constructor(message: string, exitCode = 1) {
    super(message);
    this.name = "CliError";
    this.exitCode = exitCode;
  }
}

export function isLoopbackHost(host: string | null | undefined): boolean {
  if (!host) return false;
  let hostname = String(host).trim().toLowerCase();
  const bracketed = hostname.match(/^\[([^\]]+)\](?::\d+)?$/);
  if (bracketed) {
    hostname = bracketed[1] ?? hostname;
  } else if ((hostname.match(/:/g) || []).length === 1) {
    hostname = hostname.split(":")[0] ?? hostname;
  }
  return LOOPBACK_HOSTS.has(hostname);
}

export function queryEscape(text: string): string {
  return encodeURIComponent(text);
}

export function pairingLink(brokerURL: string, token?: string): string {
  const params = new URLSearchParams({ broker: brokerURL });
  if (token) params.set("token", token);
  return `shell-control://pair?${params.toString()}`;
}

export function pairingPageURL(publicURL: string, token?: string): string {
  const base = publicURL.replace(/\/$/, "");
  return token ? `${base}/pair?token=${queryEscape(token)}` : `${base}/pair`;
}

/// Promise-based replacement for fs.existsSync: access() defaults to F_OK, so
/// it resolves when the path exists and rejects (ENOENT) when it does not.
export async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

export async function findRepoRoot(start = dirname(fileURLToPath(import.meta.url))): Promise<string | null> {
  let dir = start;
  for (let i = 0; i < 8; i++) {
    const [service, cmd] = await Promise.all([
      exists(join(dir, "services/shell-control/Package.swift")),
      exists(join(dir, "cmd/Package.swift")),
    ]);
    if (service && cmd) {
      return dir;
    }
    const parent = join(dir, "..");
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

export function makePairingToken(): string {
  const alphabet = "BCDFGHJKLMNPQRSTVWXZ23456789";
  let token = "";
  for (let i = 0; i < 8; i++) {
    const index = Math.floor(Math.random() * alphabet.length);
    token += alphabet[index];
  }
  return token;
}

export function isAbortError(error: unknown): boolean {
  if (error instanceof CliError && error.message === "cancelled") return true;
  if (error instanceof Error && error.name === "AbortError") return true;
  return false;
}

export function abortExitCode(signal?: AbortSignal | null): number {
  const reason = signal?.reason;
  if (typeof reason === "number") return reason;
  if (reason === "SIGINT" || reason === "SIGTERM" || reason === "SIGHUP") {
    return signalExitCode(reason);
  }
  if (reason instanceof Error && reason.name === "AbortError") return 130;
  return 130;
}

export function signalExitCode(signal: NodeJS.Signals | string): number {
  if (signal === "SIGINT") return 130;
  if (signal === "SIGTERM") return 143;
  if (signal === "SIGHUP") return 129;
  return 1;
}

export async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) throw new CliError("cancelled", abortExitCode(signal));
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new CliError("cancelled", abortExitCode(signal)));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

export function requireAbsolutePath(path: string, flag: string): string {
  if (!isAbsolute(path)) {
    throw new CliError(`${flag} must be an absolute path`, 2);
  }
  return path;
}

export async function assertSafePath(
  path: string,
  kind: "file" | "directory",
): Promise<void> {
  const st = await lstat(path);
  if (st.isSymbolicLink()) {
    throw new CliError(`refusing symlink ${path}`, 2);
  }
  if (kind === "file" && !st.isFile()) {
    throw new CliError(`not a regular file: ${path}`, 2);
  }
  if (kind === "directory" && !st.isDirectory()) {
    throw new CliError(`not a directory: ${path}`, 2);
  }
  const uid = process.getuid?.();
  if (uid != null && st.uid !== uid) {
    throw new CliError(`unsafe ownership: ${path}`, 2);
  }
  if ((st.mode & 0o002) !== 0) {
    throw new CliError(`world-writable path refused: ${path}`, 2);
  }
}

export function mergeSignals(...signals: Array<AbortSignal | undefined>): AbortSignal {
  const present = signals.filter((s): s is AbortSignal => s != null);
  if (present.length === 0) return new AbortController().signal;
  if (present.length === 1) return present[0]!;
  return AbortSignal.any(present);
}

export function hostnameOf(url: string): string | null {
  try {
    return new URL(url).hostname;
  } catch {
    return null;
  }
}
