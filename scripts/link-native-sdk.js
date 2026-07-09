#!/usr/bin/env node
// `native eject` bakes a machine-specific relative path into
// build.zig.zon, pointing at wherever `npm root -g` happened to resolve
// on the machine that ran `native eject` — that path is meaningless on
// any other machine (a colleague's laptop, CI, ...). Run this once
// before `native build`/`native test` on a fresh checkout (or whenever
// the error is "no module named 'native_sdk' available") to repoint the
// dependency at THIS machine's actual global npm install.
"use strict";
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const projectDir = path.join(__dirname, "..");
const zonPath = path.join(projectDir, "build.zig.zon");
const globalRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
const sdkPath = path.join(globalRoot, "@native-sdk", "cli");

if (!fs.existsSync(path.join(sdkPath, "src", "root.zig"))) {
  console.error(
    `error: ${sdkPath} doesn't look like a @native-sdk/cli install ` +
      `(no src/root.zig found). Run "npm install -g @native-sdk/cli" first.`,
  );
  process.exit(1);
}

// Zig path dependencies must be relative to the build root (an absolute
// path is a hard error), so re-derive the same relative-path shape
// `native eject` originally wrote — just freshly computed for THIS
// machine instead of frozen from whichever machine ran eject.
const relativePath = path.relative(projectDir, sdkPath) || ".";
// build.zig.zon is Zig source, not JSON — escape backslashes (Windows
// paths) and quotes so the result is a valid Zig string literal.
const escaped = relativePath.replace(/\\/g, "\\\\").replace(/"/g, '\\"');

const zon = fs.readFileSync(zonPath, "utf8");
const dependencyLine = /\.native_sdk\s*=\s*\.\{\s*\.path\s*=\s*"[^"]*"\s*\}/;
if (!dependencyLine.test(zon)) {
  console.error("error: could not find the .native_sdk dependency line in build.zig.zon to update");
  process.exit(1);
}

const updated = zon.replace(dependencyLine, `.native_sdk = .{ .path = "${escaped}" }`);
if (updated !== zon) fs.writeFileSync(zonPath, updated);
console.log(`build.zig.zon now points .native_sdk at: ${sdkPath}`);
