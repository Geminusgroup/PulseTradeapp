mkdir -p pulsetrade/pages/api pulsetrade/server pulsetrade/styles && cat > package.json <<'JSON'
{
  "name": "pulsetrade",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "next dev -p 3000",
    "build": "next build",
    "start": "next start -p 3000",
    "lint": "next lint"
  },
  "dependencies": {
    "next": "14.2.5",
    "react": "18.2.0",
    "react-dom": "18.2.0"
  },
  "devDependencies": {
    "@types/node": "^20.12.12",
    "@types/react": "^18.2.49",
    "@types/react-dom": "^18.2.18",
    "typescript": "^5.4.5",
    "eslint": "^8.57.0",
    "eslint-config-next": "14.2.5"
  }
}
JSON

cat > pulsetrade/tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["dom", "dom.iterable", "es2022"],
    "allowJs": false,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "baseUrl": "."
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx"],
  "exclude": ["node_modules"]
}
JSON

cat > pulsetrade/next.config.js <<'JS'
/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true
};
module.exports = nextConfig;
JS

cat > pulsetrade/pages/_app.tsx <<'TSX'
import type { AppProps } from "next/app";
import "@/styles/globals.css";

export default function App({ Component, pageProps }: AppProps) {
  return <Component {...pageProps} />;
}
TSX

cat > pulsetrade/pages/index.tsx <<'TSX'
import { useState } from "react";

export default function Home() {
  const [quotes, setQuotes] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);

  const fetchQuotes = async () => {
    setLoading(true);
    try {
      const resp = await fetch("/api/quotes-batch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ symbols: ["AAPL", "MSFT", "TSLA", "META", "AMZN"] })
      });
      const data = await resp.json();
      setQuotes(Object.values(data));
    } catch (e) {
      console.error("Refresh failed", e);
      alert("Failed to refresh prices.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="container">
      <div className="header">
        <div className="brand">
          <h1>PulseTrade</h1>
          <span className="badge">Demo</span>
        </div>
        <button className="btn" onClick={fetchQuotes} disabled={loading}>
          {loading ? "Refreshing..." : "Refresh Prices"}
        </button>
      </div>

      <div className="card">
        <h2>Watchlist</h2>
        <table className="table">
          <thead>
            <tr>
              <th>Symbol</th>
              <th>Price</th>
              <th>Change</th>
              <th>Label</th>
              <th>Source</th>
            </tr>
          </thead>
          <tbody>
            {quotes.map((q: any) => (
              <tr key={q.symbol}>
                <td>{q.symbol}</td>
                <td>{q.currentPrice ?? "--"}</td>
                <td className={(q.dayChange ?? 0) >= 0 ? "chg-pos" : "chg-neg"}>
                  {q.dayChange ?? "--"} {q.dayChangePercent != null ? `(${q.dayChangePercent.toFixed(2)}%)` : ""}
                </td>
                <td><span className="tag">{q.priceLabel || "--"}</span></td>
                <td className="dim">{q.source}</td>
              </tr>
            ))}
            {quotes.length === 0 && (
              <tr>
                <td colSpan={5} className="dim">Click “Refresh Prices” to load quotes.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
TSX

cat > pulsetrade/pages/api/quote.ts <<'TS'
import type { NextApiRequest, NextApiResponse } from "next";
import { getQuote } from "@/server/quotes";

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  try {
    const symbol = String(req.query.symbol || "").toUpperCase().trim();
    if (!symbol) return res.status(400).json({ error: "missing_symbol" });
    const q = await getQuote(symbol);
    return res.status(200).json(q);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message || "quote_failed" });
  }
}
TS

cat > pulsetrade/pages/api/quotes-batch.ts <<'TS'
import type { NextApiRequest, NextApiResponse } from "next";
import { getQuote } from "@/server/quotes";

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "method_not_allowed" });

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body) : req.body;
    const symbols: string[] = Array.from(new Set((body?.symbols || [])
      .map((s: string) => String(s || "").toUpperCase().trim())
      .filter(Boolean)));
    if (!symbols.length) return res.status(400).json({ error: "no_symbols" });

    const results = await Promise.all(symbols.map(s => getQuote(s)));
    const out: Record<string, any> = {};
    results.forEach((q) => out[q.symbol] = q);
    return res.status(200).json(out);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message || "batch_failed" });
  }
}
TS

cat > pulsetrade/server/quotes.ts <<'TS'
/**
 * server/quotes.ts
 * Server-only helpers for quotes with Polygon primary + Yahoo fallback,
 * market-hours aware, with simple in-memory caching.
 *
 * Set POLYGON_API_KEY in your Vercel Project → Settings → Environment Variables.
 */

type MarketPhase = "RTH" | "PRE" | "POST" | "CLOSED";
export type QuoteOut = {
  symbol: string;
  currentPrice: number | null;
  prevClose: number | null;
  dayChange: number | null;
  dayChangePercent: number | null;
  asOf: string | null;
  source: "polygon" | "yahoo" | "mixed";
  priceLabel: "Real-time" | "After hours" | "Official close";
  phase: MarketPhase;
  warning?: string;
  error?: string;
};

type CacheEntry<T> = { value: T; exp: number };
const cache = {
  lastTrade: new Map<string, CacheEntry<{ price: number | null; asOf: string | null }>>(),
  prevClose: new Map<string, CacheEntry<{ prevClose: number | null; asOf: string | null }>>(),
  marketStatus: { value: null as null | { isOpen: boolean; serverTimeISO: string | null }, exp: 0 }
};

const POLY = "https://api.polygon.io";
const safeNum = (n: any) => (Number.isFinite(+n) ? +n : null);
const nowMs = () => Date.now();

function getPolyKey(): string {
  const k = process.env.POLYGON_API_KEY || "";
  if (!k) throw new Error("server_missing_polygon_key");
  return k;
}

function toEastern(date = new Date()) {
  return new Date(date.toLocaleString("en-US", { timeZone: "America/New_York" }));
}
function isWeekdayEastern(d: Date) { const wd = d.getDay(); return wd >= 1 && wd <= 5; }
function getPhase(): MarketPhase {
  const et = toEastern();
  if (!isWeekdayEastern(et)) return "CLOSED";
  const hm = et.getHours() * 60 + et.getMinutes();
  if (hm >= 570 && hm < 960) return "RTH";   // 09:30–16:00 ET
  if (hm >= 240 && hm < 570) return "PRE";   // 04:00–09:30
  if (hm >= 960 && hm < 1200) return "POST"; // 16:00–20:00
  return "CLOSED";
}

async function httpJson(url: string) {
  const r = await fetch(url, { headers: { accept: "application/json" } });
  const text = await r.text();
  let j: any = null; try { j = text ? JSON.parse(text) : null; } catch {}
  if (!r.ok) {
    console.error("[httpJson error]", { url, status: r.status, body: text?.slice(0, 300) });
    throw new Error(j?.error || j?.message || `HTTP ${r.status}`);
  }
  return j;
}

async function polyMarketStatus(): Promise<{ isOpen: boolean; serverTimeISO: string | null }> {
  const t = nowMs();
  if (cache.marketStatus.value && cache.marketStatus.exp > t) return cache.marketStatus.value;
  try {
    const j = await httpJson(`${POLY}/v1/marketstatus/now?apiKey=${encodeURIComponent(getPolyKey())}`);
    const val = { isOpen: j?.market === "open", serverTimeISO: j?.serverTime || null };
    cache.marketStatus = { value: val, exp: t + 30_000 }; // 30s
    return val;
  } catch {
    const fallback = { isOpen: getPhase() === "RTH", serverTimeISO: null };
    cache.marketStatus = { value: fallback, exp: t + 15_000 };
    return fallback;
  }
}

async function polyLastTrade(symbol: string) {
  const key = symbol.toUpperCase();
  const t = nowMs();
  const hit = cache.lastTrade.get(key);
  if (hit && hit.exp > t) return hit.value;

  const j = await httpJson(`${POLY}/v2/last/trade/${encodeURIComponent(key)}?apiKey=${encodeURIComponent(getPolyKey())}`);
  const price = safeNum(j?.results?.p);
  const asOf = j?.results?.t ? new Date(j.results.t / 1e6).toISOString() : null;
  const ttl = getPhase() === "RTH" ? 3_000 : 30_000;
  const val = { price, asOf };
  cache.lastTrade.set(key, { value: val, exp: t + ttl });
  return val;
}

async function polyPrevClose(symbol: string) {
  const key = symbol.toUpperCase();
  const t = nowMs();
  const hit = cache.prevClose.get(key);
  if (hit && hit.exp > t) return hit.value;

  const j = await httpJson(`${POLY}/v2/aggs/ticker/${encodeURIComponent(key)}/prev?adjusted=true&apiKey=${encodeURIComponent(getPolyKey())}`);
  const r = Array.isArray(j?.results) ? j.results[0] : null;
  const prevClose = safeNum(r?.c);
  const asOf = r?.t ? new Date(r.t).toISOString() : null;
  const val = { prevClose, asOf };
  cache.prevClose.set(key, { value: val, exp: t + 12 * 60_000 }); // 12m
  return val;
}

async function yahooLatest(symbol: string) {
  const j = await httpJson(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=5d&interval=1m&_t=${Date.now()}`);
  const r = j?.chart?.result?.[0];
  const ts = r?.timestamp || [];
  const q = r?.indicators?.quote?.[0] || {};
  const closes = q?.close || [];
  let lastPrice: number | null = null;
  for (let i = closes.length - 1; i >= 0; i--) {
    const c = safeNum(closes[i]);
    if (c != null) { lastPrice = c; break; }
  }
  const prevClose = safeNum(r?.meta?.chartPreviousClose ?? r?.meta?.previousClose ?? null);
  const asOf = ts.length ? new Date(ts[ts.length - 1] * 1000).toISOString() : new Date().toISOString();
  return { lastPrice, prevClose, asOf };
}

function isStale(iso: string | null, maxAgeSec: number) {
  if (!iso) return true;
  return (Date.now() - new Date(iso).getTime()) / 1000 > maxAgeSec;
}

export async function getQuote(symbolIn: string) {
  const symbol = String(symbolIn || "").toUpperCase().trim();
  if (!symbol) return { symbol, currentPrice: null, prevClose: null, dayChange: null, dayChangePercent: null, asOf: null, source: "mixed", priceLabel: "Official close", phase: "CLOSED", error: "missing_symbol" };

  const phase = getPhase();
  const status = await polyMarketStatus();
  const isOpen = status.isOpen;

  try {
    const [lt, pc] = await Promise.all([polyLastTrade(symbol), polyPrevClose(symbol)]);
    let currentPrice: number | null = null;
    let priceLabel: "Real-time" | "After hours" | "Official close" = "Official close";
    let asOf = lt.asOf || pc.asOf || new Date().toISOString();
    let source: "polygon" | "yahoo" | "mixed" = "polygon";
    let warning: string | undefined;

    const freshTrade = lt.price != null && lt.asOf != null && !isStale(lt.asOf, phase === "RTH" ? 120 : 900);

    if (phase === "RTH" && isOpen) {
      if (freshTrade) {
        currentPrice = lt.price!;
        priceLabel = "Real-time";
      } else {
        const y = await yahooLatest(symbol);
        if (y.lastPrice != null) {
          currentPrice = y.lastPrice;
          asOf = y.asOf || asOf;
          source = "yahoo";
          warning = "polygon_trade_stale";
          priceLabel = "Real-time";
        } else {
          currentPrice = pc.prevClose ?? null;
          priceLabel = "Official close";
          warning = "fallback_prev_close";
        }
      }
    } else if (phase === "PRE" || phase === "POST") {
      if (freshTrade) {
        currentPrice = lt.price!;
        priceLabel = "After hours";
      } else {
        const y = await yahooLatest(symbol);
        if (y.lastPrice != null && y.asOf && !isStale(y.asOf, 900)) {
          currentPrice = y.lastPrice;
          asOf = y.asOf || asOf;
          source = "yahoo";
          warning = "polygon_ext_stale";
          priceLabel = "After hours";
        } else {
          currentPrice = pc.prevClose ?? null;
          priceLabel = "Official close";
          warning = "fallback_prev_close_ext";
        }
      }
    } else {
      currentPrice = pc.prevClose ?? null;
      priceLabel = "Official close";
    }

    const dayChange = (currentPrice != null && pc.prevClose != null) ? currentPrice - pc.prevClose : null;
    const dayChangePercent = (currentPrice != null && pc.prevClose != null && pc.prevClose !== 0)
      ? ((currentPrice - pc.prevClose) / pc.prevClose) * 100
      : null;

    return { symbol, currentPrice, prevClose: pc.prevClose ?? null, dayChange, dayChangePercent, asOf, source, priceLabel, phase, warning };
  } catch (e: any) {
    try {
      const y = await yahooLatest(symbol);
      const dayChange = (y.lastPrice != null && y.prevClose != null) ? y.lastPrice - y.prevClose : null;
      const dayChangePercent = (y.lastPrice != null && y.prevClose != null && y.prevClose !== 0)
        ? ((y.lastPrice - y.prevClose) / y.prevClose) * 100
        : null;
      return { symbol, currentPrice: y.lastPrice, prevClose: y.prevClose, dayChange, dayChangePercent, asOf: y.asOf, source: "yahoo", priceLabel: phase === "RTH" ? "Real-time" : (phase === "CLOSED" ? "Official close" : "After hours"), phase, warning: "polygon_failed_fallback_yahoo", error: e?.message };
    } catch (ee: any) {
      return { symbol, currentPrice: null, prevClose: null, dayChange: null, dayChangePercent: null, asOf: null, source: "mixed", priceLabel: "Official close", phase, error: `both_failed: ${e?.message} | ${ee?.message}` };
    }
  }
}
TS

cat > pulsetrade/styles/globals.css <<'CSS'
:root {
  --bg: #0b0f17;
  --panel: #111827;
  --muted: #94a3b8;
  --text: #e5e7eb;
  --accent: #60a5fa;
  --green: #22c55e;
  --red: #ef4444;
  --border: #1f2937;
}

* { box-sizing: border-box; }
html, body, #__next { height: 100%; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, "Helvetica Neue", Arial, "Apple Color Emoji", "Segoe UI Emoji";
}

.container { max-width: 1100px; margin: 0 auto; padding: 24px; }
.header { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 20px; }
.brand { display: flex; align-items: center; gap: 10px; }
.badge { font-size: 12px; padding: 3px 8px; border: 1px solid var(--border); border-radius: 999px; color: var(--muted); }

.card { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }

h1 { margin: 0; font-size: 28px; }
h2 { margin: 0 0 10px 0; font-size: 18px; color: var(--muted); }

.btn {
  background: var(--accent);
  color: black;
  border: none;
  border-radius: 8px;
  padding: 10px 14px;
  font-weight: 600;
  cursor: pointer;
}
.btn:disabled { opacity: 0.6; cursor: not-allowed; }

.table { width: 100%; border-collapse: collapse; }
.table th, .table td { padding: 10px 8px; border-bottom: 1px solid var(--border); text-align: left; }
.table th { color: var(--muted); font-weight: 600; font-size: 12px; letter-spacing: 0.05em; text-transform: uppercase; }

.tag { display: inline-block; font-size: 12px; padding: 3px 8px; border-radius: 999px; border: 1px solid var(--border); color: var(--muted); }

.chg-pos { color: var(--green); }
.chg-neg { color: var(--red); }
.dim { color: var(--muted); }
CSS

echo "✅ Created ./pulsetrade"
