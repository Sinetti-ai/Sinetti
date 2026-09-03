import { lstatSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";

const root = process.cwd();
const ignored = new Set([
  ".git",
  "node_modules",
  "artifacts",
  "cache",
  "cache_forge",
  "out",
  "dist",
  "typechain-types",
  "coverage",
  "data"
]);
const textExtensions = new Set([
  ".cjs", ".css", ".env", ".html", ".js", ".json", ".jsonc", ".md",
  ".mjs", ".sh", ".sol", ".toml", ".ts", ".txt", ".yaml", ".yml"
]);
const forbidden = [
  /\/Users\//,
  /\/home\/[A-Za-z0-9._-]+\//,
  /\b(?:PORT-PLAN|PORT-MANIFEST)\.md\b/,
  /\b(?:Codev|codev)\b/,
  /\bprivate Sinetti repo\b/i,
  /console\/identity\.py/,
  /\b(?:Raha|Besu slot|sinetti-open)\b/
];
const failures = [];

function walk(directory) {
  for (const name of readdirSync(directory)) {
    if (ignored.has(name)) continue;
    const absolute = path.join(directory, name);
    const relative = path.relative(root, absolute).split(path.sep).join("/");
    const stat = lstatSync(absolute);
    if (stat.isSymbolicLink()) {
      failures.push(`${relative}: tracked publication tree must not contain symlinks`);
      continue;
    }
    if (stat.isDirectory()) {
      walk(absolute);
      continue;
    }
    if (stat.size > 1_000_000) failures.push(`${relative}: file exceeds 1 MB`);
    const extension = name === ".env.example" ? ".env" : path.extname(name);
    if (!textExtensions.has(extension) && !["LICENSE", "NOTICE"].includes(name)) continue;
    const text = readFileSync(absolute, "utf8");
    for (const pattern of forbidden) {
      if (relative !== "scripts/check-publication.mjs" && pattern.test(text)) {
        failures.push(`${relative}: matches forbidden publication pattern ${pattern}`);
      }
    }
    if (extension !== ".md") continue;
    for (const match of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
      const raw = match[1].replace(/^<|>$/g, "").split("#", 1)[0];
      if (!raw || /^(?:https?:|mailto:)/.test(raw)) continue;
      const target = path.resolve(path.dirname(absolute), decodeURIComponent(raw));
      try {
        lstatSync(target);
      } catch {
        failures.push(`${relative}: broken local Markdown link ${match[1]}`);
      }
    }
  }
}

walk(root);
if (failures.length) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log("publication tree: clean");
}
