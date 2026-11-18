import { t, locale } from "./i18n.ts";
export class ApiError extends Error {
  readonly kind: "network" | "timeout" | "http" | "invalid_response";
  readonly status?: number;
  constructor(
    message: string,
    kind: "network" | "timeout" | "http" | "invalid_response",
    status?: number,
  ) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = status;
  }
}
export async function api<T>(
  path: string,
  body?: unknown,
  method = "POST",
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`/api${path}`, {
      ...(body === undefined
        ? {}
        : {
            method,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
          }),
      signal: AbortSignal.timeout(35_000),
    });
  } catch (error) {
    if (
      error instanceof Error &&
      (error.name === "TimeoutError" || error.name === "AbortError")
    )
      throw new ApiError(
        t("The request timed out. Please try again."),
        "timeout",
      );
    throw new ApiError(
      t("Could not connect to Prontarr. Check that the server is running."),
      "network",
    );
  }
  let data: unknown;
  try {
    data = await response.json();
  } catch {
    throw new ApiError(
      response.ok
        ? t("The server returned an invalid response.")
        : t("The server returned HTTP {{status}}. Please try again.", {
            status: response.status,
          }),
      response.ok ? "invalid_response" : "http",
      response.status,
    );
  }
  if (!response.ok) {
    const message =
      typeof data === "object" &&
      data !== null &&
      "error_message" in data &&
      typeof data.error_message === "string"
        ? t(data.error_message.slice(0, 500))
        : t("Could not complete the operation (HTTP {{status}}).", {
            status: response.status,
          });
    throw new ApiError(message, "http", response.status);
  }
  return data as T;
}
