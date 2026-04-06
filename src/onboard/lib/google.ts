import { google } from "googleapis";

export async function getDirectoryClient() {
  const keyPath = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
  const adminEmail = process.env.GOOGLE_ADMIN_EMAIL;
  if (!keyPath) throw new Error("GOOGLE_SERVICE_ACCOUNT_KEY not set");
  if (!adminEmail) throw new Error("GOOGLE_ADMIN_EMAIL not set");

  const auth = new google.auth.GoogleAuth({
    keyFile: keyPath,
    scopes: ["https://www.googleapis.com/auth/admin.directory.user"],
    clientOptions: { subject: adminEmail },
  });

  return google.admin({ version: "directory_v1", auth });
}
