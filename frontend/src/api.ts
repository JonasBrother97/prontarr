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
        "A consulta demorou demais. Tente novamente.",
        "timeout",
      );
    throw new ApiError(
      "Não foi possível conectar ao Prontarr. Verifique se o servidor está rodando.",
      "network",
    );
  }
  let data: unknown;
  try {
    data = await response.json();
  } catch {
    throw new ApiError(
      response.ok
        ? "O servidor retornou uma resposta inválida."
        : `O servidor respondeu com erro HTTP ${response.status}. Tente novamente.`,
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
        ? data.error_message.slice(0, 500)
        : `Não foi possível concluir a operação (HTTP ${response.status}).`;
    throw new ApiError(message, "http", response.status);
  }
  return data as T;
}
