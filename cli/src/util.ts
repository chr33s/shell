import { access } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

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
