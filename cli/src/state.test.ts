import assert from "node:assert/strict";
import { mkdtemp, mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  acquireInstallationLock,
  atomicWriteFile,
  loadOrCreateInstallation,
  loadSecrets,
  migrateLegacy,
  newSecrets,
  pathsFor,
  rotateLogFile,
} from "./state.ts";
import { CliError } from "./util.ts";

async function tempDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "shell-state-"));
}

describe("atomicWriteFile", () => {
  it("replaces the target and does not leave a torn file", async () => {
    const dir = await tempDir();
    const path = join(dir, "config.json");
    await atomicWriteFile(path, '{"ok":true}\n', 0o600);
    await atomicWriteFile(path, '{"ok":false}\n', 0o600);
    const { readFile } = await import("node:fs/promises");
    assert.equal(await readFile(path, "utf8"), '{"ok":false}\n');
  });
});

describe("installation lock", () => {
  it("excludes a concurrent holder and then reuses", async () => {
    const dir = await tempDir();
    const first = await acquireInstallationLock(dir, { timeoutMs: 2000 });
    let secondAcquired = false;
    const waiter = acquireInstallationLock(dir, { timeoutMs: 2000 }).then(async (lock) => {
      secondAcquired = true;
      await lock.release();
    });
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(secondAcquired, false);
    await first.release();
    await waiter;
    assert.equal(secondAcquired, true);
  });
});

describe("loadOrCreateInstallation", () => {
  it("creates identity once and reuses it", async () => {
    const dir = await tempDir();
    const first = await loadOrCreateInstallation(dir);
    const second = await loadOrCreateInstallation(dir);
    assert.equal(first.created, true);
    assert.equal(second.created, false);
    assert.equal(second.config.installation_id, first.config.installation_id);
    assert.equal(second.secrets.account_id, first.secrets.account_id);
    assert.equal(second.secrets.admin_secret, first.secrets.admin_secret);
  });

  it("refuses to mint a new account when secrets are missing", async () => {
    const dir = await tempDir();
    const created = await loadOrCreateInstallation(dir);
    const { unlink } = await import("node:fs/promises");
    await unlink(pathsFor(created.paths.root).secrets);
    await assert.rejects(() => loadOrCreateInstallation(dir), (error: unknown) => {
      assert.ok(error instanceof CliError);
      assert.match(error.message, /repair required/);
      return true;
    });
  });

  it("refuses a symlink state file", async () => {
    const dir = await tempDir();
    const created = await loadOrCreateInstallation(dir);
    const { unlink } = await import("node:fs/promises");
    await unlink(created.paths.secrets);
    await symlink("/etc/passwd", created.paths.secrets);
    await assert.rejects(() => loadSecrets(dir), /symlink/);
  });
});

describe("legacy migration", () => {
  it("imports setup.env without regenerating account identity", async () => {
    const dir = await tempDir();
    await mkdir(dir, { recursive: true, mode: 0o700 });
    await writeFile(
      join(dir, "setup.env"),
      [
        "SHELL_CONTROL_ACCOUNT_ID=11111111-1111-4111-8111-111111111111",
        "SHELL_CONTROL_ADMIN_SECRET=admintoken",
        "SHELL_CONTROL_CURSOR_SECRET=cursortoken",
        "SHELL_CONTROL_PAIRING_TOKEN=ABCD2345",
        "SHELL_CONTROL_PUBLIC_URL=https://control.example.com",
        "SHELL_CONTROL_ORIGIN_ID=22222222-2222-4222-8222-222222222222",
        "SHELL_CONTROL_ORIGIN_SECRET=originsecret",
      ].join("\n") + "\n",
      { mode: 0o600 },
    );
    const migrated = await migrateLegacy(dir);
    assert.equal(migrated.secrets.account_id, "11111111-1111-4111-8111-111111111111");
    assert.equal(migrated.secrets.admin_secret, "admintoken");
    assert.equal(migrated.secrets.origin_id, "22222222-2222-4222-8222-222222222222");
    assert.equal(migrated.config.address_mode, "external-proxy");
    assert.equal(migrated.config.public_url, "https://control.example.com");
  });

  it("does not execute setup.env as a shell", async () => {
    const dir = await tempDir();
    await mkdir(dir, { recursive: true, mode: 0o700 });
    await writeFile(
      join(dir, "setup.env"),
      "SHELL_CONTROL_ACCOUNT_ID=$(echo pwned)\nSHELL_CONTROL_ADMIN_SECRET=x\nSHELL_CONTROL_CURSOR_SECRET=y\n",
      { mode: 0o600 },
    );
    const migrated = await migrateLegacy(dir);
    assert.equal(migrated.secrets.account_id, "$(echo pwned)");
  });
});

describe("log rotation", () => {
  it("copies and truncates an oversized log without touching the journal", async () => {
    const dir = await tempDir();
    const log = join(dir, "broker.err.log");
    const journal = join(dir, "dispatch-journal.ndjson");
    await writeFile(log, "a".repeat(64));
    await writeFile(journal, "keep-me\n");
    const rotated = await rotateLogFile(log, 32, 3);
    assert.equal(rotated, true);
    const { readFile, stat } = await import("node:fs/promises");
    assert.equal((await stat(log)).size, 0);
    assert.equal((await readFile(`${log}.1`, "utf8")).length, 64);
    assert.equal(await readFile(journal, "utf8"), "keep-me\n");
  });
});

describe("newSecrets", () => {
  it("does not put secrets in a shared object", () => {
    const a = newSecrets();
    const b = newSecrets();
    assert.notEqual(a.admin_secret, b.admin_secret);
    assert.notEqual(a.account_id, b.account_id);
  });
});

