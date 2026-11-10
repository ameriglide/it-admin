import { describe, expect, test } from "bun:test";
import { isSoftDeletedSignal } from "../src/offboard/lib/google";

// Shapes mirror what gaxios throws from the Admin SDK: `code` carries the
// HTTP status and `message` the API's error text.
function gaxiosError(code: number, message: string) {
  return { code, message, response: { status: code } };
}

describe("isSoftDeletedSignal", () => {
  test("400 'Type not supported: userKey' is the trash-window signal", () => {
    expect(
      isSoftDeletedSignal(gaxiosError(400, "Type not supported: userKey")),
    ).toBe(true);
  });

  test("412 'User is deleted' right after users.delete is also deleted", () => {
    // Seen 2026-11-09 (AG-1455): waitForUserDeleted threw on this instead
    // of returning, and the offboard run aborted before the archive group.
    expect(isSoftDeletedSignal(gaxiosError(412, "User is deleted."))).toBe(
      true,
    );
  });

  test("other 400s and 412s are real errors", () => {
    expect(isSoftDeletedSignal(gaxiosError(400, "Invalid Input"))).toBe(false);
    expect(
      isSoftDeletedSignal(gaxiosError(412, "conditionNotMet: etag mismatch")),
    ).toBe(false);
  });

  test("404 is not the soft-delete signal (callers handle it separately)", () => {
    expect(
      isSoftDeletedSignal(gaxiosError(404, "Resource Not Found: userKey")),
    ).toBe(false);
  });
});
