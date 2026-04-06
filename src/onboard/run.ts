import type { Context, Step } from "./types";

export async function run(ctx: Context): Promise<void> {
  const steps: Step[] = [
    // Steps will be added as we build them
  ];

  for (const step of steps) {
    console.log(`\nChecking ${step.name}...`);
    const done = await step.check(ctx);
    if (done) {
      console.log(`  ✓ ${step.name} — already done, skipping`);
      continue;
    }
    console.log(`Running ${step.name}...`);
    await step.run(ctx);
    console.log(`  ✓ ${step.name} — done`);
  }
}
