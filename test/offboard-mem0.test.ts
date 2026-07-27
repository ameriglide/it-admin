import { test, expect } from "bun:test";
import { isOrgPersonForEmail, buildListFilters } from "../src/offboard/lib/mem0";

const gws = (email: string) => ({ metadata: { source: "gws-directory", email } });

test("isOrgPersonForEmail matches a gws-directory entry for the same email", () => {
  expect(isOrgPersonForEmail(gws("test.user@example.com"), "test.user@example.com")).toBe(true);
});

test("isOrgPersonForEmail is case-insensitive on the email", () => {
  expect(isOrgPersonForEmail(gws("Test.User@example.com"), "test.user@example.com")).toBe(true);
});

test("isOrgPersonForEmail rejects a different email", () => {
  expect(isOrgPersonForEmail(gws("someone.else@ameriglide.com"), "test.user@example.com")).toBe(false);
});

test("isOrgPersonForEmail rejects a manual-source entry even with matching email", () => {
  const manual = { metadata: { source: "manual", email: "test.user@example.com" } };
  expect(isOrgPersonForEmail(manual, "test.user@example.com")).toBe(false);
});

test("isOrgPersonForEmail rejects an entry with no metadata", () => {
  expect(isOrgPersonForEmail({}, "test.user@example.com")).toBe(false);
});

test("buildListFilters scopes to ameriglide-team / org-directory / gws-directory", () => {
  expect(buildListFilters()).toEqual({
    AND: [
      { user_id: "ameriglide-team" },
      { app_id: "org-directory" },
      { metadata: { source: "gws-directory" } },
    ],
  });
});
