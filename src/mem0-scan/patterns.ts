// Patterns for credentials that should never sit in a mem0 memory.
//
// The scan is a backstop, not a guarantee: it finds secrets with a
// recognisable shape or a nearby keyword. A short human-chosen password in a
// plain sentence, with no keyword next to it, will not be found.

export interface Finding {
  rule: string;
  /** First few characters of the match, for a human to recognise it. Never the whole value. */
  hint: string;
}

interface Rule {
  name: string;
  re: RegExp;
  /** Capture group holding the secret value; 0 = whole match. */
  group: number;
}

// A value that follows a credential keyword: at least 8 characters, not a
// sentence word. Kept loose on purpose; plausible() filters the result.
const VALUE = String.raw`["'\x60]?([^\s"'\x60,;)\]}<>]{8,})`;

const RULES: Rule[] = [
  { name: "private-key", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g, group: 0 },
  { name: "github-token", re: /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b/g, group: 0 },
  { name: "slack-token", re: /\bxox[baprs]-[A-Za-z0-9-]{12,}\b/g, group: 0 },
  { name: "anthropic-key", re: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g, group: 0 },
  { name: "openai-key", re: /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b/g, group: 0 },
  { name: "stripe-key", re: /\b[sr]k_live_[A-Za-z0-9]{16,}\b/g, group: 0 },
  { name: "google-api-key", re: /\bAIza[0-9A-Za-z_-]{35}\b/g, group: 0 },
  { name: "mem0-key", re: /\bm0-[A-Za-z0-9]{20,}\b/g, group: 0 },
  { name: "tailscale-key", re: /\btskey-[a-z]+-[A-Za-z0-9-]{16,}\b/g, group: 0 },
  { name: "digitalocean-token", re: /\bdo[opr]_v1_[a-f0-9]{40,}\b/g, group: 0 },
  { name: "linear-key", re: /\blin_(?:api|oauth)_[A-Za-z0-9]{30,}\b/g, group: 0 },
  { name: "1password-token", re: /\bops_[A-Za-z0-9_-]{40,}\b/g, group: 0 },
  { name: "npm-token", re: /\bnpm_[A-Za-z0-9]{36}\b/g, group: 0 },
  { name: "sendgrid-key", re: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g, group: 0 },
  { name: "jwt", re: /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, group: 0 },
  { name: "bearer-token", re: /\b[Bb]earer\s+([A-Za-z0-9._~+\/-]{20,}=*)/g, group: 1 },
  { name: "url-password", re: /\b[a-z][a-z0-9+.-]*:\/\/[^\s:\/@]+:([^\s@\/]{6,})@/g, group: 1 },
  {
    // password: x / password=x / -Password x / --password x / "password is x"
    name: "password-keyword",
    re: new RegExp(
      String.raw`(?:pass(?:word|wd|phrase)?|pwd|secret|sipsecret)\b["']?\s*(?:[:=]|\bis\b|\bof\b)?\s*` + VALUE,
      "gi",
    ),
    group: 1,
  },
  {
    // auth token x / api key x / TWILIO_AUTH_TOKEN=x / client_secret: x
    name: "token-keyword",
    re: new RegExp(
      String.raw`(?:auth[ _-]?token|access[ _-]?token|refresh[ _-]?token|api[ _-]?key|secret[ _-]?key|client[ _-]?secret|[A-Z0-9]+_(?:TOKEN|SECRET|KEY))\b["']?\s*(?:[:=]|\bis\b)?\s*` +
        VALUE,
      "g",
    ),
    group: 1,
  },
];

const PLACEHOLDER = /redact|\*{3,}|x{4,}|\.{3}|example|placeholder|changeme|your[-_]|<[^>]*>|\$\{?[A-Za-z_]|not stored|1password/i;

/**
 * Whether a value picked up after a keyword looks like a real secret rather
 * than prose, a placeholder, a path or an identifier.
 */
export function plausible(value: string): boolean {
  if (PLACEHOLDER.test(value)) return false;
  if (/^(?:op|https?|file):\/\//i.test(value)) return false; // a reference, not a value
  if (/^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$/.test(value)) return false; // an environment variable name
  if (/[\/\\]/.test(value) && !/^[A-Za-z0-9+\/=]{20,}$/.test(value)) return false; // a path
  const hasDigit = /\d/.test(value);
  const hasLower = /[a-z]/.test(value);
  const hasUpper = /[A-Z]/.test(value);
  const hasSymbol = /[^A-Za-z0-9]/.test(value);
  if (/^[0-9a-f]{32,}$/i.test(value)) return true; // long hex
  if (!hasDigit) return false; // plain words and identifiers
  // Mixed enough to be generated or deliberately chosen.
  return [hasLower, hasUpper, hasSymbol].filter(Boolean).length >= 2 || value.length >= 20;
}

function hint(value: string): string {
  return `${value.slice(0, 4)}... (${value.length} chars)`;
}

/** Scan one memory's text. Returns at most one finding per rule. */
export function scanText(text: string): Finding[] {
  const out: Finding[] = [];
  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    for (const m of text.matchAll(rule.re)) {
      const value = m[rule.group] ?? m[0];
      const keyworded = rule.name.endsWith("-keyword") || rule.name === "url-password";
      if (keyworded && !plausible(value)) continue;
      out.push({ rule: rule.name, hint: hint(value) });
      break;
    }
  }
  return out;
}
