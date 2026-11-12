import postgres from "postgres";

let amberjack: ReturnType<typeof postgres> | null = null;
let phenix: ReturnType<typeof postgres> | null = null;
let sonar: ReturnType<typeof postgres> | null = null;

export function getAmberjack() {
  if (!amberjack) {
    const url = process.env.AMBERJACK_DATABASE_URL;
    if (!url) throw new Error("AMBERJACK_DATABASE_URL not set");
    amberjack = postgres(url);
  }
  return amberjack;
}

export function getPhenix() {
  if (!phenix) {
    const url = process.env.PHENIX_DATABASE_URL;
    if (!url) throw new Error("PHENIX_DATABASE_URL not set");
    phenix = postgres(url);
  }
  return phenix;
}

// Sonar is the IAI CRM. Its live data is the `cg2` database, not a database
// named "sonar" — see docs/runbooks/iai-onboarding.md.
export function getSonar() {
  if (!sonar) {
    const url = process.env.SONAR_DATABASE_URL;
    if (!url) throw new Error("SONAR_DATABASE_URL not set");
    sonar = postgres(url);
  }
  return sonar;
}

// Closes every open pool, all at once, so one failing end() cannot leave the
// others open. Failures are logged, not thrown: this runs in run()'s finally,
// where a throw would mask the step error being reported.
export async function closeAll() {
  const pools = [
    ["Amberjack", amberjack],
    ["Phenix", phenix],
    ["Sonar", sonar],
  ] as const;
  const open = pools.filter(([, pool]) => pool !== null);
  const results = await Promise.allSettled(open.map(([, pool]) => pool!.end()));
  results.forEach((r, i) => {
    if (r.status === "rejected") {
      console.error(`Failed to close the ${open[i]![0]} database connection:`, r.reason);
    }
  });
}
