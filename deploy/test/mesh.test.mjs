// Renounce gate over the N·(N−1) mesh (deploy/mesh.mjs), no RPC, no keys. Run: node --test deploy/test/
// Oracle: every "conforming read" below is built LITERALLY from config/network.json fields (and the LayerZero wire formats:
// UlnConfig tuple, OptionsBuilder type 3 bytes, bytes32 peer), never from expected(). A regression in expected() or
// evaluate() that would let a wrong config pass therefore turns these tests red instead of moving the oracle with it.
// One case per gate item; the mutant that each case kills is named in the test title (G1-G7: verifier set, P2a-c: coherence).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { MSG_SEND, MSG_SEND_AND_CALL, directions, expected, evaluate, meshGate, ulnEqual, coherence } from "../mesh.mjs";
import * as mesh from "../mesh.mjs"; // producers added after the first release: a missing export fails its test, not the file

const NETWORK = JSON.parse(fs.readFileSync(new URL("../../config/network.json", import.meta.url), "utf8"));
const ORDER = NETWORK.order;
const C = NETWORK.chains;
const ADDR = Object.fromEntries(ORDER.map((n, i) => [n, "0x" + String(i + 1).padStart(40, "0")]));
const NIL_DVN_COUNT = 255; // UlnBase.sol: type(uint8).max = no optional DVNs (0 would inherit the default ones)
const OTHER = "0x00000000000000000000000000000000000000ff";

// OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0): 0x0003 | worker 01 | size 0011 | type 01 | uint128 gas
const optsHex = (gas) => "0x0003" + "01" + "0011" + "01" + BigInt(gas).toString(16).padStart(32, "0");
const peerHex = (a) => "0x" + "0".repeat(24) + a.slice(2).toLowerCase();
const uln = (conf, dvns, o = {}) => {
  const u = [BigInt(conf), dvns.length, NIL_DVN_COUNT, 0, [...dvns], []];
  for (const [i, v] of Object.entries(o)) u[i] = v;
  return u;
};

// Conforming read of loc -> rem, literal from network.json: send side uses loc's confirmations, receive side (packets
// coming FROM rem) uses rem's confirmations, the DVNs are loc's own addresses, libs and executor are loc's.
function lit(loc, rem, o = {}) {
  const L = C[loc], R = C[rem];
  return {
    isDefSend: false, curSend: L.sendLib, curRecv: L.receiveLib, isDefRecv: false,
    execApp: [L.maxMessageSize, L.executor],
    sendUln: uln(L.confirmations, L.dvns),
    recvUln: uln(R.confirmations, L.dvns),
    opts: { [MSG_SEND]: optsHex(NETWORK.lzReceiveGas), [MSG_SEND_AND_CALL]: optsHex(NETWORK.lzReceiveGas) },
    peer: peerHex(ADDR[rem]),
    ...o,
  };
}
const reads = (mut = () => ({})) => new Map(directions(ORDER).map(([l, r]) => [`${l}>${r}`, lit(l, r, mut(l, r))]));
function itemsOf(ls) {
  const res = new Map();
  for (const [k, l] of ls) {
    const [loc, rem] = k.split(">");
    res.set(k, evaluate(l, expected(C[loc], C[rem], NETWORK.lzReceiveGas), C[loc], ADDR[rem]));
  }
  return res;
}
// per-chain OApp state, literal: network.json declares no msgInspector and no preCrime, so both must read as zero
const ZERO = "0x0000000000000000000000000000000000000000";
const oappRead = (o = {}) => ({ msgInspector: ZERO, preCrime: ZERO, parkedCount: 0n, ...o });
const oappItems = (mut = () => ({})) => new Map(ORDER.map((n) => [n, (mesh.evaluateOApp ?? (() => ({})))(oappRead(mut(n)))]));
// per-chain items the renounce gate reads (F1): OApp slots plus the parked queue
const gateItems = (mut = () => ({})) => new Map(ORDER.map((n) => [n, (mesh.gateOApp ?? (() => ({})))(oappRead(mut(n)))]));
// gate as deploy.mjs runs it: meshGate over the 30 directions and the per-chain OApp state, plus coherence over config and raw reads
const gate = (ls, net = NETWORK, oapp = oappItems()) => meshGate(itemsOf(ls), ORDER, oapp).concat(coherence(net, ORDER, ls));
const one = (L, R, o) => gate(reads((l, r) => (l === L && r === R ? o(l, r) : {})));

test("six chains give 30 directions", () => {
  assert.equal(ORDER.length, 6);
  assert.equal(directions(ORDER).length, 30);
});

test("literal network.json reads on all 30 directions pass the gate (G4, G6)", () => {
  assert.deepEqual(gate(reads()), []);
});

test("receive ULN: confirmations one above / one below the source's, or a foreign DVN, is refused (G1, G4)", () => {
  for (const [L, R] of directions(ORDER))
    for (const d of [1n, -1n])
      assert.deepEqual(one(L, R, () => ({ recvUln: uln(BigInt(C[R].confirmations) + d, C[L].dvns) })).filter((f) => !f.includes("receive confirmations")),
        [`${L} -> ${R}: ulnReceive`], `${L}>${R} ${d}`);
  const [L, R] = [ORDER[1], ORDER[0]];
  assert.deepEqual(one(L, R, () => ({ recvUln: uln(C[R].confirmations, [C[L].dvns[0], OTHER]) })), [`${L} -> ${R}: ulnReceive`]);
  assert.deepEqual(one(L, R, () => ({ recvUln: uln(C[R].confirmations, C[R].dvns) })), [`${L} -> ${R}: ulnReceive`]); // remote's DVN addresses
});

test("send ULN: confirmations off by one, a foreign DVN or requiredDVNCount 1 is refused (G5)", () => {
  const [L, R] = [ORDER[0], ORDER[1]];
  for (const d of [1n, -1n]) {
    const f = one(L, R, () => ({ sendUln: uln(BigInt(C[L].confirmations) + d, C[L].dvns) }));
    assert.equal(f[0], `${L} -> ${R}: ulnSend`, `${d}`);
  }
  assert.deepEqual(one(L, R, () => ({ sendUln: uln(C[L].confirmations, [OTHER, C[L].dvns[1]]) })), [`${L} -> ${R}: ulnSend`]);
  assert.deepEqual(one(L, R, () => ({ sendUln: uln(C[L].confirmations, C[L].dvns, { 1: 1 }) })), [`${L} -> ${R}: ulnSend`]);
});

test("executor: wrong address or maxMessageSize one off is refused (G2)", () => {
  const [L, R] = [ORDER[2], ORDER[3]];
  for (const execApp of [[C[L].maxMessageSize, OTHER], [C[L].maxMessageSize + 1, C[L].executor], [C[L].maxMessageSize - 1, C[L].executor], [0, C[L].executor]])
    assert.deepEqual(one(L, R, () => ({ execApp })), [`${L} -> ${R}: executor`], String(execApp));
});

test("receive library left on the default is refused even when the default is the configured library (G3)", () => {
  const [L, R] = [ORDER[4], ORDER[5]];
  assert.deepEqual(one(L, R, () => ({ isDefRecv: true })), [`${L} -> ${R}: receiveLib`]);
  assert.deepEqual(one(L, R, () => ({ curRecv: OTHER })), [`${L} -> ${R}: receiveLib`]);
  assert.deepEqual(one(L, R, () => ({ isDefSend: true })), [`${L} -> ${R}: sendLib`]);
});

test("receive confirmations above the remote's send confirmations are refused per direction, from raw reads (P2b)", () => {
  // both sides consistently wrong (rem sends with c, loc expects c+1): evaluate flags the drift, coherence names the cause
  for (const [L, R] of directions(ORDER)) {
    const c = BigInt(C[R].confirmations);
    const ls = reads((l, r) => (l === L && r === R ? { recvUln: uln(c + 1n, C[L].dvns) } : {}));
    assert.deepEqual(coherence(NETWORK, ORDER, ls), [`${L} -> ${R}: receive confirmations ${c + 1n} > send ${c} on ${R}`]);
  }
  // equal is the boundary that passes; one below on the receive side is not a coherence fault
  const ls = reads((l, r) => (l === ORDER[1] && r === ORDER[0] ? { recvUln: uln(BigInt(C[ORDER[0]].confirmations) - 1n, C[ORDER[1]].dvns) } : {}));
  assert.deepEqual(coherence(NETWORK, ORDER, ls), []);
});

test("optional DVNs: count 0 (inherits the default set), a listed optional DVN or threshold 1 is refused (G7)", () => {
  const [L, R] = [ORDER[3], ORDER[4]];
  for (const o of [{ 2: 0 }, { 2: 1, 5: [OTHER] }, { 3: 1 }, { 5: [OTHER] }]) {
    assert.deepEqual(one(L, R, () => ({ recvUln: uln(C[R].confirmations, C[L].dvns, o) })), [`${L} -> ${R}: ulnReceive`], JSON.stringify(o));
    assert.deepEqual(one(L, R, () => ({ sendUln: uln(C[L].confirmations, C[L].dvns, o) })), [`${L} -> ${R}: ulnSend`], JSON.stringify(o));
  }
  // list comparison is length-exact in both argument orders (the read may be shorter or longer than the expected config)
  const a = uln(1, [OTHER]), b = uln(1, [OTHER], { 5: [OTHER] });
  assert.equal(ulnEqual(a, b), false);
  assert.equal(ulnEqual(b, a), false);
  assert.equal(ulnEqual(uln(1, []), uln(1, [OTHER])), false);
  assert.equal(ulnEqual(uln(1, [OTHER]), uln(1, [OTHER])), true);
});

test("dvnNames must be the same set on every chain, one address per name (P2a, P2c)", () => {
  assert.deepEqual(coherence(NETWORK, ORDER), []); // network.json today: the same two operators everywhere (order follows addresses)
  const copy = (n, o) => ({ ...NETWORK, chains: { ...C, [n]: { ...C[n], ...o } } });
  const n = ORDER[5];
  const ref = [...C[ORDER[0]].dvnNames].sort().join(",");
  assert.deepEqual(coherence(copy(n, { dvnNames: ["layerzero-labs", "horizen"] }), ORDER), [`${n}: dvnNames horizen,layerzero-labs != ${ref} (${ORDER[0]})`]);
  assert.deepEqual(coherence(copy(n, { dvnNames: ["layerzero-labs", "layerzero-labs"] }), ORDER),
    [`${n}: dvnNames and dvns do not have one address per name`, `${n}: dvnNames layerzero-labs,layerzero-labs != ${ref} (${ORDER[0]})`]);
  assert.deepEqual(coherence(copy(n, { dvnNames: [...C[n].dvnNames, "horizen"] }), ORDER),
    [`${n}: dvnNames and dvns do not have one address per name`, `${n}: dvnNames horizen,layerzero-labs,nethermind != ${ref} (${ORDER[0]})`]);
  // and the gate as a whole refuses it even with every read conforming
  assert.equal(gate(reads(), copy(n, { dvnNames: ["layerzero-labs", "horizen"] })).length, 1);
});

test("each single direction without msgType 2 enforced options is refused, by name", () => {
  for (const [L, R] of directions(ORDER))
    assert.deepEqual(one(L, R, () => ({ opts: { [MSG_SEND]: optsHex(NETWORK.lzReceiveGas), [MSG_SEND_AND_CALL]: "0x" } })), [`${L} -> ${R}: gasEnforcedCompose`]);
});

test("enforced gas one below, one above, and msgType 1 missing are refused (G6)", () => {
  const g = BigInt(NETWORK.lzReceiveGas);
  const [L, R] = [ORDER[5], ORDER[4]];
  for (const [k, v, name] of [[MSG_SEND_AND_CALL, g - 1n, "gasEnforcedCompose"], [MSG_SEND_AND_CALL, g + 1n, "gasEnforcedCompose"], [MSG_SEND, g - 1n, "gasEnforced"], [MSG_SEND, 0n, "gasEnforced"]]) {
    const o = { [MSG_SEND]: optsHex(g), [MSG_SEND_AND_CALL]: optsHex(g) };
    o[k] = v === 0n ? "0x" : optsHex(v);
    assert.deepEqual(one(L, R, () => ({ opts: o })), [`${L} -> ${R}: ${name}`], `${k}/${v}`);
  }
});

test("a direction never read (chain without deploy) is refused", () => {
  const r = itemsOf(reads());
  r.delete(`${ORDER[3]}>${ORDER[2]}`);
  assert.deepEqual(meshGate(r, ORDER, oappItems()), [`${ORDER[3]} -> ${ORDER[2]}: not read`]);
});

test("wrong peer is refused", () => {
  const [L, R] = [ORDER[1], ORDER[2]];
  assert.deepEqual(one(L, R, () => ({ peer: peerHex(ADDR[ORDER[3]]) })), [`${L} -> ${R}: peer`]);
});

// F4: every address the config pins must have code on its chain. The roles below are written LITERALLY from network.json
// (not from configAddresses), so a role dropped from the producer turns its vector red. Mutants: M1 drop a role,
// M2 accept a never-probed address (`!== "0x"`).
const rolesOf = (n) => [
  ["sendLib", C[n].sendLib],
  ["receiveLib", C[n].receiveLib],
  ["executor", C[n].executor],
  ...C[n].dvns.map((a, i) => [`dvn ${C[n].dvnNames[i]}`, a]),
];
const CODE = "0x6080";

test("a pinned config address without code is refused by role, on every chain (F4)", () => {
  for (const n of ORDER) {
    const roles = rolesOf(n);
    const all = Object.fromEntries(roles.map(([, a]) => [a.toLowerCase(), CODE]));
    assert.deepEqual(mesh.codeFaults(n, C[n], all), [], `${n}: every address with code passes`);
    for (const [role, a] of roles) {
      const want = [`${n}: ${role} ${a} has no code`];
      assert.deepEqual(mesh.codeFaults(n, C[n], { ...all, [a.toLowerCase()]: "0x" }), want, `${n} ${role}: empty code`);
      const unprobed = { ...all };
      delete unprobed[a.toLowerCase()];
      assert.deepEqual(mesh.codeFaults(n, C[n], unprobed), want, `${n} ${role}: never probed`);
      assert.deepEqual(mesh.codeFaults(n, C[n], { ...all, [a.toLowerCase()]: null }), want, `${n} ${role}: null read`);
    }
    // every address at once: one fault per role, in role order
    assert.deepEqual(mesh.codeFaults(n, C[n], {}), roles.map(([role, a]) => `${n}: ${role} ${a} has no code`));
  }
});

test("the probed addresses cover every address that wire writes and the gate compares (F4 parity)", () => {
  for (const [L, R] of directions(ORDER)) {
    const probed = new Set(mesh.configAddresses(C[L]).map(([, a]) => a.toLowerCase()));
    const e = expected(C[L], C[R], NETWORK.lzReceiveGas);
    for (const a of [C[L].sendLib, C[L].receiveLib, e.exec[1], ...e.sendUln[4], ...e.recvUln[4], ...e.sendUln[5], ...e.recvUln[5]])
      assert.ok(probed.has(a.toLowerCase()), `${L}>${R}: ${a} is not probed`);
  }
  for (const n of ORDER) assert.deepEqual(mesh.configAddresses(C[n]), rolesOf(n), n);
});

// F2: owner-settable OApp slots outside the directions. Mutants: M1 evaluateOApp without msgInspector, M2 without
// preCrime, M3 meshGate skips a chain whose state was not read, M4 renounceGate does not pass the map (rehearsal).
test("an OApp slot no direction covers is refused: msgInspector, preCrime, and a chain never read (F2)", () => {
  assert.deepEqual(gate(reads(), NETWORK, oappItems()), [], "both zero on every chain passes");
  for (const n of ORDER) {
    const only = (o) => gate(reads(), NETWORK, oappItems((m) => (m === n ? o : {})));
    assert.deepEqual(only({ msgInspector: OTHER }), [`${n}: msgInspector`], `${n} inspector`);
    assert.deepEqual(only({ preCrime: OTHER }), [`${n}: preCrime`], `${n} preCrime`);
    assert.deepEqual(only({ msgInspector: OTHER, preCrime: OTHER }), [`${n}: msgInspector, preCrime`], `${n} both`);
    assert.deepEqual(only({ msgInspector: undefined }), [`${n}: msgInspector`], `${n} field missing`);
    const missing = oappItems();
    missing.delete(n);
    assert.deepEqual(gate(reads(), NETWORK, missing), [`${n}: OApp state not read`], `${n} never read`);
  }
  // no map at all: every chain is unread, the gate fails closed
  assert.equal(meshGate(itemsOf(reads()), ORDER).length, ORDER.length);
});

// F1: a parked packet whose sender stops being a peer can never be credited once the owner and delegate are gone.
// Mutants: J1 queueItems always true, J2 a count of the wrong type passes (typeof dropped), J3 renounceGate reads
// evaluateOApp instead of gateOApp (rehearsal only).
test("a parked packet on any chain refuses the renounce: count 1, count N, count never read (F1)", () => {
  assert.deepEqual(gate(reads(), NETWORK, gateItems()), [], "an empty queue on every chain passes");
  for (const n of ORDER) {
    const only = (o) => gate(reads(), NETWORK, gateItems((m) => (m === n ? o : {})));
    for (const c of [1n, 2n ** 64n, undefined, 0, "0", null]) {
      assert.deepEqual(only({ parkedCount: c }), [`${n}: parkedQueueEmpty`], `${n} parkedCount ${String(c)}`);
    }
    assert.deepEqual(only({ preCrime: OTHER, parkedCount: 1n }), [`${n}: preCrime, parkedQueueEmpty`], `${n} both kinds`);
  }
});

// Queue and peers read again after "RENOUNCE FOREVER" (CodeRabbit on PR 2): literal reads, one chain changed at a time.
const lateRead = (n, o = {}) => ({
  parkedCount: 0n,
  peers: Object.fromEntries(ORDER.filter((r) => r !== n).map((r) => [r, peerHex(ADDR[r])])),
  ...o,
});
const late = (mut = () => ({})) => new Map(ORDER.map((n) => [n, lateRead(n, mut(n))]));
const lateGateOf = (rs, addrs = ADDR) => (mesh.lateGate ?? (() => ["lateGate missing"]))(rs, ORDER, addrs);

test("after the confirmation, a parked packet, a moved peer or a value not read refuses the renounce (L1, L2, L3)", () => {
  assert.deepEqual(lateGateOf(late()), [], "unchanged reads pass");
  assert.deepEqual(lateGateOf(new Map()), [], "no target, nothing to refuse");
  for (const n of ORDER) {
    const only = (o) => lateGateOf(late((m) => (m === n ? o(m) : {})));
    for (const c of [1n, 2n ** 64n, undefined, 0, "0", null]) {
      assert.deepEqual(only(() => ({ parkedCount: c })), [`${n}: parkedQueueEmpty`], `${n} parkedCount ${String(c)}`);
    }
    for (const r of ORDER.filter((x) => x !== n)) {
      for (const [label, v] of [["moved", peerHex(OTHER)], ["removed", "0x" + "0".repeat(64)], ["not read", undefined]]) {
        const peers = { ...lateRead(n).peers, [r]: v };
        assert.deepEqual(only(() => ({ peers })), [`${n}: peer ${r}`], `${n} peer ${r} ${label}`);
      }
      const noAddr = { ...ADDR, [r]: undefined };
      assert.ok(lateGateOf(late(), noAddr).includes(`${n}: peer ${r}`), `${n} peer ${r} without a recorded address`);
    }
    assert.deepEqual(only(() => ({ peers: undefined })), [`${n}: ${ORDER.filter((x) => x !== n).map((r) => `peer ${r}`).join(", ")}`], `${n} peers not read`);
    assert.deepEqual(only(() => ({ parkedCount: 1n, peers: undefined })).length, 1, `${n} both kinds on one line`);
  }
});

test("deploy.mjs re-reads the queue and the peers between the confirmation and the first transaction (L4)", () => {
  const src = fs.readFileSync(new URL("../deploy.mjs", import.meta.url), "utf8");
  const from = src.indexOf('await confirm("", "RENOUNCE FOREVER")');
  assert.ok(from > 0, "confirmation not found");
  const to = src.indexOf("waitTx(", from);
  assert.ok(to > from, "no transaction after the confirmation");
  const window = src.slice(from, to);
  for (const needle of [".parkedCount()", ".peers(", "= lateGate(", "if (changed.length) throw new Error("]) {
    assert.ok(window.includes(needle), `missing between the confirmation and the first transaction: ${needle}`);
  }
});
