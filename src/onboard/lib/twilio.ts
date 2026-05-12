type TwilioEnv = {
  accountSid: string;
  authToken: string;
  workspaceSid: string;
  credentialListSid: string;
};

function getEnv(): TwilioEnv {
  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  const workspaceSid = process.env.TWILIO_WORKSPACE_SID;
  const credentialListSid = process.env.TWILIO_CREDENTIAL_LIST_SID;
  if (!accountSid || !authToken || !workspaceSid || !credentialListSid) {
    throw new Error("Missing TWILIO_* environment variables");
  }
  return { accountSid, authToken, workspaceSid, credentialListSid };
}

function authHeaders(env: TwilioEnv): HeadersInit {
  const basic = Buffer.from(`${env.accountSid}:${env.authToken}`).toString("base64");
  return { Authorization: `Basic ${basic}` };
}

async function twilioFetch(url: string, init?: RequestInit): Promise<any> {
  const env = getEnv();
  const res = await fetch(url, {
    ...init,
    headers: { ...authHeaders(env), ...init?.headers },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Twilio API ${res.status}: ${body}`);
  }
  return res.json();
}

async function twilioPost(url: string, params: Record<string, string>): Promise<any> {
  const env = getEnv();
  const res = await fetch(url, {
    method: "POST",
    headers: {
      ...authHeaders(env),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(params),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Twilio API ${res.status}: ${body}`);
  }
  return res.json();
}

const BASE = "https://api.twilio.com/2010-04-01";
const TASKROUTER = "https://taskrouter.twilio.com/v1";

export async function findWorkerByEmail(email: string): Promise<{ sid: string } | null> {
  const env = getEnv();
  let url: string | null =
    `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers?PageSize=100`;
  while (url) {
    const data: any = await twilioFetch(url);
    for (const w of data.workers ?? []) {
      try {
        const attrs = JSON.parse(w.attributes);
        if (attrs.email === email) return { sid: w.sid };
      } catch {}
    }
    // TaskRouter pages via meta.next_page_url (absolute URL) or null.
    url = data.meta?.next_page_url ?? null;
  }
  return null;
}

export async function createWorker(
  friendlyName: string,
  attributes: Record<string, any>,
): Promise<string> {
  const env = getEnv();
  const url = `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers`;
  const data = await twilioPost(url, {
    FriendlyName: friendlyName,
    Attributes: JSON.stringify(attributes),
  });
  return data.sid;
}

export async function updateWorkerAttributes(
  workerSid: string,
  attributes: Record<string, any>,
): Promise<void> {
  const env = getEnv();
  const url = `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers/${workerSid}`;
  await twilioPost(url, { Attributes: JSON.stringify(attributes) });
}

export async function findCredentialByUsername(username: string): Promise<{ sid: string } | null> {
  const env = getEnv();
  let url: string | null =
    `${BASE}/Accounts/${env.accountSid}/SIP/CredentialLists/${env.credentialListSid}/Credentials.json?PageSize=100`;
  while (url) {
    const data: any = await twilioFetch(url);
    const cred = (data.credentials ?? []).find(
      (c: any) => c.username === username,
    );
    if (cred) return { sid: cred.sid };
    // REST v2010 pages via next_page_uri (relative path).
    url = data.next_page_uri ? `https://api.twilio.com${data.next_page_uri}` : null;
  }
  return null;
}

export async function createCredential(username: string, password: string): Promise<string> {
  const env = getEnv();
  const url = `${BASE}/Accounts/${env.accountSid}/SIP/CredentialLists/${env.credentialListSid}/Credentials.json`;
  const data = await twilioPost(url, { Username: username, Password: password });
  return data.sid;
}

export async function searchLocalNumbers(
  areaCode?: string,
  inLocality?: string,
): Promise<Array<{ phoneNumber: string; friendlyName: string; locality: string; region: string }>> {
  const env = getEnv();
  const params = new URLSearchParams();
  if (areaCode) params.set("AreaCode", areaCode);
  if (inLocality) params.set("InLocality", inLocality);
  params.set("VoiceEnabled", "true");
  const url = `${BASE}/Accounts/${env.accountSid}/AvailablePhoneNumbers/US/Local.json?${params}`;
  const data = await twilioFetch(url);
  return data.available_phone_numbers.map((n: any) => ({
    phoneNumber: n.phone_number,
    friendlyName: n.friendly_name,
    locality: n.locality,
    region: n.region,
  }));
}

export async function buyNumber(phoneNumber: string): Promise<string> {
  const env = getEnv();
  const twimlAppSid = process.env.TWILIO_TWIML_APP_SID;
  if (!twimlAppSid) throw new Error("TWILIO_TWIML_APP_SID not set");
  const url = `${BASE}/Accounts/${env.accountSid}/IncomingPhoneNumbers.json`;
  const data = await twilioPost(url, {
    PhoneNumber: phoneNumber,
    VoiceApplicationSid: twimlAppSid,
  });
  return data.sid;
}

async function twilioDelete(url: string): Promise<void> {
  const env = getEnv();
  const res = await fetch(url, {
    method: "DELETE",
    headers: { ...authHeaders(env) },
  });
  if (!res.ok && res.status !== 404) {
    const body = await res.text();
    throw new Error(`Twilio API ${res.status}: ${body}`);
  }
}

export async function deleteWorker(workerSid: string): Promise<void> {
  const env = getEnv();
  await twilioDelete(
    `${TASKROUTER}/Workspaces/${env.workspaceSid}/Workers/${workerSid}?ReevaluateTasks=true`,
  );
}

export async function deleteCredential(credentialSid: string): Promise<void> {
  const env = getEnv();
  await twilioDelete(
    `${BASE}/Accounts/${env.accountSid}/SIP/CredentialLists/${env.credentialListSid}/Credentials/${credentialSid}.json`,
  );
}
