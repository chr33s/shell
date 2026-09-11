import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { findRepoRoot, isLoopbackHost, pairingLink, pairingPageURL, queryEscape } from "./util.ts";

describe("isLoopbackHost", () => {
  it("accepts localhost, 127.0.0.1, and ::1 with optional ports", () => {
    assert.equal(isLoopbackHost("localhost"), true);
    assert.equal(isLoopbackHost("127.0.0.1"), true);
    assert.equal(isLoopbackHost("127.0.0.1:8443"), true);
    assert.equal(isLoopbackHost("[::1]"), true);
    assert.equal(isLoopbackHost("::1"), true);
    assert.equal(isLoopbackHost("random.trycloudflare.com"), false);
    assert.equal(isLoopbackHost("evil.example"), false);
    assert.equal(isLoopbackHost(""), false);
  });
});

describe("pairingLink", () => {
  it("percent-encodes the broker so :// cannot split the query", () => {
    const link = pairingLink("https://random.trycloudflare.com", "ABCD1234");
    assert.match(link, /^shell-control:\/\/pair\?/);
    assert.match(link, /broker=https%3A%2F%2Frandom.trycloudflare.com/);
    assert.match(link, /token=ABCD1234/);
    assert.doesNotMatch(link, /broker=https:\/\//);
  });
});

describe("pairingPageURL", () => {
  it("puts the token on /pair without using Host", () => {
    assert.equal(
      pairingPageURL("https://random.trycloudflare.com", "ABCD1234"),
      "https://random.trycloudflare.com/pair?token=ABCD1234"
    );
  });
});

describe("queryEscape", () => {
  it("encodes reserved URL characters", () => {
    assert.equal(queryEscape("https://x.example/a?b=c"), "https%3A%2F%2Fx.example%2Fa%3Fb%3Dc");
  });
});

describe("findRepoRoot", () => {
  it("finds this checkout from cli/src", async () => {
    const root = await findRepoRoot();
    assert.ok(root, "expected to find services/shell-control/Package.swift");
    assert.match(root, /shell$/);
  });
});
