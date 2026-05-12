type GraphQLResponse<T> = {
  data?: T;
  errors?: Array<{ message: string }>;
};

function getEnv() {
  const url = process.env.REMIX_GRAPHQL_URL;
  const key = process.env.REMIX_API_KEY;
  if (!url) throw new Error("REMIX_GRAPHQL_URL not set");
  if (!key) throw new Error("REMIX_API_KEY not set");
  return { url, key };
}

async function graphql<T>(
  query: string,
  variables: Record<string, unknown> = {},
): Promise<T> {
  const { url, key } = getEnv();
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${key}`,
    },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Remix GraphQL ${res.status}: ${body}`);
  }
  const payload = (await res.json()) as GraphQLResponse<T>;
  if (payload.errors?.length) {
    throw new Error(
      `Remix GraphQL errors: ${payload.errors.map((e) => e.message).join("; ")}`,
    );
  }
  if (!payload.data) throw new Error("Remix GraphQL: empty response");
  return payload.data;
}

export interface Agent {
  email: string;
  active: boolean;
}

export interface SalesManager {
  name: string;
  email: string;
}

export async function getAgent(email: string): Promise<Agent | null> {
  const data = await graphql<{ agent: Agent | null }>(
    `query Agent($email: String!) {
       agent(email: $email) { email active }
     }`,
    { email },
  );
  return data.agent;
}

export async function setAgentInactive(email: string): Promise<Agent> {
  const data = await graphql<{ setAgentInactive: Agent }>(
    `mutation SetAgentInactive($email: String!) {
       setAgentInactive(email: $email) { email active }
     }`,
    { email },
  );
  return data.setAgentInactive;
}

export async function listSalesManagers(): Promise<SalesManager[]> {
  const data = await graphql<{ salesManagers: SalesManager[] }>(
    `query SalesManagers {
       salesManagers { name email }
     }`,
  );
  return data.salesManagers;
}
