import { test, expect, beforeEach, afterEach } from "bun:test";
import { makeSonarStep, type SqlLike } from "../src/onboard/steps/sonar";
import type { Context } from "../src/onboard/types";

// Exercises sonarStep's check()/run() against a fake tagged-template sql that
// records every query and answers from canned responses keyed on SQL text.
// Extensions are fake 9xxx numbers.

interface Query {
  text: string;
  values: unknown[];
}

// A response is rows to resolve with, or a function that may throw (to model
// a rejected query) or return rows.
type Response = unknown[] | ((values: unknown[]) => unknown[]);

function fakeSql(routes: [RegExp, Response][]) {
  const queries: Query[] = [];
  const sql = (async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const text = strings.join("?").replace(/\s+/g, " ").trim();
    queries.push({ text, values });
    const route = routes.find(([re]) => re.test(text));
    if (!route) throw new Error(`fakeSql: no route for: ${text}`);
    const [, res] = route;
    return typeof res === "function" ? res(values) : res;
  }) as SqlLike;
  return { sql, queries };
}

const CALL_CENTERS = [
  { id: 1, name: "Main" },
  { id: 2, name: "Overflow" },
];

function ctx(extra: Partial<Context> = {}): Context {
  return {
    firstName: "Test",
    lastName: "User",
    email: "test.user@example.com",
    directLine: undefined,
    ...extra,
  };
}

function setup(opts: {
  routes: [RegExp, Response][];
  pbxEnabled?: (ext: string) => boolean | null;
  inputValue?: string;
  chooseValue?: string;
}) {
  const { sql, queries } = fakeSql(opts.routes);
  const calls = { input: 0, choose: 0 };
  const step = makeSonarStep({
    sql: () => sql,
    input: async () => {
      calls.input++;
      return opts.inputValue ?? "9001";
    },
    choose: async () => {
      calls.choose++;
      return opts.chooseValue ?? "Main";
    },
    pbxEnabled: opts.pbxEnabled ?? (() => true),
  });
  return { step, queries, calls };
}

// Routes for a fresh run(): key free, two call centers, INSERT succeeds.
function freshRoutes(insert: Response = []): [RegExp, Response][] {
  return [
    [/^INSERT INTO agent/, insert],
    [/SELECT firstname, lastname FROM agent WHERE key/, []],
    [/FROM callcenter/, CALL_CENTERS],
  ];
}

let logs: string[];
const realLog = console.log;
beforeEach(() => {
  logs = [];
  console.log = (...args: unknown[]) => {
    logs.push(args.map(String).join(" "));
  };
});
afterEach(() => {
  console.log = realLog;
});

// ---- check() ----

test("check() returns false when no agent has the email", async () => {
  const { step, queries } = setup({ routes: [[/FROM agent WHERE lower\(email\)/, []]] });
  const c = ctx();
  expect(await step.check(c)).toBe(false);
  expect(queries[0]!.values).toEqual(["test.user@example.com"]);
  expect(c.sonarAgentKey).toBeUndefined();
  expect(c.sonarAgentCreated).toBeUndefined();
});

test("check() adopts an existing agent's key and paused flag", async () => {
  const { step } = setup({
    routes: [[/SELECT key, paused FROM agent/, [{ key: "9002", paused: true }]]],
  });
  const c = ctx();
  expect(await step.check(c)).toBe(true);
  expect(c.extension).toBe("9002");
  expect(c.sonarAgentKey).toBe("9002");
  expect(c.sonarAgentCreated).toBe(false);
  expect(c.sonarAgentPaused).toBe(true);
});

test("check() reports paused=false from the row", async () => {
  const { step } = setup({
    routes: [[/SELECT key, paused FROM agent/, [{ key: "9002", paused: false }]]],
  });
  const c = ctx();
  await step.check(c);
  expect(c.sonarAgentPaused).toBe(false);
});

test("check() throws on more than one agent with the email", async () => {
  const { step } = setup({
    routes: [
      [
        /SELECT key, paused FROM agent/,
        [
          { key: "9002", paused: true },
          { key: "9003", paused: false },
        ],
      ],
    ],
  });
  await expect(step.check(ctx())).rejects.toThrow(/More than one Sonar agent.*9002, 9003/);
});

test("check() throws when --extension disagrees with the existing key", async () => {
  const { step } = setup({
    routes: [[/SELECT key, paused FROM agent/, [{ key: "9002", paused: true }]]],
  });
  await expect(step.check(ctx({ extension: "9004" }))).rejects.toThrow(
    /already has key 9002.*--extension 9004/,
  );
});

test("check() warns that --call-center and --no-sales are ignored for an existing agent", async () => {
  const { step } = setup({
    routes: [[/SELECT key, paused FROM agent/, [{ key: "9002", paused: true }]]],
  });
  await step.check(ctx({ sonarCallCenter: "Overflow", sales: false }));
  expect(logs.join("\n")).toMatch(
    /Warning: Sonar agent 9002 already exists; --call-center "Overflow" and --no-sales not applied/,
  );
});

test("check() prints no warning when no preselects were given", async () => {
  const { step } = setup({
    routes: [[/SELECT key, paused FROM agent/, [{ key: "9002", paused: true }]]],
  });
  await step.check(ctx());
  expect(logs.join("\n")).not.toMatch(/Warning/);
});

// ---- run() ----

test("run() INSERTs a paused, unlocked sales agent with values in column order", async () => {
  const { step, queries, calls } = setup({ routes: freshRoutes() });
  const c = ctx({ extension: "9001" });
  await step.run(c);

  const insert = queries.find((q) => q.text.startsWith("INSERT INTO agent"))!;
  expect(insert.text).toMatch(
    /\(\s*key, firstname, lastname, email, callcenter, sales, locked, paused, forwarded, penalizedforwarding\s*\)/,
  );
  // Positional binding: [key, first, last, email, callcenter, sales, locked, paused]
  // followed by the two literal `false`s in the SQL text, not bound values.
  expect(insert.values).toEqual([
    "9001",
    "Test",
    "User",
    "test.user@example.com",
    1,
    true,
    false,
    true,
  ]);
  expect(insert.text).toMatch(/\?, false, false \)$/);

  expect(calls.choose).toBe(1);
  expect(calls.input).toBe(0);
  expect(c.sonarAgentKey).toBe("9001");
  expect(c.sonarAgentCreated).toBe(true);
  expect(c.sonarAgentPaused).toBe(true);
  expect(c.extension).toBe("9001");
});

test("run() honors --no-sales and a preselected call center without prompting", async () => {
  const { step, queries, calls } = setup({ routes: freshRoutes() });
  await step.run(ctx({ extension: "9001", sales: false, sonarCallCenter: "Overflow" }));
  const insert = queries.find((q) => q.text.startsWith("INSERT INTO agent"))!;
  expect(insert.values[4]).toBe(2); // callcenter id
  expect(insert.values[5]).toBe(false); // sales
  expect(calls.choose).toBe(0);
});

test("run() prompts for the extension when none was given", async () => {
  const { step, queries, calls } = setup({ routes: freshRoutes(), inputValue: "9005" });
  const c = ctx();
  await step.run(c);
  expect(calls.input).toBe(1);
  expect(queries.find((q) => q.text.startsWith("INSERT"))!.values[0]).toBe("9005");
  expect(c.extension).toBe("9005");
});

test("run() refuses a taken key before prompting for a call center", async () => {
  const { step, queries, calls } = setup({
    routes: [
      [/SELECT firstname, lastname FROM agent WHERE key/, [{ firstname: "Other", lastname: "Agent" }]],
      [/FROM callcenter/, CALL_CENTERS],
    ],
  });
  await expect(step.run(ctx({ extension: "9001" }))).rejects.toThrow(
    /9001 already belongs to Other Agent/,
  );
  expect(calls.choose).toBe(0);
  expect(queries.some((q) => q.text.startsWith("INSERT"))).toBe(false);
});

test("run() refuses an extension disabled on the PBX before prompting", async () => {
  const { step, queries, calls } = setup({ routes: freshRoutes(), pbxEnabled: () => false });
  await expect(step.run(ctx({ extension: "9001" }))).rejects.toThrow(/disabled on the PBX/);
  expect(calls.choose).toBe(0);
  expect(queries.some((q) => q.text.startsWith("INSERT"))).toBe(false);
});

test("run() says so before the INSERT when PBX enablement is unknown", async () => {
  const order: string[] = [];
  const { step } = setup({
    routes: freshRoutes(() => {
      order.push("INSERT");
      return [];
    }),
    pbxEnabled: () => null,
  });
  const realPush = logs.push.bind(logs);
  logs.push = (...items: string[]) => {
    for (const i of items) if (i.includes("PBX_ENABLED_EXTENSIONS unset")) order.push("notice");
    return realPush(...items);
  };
  await step.run(ctx({ extension: "9001" }));
  expect(logs.join("\n")).toMatch(
    /\(PBX_ENABLED_EXTENSIONS unset - not checking whether 9001 is enabled on the PBX\)/,
  );
  expect(order).toEqual(["notice", "INSERT"]);
});

test("run() prints no PBX notice when enablement is known", async () => {
  const { step } = setup({ routes: freshRoutes() });
  await step.run(ctx({ extension: "9001" }));
  expect(logs.join("\n")).not.toMatch(/PBX_ENABLED_EXTENSIONS unset/);
});

test("run() translates a 23505 on INSERT into the holder message", async () => {
  let keyLookups = 0;
  const { step } = setup({
    routes: [
      [
        /^INSERT INTO agent/,
        () => {
          throw Object.assign(new Error("duplicate key"), {
            code: "23505",
            detail: "Key (key)=(9001) already exists.",
          });
        },
      ],
      [
        /SELECT firstname, lastname FROM agent WHERE key/,
        // First lookup (preflight): free. Second (after the 23505): claimed.
        () => (keyLookups++ === 0 ? [] : [{ firstname: "Racing", lastname: "Agent" }]),
      ],
      [/FROM callcenter/, CALL_CENTERS],
    ],
  });
  const c = ctx({ extension: "9001" });
  await expect(step.run(c)).rejects.toThrow(/9001 already belongs to Racing Agent/);
  expect(c.sonarAgentCreated).toBeUndefined();
});

test("run() reports the violation detail on a 23505 when no holder is found", async () => {
  const { step } = setup({
    routes: freshRoutes(() => {
      throw Object.assign(new Error("duplicate key"), {
        code: "23505",
        detail: "Key (email)=(test.user@example.com) already exists.",
      });
    }),
  });
  await expect(step.run(ctx({ extension: "9001" }))).rejects.toThrow(
    /INSERT for 9001 hit a unique violation: Key \(email\)/,
  );
});

test("run() keeps the 23505 when the follow-up holder lookup fails", async () => {
  let keyLookups = 0;
  const original = Object.assign(new Error("duplicate key"), {
    code: "23505",
    detail: "Key (key)=(9001) already exists.",
  });
  const { step } = setup({
    routes: [
      [
        /^INSERT INTO agent/,
        () => {
          throw original;
        },
      ],
      [
        /SELECT firstname, lastname FROM agent WHERE key/,
        () => {
          if (keyLookups++ === 0) return [];
          throw new Error("connection reset");
        },
      ],
      [/FROM callcenter/, CALL_CENTERS],
    ],
  });
  let caught: unknown;
  try {
    await step.run(ctx({ extension: "9001" }));
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(Error);
  const err = caught as Error;
  expect(err.message).toMatch(/unique violation: Key \(key\)=\(9001\) already exists/);
  expect(err.message).toMatch(/connection reset/);
  expect(err.cause).toBe(original);
});

test("run() rethrows a non-23505 INSERT error unchanged", async () => {
  const original = Object.assign(new Error("internal error"), { code: "XX000" });
  const { step, queries } = setup({
    routes: freshRoutes(() => {
      throw original;
    }),
  });
  let caught: unknown;
  try {
    await step.run(ctx({ extension: "9001" }));
  } catch (e) {
    caught = e;
  }
  expect(caught).toBe(original);
  // No holder lookup after a non-unique failure: only the preflight one.
  expect(queries.filter((q) => /WHERE key/.test(q.text)).length).toBe(1);
});
