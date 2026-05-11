import { listSalesManagers, type SalesManager } from "./remix";
import { choose } from "../../onboard/lib/prompt";

export async function pickManager(): Promise<SalesManager> {
  const managers = await listSalesManagers();
  if (managers.length === 0) {
    throw new Error(
      "Remix returned no sales managers — cannot resolve a Drive transfer target",
    );
  }
  const labels = managers.map(
    (m) => `${m.firstName} ${m.lastName} <${m.email}>`,
  );
  console.log("\nSelect manager to transfer Drive ownership to:");
  const selected = await choose(labels);
  const idx = labels.indexOf(selected);
  return managers[idx]!;
}

export async function resolveManager(email: string): Promise<SalesManager> {
  const managers = await listSalesManagers();
  const match = managers.find(
    (m) => m.email.toLowerCase() === email.toLowerCase(),
  );
  if (!match) {
    throw new Error(
      `--manager ${email} is not in the Remix salesManagers list. Available: ${managers
        .map((m) => m.email)
        .join(", ")}`,
    );
  }
  return match;
}
