// LOCAL REHEARSAL only: delivers the last LayerZero message sent from <source> to the other chain, between two anvil
// forks, acting as the DVNs (anvil_impersonateAccount) and as the executor. Refuses any RPC that is not 127.0.0.1 / localhost.
// Usage: RPC_BASE=http://127.0.0.1:P1 RPC_ROBINHOOD=http://127.0.0.1:P2 node deliver.mjs <base|robinhood>
import fs from "node:fs";
import { ethers } from "ethers";

const NETWORK = JSON.parse(fs.readFileSync(new URL("../../config/network.json", import.meta.url), "utf8"));
const source = process.argv[2];
if (!["base", "robinhood"].includes(source)) throw new Error("usage: deliver.mjs <base|robinhood>");
const dest = source === "base" ? "robinhood" : "base";
const url = (n) => (n === "base" ? process.env.RPC_BASE : process.env.RPC_ROBINHOOD) || "";
for (const n of [source, dest]) {
  const h = (() => {
    try {
      return new URL(url(n)).hostname;
    } catch {
      return "";
    }
  })();
  if (h !== "127.0.0.1" && h !== "localhost") throw new Error(`${n}: RPC is not local, refused`);
}
const src = NETWORK.chains[source];
const dst = NETWORK.chains[dest];
const pSrc = new ethers.JsonRpcProvider(url(source), undefined, { staticNetwork: true });
const pDst = new ethers.JsonRpcProvider(url(dest), undefined, { staticNetwork: true });

const topic = ethers.id("PacketSent(bytes,bytes,address)");
const lastBlock = await pSrc.getBlockNumber();
// only local fork blocks (after the fork block): anvil would request earlier ones from the remote RPC
const info = await pSrc.send("anvil_nodeInfo", []);
const forkBlock = Number(info?.forkConfig?.forkBlockNumber ?? lastBlock - 50);
const logs = await pSrc.getLogs({ address: src.endpoint, topics: [topic], fromBlock: forkBlock + 1, toBlock: lastBlock });
if (!logs.length) throw new Error("no recent PacketSent on the source chain");
const [packet, , lib] = ethers.AbiCoder.defaultAbiCoder().decode(["bytes", "bytes", "address"], logs[logs.length - 1].data);
if (lib.toLowerCase() !== src.sendLib.toLowerCase()) throw new Error(`send lib ${lib} != network.json`);
const b = ethers.getBytes(packet);
const header = ethers.hexlify(b.slice(0, 81));
const payload = b.slice(81);
const payloadHash = ethers.keccak256(payload);
const nonce = BigInt(ethers.hexlify(b.slice(1, 9)));
const srcEid = Number(BigInt(ethers.hexlify(b.slice(9, 13))));
const sender = ethers.hexlify(b.slice(13, 45));
const dstEid = Number(BigInt(ethers.hexlify(b.slice(45, 49))));
const receiver = ethers.getAddress(ethers.dataSlice(ethers.hexlify(b.slice(49, 81)), 12));
const guid = ethers.hexlify(payload.slice(0, 32));
const message = ethers.hexlify(payload.slice(32));
if (srcEid !== src.eid || dstEid !== dst.eid) throw new Error("packet eids do not match");
console.log(`packet nonce ${nonce} ${source}(${srcEid}) -> ${dest}(${dstEid}) receiver ${receiver}`);

const uln = new ethers.Interface([
  "function verify(bytes,bytes32,uint64)",
  "function commitVerification(bytes,bytes32)",
]);
const ep = new ethers.Interface([
  "function lzReceive((uint32,bytes32,uint64),address,bytes32,bytes,bytes) payable",
  "event PacketDelivered((uint32,bytes32,uint64) origin, address receiver)",
]);
for (const dvn of dst.dvns) {
  await pDst.send("anvil_impersonateAccount", [dvn]);
  await pDst.send("anvil_setBalance", [dvn, "0xde0b6b3a7640000"]);
  const s = await pDst.getSigner(dvn);
  const tx = await s.sendTransaction({ to: dst.receiveLib, data: uln.encodeFunctionData("verify", [header, payloadHash, src.confirmations]) });
  await tx.wait();
  await pDst.send("anvil_stopImpersonatingAccount", [dvn]);
  console.log(`  DVN ${dvn} verify OK`);
}
const anyone = await pDst.getSigner(0); // anvil test account: commit and lzReceive are permissionless
await (await anyone.sendTransaction({ to: dst.receiveLib, data: uln.encodeFunctionData("commitVerification", [header, payloadHash]) })).wait();
console.log("  commitVerification OK");
const calldata = ep.encodeFunctionData("lzReceive", [[srcEid, sender, nonce], receiver, guid, message, "0x"]);
// minimum execution gas of endpoint.lzReceive (= what the executor must supply): estimateGas minus the intrinsic cost
const est = await pDst.estimateGas({ from: await anyone.getAddress(), to: dst.endpoint, data: calldata });
let intrinsic = 21000n;
for (const x of ethers.getBytes(calldata)) intrinsic += x === 0 ? 4n : 16n;
console.log(`  estimateGas ${est}  intrinsic ${intrinsic}  minimum execution ≈ ${est - intrinsic}  (enforced ${NETWORK.lzReceiveGas})`);
const tx = await anyone.sendTransaction({ to: dst.endpoint, data: calldata, gasLimit: BigInt(NETWORK.lzReceiveGas) + 60000n });
const r = await tx.wait();
const delivered = r.logs.some((l) => l.topics[0] === ep.getEvent("PacketDelivered").topicHash);
console.log(`  lzReceive ${r.status === 1 && delivered ? "DELIVERED" : "FAILED"} gasUsed(tx) ${r.gasUsed}`);
if (!(r.status === 1 && delivered)) process.exit(1);
