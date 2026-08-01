#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// THE APP ICON, DRAWN FROM THE SAME MARK EVERYTHING ELSE WEARS
//
// The fovea is the point of the retina that sees detail, and the mark — a ring
// with a centred dot — is the product's whole thesis in one shape. The orb's
// coin draws it in SwiftUI, the menu bar draws it in Core Graphics, and this
// draws it into an `.icns`. Three renderers, one shape, because an icon that
// drifted from the coin would make the Dock and the orb look like two apps.
//
// Generated rather than designed in a tool, and committed as an `.icns`, so
// that `make bundle` needs nothing but a copy. Re-run `make icon` after
// changing the geometry below.
//
// No image library: PNG is a zlib stream plus four chunks, and everything here
// is circles. Coverage is computed analytically and supersampled, which gives
// cleaner edges at 16pt than any resampler would.
// ─────────────────────────────────────────────────────────────────────────────

import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";

// ── Geometry, as fractions of the canvas ────────────────────────────────────
//
// macOS icons are a rounded rectangle inset inside a transparent canvas — the
// system draws shadows in that margin, so filling the whole square makes an app
// look subtly larger and cheaper than every icon beside it.

const INSET = 0.098;        // Apple's macOS template: ~824/1024 content
const CORNER = 0.225;       // Apple's template: 185.4 radius on an 824 rect
const RING_OUTER = 0.245;   // the mark's ring, from the canvas centre
const RING_WIDTH = 0.046;
const DOT_RADIUS = 0.061;

// Indigo, the one hue the product owns. A vertical gradient rather than a flat
// fill, matching the coin's rim light.
const TOP = [0x5a, 0x6b, 0xc4];
const BOTTOM = [0x37, 0x44, 0x8c];
const MARK = [0xee, 0xf1, 0xff];

/// Coverage of a disc edge at a point, antialiased over roughly one pixel.
function edge(distance, radius, feather) {
  const t = (radius - distance) / feather;
  return Math.max(0, Math.min(1, t + 0.5));
}

/// Coverage of a rounded rectangle, by distance to its inner rectangle.
function roundedRectCoverage(x, y, left, top, right, bottom, radius, feather) {
  const cx = Math.min(Math.max(x, left + radius), right - radius);
  const cy = Math.min(Math.max(y, top + radius), bottom - radius);
  const dx = x - cx;
  const dy = y - cy;
  const distance = Math.hypot(dx, dy);
  return edge(distance, radius, feather);
}

/// Render the icon at `size`, supersampled `ss`× and box-filtered down.
function render(size, ss = 4) {
  const n = size * ss;
  const feather = 1.0; // in supersampled pixels
  const inset = n * INSET;
  const left = inset;
  const top = inset;
  const right = n - inset;
  const bottom = n - inset;
  const corner = (right - left) * CORNER;
  const centre = n / 2;
  const ringOuter = n * RING_OUTER;
  const ringInner = ringOuter - n * RING_WIDTH;
  const dot = n * DOT_RADIUS;

  // Accumulate straight into the final resolution: for each output pixel, sum
  // the ss×ss samples under it.
  const out = Buffer.alloc(size * size * 4);

  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < ss; sy++) {
        for (let sx = 0; sx < ss; sx++) {
          const x = px * ss + sx + 0.5;
          const y = py * ss + sy + 0.5;

          const plate = roundedRectCoverage(x, y, left, top, right, bottom, corner, feather);
          if (plate <= 0) continue;

          // The plate's gradient.
          const t = (y - top) / (bottom - top);
          const pr = TOP[0] + (BOTTOM[0] - TOP[0]) * t;
          const pg = TOP[1] + (BOTTOM[1] - TOP[1]) * t;
          const pb = TOP[2] + (BOTTOM[2] - TOP[2]) * t;

          // The mark: an annulus plus a centred dot.
          const d = Math.hypot(x - centre, y - centre);
          const ring = Math.min(edge(d, ringOuter, feather), 1 - edge(d, ringInner, feather));
          const centreDot = edge(d, dot, feather);
          const mark = Math.min(1, ring + centreDot);

          r += (pr + (MARK[0] - pr) * mark) * plate;
          g += (pg + (MARK[1] - pg) * mark) * plate;
          b += (pb + (MARK[2] - pb) * mark) * plate;
          a += plate;
        }
      }
      const samples = ss * ss;
      const i = (py * size + px) * 4;
      // Straight (non-premultiplied) alpha: divide the colour by its own
      // coverage, or the edges darken toward black.
      const cov = a || 1;
      out[i] = Math.round(r / cov);
      out[i + 1] = Math.round(g / cov);
      out[i + 2] = Math.round(b / cov);
      out[i + 3] = Math.round((a / samples) * 255);
    }
  }
  return out;
}

// ── PNG ─────────────────────────────────────────────────────────────────────

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function png(size, rgba) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;  // bit depth
  header[9] = 6;  // RGBA
  // 10–12: deflate, adaptive filtering, no interlace — all zero.

  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ── Emit the iconset ────────────────────────────────────────────────────────

const outDir = process.argv[2];
if (!outDir) {
  console.error("usage: node scripts/make-icon.mjs <Fovea.iconset>");
  process.exit(2);
}

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

// The names `iconutil` expects. Each logical size twice: at 1× and at 2×.
const wanted = [
  [16, "icon_16x16.png"], [32, "icon_16x16@2x.png"],
  [32, "icon_32x32.png"], [64, "icon_32x32@2x.png"],
  [128, "icon_128x128.png"], [256, "icon_128x128@2x.png"],
  [256, "icon_256x256.png"], [512, "icon_256x256@2x.png"],
  [512, "icon_512x512.png"], [1024, "icon_512x512@2x.png"],
];

// Rendered once per distinct pixel size — `icon_32x32.png` and
// `icon_16x16@2x.png` are the same 32px image under two names.
const cache = new Map();
for (const [size, name] of wanted) {
  if (!cache.has(size)) cache.set(size, png(size, render(size)));
  writeFileSync(join(outDir, name), cache.get(size));
}

console.error(`✓ ${wanted.length} pngs → ${outDir}`);
