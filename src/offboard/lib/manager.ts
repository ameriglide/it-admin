import { listSalesManagers, type SalesManager } from "./remix";
import { getUserDisplayName, listActiveUsers } from "./google";
import { choose, filter } from "../../onboard/lib/prompt";

const OTHER_OPTION = "Other (search all users)...";

export async function pickManager(targetEmail?: string): Promise<SalesManager> {
  const managers = await listSalesManagers();
  if (managers.length === 0) {
    throw new Error(
      "Remix returned no sales managers — cannot resolve a Drive transfer target",
    );
  }
  const labels = managers.map((m) => `${m.name} <${m.email}>`);
  console.log("\nSelect recipient to transfer Drive ownership to:");
  const selected = await choose([...labels, OTHER_OPTION]);
  if (selected !== OTHER_OPTION) {
    const idx = labels.indexOf(selected);
    return managers[idx]!;
  }
  return pickOther(managers, targetEmail);
}

async function pickOther(
  managers: SalesManager[],
  targetEmail?: string,
): Promise<SalesManager> {
  const managerEmails = new Set(managers.map((m) => m.email.toLowerCase()));
  const target = targetEmail?.toLowerCase();
  const all = await listActiveUsers();
  const candidates = all.filter((u) => {
    const e = u.email.toLowerCase();
    return !managerEmails.has(e) && e !== target;
  });
  if (candidates.length === 0) {
    throw new Error("No other active users available to transfer Drive ownership to");
  }
  const labels = candidates.map((u) => `${u.name} <${u.email}>`);
  console.log("\nSearch for recipient:");
  const selected = await filter(labels, "Type a name or email");
  const idx = labels.indexOf(selected);
  if (idx === -1) {
    throw new Error(`Selection "${selected}" did not match any candidate`);
  }
  const picked = candidates[idx]!;
  return { name: picked.name, email: picked.email };
}

export async function resolveManager(email: string): Promise<SalesManager> {
  const managers = await listSalesManagers();
  const match = managers.find(
    (m) => m.email.toLowerCase() === email.toLowerCase(),
  );
  if (match) return match;
  // Not a sales manager — fall back to a direct Google Workspace lookup so
  // --manager can target anyone with an active account.
  const name = await getUserDisplayName(email);
  if (!name) {
    throw new Error(
      `--manager ${email} is neither a Remix sales manager nor an active Google Workspace user`,
    );
  }
  return { name, email };
}
