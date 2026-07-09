#!/usr/bin/env node
// `native eject` bakes a path into build.zig.zon pointing at wherever
// `npm root -g` resolved on the machine that ran `native eject` — that
// path is meaningless on any other machine (a colleague's laptop, CI).
// Worse on Windows: npm's global prefix and a git checkout often sit on
// DIFFERENT DRIVE LETTERS (e.g. npm on C:, checkout on D:), and Windows
// relative paths cannot cross drives at all — no relative path exists
// to write, no matter how it's computed. Tried forcing npm's prefix onto
// the checkout's drive first; GitHub's Windows runner image pre-sets it
// via an environment variable that overrides that, so it never actually
// moved.
//
// So instead of computing a path to the global install, this VENDORS a
// copy of it into `.native-sdk/` inside the repo (gitignored) — always
// on the same drive as the checkout by construction, so build.zig.zon
// can point at it with a fixed, permanent, committed relative path
// that never needs to change. Run this once after cloning (or whenever
// the error is "no module named 'native_sdk' available") to refresh it.
"use strict";
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const projectDir = path.join(__dirname, "..");
const vendorDir = path.join(projectDir, ".native-sdk");
const globalRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
const sdkPath = path.join(globalRoot, "@native-sdk", "cli");

if (!fs.existsSync(path.join(sdkPath, "src", "root.zig"))) {
  console.error(
    `error: ${sdkPath} doesn't look like a @native-sdk/cli install ` +
      `(no src/root.zig found). Run "npm install -g @native-sdk/cli" first.`,
  );
  process.exit(1);
}

fs.rmSync(vendorDir, { recursive: true, force: true });
fs.cpSync(sdkPath, vendorDir, { recursive: true });
console.log(`vendored @native-sdk/cli (from ${sdkPath}) into ${vendorDir}`);
