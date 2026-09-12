import { open, readFile, stat } from "node:fs/promises";
import { CliError, hostnameOf, isLoopbackHost, mergeSignals, requireAbsolutePath, sleep } from "./util.ts";
import { assertSafePath } from "./util.ts";
import type { AddressMode } from "./state.ts";

export const QUICK_TUNNEL_URL = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;
const PARTIAL_LINE_LIMIT = 8192;
const READ_CHUNK = 64 * 1024;

export type TunnelMode = AddressMode;

export type NamedTunnelConfig = {
  tunnel: string;
  credentialsFile: string;
  ingress: Array<{ hostname?: string; service?: string }>;
};

export function parseTunnelConfig(text: string): NamedTunnelConfig {
  const ingress: Array<{ hostname?: string; service?: string }> = [];
  let tunnel = "";
  let credentialsFile = "";
  let inIngress = false;
  let current: { hostname?: string; service?: string } | null = null;
  const flush = () => {
    if (current && (current.hostname || current.service)) ingress.push(current);
    current = null;
  };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\t/g, "  ");
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    if (/^ingress\s*:/.test(trimmed)) {
      inIngress = true;
      continue;
    }
    if (!line.startsWith(" ") && !line.startsWith("-") && inIngress && !trimmed.startsWith("-")) {
      inIngress = false;
      flush();
    }
    if (inIngress) {
      if (trimmed.startsWith("- ")) {
        flush();
        current = {};
        const rest = trimmed.slice(2);
        const hm = rest.match(/^hostname\s*:\s*(.+)$/);
        const sm = rest.match(/^service\s*:\s*(.+)$/);
        if (hm) current.hostname = unquote(hm[1] ?? "");
        if (sm) current.service = unquote(sm[1] ?? "");
        continue;
      }
      if (!current) current = {};
      const hm = trimmed.match(/^hostname\s*:\s*(.+)$/);
      const sm = trimmed.match(/^service\s*:\s*(.+)$/);
      if (hm) current.hostname = unquote(hm[1] ?? "");
      if (sm) current.service = unquote(sm[1] ?? "");
      continue;
    }
    const tm = trimmed.match(/^tunnel\s*:\s*(.+)$/);
    if (tm) tunnel = unquote(tm[1] ?? "");
    const cm = trimmed.match(/^credentials-file\s*:\s*(.+)$/);
    if (cm) credentialsFile = unquote(cm[1] ?? "");
  }
  flush();
  return { tunnel, credentialsFile, ingress };
}

function unquote(value: string): string {
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

export async function validateNamedTunnel(options: {
  configPath: string;
  publicURL: string;
  port: number;
  uid: number;
}): Promise<NamedTunnelConfig> {
  const configPath = requireAbsolutePath(options.configPath, "--tunnel-config");
  await assertSafePath(configPath, "file");
  const parsed = parseTunnelConfig(await readFile(configPath, "utf8"));
  if (!parsed.tunnel) {
    throw new CliError("named tunnel config is missing tunnel identity", 2);
  }
  if (!parsed.credentialsFile) {
    throw new CliError("named tunnel config is missing credentials-file", 2);
  }
  const credPath = requireAbsolutePath(parsed.credentialsFile, "credentials-file");
  await assertSafePath(credPath, "file");
  const { lstat } = await import("node:fs/promises");
  const cred = await lstat(credPath);
  if (cred.uid !== options.uid) {
    throw new CliError("tunnel credential file is not owned by the current user", 2);
  }
  if ((cred.mode & 0o077) !== 0) {
    throw new CliError("tunnel credential file must not be group/world accessible", 2);
  }
  const wantHost = hostnameOf(options.publicURL);
  if (!wantHost) throw new CliError("--public-url is not a valid URL", 2);
  const match = parsed.ingress.find((rule) => rule.hostname && hostnameEquals(rule.hostname, wantHost));
  if (!match) {
    throw new CliError(`named tunnel ingress does not include hostname ${wantHost}`, 2);
  }
  if (match.service && !serviceTargetsLoopback(match.service, options.port)) {
    throw new CliError(
      `named tunnel ingress for ${wantHost} must target loopback port ${options.port}`,
      2,
    );
  }
  return parsed;
}

function hostnameEquals(a: string, b: string): boolean {
  return a.replace(/\.$/, "").toLowerCase() === b.replace(/\.$/, "").toLowerCase();
}

export function serviceTargetsLoopback(service: string, port: number): boolean {
  try {
    const url = new URL(service);
    if (!isLoopbackHost(url.hostname)) return false;
    const servicePort = url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80;
    return servicePort === port;
  } catch {
    return false;
  }
}

export function classifyPublicFailure(error: unknown, status?: number): { category: string; message: string } {
  if (status === 530) return { category: "tunnel_disconnected", message: "cloudflare 530 — tunnel not registered" };
  if (status === 502 || status === 503 || status === 504) {
    return { category: "upstream_error", message: `HTTP ${status}` };
  }
  if (status && status >= 500) return { category: "broker_error", message: `HTTP ${status}` };
  const err = error as NodeJS.ErrnoException & { cause?: NodeJS.ErrnoException };
  const code = err?.code || err?.cause?.code || "";
  const name = err?.name || "";
  const message = err?.message || String(error);
  if (code === "ENOTFOUND" || code === "EAI_AGAIN" || /dns/i.test(message)) {
    return { category: "dns_timeout", message };
  }
  if (code === "CERT_HAS_EXPIRED" || code === "UNABLE_TO_VERIFY_LEAF_SIGNATURE" || /ssl|tls|cert/i.test(message + name)) {
    return { category: "tls_failure", message };
  }
  if (code === "ETIMEDOUT" || name === "TimeoutError" || /timeout/i.test(message)) {
    return { category: "timeout", message };
  }
  if (/captive/i.test(message)) return { category: "captive_portal", message };
  return { category: "unreachable", message };
}

export async function discoverQuickTunnelURL(options: {
  logPath: string;
  logPaths?: string[];
  generation: string;
  signal: AbortSignal;
  timeoutMs?: number;
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
}): Promise<string> {
  const wait = options.sleep ?? sleep;
  const paths = options.logPaths ?? [options.logPath];
  const deadline = Date.now() + (options.timeoutMs ?? 30_000);
  const state = new Map(paths.map((path) => [path, { offset: 0, partial: "", seenGeneration: false }]));
  while (!options.signal.aborted) {
    if (Date.now() >= deadline) {
      throw new CliError(`cloudflared did not print a trycloudflare URL (log: ${paths.join(", ")})`, 1);
    }
    for (const path of paths) {
      const cursor = state.get(path)!;
      try {
        const st = await stat(path);
        if (st.size < cursor.offset) {
          cursor.offset = 0;
          cursor.partial = "";
          cursor.seenGeneration = false;
        }
        if (st.size > cursor.offset) {
          const handle = await open(path, "r");
          try {
            const length = Math.min(st.size - cursor.offset, READ_CHUNK);
            const buf = Buffer.alloc(length);
            const { bytesRead } = await handle.read(buf, 0, length, cursor.offset);
            cursor.offset += bytesRead;
            const text = cursor.partial + buf.subarray(0, bytesRead).toString("utf8");
            const lines = text.split(/\r?\n/);
            cursor.partial = lines.pop() ?? "";
            if (cursor.partial.length > PARTIAL_LINE_LIMIT) {
              cursor.partial = cursor.partial.slice(-PARTIAL_LINE_LIMIT / 2);
            }
            for (const line of lines) {
              if (line.includes(options.generation)) cursor.seenGeneration = true;
              if (!cursor.seenGeneration) continue;
              const match = line.match(QUICK_TUNNEL_URL);
              if (match) return match[0];
            }
          } finally {
            await handle.close();
          }
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    await wait(50, options.signal);
  }
  throw new CliError("cancelled", 130);
}

export function validatePublicURL(url: string, mode: TunnelMode): string {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new CliError("--public-url is not a valid URL", 2);
  }
  const normalized = url.replace(/\/$/, "");
  if (mode === "loopback") {
    if (!isLoopbackHost(parsed.hostname)) {
      throw new CliError("loopback mode requires a loopback public URL", 2);
    }
    return normalized;
  }
  if (parsed.protocol !== "https:") {
    throw new CliError(`${mode} mode requires an https:// public URL`, 2);
  }
  if (mode === "quick" && !parsed.hostname.endsWith(".trycloudflare.com")) {
    throw new CliError("quick mode public URL must be a trycloudflare.com hostname", 2);
  }
  if ((mode === "named" || mode === "external-proxy") && parsed.hostname.endsWith(".trycloudflare.com")) {
    throw new CliError(`${mode} mode requires a stable hostname, not a quick tunnel`, 2);
  }
  return normalized;
}

export function resolveAddressMode(options: {
  explicitMode?: string;
  explicitPublicURL?: string;
  envPublicURL?: string;
  stored?: { address_mode: AddressMode; public_url: string | null };
  fresh: boolean;
}): { mode: AddressMode; publicURL: string | null; fromEnv: boolean } {
  if (options.explicitMode) {
    const mode = options.explicitMode as AddressMode;
    if (mode !== "quick" && mode !== "named" && mode !== "external-proxy" && mode !== "loopback") {
      throw new CliError("unknown --tunnel-mode (use quick|named|external-proxy)", 2);
    }
    const url = options.explicitPublicURL
      ? validatePublicURL(options.explicitPublicURL, mode)
      : options.stored?.public_url ?? null;
    return { mode, publicURL: url, fromEnv: false };
  }
  if (options.explicitPublicURL) {
    const url = options.explicitPublicURL.replace(/\/$/, "");
    const mode: AddressMode = url.includes("trycloudflare.com")
      ? "quick"
      : isLoopbackHost(hostnameOf(url))
        ? "loopback"
        : "external-proxy";
    return { mode, publicURL: validatePublicURL(url, mode), fromEnv: false };
  }
  if (!options.fresh && options.stored) {
    if (options.envPublicURL) {
      const envURL = options.envPublicURL.replace(/\/$/, "");
      if (options.stored.public_url && envURL !== options.stored.public_url) {
        throw new CliError(
          "SHELL_CONTROL_PUBLIC_URL conflicts with the stored installation endpoint; pass --public-url to change it deliberately",
          2,
        );
      }
    }
    return { mode: options.stored.address_mode, publicURL: options.stored.public_url, fromEnv: false };
  }
  if (options.envPublicURL) {
    const url = options.envPublicURL.replace(/\/$/, "");
    const mode: AddressMode = isLoopbackHost(hostnameOf(url)) ? "loopback" : "external-proxy";
    return { mode, publicURL: validatePublicURL(url, mode), fromEnv: true };
  }
  return { mode: "quick", publicURL: null, fromEnv: false };
}

export function rotationNotice(oldURL: string | null, newURL: string): string {
  return [
    `public URL changed`,
    `  old    ${oldURL || "(none)"}`,
    `  new    ${newURL}`,
    `Re-pair every Watch and iPhone. A device pointing at the old hostname cannot learn the replacement over that dead connection.`,
  ].join("\n");
}

export async function probeURL(
  url: string,
  options: {
    fetchImpl: typeof fetch;
    signal: AbortSignal;
    timeoutMs?: number;
  },
): Promise<{ status: number; body: string; headers: Headers }> {
  const timeout = AbortSignal.timeout(options.timeoutMs ?? 4000);
  const signal = mergeSignals(options.signal, timeout);
  const response = await options.fetchImpl(url, {
    method: "GET",
    signal,
    headers: {
      accept: "application/json",
      "cache-control": "no-store",
    },
    redirect: "manual",
  });
  const body = await response.text();
  return { status: response.status, body, headers: response.headers };
}
