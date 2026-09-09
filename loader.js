"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const vm = require("vm");
const Module = require("module");
const manifest = require("./payload/manifest.json");
const normalize = text => text.replace(/\r\n/g, "\n");
const hash = text => crypto.createHash("sha256").update(text).digest("hex");
const root = path.resolve(__dirname, "../..");
const marker = Symbol.for("AutoMiningDrones.loader.v1");
if (!globalThis[marker]) {
  const runtime = path.join(__dirname, "payload/autoMiningDrones.js");
  if (hash(normalize(fs.readFileSync(runtime, "utf8"))) !== manifest.added.sha256)
    throw new Error("[AutoMiningDrones] Runtime checksum mismatch");
  const targets = new Map();
  for (const file of manifest.files) {
    const filename = path.resolve(root, file.path);
    if (require.cache[filename])
      throw new Error("[AutoMiningDrones] Loaded too late: " + filename);
    let source = normalize(fs.readFileSync(filename, "utf8"));
    if (hash(source) !== file.originalHash)
      throw new Error("[AutoMiningDrones] Unsupported or already patched file: " + file.path);
    for (const edit of file.edits) {
      if (source.split(edit.find).length !== 2)
        throw new Error("[AutoMiningDrones] Non-unique patch anchor: " + file.path);
      source = source.replace(edit.find, () => edit.replace);
    }
    if (hash(source) !== file.patchedHash)
      throw new Error("[AutoMiningDrones] Patched checksum mismatch: " + file.path);
    source = source.replace('require("./autoMiningDrones")',
      () => "require(" + JSON.stringify(runtime) + ")");
    new vm.Script(Module.wrap(source), { filename });
    targets.set(filename, { source, originalHash: file.originalHash });
  }
  const originalCompile = Module.prototype._compile;
  Module.prototype._compile = function autoMiningDronesCompile(content, filename) {
    const target = targets.get(path.resolve(filename));
    if (target) {
      if (hash(normalize(content)) !== target.originalHash)
        throw new Error("[AutoMiningDrones] Conflicting mod source: " + filename);
      content = target.source;
    }
    return originalCompile.call(this, content, filename);
  };
  globalThis[marker] = true;
  console.log(`[AutoMiningDrones] ${manifest.version} loader ready; in-memory patches enabled.`);
}
