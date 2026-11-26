import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const folder = path.join(root, "data", "knowledge");
const manifest = JSON.parse(await readFile(path.join(folder, "manifest.json"), "utf8"));
if (manifest.companyId !== "harbor-it-services" || manifest.documents.length !== 8) {
  throw new Error("Only the eight approved Harbor documents may be compiled.");
}
const documents = await Promise.all(manifest.documents.map(async (entry) => {
  if (!/^hbr-[a-z0-9-]+$/.test(entry.docId)) throw new Error("Invalid corpus document identifier.");
  const content = (await readFile(path.join(folder, `${entry.docId}.md`), "utf8")).replaceAll("\r\n", "\n");
  return {
    docId: entry.docId,
    companyId: manifest.companyId,
    serviceId: entry.serviceId,
    title: entry.title,
    content,
    sourceRef: `knowledge/${entry.docId}.md`,
    docVersion: manifest.docVersion,
    contentHash: createHash("sha256").update(content, "utf8").digest("hex"),
    updatedAt: manifest.updatedAt,
  };
}));
if (new Set(documents.map((document) => document.docId)).size !== 8) throw new Error("Duplicate document identifier.");
await writeFile(path.join(folder, "search-documents.json"), `${JSON.stringify(documents, null, 2)}\n`);
console.log(`Compiled ${documents.length} synthetic Harbor documents; SHA-256 content digests included. No uploads.`);
