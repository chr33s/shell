import { createConnection } from "node:net";
import { abortExitCode, CliError, mergeSignals } from "./util.ts";
import { classifyPublicFailure, probeURL } from "./tunnel.ts";
import type { AddressMode, DesiredState, InstallationConfig, RuntimeState } from "./state.ts";
import type { JobObservation, ServiceManager } from "./services.ts";

export const STATUS_SCHEMA_VERSION = 2;
export const PROTOCOL_NAME = "shell-control/1";

export type ComponentState =
  | "ready"
  | "recovering"
  | "running"
  | "not_ready"
  | "unreachable"
  | "externally_managed"
  | "not_configured"
  | "legacy_unmanaged"
  | "stopped"
  | "disabled";

export type Observation = {
  state: ComponentState;
  checked_at: string;
  error?: string;
  error_category?: string;
  pid?: number | null;
  mode?: string;
  recovery_pending?: number;
  diagnostic_id?: string;
};

export type StatusV2 = {
  schema_version: number;
  broker: boolean;
  tunnel: boolean;
  daemon: boolean;
  overall: "ready" | "degraded" | "stopped" | "unavailable";
  manager: "launchd" | "detached" | "fake";
  persistent: boolean;
  desired_state: DesiredState;
  public_url: string | null;
  components: {
    broker: Observation;
    daemon: Observation;
    tunnel: Observation;
    public_route: Observation;
    push: Observation;
  };
};

export type ProbeDeps = {
  fetchImpl: typeof fetch;
  now: () => Date;
  signal: AbortSignal;
  readHealthSocket?: (path: string) => Promise<string | null>;
};

export function isoNow(now: () => Date): string {
  return now().toISOString();
}

export function capabilitiesLookValid(body: string, expectedIdentity?: string | null): boolean {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return false;
  }
  if (parsed == null || typeof parsed !== "object") return false;
  const obj = parsed as Record<string, unknown>;
  const versions = obj.protocol_versions;
  if (!Array.isArray(versions) || !versions.includes(PROTOCOL_NAME)) return false;
  if (typeof obj.service_identity !== "string" || obj.service_identity.length === 0) return false;
  if (expectedIdentity && obj.service_identity !== expectedIdentity) return false;
  return true;
}

export async function probeLocalBroker(
  url: string,
  deps: ProbeDeps,
): Promise<Observation> {
  const checked_at = isoNow(deps.now);
  try {
    const result = await probeURL(`${url.replace(/\/$/, "")}/v1/capabilities`, {
      fetchImpl: deps.fetchImpl,
      signal: deps.signal,
      timeoutMs: 4000,
    });
    if (result.status !== 200 || !capabilitiesLookValid(result.body)) {
      const classified = classifyPublicFailure(undefined, result.status);
      return {
        state: "not_ready",
        checked_at,
        error: classified.message,
        error_category: classified.category,
        diagnostic_id: "broker.local",
      };
    }
    return { state: "ready", checked_at, diagnostic_id: "broker.local" };
  } catch (error) {
    if (deps.signal.aborted) {
      throw new CliError("cancelled", abortExitCode(deps.signal));
    }
    const classified = classifyPublicFailure(error);
    return {
      state: "not_ready",
      checked_at,
      error: classified.message,
      error_category: classified.category,
      diagnostic_id: "broker.local",
    };
  }
}

export async function probePublicRoute(
  publicURL: string,
  deps: ProbeDeps,
): Promise<Observation> {
  const checked_at = isoNow(deps.now);
  try {
    const result = await probeURL(`${publicURL.replace(/\/$/, "")}/v1/capabilities`, {
      fetchImpl: deps.fetchImpl,
      signal: deps.signal,
      timeoutMs: 4000,
    });
    if (result.status === 200 && capabilitiesLookValid(result.body)) {
      return { state: "ready", checked_at, diagnostic_id: "public_route" };
    }
    const classified = classifyPublicFailure(undefined, result.status);
    return {
      state: "unreachable",
      checked_at,
      error: classified.message,
      error_category: classified.category,
      diagnostic_id: "public_route",
    };
  } catch (error) {
    if (deps.signal.aborted) {
      throw new CliError("cancelled", abortExitCode(deps.signal));
    }
    const classified = classifyPublicFailure(error);
    return {
      state: "unreachable",
      checked_at,
      error: classified.message,
      error_category: classified.category,
      diagnostic_id: "public_route",
    };
  }
}

export async function probeDaemonHealth(socketPath: string, deps: ProbeDeps): Promise<Observation> {
  const checked_at = isoNow(deps.now);
  try {
    const body = deps.readHealthSocket
      ? await deps.readHealthSocket(socketPath)
      : await readUnixHealth(socketPath, deps.signal);
    if (!body) {
      return { state: "not_ready", checked_at, error: "health socket produced no data", diagnostic_id: "daemon.health" };
    }
    const parsed = JSON.parse(body) as Record<string, unknown>;
    const state = typeof parsed.state === "string" ? parsed.state : "not_ready";
    const recovery = typeof parsed.recovery_pending === "number" ? parsed.recovery_pending : 0;
    const allowed: ComponentState[] = ["ready", "recovering", "not_ready"];
    return {
      state: allowed.includes(state as ComponentState) ? state as ComponentState : "not_ready",
      checked_at,
      recovery_pending: recovery,
      diagnostic_id: "daemon.health",
    };
  } catch (error) {
    if (deps.signal.aborted) {
      throw new CliError("cancelled", abortExitCode(deps.signal));
    }
    return {
      state: "not_ready",
      checked_at,
      error: error instanceof Error ? error.message : String(error),
      error_category: "ipc_unresponsive",
      diagnostic_id: "daemon.health",
    };
  }
}

export async function readUnixHealth(path: string, signal: AbortSignal, timeoutMs = 2000): Promise<string> {
  const timeout = AbortSignal.timeout(timeoutMs);
  const combined = mergeSignals(signal, timeout);
  return await new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = [];
    const socket = createConnection({ path });
    const onAbort = () => {
      socket.destroy();
      reject(new CliError("health socket cancelled", 1));
    };
    combined.addEventListener("abort", onAbort, { once: true });
    socket.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    socket.on("end", () => {
      combined.removeEventListener("abort", onAbort);
      resolve(Buffer.concat(chunks).toString("utf8").trim());
    });
    socket.on("error", (error) => {
      combined.removeEventListener("abort", onAbort);
      reject(error);
    });
  });
}

export async function probeAdminHealth(
  localURL: string,
  adminSecret: string,
  deps: ProbeDeps,
): Promise<Observation> {
  const checked_at = isoNow(deps.now);
  try {
    const timeout = AbortSignal.timeout(4000);
    const response = await deps.fetchImpl(`${localURL.replace(/\/$/, "")}/v1/admin/health`, {
      method: "GET",
      signal: mergeSignals(deps.signal, timeout),
      headers: {
        authorization: `Admin ${adminSecret}`,
        accept: "application/json",
        host: "127.0.0.1",
        "cache-control": "no-store",
      },
    });
    const body = await response.text();
    if (!response.ok) {
      return {
        state: "not_ready",
        checked_at,
        error: `admin health HTTP ${response.status}`,
        diagnostic_id: "broker.admin",
      };
    }
    const parsed = JSON.parse(body) as Record<string, unknown>;
    const state = parsed.state === "ready" ? "ready" : parsed.state === "recovering" ? "recovering" : "not_ready";
    return { state, checked_at, diagnostic_id: "broker.admin" };
  } catch (error) {
    return {
      state: "not_ready",
      checked_at,
      error: error instanceof Error ? error.message : String(error),
      diagnostic_id: "broker.admin",
    };
  }
}

export function observationFromJob(job: JobObservation, now: string): Observation {
  if (!job.loaded) {
    return { state: "stopped", checked_at: now, pid: job.pid ?? null, error: job.error, diagnostic_id: job.label };
  }
  if (!job.enabled) {
    return { state: "disabled", checked_at: now, pid: job.pid ?? null, diagnostic_id: job.label };
  }
  if (job.pid == null) {
    return { state: "not_ready", checked_at: now, pid: null, error: "registered but not running", diagnostic_id: job.label };
  }
  return { state: "running", checked_at: now, pid: job.pid, diagnostic_id: job.label };
}

export function projectStatus(input: {
  config: InstallationConfig;
  runtime: RuntimeState;
  manager: ServiceManager["kind"];
  brokerJob: Observation;
  daemonJob: Observation;
  tunnelJob: Observation;
  brokerReady: Observation;
  daemonReady: Observation;
  publicRoute: Observation;
  push: Observation;
}): StatusV2 {
  const brokerReady = input.brokerReady.state === "ready";
  const daemonReady = input.daemonReady.state === "ready";
  const tunnelReady =
    input.tunnelJob.state === "externally_managed" ||
    input.tunnelJob.state === "running" ||
    input.tunnelJob.state === "ready" ||
    (input.config.address_mode === "loopback" && input.tunnelJob.state !== "not_ready");
  const connectorReady = input.config.address_mode === "external-proxy" ||
    input.config.address_mode === "loopback" ||
    input.tunnelJob.state === "running" ||
    input.tunnelJob.state === "ready";
  const routeReady = input.config.address_mode === "loopback" || input.publicRoute.state === "ready";
  const requiredReady = brokerReady && daemonReady && connectorReady && routeReady;
  let overall: StatusV2["overall"] = "ready";
  if (input.config.desired_state === "stopped") overall = "stopped";
  else if (!brokerReady && !daemonReady) overall = "unavailable";
  else if (!requiredReady || input.publicRoute.state === "unreachable") overall = "degraded";

  const broker: Observation = {
    ...input.brokerJob,
    state: brokerReady ? "ready" : input.brokerJob.state,
  };
  if (input.brokerReady.error) broker.error = input.brokerReady.error;
  const daemon: Observation = {
    ...input.daemonJob,
    state: daemonReady ? input.daemonReady.state : input.daemonJob.state === "running" ? "not_ready" : input.daemonJob.state,
    recovery_pending: input.daemonReady.recovery_pending,
  };
  if (input.daemonReady.error) daemon.error = input.daemonReady.error;

  return {
    schema_version: STATUS_SCHEMA_VERSION,
    broker: brokerReady,
    tunnel: tunnelReady,
    daemon: daemonReady,
    overall,
    manager: input.manager,
    persistent: input.config.persistent,
    desired_state: input.config.desired_state,
    public_url: input.config.public_url,
    components: {
      broker,
      daemon,
      tunnel: input.tunnelJob,
      public_route: input.publicRoute,
      push: input.push,
    },
  };
}

export function pushObservation(configured: boolean, now: string): Observation {
  if (!configured) {
    return {
      state: "not_configured",
      checked_at: now,
      error: "Push not configured; open the Watch app to refresh",
      diagnostic_id: "push",
    };
  }
  return {
    state: "ready",
    checked_at: now,
    error: "provider credentials present; delivery to a device is not proven",
    diagnostic_id: "push",
  };
}

export function tunnelObservation(options: {
  mode: AddressMode;
  job: JobObservation;
  runtime: RuntimeState;
  now: string;
}): Observation {
  if (options.mode === "external-proxy") {
    return { state: "externally_managed", checked_at: options.now, mode: options.mode, diagnostic_id: "tunnel" };
  }
  if (options.runtime.observations.tunnel_legacy_unmanaged) {
    return {
      state: "legacy_unmanaged",
      checked_at: options.now,
      mode: options.mode,
      pid: options.job.pid,
      error: "legacy quick tunnel is unmanaged; explicit migration required",
      diagnostic_id: "tunnel",
    };
  }
  const base = observationFromJob(options.job, options.now);
  return { ...base, mode: options.mode };
}

export function requiredComponentsReady(status: StatusV2): boolean {
  if (status.desired_state === "stopped") return false;
  const { broker, daemon, tunnel, public_route } = status.components;
  if (broker.state !== "ready") return false;
  if (daemon.state !== "ready") return false;
  if (tunnel.mode === "loopback") return true;
  if (public_route.state !== "ready") return false;
  if (tunnel.state === "externally_managed") return true;
  if (tunnel.mode === "quick" || tunnel.mode === "named") {
    return tunnel.state === "running" || tunnel.state === "ready";
  }
  return true;
}

export function redactStatus(status: StatusV2): StatusV2 {
  return JSON.parse(JSON.stringify(status)) as StatusV2;
}

export function statusContainsSecrets(text: string, secrets: { admin_secret: string; origin_secret: string | null; pairing_token: string; cursor_secret: string }): boolean {
  if (text.includes(secrets.admin_secret)) return true;
  if (text.includes(secrets.cursor_secret)) return true;
  if (text.includes(secrets.pairing_token)) return true;
  if (secrets.origin_secret && text.includes(secrets.origin_secret)) return true;
  if (/"pairing_token"/.test(text)) return true;
  return false;
}
