// Reads machine-written values from the 1Password runtime item.
//
// These used to live in .env, but .env is now a read-only 1Password-mounted
// FIFO and Environments cannot be written outside the desktop app, so anything
// a script rotates (SSM activations, Tailscale keys, Vector tokens) lives in
// the item `ag-admin-runtime` instead. The Environment still carries stale
// copies of some of these keys, so reading them from `.env` gives you a value
// that was correct at some point and silently is not any more.
//
// Deliberately NOT wired into load-env.ts: reading 1Password costs ~4s, and
// most entrypoints (offboard, groups, cost-allocation) need none of these.
// Fetch the one field you need, when you need it.
import { spawnSync } from "child_process";

const ACCOUNT = process.env.OP_ACCOUNT_AG ?? "ameriglide.1password.com";
const VAULT = process.env.OP_RUNTIME_VAULT ?? "ag-admin-runtime";
const ITEM = process.env.OP_RUNTIME_ITEM ?? "ag-admin-runtime";

const cache = new Map<string, string | null>();

/**
 * Fetch one field from the runtime item, or null if it cannot be read.
 *
 * Returns null rather than throwing: every caller has a sensible fallback
 * (prompt the operator, use a placeholder), and a missing 1Password should
 * not take down an onboarding run that is otherwise fine. Callers are
 * expected to say something when they get null.
 */
export function runtimeValue(name: string): string | null {
  const hit = cache.get(name);
  if (hit !== undefined) return hit;

  const res = spawnSync(
    "op",
    [
      "item",
      "get",
      ITEM,
      "--vault",
      VAULT,
      "--account",
      ACCOUNT,
      "--fields",
      `label=${name}`,
      "--reveal",
    ],
    { encoding: "utf8" },
  );

  const value =
    res.status === 0 && res.stdout.trim() ? res.stdout.trim() : null;
  cache.set(name, value);
  return value;
}
