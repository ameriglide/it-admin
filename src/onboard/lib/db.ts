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

export async function closeAll() {
  if (amberjack) await amberjack.end();
  if (phenix) await phenix.end();
  if (sonar) await sonar.end();
}
