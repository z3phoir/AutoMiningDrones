"use strict";
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const Module = require("module");
const os = require("os");
const child = require("child_process");
const serverRoot = path.resolve(process.argv[2] || ".");
const packageRoot = path.resolve(__dirname, "..");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "automining-loader-"));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));
const installed = path.join(root, "mods/AutoMiningDrones");
fs.mkdirSync(installed, {recursive:true});
fs.copyFileSync(path.join(packageRoot,"loader.js"),path.join(installed,"loader.js"));
fs.cpSync(path.join(packageRoot,"payload"),path.join(installed,"payload"),{recursive:true});
const manifest = require(path.join(installed,"payload/manifest.json"));
for (const file of manifest.files) {
  const target = path.join(root,file.path);
  fs.mkdirSync(path.dirname(target),{recursive:true});
  fs.copyFileSync(path.join(serverRoot,file.path),target);
}
const parser = Module.createRequire(path.join(serverRoot, "package.json"))("@babel/parser");
const chat = path.join(root, "server/src/services/chat/chatCommands.js");
const drone = path.join(root, "server/src/services/drone/droneRuntime.js");
const originals = new Map([chat, drone].map(f => [f, fs.readFileSync(f)]));
const compile = Module.prototype._compile;
const patched = new Map();
Module.prototype._compile = function(content, filename) {
  if (originals.has(filename)) { patched.set(filename, content); return; }
  return compile.call(this, content, filename);
};
try {
  require(path.join(installed,"loader.js"));
  for (const filename of originals.keys()) {
    const mod = new Module(filename);
    mod._compile(originals.get(filename).toString("utf8"), filename);
    assert.throws(() => mod._compile("// conflicting mod", filename), /Conflicting/);
  }
} finally { Module.prototype._compile = compile; }
const runtime = require(path.join(installed,"payload/autoMiningDrones.js")).create({context: () => null});
let forwardedArgument;
function command(source, staff, text = "/autominingdrones status") {
  const ast = parser.parse(source, {sourceType:"script"});
  const names = new Set(["executeChatCommand", "normalizeCommandName", "handledResult"]);
  const functions = ast.program.body.filter(n => n.type === "FunctionDeclaration" && names.has(n.id.name))
    .map(n => source.slice(n.start,n.end)).join("\n");
  const context = vm.createContext({
    hasStaffDebugRole:()=>staff, emitChatFeedback:()=>{}, CAPITAL_NPC_CHAT_COMMANDS:[], WORMHOLE_CHAT_COMMANDS:[], TRIG_DRIFTER_CHAT_COMMANDS:[], GATE_SKIN_CHAT_COMMANDS:[],
    resolveSingleRackCommandPreset:()=>null, suggestCommands:()=>[], formatSuggestions:()=>"",
    require: id => { assert.equal(id,"../drone/droneRuntime"); return {autoMiningDronesCommand:(session, argument) => { forwardedArgument = argument; return runtime.command(session, argument); }}; },
  });
  vm.runInContext(functions, context);
  return context.executeChatCommand({characterID:1}, text, null);
}
assert.match(command(originals.get(chat).toString("utf8"), true).message, /Unknown command/);
assert.equal(command(patched.get(chat), true).message, "AutoMiningDrones off.");
assert.match(command(patched.get(chat), false).message, /staff\/GM/);
assert.match(patched.get(drone), /autoMiningDronesCommand: autoMiningDrones.command/);
for (const [file, data] of originals) assert.deepEqual(fs.readFileSync(file),data);
console.log("PASS: stock command unknown; real patched command routes to upstream status; staff guard retained; both compile hooks work; conflicts rejected; disk source unchanged.");





for (const option of ["", "on", "on focus", "on spread", "focus", "spread", "off", "status", "invalid"]) {
  assert.equal(command(patched.get(chat),true,"/amd " + option).message,
               command(patched.get(chat),true,"/autominingdrones " + option).message);
  assert.equal(forwardedArgument.trim(), option);
  assert.match(command(patched.get(chat),false,"/amd " + option).message,/staff\/GM/);
}
function preload() {
  return child.spawnSync(process.execPath, ["--require", path.join(installed,"loader.js"), "-e", ""], {encoding:"utf8"});
}
assert.equal(preload().status, 0);
fs.writeFileSync(chat, "// unsupported source");
assert.match(preload().stderr, /Unsupported or already patched/);
fs.writeFileSync(chat, originals.get(chat));
let installedSource = originals.get(chat).toString("utf8").replace(/\r\n/g,"\n");
for (const edit of manifest.files.find(f=>f.path.endsWith("chatCommands.js")).edits) installedSource=installedSource.replace(edit.find,()=>edit.replace);
fs.writeFileSync(chat, installedSource);
assert.match(preload().stderr, /Unsupported or already patched/);
fs.writeFileSync(chat, originals.get(chat));
fs.appendFileSync(path.join(installed,"payload/autoMiningDrones.js"),"\n// tampered");
assert.match(preload().stderr,/Runtime checksum mismatch/);
console.log("PASS: short/long commands equivalent; clean preload accepted; unsupported, installer-patched and tampered files rejected.");
