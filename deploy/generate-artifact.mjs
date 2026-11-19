// Only for whoever compiles: generates deploy/BZPX.artifact.json from out/BZPX.sol/BZPX.json
// (output of the project's Foundry build).
import fs from "node:fs";
import crypto from "node:crypto";
const j = JSON.parse(fs.readFileSync(new URL("../out/BZPX.sol/BZPX.json", import.meta.url), "utf8"));
const m = typeof j.metadata === "object" && j.metadata ? j.metadata : JSON.parse(j.rawMetadata);
const bytecode = j.bytecode.object.startsWith("0x") ? j.bytecode.object : "0x" + j.bytecode.object;
const art = {
  contractName: "BZPX",
  compiler: m.compiler.version,
  evmVersion: m.settings.evmVersion,
  optimizer: m.settings.optimizer,
  bytecodeSha256: crypto.createHash("sha256").update(bytecode).digest("hex"),
  abi: j.abi,
  bytecode,
};
fs.writeFileSync(new URL("./BZPX.artifact.json", import.meta.url), JSON.stringify(art, null, 1) + "\n");
console.log(`BZPX.artifact.json: solc ${art.compiler} evm ${art.evmVersion} bytes ${(bytecode.length - 2) / 2} sha256 ${art.bytecodeSha256}`);
