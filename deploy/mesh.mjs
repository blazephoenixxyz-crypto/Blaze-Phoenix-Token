// BZPX: pure logic of the N-chain mesh (no RPC, no key), shared by deploy.mjs and the tests (deploy/test).
//   directions(order)             all ordered pairs (loc, rem), loc != rem: N·(N−1) directions (6 chains: 30)
//   expected(loc, rem, gas)       config required for the path loc -> rem
//   evaluate(read, e, peer)       conforming / non-conforming items of ONE direction, from the raw reads
//   meshGate(results, order)      renounce gate: list of faults; empty only if all N·(N−1) directions conform
//   configAddresses(cfg)          every address the config pins on one chain, by role (libs, executor, DVNs)
//   codeFaults(name, cfg, codes)  one fault per pinned address without code (or never probed) on that chain
import { ethers } from "ethers";

export const MSG_SEND = 1; // OFTMsgCodec SEND
export const MSG_SEND_AND_CALL = 2; // SEND_AND_CALL (compose): without an enforced option a caller sets gas 1 (OFT-01)
export const NIL = 255; // no optional DVN (does not inherit from the default config)

export const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
export const b32 = (a) => ethers.zeroPadValue(ethers.getAddress(a), 32).toLowerCase();

export function directions(order) {
  const d = [];
  for (const loc of order) for (const rem of order) if (loc !== rem) d.push([loc, rem]);
  return d;
}

/// OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0): TYPE_3 | worker 1 | len 17 | LZRECEIVE 1 | uint128 gas
export function lzReceiveOptions(gas) {
  return ethers.solidityPacked(["uint16", "uint8", "uint16", "uint8", "uint128"], [3, 1, 17, 1, BigInt(gas)]).toLowerCase();
}

export function expected(loc, rem, gas) {
  const dvns = loc.dvns.map((a) => ethers.getAddress(a));
  for (let i = 1; i < dvns.length; i++)
    if (BigInt(dvns[i]) <= BigInt(dvns[i - 1])) throw new Error(`${loc.name}: dvns must be in ascending order`);
  const opts = lzReceiveOptions(gas);
  return {
    exec: [Number(loc.maxMessageSize), ethers.getAddress(loc.executor)],
    sendUln: [BigInt(loc.confirmations), dvns.length, NIL, 0, dvns, []],
    recvUln: [BigInt(rem.confirmations), dvns.length, NIL, 0, dvns, []],
    // the same lzReceive gas for SEND and SEND_AND_CALL: receiving a compose credits (or parks) and queues the compose
    opts: { [MSG_SEND]: opts, [MSG_SEND_AND_CALL]: opts },
  };
}

export function ulnEqual(a, b) {
  return (
    BigInt(a[0]) === BigInt(b[0]) &&
    Number(a[1]) === Number(b[1]) &&
    Number(a[2]) === Number(b[2]) &&
    Number(a[3]) === Number(b[3]) &&
    a[4].length === b[4].length &&
    a[4].every((x, i) => eq(x, b[4][i])) &&
    a[5].length === b[5].length &&
    a[5].every((x, i) => eq(x, b[5][i]))
  );
}

/// read = { isDefSend, curSend, curRecv, isDefRecv, execApp, sendUln, recvUln, opts: {1: bytes, 2: bytes}, peer }
export function evaluate(l, e, loc, remAddress) {
  return {
    sendLib: !l.isDefSend && eq(l.curSend, loc.sendLib),
    receiveLib: !l.isDefRecv && eq(l.curRecv, loc.receiveLib),
    executor: Number(l.execApp[0]) === e.exec[0] && eq(l.execApp[1], e.exec[1]),
    ulnSend: ulnEqual(l.sendUln, e.sendUln),
    ulnReceive: ulnEqual(l.recvUln, e.recvUln),
    gasEnforced: eq(l.opts[MSG_SEND], e.opts[MSG_SEND]),
    gasEnforcedCompose: eq(l.opts[MSG_SEND_AND_CALL], e.opts[MSG_SEND_AND_CALL]),
    peer: remAddress ? eq(l.peer, b32(remAddress)) : false,
  };
}

/// Config coherence (P2), independent of expected(): the same set of DVNs (by name) on every chain, one address per
/// name, and, per direction read, receive confirmations on loc <= send confirmations read on rem.
/// reads: Map "loc>rem" -> raw read (the one evaluate takes). A direction without a read pair is left to the gate ("not read").
export function coherence(network, order, reads = new Map()) {
  const faults = [];
  const names = (c) => [...c.dvnNames].sort().join(",");
  const ref = names(network.chains[order[0]]);
  for (const n of order) {
    const c = network.chains[n];
    if (new Set(c.dvnNames).size !== c.dvnNames.length || c.dvnNames.length !== c.dvns.length)
      faults.push(`${n}: dvnNames and dvns do not have one address per name`);
    if (names(c) !== ref) faults.push(`${n}: dvnNames ${names(c)} != ${ref} (${order[0]})`);
  }
  for (const [loc, rem] of directions(order)) {
    const r = reads.get(`${loc}>${rem}`);
    const s = reads.get(`${rem}>${loc}`);
    if (r && s && !(BigInt(r.recvUln[0]) <= BigInt(s.sendUln[0])))
      faults.push(`${loc} -> ${rem}: receive confirmations ${r.recvUln[0]} > send ${s.sendUln[0]} on ${rem}`);
  }
  return faults;
}

/// results: Map "loc>rem" -> items (from evaluate). Fault = a direction without a result or with a false item.
export function meshGate(results, order) {
  const faults = [];
  for (const [loc, rem] of directions(order)) {
    const items = results.get(`${loc}>${rem}`);
    if (!items) {
      faults.push(`${loc} -> ${rem}: not read`);
      continue;
    }
    const f = Object.entries(items).filter(([, v]) => v !== true).map(([k]) => k);
    if (f.length) faults.push(`${loc} -> ${rem}: ${f.join(", ")}`);
  }
  return faults;
}

/// Every address network.json pins on one chain, by role: what wire writes and the gate compares (expected/evaluate).
/// The gate compares the on-chain config with these same values, so it cannot tell whether they exist: codeFaults does.
export function configAddresses(cfg) {
  return [
    ["sendLib", cfg.sendLib],
    ["receiveLib", cfg.receiveLib],
    ["executor", cfg.executor],
    ...cfg.dvns.map((a, i) => [`dvn ${cfg.dvnNames[i]}`, a]),
  ];
}

/// codes: lower-case address -> eth_getCode result. An address never probed counts as without code (absent is not empty).
export function codeFaults(name, cfg, codes) {
  return configAddresses(cfg)
    .filter(([, a]) => {
      const code = codes[a.toLowerCase()];
      return !(typeof code === "string" && code.length > 2);
    })
    .map(([role, a]) => `${name}: ${role} ${a} has no code`);
}
