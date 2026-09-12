import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  capabilitiesLookValid,
  projectStatus,
  pushObservation,
  requiredComponentsReady,
  statusContainsSecrets,
  type Observation,
} from "./health.ts";
import { defaultConfig, emptyRuntime } from "./state.ts";

const now = "2026-09-12T00:00:00.000Z";
const ready: Observation = { state: "ready", checked_at: now };
const running: Observation = { state: "running", checked_at: now, pid: 12 };

describe("capabilitiesLookValid", () => {
  it("rejects a bare HTTP 200 body", () => {
    assert.equal(capabilitiesLookValid("ok"), false);
    assert.equal(capabilitiesLookValid(JSON.stringify({ ok: true })), false);
    assert.equal(
      capabilitiesLookValid(JSON.stringify({
        protocol_versions: ["shell-control/1"],
        service_identity: "shell-control",
      })),
      true,
    );
  });
});

describe("status projection", () => {
  it("omits pairing secrets and keeps liveness booleans", () => {
    const status = projectStatus({
      config: defaultConfig({ public_url: "https://control.example.com", persistent: true, address_mode: "named" }),
      runtime: emptyRuntime(),
      manager: "launchd",
      brokerJob: running,
      daemonJob: running,
      tunnelJob: { state: "running", checked_at: now, mode: "named" },
      brokerReady: ready,
      daemonReady: ready,
      publicRoute: { state: "unreachable", checked_at: now, error: "dns_timeout", error_category: "dns_timeout" },
      push: pushObservation(false, now),
    });
    assert.equal(status.schema_version, 2);
    assert.equal(status.broker, true);
    assert.equal(status.daemon, true);
    assert.equal(status.overall, "degraded");
    assert.equal(requiredComponentsReady(status), false);
    assert.equal(status.components.push.state, "not_configured");
    assert.match(status.components.push.error || "", /Push not configured/);
    const text = JSON.stringify(status);
    assert.equal(statusContainsSecrets(text, {
      admin_secret: "admin-secret-value",
      origin_secret: "origin-secret-value",
      pairing_token: "ABCD2345",
      cursor_secret: "cursor-secret-value",
    }), false);
    assert.doesNotMatch(text, /pairing_token/);
  });

  it("reports an external connector as externally_managed", () => {
    const status = projectStatus({
      config: defaultConfig({ address_mode: "external-proxy", public_url: "https://control.example.com" }),
      runtime: emptyRuntime(),
      manager: "launchd",
      brokerJob: running,
      daemonJob: running,
      tunnelJob: { state: "externally_managed", checked_at: now, mode: "external-proxy" },
      brokerReady: ready,
      daemonReady: ready,
      publicRoute: ready,
      push: pushObservation(true, now),
    });
    assert.equal(status.components.tunnel.state, "externally_managed");
    assert.equal(requiredComponentsReady(status), true);
  });

  it("does not treat a live pid as ready", () => {
    const status = projectStatus({
      config: defaultConfig(),
      runtime: emptyRuntime(),
      manager: "launchd",
      brokerJob: running,
      daemonJob: running,
      tunnelJob: running,
      brokerReady: { state: "not_ready", checked_at: now, error: "unresponsive" },
      daemonReady: { state: "not_ready", checked_at: now },
      publicRoute: { state: "unreachable", checked_at: now },
      push: pushObservation(false, now),
    });
    assert.equal(status.broker, false);
    assert.equal(status.daemon, false);
    assert.notEqual(status.overall, "ready");
    assert.equal(requiredComponentsReady(status), false);
  });
});
