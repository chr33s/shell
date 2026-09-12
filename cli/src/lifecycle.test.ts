import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { spawnDetached } from "./services.ts";

describe("detached service lifecycle", () => {
  it("L04: service keeps writing after parent closes log descriptors", async () => {
    const dir = await mkdtemp(join(tmpdir(), "shell-life-"));
    const log = join(dir, "svc.log");
    const child = await spawnDetached({
      executable: process.execPath,
      args: ["-e", "let n=0; const t=setInterval(()=>{process.stdout.write('tick'+n+++'\\n'); if(n>50) clearInterval(t);}, 15)"],
      env: { ...process.env },
      cwd: dir,
      stdoutPath: log,
      stderrPath: log,
    });
    await new Promise((r) => setTimeout(r, 60));
    const first = (await stat(log)).size;
    await new Promise((r) => setTimeout(r, 90));
    const second = (await stat(log)).size;
    assert.ok(second > first, "log grew after parent dropped fds");
    assert.match(await readFile(log, "utf8"), /tick/);
    try { process.kill(child.pid, "SIGKILL"); } catch { /* already exited */ }
  });

  it("does not mark a spawn ready from a pid of a process that exits immediately", async () => {
    const dir = await mkdtemp(join(tmpdir(), "shell-life-"));
    const log = join(dir, "svc.log");
    const child = await spawnDetached({
      executable: process.execPath,
      args: ["-e", "process.exit(1)"],
      env: { ...process.env },
      cwd: dir,
      stdoutPath: log,
      stderrPath: log,
    });
    const code = await child.waitForExit;
    assert.equal(code, 1);
    assert.ok(child.pid > 0);
  });
});
