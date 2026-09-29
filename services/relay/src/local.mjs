#!/usr/bin/env node
// The relay on this machine, metering into memory.
//
//   node services/relay/src/local.mjs          # what `make relay-dev` and
//                                          # `scripts/flow-check.sh` run
//
// `server.mjs` alone meters into the real `deiko-usage` table whenever AWS
// credentials are present, spending the live relay's daily allowances. This
// starts a DynamoDB that lives in a Map and points the SDK at it through
// `AWS_ENDPOINT_URL_DYNAMODB` (the same seam `test/metering.test.mjs` uses),
// then loads the relay unchanged. Nothing it counts outlives the process.
//
// Never deployed: `deploy.sh` packages its files by name.

import { createServer } from "node:http";

const rows = new Map();

function answer(target, body) {
  const key = body.Key?.subject?.S ?? body.Item?.subject?.S;
  if (target.endsWith("DescribeTable")) return { Table: { TableStatus: "ACTIVE" } };
  if (target.endsWith("UpdateItem")) {
    const row = rows.get(key) ?? {};
    row.audioSeconds = (row.audioSeconds ?? 0) + Number(body.ExpressionAttributeValues?.[":n"]?.N ?? 0);
    rows.set(key, row);
    return { Attributes: { audioSeconds: { N: String(row.audioSeconds) } } };
  }
  if (target.endsWith("GetItem")) {
    const row = rows.get(key);
    if (!row) return {};
    const Item = { subject: { S: key } };
    if (row.audioSeconds != null) Item.audioSeconds = { N: String(row.audioSeconds) };
    if (row.tier != null) Item.tier = { S: row.tier };
    if (row.checkedAt != null) Item.checkedAt = { N: String(row.checkedAt) };
    return { Item };
  }
  if (target.endsWith("PutItem")) {
    rows.set(key, { tier: body.Item?.tier?.S, checkedAt: Number(body.Item?.checkedAt?.N ?? 0) });
    return {};
  }
  throw new Error(`unexpected DynamoDB call: ${target}`);
}

const dynamo = createServer((req, res) => {
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    try {
      const out = answer(req.headers["x-amz-target"] ?? "", raw ? JSON.parse(raw) : {});
      res.writeHead(200, { "content-type": "application/x-amz-json-1.0" });
      res.end(JSON.stringify(out));
    } catch (err) {
      res.writeHead(400, { "content-type": "application/x-amz-json-1.0" });
      res.end(JSON.stringify({ __type: "ValidationException", message: String(err.message) }));
    }
  });
});
await new Promise((r) => dynamo.listen(0, "127.0.0.1", r));
dynamo.unref();

// Before the relay loads: the SDK reads its endpoint and credentials from the
// environment, and these win over any profile in ~/.aws.
process.env.AWS_ENDPOINT_URL_DYNAMODB = `http://127.0.0.1:${dynamo.address().port}`;
process.env.AWS_ACCESS_KEY_ID = "local";
process.env.AWS_SECRET_ACCESS_KEY = "local";
delete process.env.AWS_SESSION_TOKEN;
delete process.env.AWS_PROFILE;
process.env.AWS_REGION ??= "ap-south-1";

await import("./server.mjs");
