export async function api<T>(
  path: string,
  body?: unknown,
  method = "POST",
): Promise<T> {
  const response = await fetch(`/api${path}`, {
    ...(body === undefined
      ? {}
      : {
          method,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
    signal: AbortSignal.timeout(35_000),
  });
  const data = await response.json();
  if (!response.ok)
    throw new Error(
      data.error_message ?? "Não foi possível concluir a operação.",
    );
  return data as T;
}
