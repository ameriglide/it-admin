async function gum(args: string[]): Promise<string> {
  const proc = Bun.spawn(["gum", ...args], {
    stdin: "inherit",
    stdout: "pipe",
    stderr: "inherit",
  });
  const text = await new Response(proc.stdout).text();
  const code = await proc.exited;
  if (code !== 0) throw new Error(`gum exited with code ${code}`);
  return text.trim();
}

export async function input(label: string): Promise<string> {
  return gum(["input", "--prompt", `${label}: `, "--placeholder", label]);
}

export async function choose(items: string[]): Promise<string> {
  return gum(["choose", ...items]);
}

export async function filter(items: string[], placeholder = "Type to search"): Promise<string> {
  const proc = Bun.spawn(["gum", "filter", "--placeholder", placeholder], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "inherit",
  });
  proc.stdin.write(items.join("\n"));
  await proc.stdin.end();
  const text = await new Response(proc.stdout).text();
  const code = await proc.exited;
  if (code !== 0) throw new Error(`gum exited with code ${code}`);
  return text.trim();
}

export async function chooseMulti(
  items: string[],
  options: { selected?: string[] } = {},
): Promise<string[]> {
  const args = ["choose", "--no-limit"];
  if (options.selected?.length) {
    args.push(`--selected=${options.selected.join(",")}`);
  }
  args.push(...items);
  const result = await gum(args);
  return result.split("\n").filter(Boolean);
}

export async function confirm(message: string): Promise<boolean> {
  const proc = Bun.spawn(["gum", "confirm", message], {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await proc.exited;
  return code === 0;
}
