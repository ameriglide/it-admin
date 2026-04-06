import postgres from "postgres";

let amberjack: ReturnType<typeof postgres> | null = null;
let phenix: ReturnType<typeof postgres> | null = null;

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

export async function closeAll() {
  if (amberjack) await amberjack.end();
  if (phenix) await phenix.end();
}
