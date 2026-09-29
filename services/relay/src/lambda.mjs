// The relay on Lambda: a thin adapter over `relay.mjs`, which holds every
// decision.
//
// It sits behind a Function URL rather than API Gateway; the 6MB request cap is
// far above a 25-second audio chunk. Auth is `NONE` at the URL with a bearer
// check in `relay.mjs`, since IAM auth would need AWS credentials on every
// user's Mac.

import { handle, bearerFrom, logLine } from "./relay.mjs";

export async function handler(event) {
  const started = Date.now();

  const method = event?.requestContext?.http?.method ?? "GET";
  const path = event?.rawPath ?? "/";
  const query = event?.rawQueryString ?? "";
  // Lambda lower-cases header names for Function URLs, but not every invoker
  // does; check both rather than depend on it.
  const headers = event?.headers ?? {};
  const authorization = headers.authorization ?? headers.Authorization;
  const contentType = headers["content-type"] ?? headers["Content-Type"] ?? "";
  const token = bearerFrom(authorization);
  const origin = headers.origin ?? headers.Origin ?? "";
  // Function URLs put the caller here, and only the URL may invoke this
  // function (deploy.sh scopes the grant), so it is the real peer rather than a
  // field a direct invoker wrote. Used only as a salted hash, to ration
  // playground tickets and text calls per caller.
  const ip = event?.requestContext?.http?.sourceIp ?? "";

  // Binary bodies arrive base64-encoded. Getting this wrong corrupts audio
  // uploads while the JSON routes keep working.
  const body = event?.body
    ? Buffer.from(event.body, event.isBase64Encoded ? "base64" : "utf8")
    : null;

  let result;
  try {
    result = await handle({ method, path, query, token, contentType, body, origin, ip });
  } catch (err) {
    // The reason goes to CloudWatch, not to the caller: anything that throws
    // past `handle` (an AWS SDK error can name the table and its ARN) must not
    // reach the body of a public endpoint.
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
    // `result.headers` is how the playground returns its CORS headers; every
    // other route sets none and this spreads nothing.
    headers: { "content-type": result.contentType, ...(result.headers ?? {}) },
    body: result.body,
  };
}
