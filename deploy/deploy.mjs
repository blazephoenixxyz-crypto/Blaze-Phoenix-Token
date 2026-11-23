// BZPX (LayerZero V2 OFT): deploy and configuration on the mesh of config/network.json (order: Base main + 5 mirrors).
// Run it through bzpx.sh, which reads the private key with `read -s` (never from a file) and passes it only as an
// environment variable.
//
//   status                                       read-only, needs no key
//   deploy                                       creates the contract on every chain (same code; 1e9 BZPX only on Base)
//   wire                                         explicit LayerZero config on the N·(N−1) directions (6 chains: 30) + peers
//   send <source> <amount> [chain] [recipient]   test send (default chain: the 1st of the order, or the 2nd if the source is the 1st)
//   renounce                                     read-only: gate over the N·(N−1) directions (nothing is sent)
//   renounce --execute                           IRREVERSIBLE: after the gate, setDelegate(0) and renounceOwnership() on all
//
// RPC: config/network.json; for a local rehearsal override with RPC_<CHAIN> (RPC_BASE, RPC_ROBINHOOD, RPC_OPTIMISM, ...).
// Addresses are written to deploy/addresses.json (override with BZPX_ADDRESSES); log in deploy/deploys.txt (BZPX_LOG).
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { MSG_SEND, MSG_SEND_AND_CALL, eq, b32, directions, expected as expectedMesh, evaluate, evaluateOApp, gateOApp, meshGate, coherence, configAddresses, codeFaults } from "./mesh.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NETWORK = JSON.parse(fs.readFileSync(path.join(HERE, "..", "config", "network.json"), "utf8"));
const ART = JSON.parse(fs.readFileSync(path.join(HERE, "BZPX.artifact.json"), "utf8"));
const ADDRESSES = process.env.BZPX_ADDRESSES || path.join(HERE, "addresses.json");
const LOG = process.env.BZPX_LOG || path.join(HERE, "deploys.txt");
const ORDER = NETWORK.order;
// config guards: the order covers all chains, Base is the main one (the only place that mints) and the receive gas
// does not drop below the measured value
if (!Array.isArray(ORDER) || ORDER.length < 2 || new Set(ORDER).size !== ORDER.length ||
    ORDER.length !== Object.keys(NETWORK.chains).length || !ORDER.every((n) => NETWORK.chains[n]?.name === n))
  throw new Error("network.json: order must list each chain of chains exactly once");
if (NETWORK.mainChainId !== NETWORK.chains.base?.chainId || ORDER.filter((n) => NETWORK.chains[n].chainId === NETWORK.mainChainId).length !== 1)
  throw new Error("network.json: mainChainId must be the chainId of Base (8453) and of Base only");
if (new Set(ORDER.map((n) => NETWORK.chains[n].eid)).size !== ORDER.length) throw new Error("network.json: duplicate eids");
if (!(Number(NETWORK.lzReceiveGas) >= 150000))
  throw new Error("network.json: lzReceiveGas below 150000 (the first receive on Robinhood measured ~89 400 of execution)");
const SUPPLY = 10n ** 27n; // 1e9 * 1e18
const DUST = 10n ** 12n; // 18 local decimals, 6 shared
const CFG_EXECUTOR = 1;
const CFG_ULN = 2;
const ULN_T = "tuple(uint64,uint8,uint8,uint8,address[],address[])";
const coder = ethers.AbiCoder.defaultAbiCoder();

const EP_ABI = [
  "function eid() view returns (uint32)",
  "function delegates(address) view returns (address)",
  "function isSupportedEid(uint32) view returns (bool)",
  "function setSendLibrary(address,uint32,address)",
  "function setReceiveLibrary(address,uint32,address,uint256)",
  "function setConfig(address,address,(uint32,uint32,bytes)[])",
  "function getSendLibrary(address,uint32) view returns (address)",
  "function isDefaultSendLibrary(address,uint32) view returns (bool)",
  "function getReceiveLibrary(address,uint32) view returns (address,bool)",
];
const LIB_ABI = [
  "function executorConfigs(address,uint32) view returns (uint32,address)",
  `function getAppUlnConfig(address,uint32) view returns (${ULN_T})`,
];

// ------------------------------------------------------------------ util

// created only when needed: this way no line written before the question is lost
let rl = null;
async function confirm(question, word) {
  rl ??= readline.createInterface({ input: process.stdin, output: process.stdout });
  const r = (await rl.question(`${question}\nType ${word} to continue (anything else cancels): `)).trim();
  if (r !== word) {
    console.log("cancelled, nothing was sent.");
    rl?.close();
    process.exit(0);
  }
}
const fmt = (x) => ethers.formatUnits(x, 18);
const others = (n) => ORDER.filter((x) => x !== n);
const hostOf = (u) => {
  try {
    return new URL(u).host;
  } catch {
    return "?";
  }
};

function readAddresses() {
  return fs.existsSync(ADDRESSES) ? JSON.parse(fs.readFileSync(ADDRESSES, "utf8")) : {};
}
function writeAddresses(e) {
  fs.writeFileSync(ADDRESSES, JSON.stringify(e, null, 2) + "\n");
}

function readKey() {
  const raw = (process.env.PK || "").trim().replace(/^0x/, "");
  delete process.env.PK;
  if (!/^[0-9a-fA-F]{64}$/.test(raw)) {
    console.error("key missing or badly formatted (64 hex characters). Use ./bzpx.sh, which asks for it with read -s.");
    process.exit(1);
  }
  return new ethers.Wallet("0x" + raw);
}

// public RPCs sometimes fail midway: the startup reads retry up to 4 times (a tx send is never retried)
async function chain(name) {
  for (let i = 1; ; i++) {
    try {
      return await chain1(name);
    } catch (e) {
      if (i >= 4 || /chainId|no code|eid\(\)/.test(e.message)) throw e;
      console.log(`  (${name}: RPC failed, retry ${i + 1}/4: ${e.shortMessage || e.message})`);
      await new Promise((r) => setTimeout(r, 2000 * i));
    }
  }
}
async function chain1(name) {
  const cfg = NETWORK.chains[name];
  const rpc = process.env[`RPC_${name.toUpperCase()}`] || cfg.rpc;
  // cacheTimeout -1: no cache for identical requests (with a cache, a repeated getTransactionCount within 250 ms returned the old nonce)
  const provider = new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true, cacheTimeout: -1 });
  const chainId = (await provider.getNetwork()).chainId;
  const real = BigInt(await provider.send("eth_chainId", []));
  if (chainId !== BigInt(cfg.chainId) || real !== BigInt(cfg.chainId))
    throw new Error(`${name}: the RPC answers chainId ${real}, expected ${cfg.chainId}`);
  const ep = new ethers.Contract(cfg.endpoint, EP_ABI, provider);
  if ((await provider.getCode(cfg.endpoint)) === "0x") throw new Error(`${name}: endpoint has no code`);
  const eid = Number(await ep.eid());
  if (eid !== cfg.eid) throw new Error(`${name}: endpoint.eid() = ${eid}, expected ${cfg.eid}`);
  // libs, executor and DVNs of network.json must exist on this chain: the gate only compares them with themselves
  const codes = Object.fromEntries(
    await Promise.all(configAddresses(cfg).map(async ([, a]) => [a.toLowerCase(), await provider.getCode(a)])),
  );
  const faults = codeFaults(name, cfg, codes);
  if (faults.length) throw new Error(faults.join("; ")); // "no code": not retried by chain()
  return { name, cfg, rpc, provider, ep };
}

/// Config required for the path loc -> rem (what "wire" sets and what "status" and the gate check): see mesh.mjs.
const expected = (loc, rem) => expectedMesh(loc, rem, NETWORK.lzReceiveGas);

/// Reads the OApp's OWN config from the endpoint and the libs (not the effective one with default values) and compares it to the required one.
async function readConfig(c, token, remName, remAddress) {
  const rem = NETWORK.chains[remName];
  const e = expected(c.cfg, rem);
  const oapp = await token.getAddress();
  const sl = new ethers.Contract(c.cfg.sendLib, LIB_ABI, c.provider);
  const rlib = new ethers.Contract(c.cfg.receiveLib, LIB_ABI, c.provider);
  const [isDefSend, curSend, [curRecv, isDefRecv], execApp, sendUln, recvUln, opts1, opts2, peer] = await Promise.all([
    c.ep.isDefaultSendLibrary(oapp, rem.eid),
    c.ep.getSendLibrary(oapp, rem.eid),
    c.ep.getReceiveLibrary(oapp, rem.eid),
    sl.executorConfigs(oapp, rem.eid),
    sl.getAppUlnConfig(oapp, rem.eid),
    rlib.getAppUlnConfig(oapp, rem.eid),
    token.enforcedOptions(rem.eid, MSG_SEND),
    token.enforcedOptions(rem.eid, MSG_SEND_AND_CALL),
    token.peers(rem.eid),
  ]);
  const read = { isDefSend, curSend, curRecv, isDefRecv, execApp, sendUln, recvUln, opts: { [MSG_SEND]: opts1, [MSG_SEND_AND_CALL]: opts2 }, peer };
  return { expected: e, items: evaluate(read, e, c.cfg, remAddress), read };
}

/// Owner-settable OApp state outside the directions (what "wire" resets and what "status" and the gate check): see mesh.mjs.
async function readOApp(token) {
  const [msgInspector, preCrime, parkedCount] = await Promise.all([token.msgInspector(), token.preCrime(), token.parkedCount()]);
  return { msgInspector, preCrime, parkedCount };
}

async function waitTx(promise, desc) {
  const tx = await promise;
  console.log(`  ${desc}: tx ${tx.hash}`);
  const r = await tx.wait(1);
  if (!r || r.status !== 1) throw new Error(`${desc}: tx failed`);
  return r;
}

// ------------------------------------------------------------------ commands

async function status() {
  const addrs = readAddresses();
  let sum = 0n;
  let all = true;
  for (const name of ORDER) {
    const c = await chain(name);
    console.log(`\n== ${name} (chainId ${c.cfg.chainId}, eid ${c.cfg.eid}, rpc ${hostOf(c.rpc)}) endpoint ${c.cfg.endpoint} OK`);
    const a = addrs[name]?.address;
    if (!a) {
      console.log(addrs[name]?.pending ? `  deploy PENDING (expected ${addrs[name].pending.expectedAddress}): run ./bzpx.sh deploy to check it` : "  no deploy recorded");
      all = false;
      continue;
    }
    if ((await c.provider.getCode(a)) === "0x") throw new Error(`${name}: ${a} has no code`);
    const t = new ethers.Contract(a, ART.abi, c.provider);
    const [nm, sym, ts, own, del, epAddr] = await Promise.all([
      t.name(),
      t.symbol(),
      t.totalSupply(),
      t.owner(),
      c.ep.delegates(a),
      t.endpoint(),
    ]);
    sum += ts;
    console.log(`  BZPX ${a}  ${nm} (${sym})  totalSupply ${fmt(ts)}`);
    console.log(`  owner ${own}  delegate ${del}  endpoint ${eq(epAddr, c.cfg.endpoint) ? "OK" : "WRONG " + epAddr}`);
    if (own === ethers.ZeroAddress && del !== ethers.ZeroAddress)
      console.log("  WARNING: owner renounced but the delegate can still change the config on the endpoint (no way back)");
    for (const remName of others(name)) {
      const r = await readConfig(c, t, remName, addrs[remName]?.address);
      const f = Object.entries(r.items).filter(([, ok]) => !ok).map(([k]) => k);
      console.log(`  ${f.length ? "MISSING " : "OK      "} -> ${remName}${f.length ? ": " + f.join(", ") : ""}`);
      if (f.length) all = false;
    }
    const ro = await readOApp(t);
    const fo = Object.entries(evaluateOApp(ro)).filter(([, ok]) => !ok).map(([k]) => k);
    console.log(`  ${fo.length ? "MISSING " : "OK      "} OApp state${fo.length ? ": " + fo.join(", ") : " (msgInspector, preCrime)"}`);
    if (fo.length) all = false;
    console.log(`  parked packets: ${ro.parkedCount}`); // informative: the renounce gate needs 0, the config does not
  }
  console.log(`\nsum of supplies: ${fmt(sum)} BZPX ${sum <= SUPPLY ? "(<= 1e9 OK)" : "(> 1e9 !!!)"}`);
  console.log(all ? `config complete on all ${directions(ORDER).length} directions.` : "config incomplete: run ./bzpx.sh wire");
  return all;
}

async function deploy() {
  const w = readKey();
  const addrs = readAddresses();
  const plan = [];
  console.log(`wallet (owner, delegate and recipient of 1e9 BZPX on Base): ${w.address}`);
  for (const name of ORDER) {
    const c = await chain(name);
    for (const remName of others(name)) {
      const remEid = NETWORK.chains[remName].eid;
      if (!(await c.ep.isSupportedEid(remEid))) throw new Error(`${name}: endpoint does not support eid ${remEid} (${remName})`);
    }
    const signer = w.connect(c.provider);
    const f = new ethers.ContractFactory(ART.abi, ART.bytecode, signer);
    const txReq = await f.getDeployTransaction(c.cfg.endpoint, w.address); // constructor(endpoint, owner): MAIN_CHAIN_ID is a contract constant
    const [balance, nonce, fee] = await Promise.all([
      c.provider.getBalance(w.address),
      c.provider.getTransactionCount(w.address, "pending"),
      c.provider.getFeeData(),
    ]);
    const expectedAddress = ethers.getCreateAddress({ from: w.address, nonce });
    const main = c.cfg.chainId === NETWORK.mainChainId;
    console.log(`\n== ${name} (chainId ${c.cfg.chainId}, rpc ${hostOf(c.rpc)})`);
    if (addrs[name]?.address) {
      console.log(`  deploy already recorded: ${addrs[name].address} (skipped; to redo, delete it from ${ADDRESSES})`);
      continue;
    }
    // a deploy sent in an earlier run that never got to record the address (the RPC dropped midway)?
    const pend = addrs[name]?.pending;
    if (pend) {
      if ((await c.provider.getCode(pend.expectedAddress)) !== "0x") {
        console.log(`  pending deploy found at ${pend.expectedAddress}: checking and recording (it will not deploy again)`);
        await record(name, c, w, pend.expectedAddress, pend.tx ?? "?", null);
        continue;
      }
      const used = await c.provider.getTransactionCount(w.address, "latest");
      if (used > pend.nonce)
        throw new Error(`${name}: the nonce ${pend.nonce} of the pending deploy was already used but there is no contract at ${pend.expectedAddress}. Check the wallet on the explorer before repeating.`);
      if (nonce > pend.nonce)
        throw new Error(`${name}: pending deploy transaction not yet mined (tx ${pend.tx ?? "?"}). Wait a few minutes and run again.`);
      console.log("  the earlier pending deploy was never sent: it will be done again");
    }
    const gas = await c.provider.estimateGas({ ...txReq, from: w.address });
    const price = fee.maxFeePerGas ?? fee.gasPrice;
    const cost = gas * price;
    console.log(`  balance ${ethers.formatEther(balance)} ETH  nonce ${nonce}  expected address ${expectedAddress}`);
    console.log(`  gas ${gas}  max estimated cost ${ethers.formatEther(cost)} ETH`);
    console.log(`  initial supply: ${main ? "1 000 000 000 BZPX to the wallet" : "0"}`);
    if (balance < cost) throw new Error(`${name}: insufficient balance for the deploy`);
    plan.push({ name, c, signer, f, nonce, expectedAddress, main });
  }
  if (plan.length === 0) return console.log("\nnothing to do.");
  if (plan.length > 1)
    console.log(
      plan.every((p) => p.nonce === plan[0].nonce)
        ? `\nequal nonces: the contract address will be the SAME on the ${plan.length} chains.`
        : `\ndifferent nonces: the addresses will differ between the ${plan.length} chains (harmless: the peers link them).`,
    );
  await confirm("\nThis creates the BZPX contract on the chains above (spends ETH for gas).", "DEPLOY");
  for (const p of plan) {
    console.log(`\n${p.name}: sending deploy...`);
    // write BEFORE sending: if the RPC drops midway, the next run finds the contract instead of deploying another
    const e0 = readAddresses();
    e0[p.name] = { pending: { expectedAddress: p.expectedAddress, nonce: p.nonce, at: new Date().toISOString() } };
    writeAddresses(e0);
    const ct = await p.f.deploy(p.c.cfg.endpoint, w.address, { nonce: p.nonce });
    const txd = ct.deploymentTransaction();
    e0[p.name].pending.tx = txd.hash;
    writeAddresses(e0);
    const r = await waitTx(Promise.resolve(txd), "deploy");
    const a = await ct.getAddress();
    if (!eq(a, p.expectedAddress)) throw new Error(`${p.name}: address ${a} != expected ${p.expectedAddress}`);
    await record(p.name, p.c, w, a, r.hash, r.blockNumber);
  }
  console.log(`\naddresses written to ${ADDRESSES}. Next: ./bzpx.sh wire`);
}

/// Checks the freshly created contract and writes it to addresses.json (only if it checks out).
async function record(name, c, w, a, txHash, block) {
  const main = c.cfg.chainId === NETWORK.mainChainId;
  const t = new ethers.Contract(a, ART.abi, c.provider);
  const [nm, sym, ts, bal, own, del, epAddr] = await Promise.all([
    t.name(),
    t.symbol(),
    t.totalSupply(),
    t.balanceOf(w.address),
    t.owner(),
    c.ep.delegates(a),
    t.endpoint(),
  ]);
  const expectedSupply = main ? SUPPLY : 0n;
  const ok =
    nm === "Blaze Phoenix" &&
    sym === "BZPX" &&
    ts === expectedSupply &&
    bal === expectedSupply &&
    eq(own, w.address) &&
    eq(del, w.address) &&
    eq(epAddr, c.cfg.endpoint);
  if (!ok) throw new Error(`${name}: the contract at ${a} does not check out (see below); do NOT continue without understanding why. ${JSON.stringify({ nm, sym, ts: String(ts), bal: String(bal), own, del, epAddr })}`);
  const addrs2 = readAddresses();
  addrs2[name] = {
    address: a,
    tx: txHash,
    block,
    chainId: c.cfg.chainId,
    eid: c.cfg.eid,
    owner: w.address,
    at: new Date().toISOString(),
  };
  writeAddresses(addrs2);
  fs.appendFileSync(LOG, `${new Date().toISOString()} deploy ${name} ${a} tx ${txHash} owner ${w.address}\n`);
  console.log(`  ${name}: BZPX at ${a}  supply ${fmt(ts)}  check OK`);
  const args = coder.encode(["address", "address"], [c.cfg.endpoint, w.address]);
  console.log(`  constructor arguments (to verify the code on the explorer): ${args}`);
}

async function wire() {
  const w = readKey();
  const addrs = readAddresses();
  for (const n of ORDER) if (!addrs[n]?.address) throw new Error(`missing deploy on ${n}`);
  const plans = [];
  for (const name of ORDER) {
    const c = await chain(name);
    const signer = new ethers.NonceManager(w.connect(c.provider)); // local nonce: several txs in a row without depending on the RPC
    const t = new ethers.Contract(addrs[name].address, ART.abi, signer);
    const ep = c.ep.connect(signer);
    const oapp = addrs[name].address;
    const [own, del] = await Promise.all([t.owner(), c.ep.delegates(oapp)]);
    if (!eq(own, w.address) || !eq(del, w.address))
      throw new Error(`${name}: owner ${own} / delegate ${del} are not this wallet; cannot configure`);
    const oappItems = evaluateOApp(await readOApp(t));
    const otxs = [];
    if (!oappItems.msgInspector) otxs.push(["setMsgInspector(0)", () => t.setMsgInspector(ethers.ZeroAddress)]);
    if (!oappItems.preCrime) otxs.push(["setPreCrime(0)", () => t.setPreCrime(ethers.ZeroAddress)]);
    if (otxs.length) {
      console.log(`\n== ${name}: ${otxs.length} transactions (OApp state)`);
      for (const [d] of otxs) console.log(`   - ${d}`);
    }
    plans.push({ name, c, t, txs: otxs, remName: null });
    for (const remName of others(name)) {
      const rem = NETWORK.chains[remName];
      const { expected: e, items } = await readConfig(c, t, remName, addrs[remName].address);
      const txs = [];
      if (!items.sendLib) txs.push(["setSendLibrary", () => ep.setSendLibrary(oapp, rem.eid, c.cfg.sendLib)]);
      if (!items.receiveLib) txs.push(["setReceiveLibrary", () => ep.setReceiveLibrary(oapp, rem.eid, c.cfg.receiveLib, 0)]);
      const send = [];
      if (!items.executor) send.push([rem.eid, CFG_EXECUTOR, coder.encode(["tuple(uint32,address)"], [e.exec])]);
      if (!items.ulnSend) send.push([rem.eid, CFG_ULN, coder.encode([ULN_T], [e.sendUln])]);
      if (send.length) txs.push(["setConfig(send: executor/DVNs/confirmations)", () => ep.setConfig(oapp, c.cfg.sendLib, send)]);
      if (!items.ulnReceive)
        txs.push([
          "setConfig(receive: DVNs/confirmations)",
          () => ep.setConfig(oapp, c.cfg.receiveLib, [[rem.eid, CFG_ULN, coder.encode([ULN_T], [e.recvUln])]]),
        ]);
      const opts = [];
      if (!items.gasEnforced) opts.push([rem.eid, MSG_SEND, e.opts[MSG_SEND]]);
      if (!items.gasEnforcedCompose) opts.push([rem.eid, MSG_SEND_AND_CALL, e.opts[MSG_SEND_AND_CALL]]); // OFT-01
      if (opts.length) txs.push([`setEnforcedOptions(lzReceive gas, msgType ${opts.map((o) => o[1]).join("+")})`, () => t.setEnforcedOptions(opts)]);
      // the peer goes last: the path only opens once the whole config is set
      if (!items.peer) txs.push(["setPeer", () => t.setPeer(rem.eid, b32(addrs[remName].address))]);
      const balance = await c.provider.getBalance(w.address);
      console.log(`\n== ${name} -> ${remName}: ${txs.length} transactions (balance ${ethers.formatEther(balance)} ETH)`);
      console.log(`   DVNs ${c.cfg.dvnNames.join(" + ")}; send confirmations ${c.cfg.confirmations}, receive ${rem.confirmations}; lzReceive gas ${NETWORK.lzReceiveGas}`);
      for (const [d] of txs) console.log(`   - ${d}`);
      plans.push({ name, c, t, txs, remName });
    }
  }
  if (plans.every((p) => p.txs.length === 0)) return console.log("\neverything is already wired.");
  const nDirs = plans.filter((p) => p.remName).length;
  await confirm(`\nThis sets the LayerZero config and wires the ${nDirs} directions.`, "WIRE");
  for (const p of plans) {
    if (p.txs.length === 0) continue;
    console.log(`\n${p.name}${p.remName ? " -> " + p.remName : ""}:`);
    for (const [d, f] of p.txs) await waitTx(f(), d);
  }
  let ok = true;
  for (const p of plans) {
    const items = p.remName ? (await readConfig(p.c, p.t, p.remName, addrs[p.remName].address)).items : evaluateOApp(await readOApp(p.t));
    for (const [k, v] of Object.entries(items)) {
      if (!v) {
        ok = false;
        console.log(`${p.name}${p.remName ? " -> " + p.remName : ""}: MISSING ${k}`);
      }
    }
  }
  if (!ok) throw new Error("after wire the config still does not check out");
  console.log(`\nwired and checked on the ${nDirs} directions. Next: ./bzpx.sh send base 1 <chain> (and the return from each chain)`);
}

async function send(args) {
  const [source, amount, a3, a4] = args;
  if (!ORDER.includes(source) || !amount) throw new Error(`usage: send <${ORDER.join("|")}> <amount in BZPX> [destination chain] [recipient]`);
  // 3rd argument 0x… = address (old 2-chain form); default chain: the 1st of the order, or the 2nd if the source is the 1st
  const remName = a3 && !a3.startsWith("0x") ? a3 : source === ORDER[0] ? ORDER[1] : ORDER[0];
  const recipient = a3 && a3.startsWith("0x") ? a3 : a4;
  if (!ORDER.includes(remName) || remName === source) throw new Error(`invalid destination chain: ${remName}`);
  const w = readKey();
  const addrs = readAddresses();
  if (!addrs[source]?.address || !addrs[remName]?.address) throw new Error("missing deploy on one of the chains");
  const c = await chain(source);
  const signer = new ethers.NonceManager(w.connect(c.provider));
  const t = new ethers.Contract(addrs[source].address, ART.abi, signer);
  const value = ethers.parseUnits(amount, 18);
  const noDust = value - (value % DUST);
  if (noDust === 0n) throw new Error("amount below 0.000001 BZPX");
  const to = recipient ? ethers.getAddress(recipient) : w.address;
  const balance = await t.balanceOf(w.address);
  if (balance < value) throw new Error(`insufficient BZPX balance: ${fmt(balance)}`);
  const param = [NETWORK.chains[remName].eid, b32(to), value, noDust, "0x", "0x", "0x"];
  const [nativeFee] = await t.quoteSend(param, false);
  console.log(`${source} -> ${remName}: ${fmt(noDust)} BZPX to ${to}`);
  console.log(`LayerZero fee: ${ethers.formatEther(nativeFee)} ETH (+ transaction gas)`);
  if (noDust !== value) console.log(`(${fmt(value - noDust)} BZPX of dust below 6 decimals stays in the wallet)`);
  await confirm("", "SEND");
  const r = await waitTx(t.send(param, [nativeFee, 0n], w.address, { value: nativeFee }), "send");
  fs.appendFileSync(LOG, `${new Date().toISOString()} send ${source}->${remName} ${fmt(noDust)} tx ${r.hash}\n`);
  console.log(`track: https://layerzeroscan.com/tx/${r.hash}\n       (API: https://scan.layerzero-api.com/v1/messages/tx/${r.hash})`);
}

/// Renounce gate: reads the N·(N−1) directions (6 chains: 30) and each chain's OApp state (msgInspector, preCrime,
/// parked queue) and
/// returns the faults; empty only if all conform, including msgType 1 AND 2 enforcedOptions. A partial renounce would
/// freeze the mesh forever.
async function renounceGate(addrs) {
  const results = new Map();
  const reads = new Map();
  const oapp = new Map();
  const faults = [];
  const chains = {};
  for (const name of ORDER) {
    if (!addrs[name]?.address) {
      faults.push(`${name}: no deploy recorded`);
      continue;
    }
    chains[name] = await chain(name);
    const t = new ethers.Contract(addrs[name].address, ART.abi, chains[name].provider);
    oapp.set(name, gateOApp(await readOApp(t)));
    for (const remName of others(name)) {
      if (!addrs[remName]?.address) continue; // the direction stays "not read" in the gate
      const { items, read } = await readConfig(chains[name], t, remName, addrs[remName].address);
      results.set(`${name}>${remName}`, items);
      reads.set(`${name}>${remName}`, read);
    }
  }
  return { faults: faults.concat(meshGate(results, ORDER, oapp), coherence(NETWORK, ORDER, reads)), chains };
}

async function renounce(args) {
  const execute = args[0] === "--execute";
  if (args.length && !execute) throw new Error("usage: renounce [--execute]");
  const addrs = readAddresses();
  const { faults, chains } = await renounceGate(addrs);
  const n = directions(ORDER).length;
  if (faults.length) {
    for (const f of faults) console.log(`  MISSING ${f}`);
    throw new Error(`renounce gate: ${faults.length} fault(s) on the ${n} directions. After renouncing nothing can be fixed. Run wire first.`);
  }
  console.log(`renounce gate: the ${n} directions check out (libs, executor, DVNs, confirmations, msgType 1 and 2 gas, peers; msgInspector, preCrime; empty parked queue).`);
  if (!execute) return console.log("read-only: nothing was sent. Renouncing only runs with: renounce --execute");
  const w = readKey();
  const targets = [];
  for (const name of ORDER) {
    const c = chains[name];
    const signer = new ethers.NonceManager(w.connect(c.provider)); // local nonce: several txs in a row without depending on the RPC
    const t = new ethers.Contract(addrs[name].address, ART.abi, signer);
    const [own, del] = await Promise.all([t.owner(), c.ep.delegates(addrs[name].address)]);
    if (own === ethers.ZeroAddress && del === ethers.ZeroAddress) {
      console.log(`${name}: already renounced.`);
      continue;
    }
    if (!eq(own, w.address)) throw new Error(`${name}: owner ${own} is not this wallet`);
    targets.push({ name, c, t, del });
  }
  if (targets.length === 0) return console.log("nothing to do.");
  console.log(`
WHAT IS LOST FOREVER (on the chains: ${targets.map((a) => a.name).join(", ")}):
 - nobody can change peers, DVNs, confirmations, executor, libraries, gas, msgInspector or preCrime again;
 - if a chosen DVN stops working or LayerZero discontinues the pinned ULN302 library, transfers between chains
   can stay stuck forever (tokens already received remain normal on each chain);
 - there is no way to pause, nor to fix a config mistake;
 - with delegate 0 nobody burns a parked packet (burnParked reverts): a credit forged by a compromised DVN
   can only be claimed after releaseAt, with no possible reaction;
 - a packet parked from a sender that is no longer the peer is never credited (claimParked re-reads the peer)
   nor burned: this is why the gate refuses while any chain has a parked packet.
What is NOT lost: the tokens, and transfers between chains while the DVNs and the executor work.
Do this only after a test send has arrived on each of the ${n} directions.`);
  await confirm("", "RENOUNCE FOREVER");
  for (const a of targets) {
    console.log(`\n${a.name}:`);
    if (a.del !== ethers.ZeroAddress) await waitTx(a.t.setDelegate(ethers.ZeroAddress), "setDelegate(0)");
    await waitTx(a.t.renounceOwnership(), "renounceOwnership");
    const [own, del] = await Promise.all([a.t.owner(), a.c.ep.delegates(addrs[a.name].address)]);
    const ok = own === ethers.ZeroAddress && del === ethers.ZeroAddress;
    fs.appendFileSync(LOG, `${new Date().toISOString()} renounce ${a.name} owner ${own} delegate ${del}\n`);
    console.log(`  owner ${own}  delegate ${del}  ${ok ? "RENOUNCED" : "DOES NOT CHECK OUT"}`);
    if (!ok) throw new Error(`${a.name}: the renounce does not check out`);
  }
}

// ------------------------------------------------------------------ main

const [cmd, ...args] = process.argv.slice(2);
const cmds = { status, deploy, wire, send: () => send(args), renounce: () => renounce(args) };
if (!cmds[cmd]) {
  console.error("usage: status | deploy | wire | send <source> <amount> [chain] [recipient] | renounce [--execute]");
  process.exit(64);
}
try {
  const r = await cmds[cmd]();
  rl?.close();
  process.exit(cmd === "status" && r === false ? 3 : 0);
} catch (e) {
  rl?.close();
  let errName = "";
  try {
    const d = e.data && new ethers.Interface(ART.abi).parseError(e.data);
    if (d) errName = ` = ${d.name}(${d.args.join(", ")})`;
  } catch {}
  console.error(`ERROR: ${e.shortMessage || e.message}${e.data ? " (revert data " + e.data + errName + ")" : ""}`);
  process.exit(1);
}
