import { test, expect } from "bun:test";
import {
  personFromDirectoryUser,
  memoryContent,
  memoryMetadata,
} from "../src/offboard/lib/mem0";
import { mirrorsOrgDirectory } from "../src/onboard/steps/org-directory";

// These shapes must stay identical to ameriglide-claude-config's
// scripts/lib/{gws,mem0}.mjs: seed-org diffs on the metadata fields, so a
// drifting entry is rewritten (or, for the text, never corrected) on reseed.

const newHire = {
  primaryEmail: "test.user@example.com",
  name: { fullName: "Test User" },
  orgUnitPath: "/Exempt from MFA",
};

test("personFromDirectoryUser reads a bare new hire", () => {
  expect(personFromDirectoryUser(newHire)).toEqual({
    email: "test.user@example.com",
    name: "Test User",
    title: null,
    department: null,
    orgUnit: "/Exempt from MFA",
    manager: null,
    pronouns: null,
  });
});

test("personFromDirectoryUser prefers the primary organization and reads manager and pronouns", () => {
  const person = personFromDirectoryUser({
    primaryEmail: "test.user@example.com",
    name: { fullName: "Test User" },
    orgUnitPath: "/",
    organizations: [
      { title: "Old Title", department: "Old Dept" },
      { primary: true, title: "Sales Rep", department: "Sales" },
    ],
    relations: [
      { type: "assistant", value: "helper@example.com" },
      { type: "manager", value: "boss@example.com" },
    ],
    gender: { addressMeAs: " they/them " },
  });
  expect(person.title).toBe("Sales Rep");
  expect(person.department).toBe("Sales");
  expect(person.manager).toBe("boss@example.com");
  expect(person.pronouns).toBe("they/them");
});

test("personFromDirectoryUser falls back to the first organization and to the email as name", () => {
  const person = personFromDirectoryUser({
    primaryEmail: "test.user@example.com",
    organizations: [{ department: "Sales" }],
    gender: { addressMeAs: "  " },
  });
  expect(person.name).toBe("test.user@example.com");
  expect(person.department).toBe("Sales");
  expect(person.orgUnit).toBeNull();
  expect(person.pronouns).toBeNull();
});

test("memoryContent for a bare new hire", () => {
  expect(memoryContent(personFromDirectoryUser(newHire))).toBe(
    "Test User (org unit /Exempt from MFA). Email test.user@example.com.",
  );
});

test("memoryContent with title, department, named manager and pronouns", () => {
  const person = {
    email: "test.user@example.com",
    name: "Test User",
    title: "Sales Rep",
    department: "Sales",
    orgUnit: "/",
    manager: "boss@example.com",
    pronouns: "they/them",
  };
  expect(memoryContent(person, "Big Boss")).toBe(
    "Test User — Sales Rep, Sales department (org unit /). Email test.user@example.com." +
      " Manager: Big Boss (boss@example.com). Pronouns: they/them.",
  );
});

test("memoryContent falls back to the manager's email when the name is unknown", () => {
  const person = {
    ...personFromDirectoryUser(newHire),
    department: "Sales",
    manager: "boss@example.com",
  };
  expect(memoryContent(person)).toBe(
    "Test User — Sales department (org unit /Exempt from MFA). Email test.user@example.com." +
      " Manager: boss@example.com.",
  );
});

test("memoryMetadata marks a new entry as an unreviewed gws-directory org-person", () => {
  expect(memoryMetadata(personFromDirectoryUser(newHire), false)).toEqual({
    type: "org-person",
    source: "gws-directory",
    email: "test.user@example.com",
    name: "Test User",
    title: null,
    department: null,
    orgUnit: "/Exempt from MFA",
    manager: null,
    pronouns: null,
    reviewed: false,
  });
});

test("mirrorsOrgDirectory needs a mem0 key and the ameriglide.com tenant", () => {
  expect(mirrorsOrgDirectory({ MEM0_API_KEY: "k", DOMAIN: "ameriglide.com" })).toBe(true);
  expect(mirrorsOrgDirectory({ MEM0_API_KEY: "k" })).toBe(true); // DOMAIN defaults to ameriglide.com
  expect(mirrorsOrgDirectory({ DOMAIN: "ameriglide.com" })).toBe(false);
  expect(mirrorsOrgDirectory({ MEM0_API_KEY: "k", DOMAIN: "inetalliance.net" })).toBe(false);
});
