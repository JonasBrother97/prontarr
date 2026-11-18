import { useEffect, useState } from "react";
export type Validator<T> = (value: unknown) => value is T;
export function restorePreference<T>(
  storage: Pick<Storage, "getItem">,
  key: string,
  valid: Validator<T>,
  fallback: T,
): T {
  try {
    const raw = storage.getItem(`prontarr:${key}`);
    if (raw === null || raw.length > 4096) return fallback;
    const value: unknown = JSON.parse(raw);
    return valid(value) ? value : fallback;
  } catch {
    return fallback;
  }
}
export function savePreference(
  storage: Pick<Storage, "setItem">,
  key: string,
  value: unknown,
): boolean {
  try {
    storage.setItem(`prontarr:${key}`, JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
}
export function useStoredState<T>(
  key: string,
  fallback: T,
  valid: Validator<T>,
  kind: "local" | "session" = "local",
) {
  const [value, setValue] = useState<T>(() => {
    try {
      return restorePreference(
        kind === "local" ? window.localStorage : window.sessionStorage,
        key,
        valid,
        fallback,
      );
    } catch {
      return fallback;
    }
  });
  useEffect(() => {
    try {
      savePreference(
        kind === "local" ? window.localStorage : window.sessionStorage,
        key,
        value,
      );
    } catch {
      /* Browser storage may be disabled. */
    }
  }, [key, value, kind]);
  return [value, setValue] as const;
}
export const isBoolean = (value: unknown): value is boolean =>
  typeof value === "boolean";
export const isShortText = (value: unknown): value is string =>
  typeof value === "string" && value.length <= 200;
export type Page = "dashboard" | "live" | "simulator" | "policy";
export const routes: Record<Page, string> = {
  dashboard: "#/overview",
  live: "#/downloads",
  simulator: "#/simulator",
  policy: "#/settings",
};
export function pageFromHash(hash: string): Page {
  return (
    (Object.keys(routes) as Page[]).find((page) => routes[page] === hash) ??
    "live"
  );
}
