#!/usr/bin/env bun
// Analyze Kalamos usage to find the idle-unload sweet spot.
// Reads the privacy-safe usage log (timestamps only) and reports, for several
// candidate timeouts, how many model reloads they'd cause vs how long the model
// stays resident — then recommends a value.
//
//   bun Scripts/analyze-idle.ts            # default log path
//   bun Scripts/analyze-idle.ts <path>
import { readFileSync } from "fs";
import { homedir } from "os";

const path =
  process.argv[2] ??
  `${homedir()}/Library/Application Support/Kalamos/usage.log`;

let raw: string;
try {
  raw = readFileSync(path, "utf8");
} catch {
  console.error(`No usage log at ${path} — use Kalamos for a while first.`);
  process.exit(1);
}

const ts = raw
  .split("\n")
  .map((s) => s.trim())
  .filter(Boolean)
  .map((s) => Date.parse(s))
  .filter((n) => !Number.isNaN(n))
  .sort((a, b) => a - b);

if (ts.length < 2) {
  console.log("Not enough data yet (need at least 2 dictations).");
  process.exit(0);
}

const gaps: number[] = [];
for (let i = 1; i < ts.length; i++) gaps.push((ts[i] - ts[i - 1]) / 1000); // seconds
const days = Math.max((ts[ts.length - 1] - ts[0]) / 86_400_000, 1 / 24);

const sorted = [...gaps].sort((a, b) => a - b);
const pct = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];

console.log(`Dictations: ${ts.length} over ${days.toFixed(1)} days (${(ts.length / days).toFixed(1)}/day)`);
console.log(`Gap percentiles (s): p50=${pct(50) | 0}  p75=${pct(75) | 0}  p85=${pct(85) | 0}  p90=${pct(90) | 0}`);
console.log(`\n timeout   reloads  reload%   loaded min/day`);

const candidates = [60, 120, 180, 300, 600, 900, 1800];
for (const t of candidates) {
  const reloads = gaps.filter((g) => g > t).length;
  const loadedSec = gaps.reduce((s, g) => s + Math.min(g, t), 0) + t;
  const perDay = loadedSec / 60 / days;
  console.log(
    `${String(t).padStart(6)}s  ${String(reloads).padStart(7)}  ${((reloads / gaps.length) * 100).toFixed(0).padStart(6)}%  ${perDay.toFixed(0).padStart(13)}`
  );
}

// Recommend the smallest timeout that keeps the reload rate ≤ 15%.
let rec = 300;
for (const t of candidates) {
  if (gaps.filter((g) => g > t).length / gaps.length <= 0.15) {
    rec = t;
    break;
  }
}
console.log(`\nRecommended idleUnloadSeconds: ${rec}`);
console.log(`Apply (no rebuild needed):  defaults write com.kalamos.app idleUnloadSeconds -int ${rec}`);
