const API = "https://api.digitalocean.com/v2";

function authHeaders(): Record<string, string> {
  const token = process.env.DO_BILLING_TOKEN;
  if (!token) {
    throw new Error(
      "DO_BILLING_TOKEN is not set. Create a billing-scoped DigitalOcean Personal " +
        "Access Token (the default doctl token returns 403 on billing endpoints) and " +
        "add it to .env as DO_BILLING_TOKEN.",
    );
  }
  return { Authorization: `Bearer ${token}` };
}

export interface InvoiceSummary {
  invoice_uuid: string;
  invoice_period: string; // "YYYY-MM"
  amount: string;
}

/** All issued invoices, newest period first. */
export async function listInvoices(): Promise<InvoiceSummary[]> {
  const res = await fetch(`${API}/customers/my/invoices?per_page=50`, {
    headers: authHeaders(),
  });
  if (!res.ok) {
    throw new Error(`invoice list failed: ${res.status} ${await res.text()}`);
  }
  const json = (await res.json()) as { invoices: InvoiceSummary[] };
  return [...(json.invoices ?? [])].sort((a, b) =>
    b.invoice_period.localeCompare(a.invoice_period),
  );
}

/** The line-item CSV for one invoice (includes the project_name column). */
export async function fetchInvoiceCsv(uuid: string): Promise<string> {
  const res = await fetch(`${API}/customers/my/invoices/${uuid}/csv`, {
    headers: authHeaders(),
  });
  if (!res.ok) {
    throw new Error(`invoice CSV failed: ${res.status} ${await res.text()}`);
  }
  return res.text();
}
