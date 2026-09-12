import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  FakeServiceManager,
  inspectLegacyPid,
  jobSpecFor,
  LaunchdServiceManager,
  renderLaunchdPlist,
  spawnDetached,
} from "./services.ts";
import { defaultConfig } from "./state.ts";

describe("launchd plist", () => {
  it("uses absolute program arguments and never a shell", () => {
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd" }), {
      executable: "/opt/chr33s-shell/shell-control-broker",
      arguments: ["--config", "/state/broker.service.json"],
      workingDirectory: "/state",
      logsDir: "/state/logs",
      sessionPlistDir: "/state/launchd",
      launchAgentsDir: "/tmp/LaunchAgents",
      environment: { SHELL_CONTROL_STATE_DIR: "/state" },
    });
    const plist = renderLaunchdPlist(spec);
    assert.match(plist, /<string>dev.chr33s.shell.control.abcd.broker<\/string>/);
    assert.match(plist, /<string>\/opt\/chr33s-shell\/shell-control-broker<\/string>/);
    assert.doesNotMatch(plist, /npx|bash -lc|eval /);
    assert.match(plist, /<key>StandardInPath<\/key>\s*<string>\/dev\/null<\/string>/);
    assert.match(plist, /<key>ThrottleInterval<\/key>\s*<integer>10<\/integer>/);
  });

  it("does not keep a quick tunnel alive", () => {
    const spec = jobSpecFor("tunnel", defaultConfig({ installation_id: "abcd", address_mode: "quick" }), {
      executable: "/usr/local/bin/cloudflared",
      arguments: ["tunnel", "--url", "http://127.0.0.1:8443"],
      workingDirectory: "/state",
      logsDir: "/state/logs",
      sessionPlistDir: "/state/launchd",
      launchAgentsDir: "/tmp/LaunchAgents",
    });
    assert.equal(spec.keepAlive, false);
    assert.equal(spec.persistent, false);
  });
});

describe("LaunchdServiceManager", () => {
  it("fails clearly when the gui domain is unavailable", async () => {
    const manager = new LaunchdServiceManager({
      uid: 501,
      run: async (cmd, args) => {
        if (args[0] === "print" && args[1] === "gui/501") {
          return { status: 1, stdout: "", stderr: "Could not find domain" };
        }
        return { status: 0, stdout: "", stderr: "" };
      },
    });
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd" }), {
      executable: "/bin/true",
      arguments: [],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: await mkdtemp(join(tmpdir(), "plist-")),
      launchAgentsDir: await mkdtemp(join(tmpdir(), "agents-")),
    });
    await assert.rejects(() => manager.install(spec), /gui\/501 domain is unavailable/);
  });

  it("does not restart an unchanged running session job when installing for login", async () => {
    const calls: string[] = [];
    const dir = await mkdtemp(join(tmpdir(), "plist-"));
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd", persistent: true }), {
      executable: "/bin/true",
      arguments: ["--config", "/state/broker.service.json"],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: dir,
      launchAgentsDir: await mkdtemp(join(tmpdir(), "agents-")),
    });
    const plist = renderLaunchdPlist(spec);
    await writeFile(join(dir, "dev.chr33s.shell.control.abcd.broker.plist"), plist);
    const manager = new LaunchdServiceManager({
      uid: 501,
      run: async (_cmd, args) => {
        calls.push(args.join(" "));
        if (args[0] === "print" && args[1] === "gui/501") return { status: 0, stdout: "ok", stderr: "" };
        if (args[0] === "print") return { status: 0, stdout: "pid = 4242\nstate = running\n", stderr: "" };
        return { status: 0, stdout: "", stderr: "" };
      },
    });
    await manager.install(spec);
    assert.equal(calls.some((c) => c.startsWith("kickstart") || c.startsWith("bootstrap")), false);
  });

  it("reloads a running job when its plist changes", async () => {
    const calls: string[] = [];
    const dir = await mkdtemp(join(tmpdir(), "plist-"));
    const agents = await mkdtemp(join(tmpdir(), "agents-"));
    const config = defaultConfig({ installation_id: "abcd" });
    const oldSpec = jobSpecFor("broker", config, {
      executable: "/bin/true",
      arguments: ["--config", "/state/old.json"],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: dir,
      launchAgentsDir: agents,
    });
    const newSpec = { ...oldSpec, arguments: ["--config", "/state/new.json"] };
    await writeFile(join(dir, "dev.chr33s.shell.control.abcd.broker.plist"), renderLaunchdPlist(oldSpec));
    const manager = new LaunchdServiceManager({
      uid: 501,
      run: async (_cmd, args) => {
        calls.push(args.join(" "));
        if (args[0] === "print" && args[1] === "gui/501") return { status: 0, stdout: "ok", stderr: "" };
        if (args[0] === "print") return { status: 0, stdout: "pid = 4242\nstate = running\n", stderr: "" };
        return { status: 0, stdout: "", stderr: "" };
      },
    });
    await manager.install(newSpec);
    assert.equal(calls.some((c) => c.startsWith("bootout")), true);
    assert.equal(calls.some((c) => c.startsWith("bootstrap")), true);
    const { readFile } = await import("node:fs/promises");
    assert.match(await readFile(join(dir, "dev.chr33s.shell.control.abcd.broker.plist"), "utf8"), /new\.json/);
  });

  it("updates a stale persistent plist without restarting an unchanged session job", async () => {
    const calls: string[] = [];
    const dir = await mkdtemp(join(tmpdir(), "plist-"));
    const agents = await mkdtemp(join(tmpdir(), "agents-"));
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd", persistent: true }), {
      executable: "/bin/true",
      arguments: ["--config", "/state/current.json"],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: dir,
      launchAgentsDir: agents,
    });
    const label = "dev.chr33s.shell.control.abcd.broker.plist";
    await writeFile(join(dir, label), renderLaunchdPlist(spec));
    await writeFile(join(agents, label), "stale");
    const manager = new LaunchdServiceManager({
      uid: 501,
      run: async (_cmd, args) => {
        calls.push(args.join(" "));
        if (args[0] === "print" && args[1] === "gui/501") return { status: 0, stdout: "ok", stderr: "" };
        if (args[0] === "print") return { status: 0, stdout: "pid = 4242\nstate = running\n", stderr: "" };
        return { status: 0, stdout: "", stderr: "" };
      },
    });
    await manager.install(spec);
    const { readFile } = await import("node:fs/promises");
    assert.equal(await readFile(join(agents, label), "utf8"), renderLaunchdPlist(spec));
    assert.equal(calls.some((c) => c.startsWith("bootout") || c.startsWith("bootstrap")), false);
  });

  it("start does not kickstart a job that is already running", async () => {
    const calls: string[] = [];
    const dir = await mkdtemp(join(tmpdir(), "plist-"));
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd" }), {
      executable: "/bin/true",
      arguments: ["--config", "/state/broker.service.json"],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: dir,
      launchAgentsDir: await mkdtemp(join(tmpdir(), "agents-")),
    });
    await writeFile(join(dir, "dev.chr33s.shell.control.abcd.broker.plist"), renderLaunchdPlist(spec));
    const manager = new LaunchdServiceManager({
      uid: 501,
      run: async (_cmd, args) => {
        calls.push(args.join(" "));
        if (args[0] === "print" && args[1] === "gui/501") return { status: 0, stdout: "ok", stderr: "" };
        if (args[0] === "print") return { status: 0, stdout: "pid = 4242\nstate = running\n", stderr: "" };
        if (args[0] === "enable") return { status: 0, stdout: "", stderr: "" };
        return { status: 0, stdout: "", stderr: "" };
      },
    });
    await manager.start(spec);
    assert.equal(calls.some((c) => c.startsWith("kickstart")), false);
  });

  it("stop reports a real bootout failure", async () => {
    const manager = new LaunchdServiceManager({
      uid: 501,
      run: async () => ({ status: 1, stdout: "", stderr: "permission denied" }),
    });
    await assert.rejects(() => manager.stop("dev.chr33s.shell.control.abcd.broker"), /permission denied/);
  });
});

describe("legacy pid inspection", () => {
  it("does not treat an unrelated live pid as owned", async () => {
    const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    assert.ok(child.pid);
    try {
      const report = await inspectLegacyPid(child.pid, "shell-control-broker", process.getuid?.() ?? 0);
      assert.equal(report.verifiable, false);
      assert.match(report.reason || "", /executable path does not match/);
    } finally {
      child.kill("SIGKILL");
    }
  });
});

describe("FakeServiceManager", () => {
  it("reuses a healthy pid across start", async () => {
    const manager = new FakeServiceManager();
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd" }), {
      executable: "/bin/true",
      arguments: [],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: "/tmp",
      launchAgentsDir: "/tmp",
    });
    await manager.start(spec);
    const first = await manager.observe("dev.chr33s.shell.control.abcd.broker");
    await manager.start(spec);
    const second = await manager.observe("dev.chr33s.shell.control.abcd.broker");
    assert.equal(first.pid, second.pid);
  });

  it("down disables restart by leaving the job unloaded", async () => {
    const manager = new FakeServiceManager();
    const spec = jobSpecFor("broker", defaultConfig({ installation_id: "abcd" }), {
      executable: "/bin/true",
      arguments: [],
      workingDirectory: "/tmp",
      logsDir: "/tmp",
      sessionPlistDir: "/tmp",
      launchAgentsDir: "/tmp",
    });
    await manager.start(spec);
    const label = "dev.chr33s.shell.control.abcd.broker";
    await manager.disable(label);
    await manager.stop(label);
    const observed = await manager.observe(label);
    assert.equal(observed.pid, null);
    assert.equal(observed.enabled, false);
  });
});

describe("spawnDetached", () => {
  it("keeps writing after the parent drops stdio", async () => {
    const dir = await mkdtemp(join(tmpdir(), "shell-spawn-"));
    const log = join(dir, "child.log");
    const child = await spawnDetached({
      executable: process.execPath,
      args: ["-e", "let n=0; setInterval(() => process.stdout.write('tick'+n+++'\\n'), 20)"],
      env: process.env,
      cwd: dir,
      stdoutPath: log,
      stderrPath: log,
    });
    await new Promise((r) => setTimeout(r, 80));
    const { readFile, stat } = await import("node:fs/promises");
    const before = (await stat(log)).size;
    await new Promise((r) => setTimeout(r, 80));
    const after = (await stat(log)).size;
    assert.ok(after > before, "service continued writing after parent closed log fds");
    assert.match(await readFile(log, "utf8"), /tick/);
    try { process.kill(child.pid, "SIGKILL"); } catch { /* gone */ }
  });
});
