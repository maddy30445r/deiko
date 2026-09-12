// ─────────────────────────────────────────────────────────────────────────────
// THE RELAY ON LAMBDA
//
// A thin adapter over `relay.mjs`, which holds every decision. Lambda is a good
// fit for this service specifically because it scales to ZERO — a container
// platform bills for provisioned memory while nobody is recording, and the
// service is idle most of the day by design.
//
// Function URL, not API Gateway: one fewer resource, one fewer bill, and the
// 6MB request cap is far above the 0.76MB a 25-second audio chunk actually
// weighs. Auth is `NONE` at the URL and a bearer check in `relay.mjs` — IAM
// auth would mean signing requests from the app, which means AWS credentials
// on every user's Mac.
// ─────────────────────────────────────────────────────────────────────────────

import { handle, bearerFrom, logLine } from "./relay.mjs";

export async function handler(event) {
  const started = Date.now();

  const method = event?.requestContext?.http?.method ?? "GET";
  const path = event?.rawPath ?? "/";
  // Lambda lower-cases header names for Function URLs, but not every invoker
  // does; check both rather than depend on it.
  const headers = event?.headers ?? {};
  const authorization = headers.authorization ?? headers.Authorization;
  const contentType = headers["content-type"] ?? headers["Content-Type"] ?? "";
  const token = bearerFrom(authorization);

  // Binary bodies arrive base64-encoded. The audio is binary, so getting this
  // wrong would corrupt every upload while leaving the JSON routes working —
  // a failure that passes a smoke test and fails every real session.
  const body = event?.body
    ? Buffer.from(event.body, event.isBase64Encoded ? "base64" : "utf8")
    : null;

  let result;
  try {
    result = await handle({ method, path, token, contentType, body });
  } catch (err) {
    // THE REASON GOES TO CLOUDWATCH, NOT TO THE CALLER. `unavailable()` was
    // taught this for the metering paths and this catch-all was not: anything
    // that threw past `handle` — an AWS SDK error naming the table and its
    // ARN — went straight into the body of a public endpoint. A direct
    // invoker could read the log line too, so the split matters either way.
    console.error(`unhandled: ${String(err?.stack ?? err?.message ?? err)}`);
    result = {
      status: 500,
      body: JSON.stringify({ error: "internal error" }),
      contentType: "application/json",
    };
  }

  console.log(logLine({
    method, path, status: result.status, ms: Date.now() - started, token,
  }));

  return {
    statusCode: result.status,
    headers: { "content-type": result.contentType },
    body: result.body,
  };
}
