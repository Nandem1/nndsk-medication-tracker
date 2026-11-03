import { z } from "zod";
import type { Identity } from "@identity";
export class ApiError extends Error {
  constructor(public status: number) {
    super(
      status === 401
        ? "La sesión venció. Vuelve a iniciar sesión."
        : status === 403 || status === 404
          ? "No tienes permiso para consultar esta información."
          : status === 409
            ? "La información cambió o esta operación ya se procesó. Actualiza antes de intentar otra vez."
            : status === 422
              ? "Revisa los datos, las fechas y la política de cambio de hora."
              : "No se pudo completar la solicitud. Intenta nuevamente.",
    );
  }
}
export class Api {
  constructor(private identity: Identity) {}
  async request<T>(
    path: string,
    schema: z.ZodType<T>,
    body?: unknown,
    method = body === undefined ? "GET" : "POST",
    signal?: AbortSignal,
  ): Promise<T> {
    const token = await this.identity.token();
    const response = await fetch("/v1" + path, {
      method,
      signal,
      headers: {
        Authorization: "Bearer " + token,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
    }).catch((error: unknown) => {
      if (error instanceof DOMException && error.name === "AbortError")
        throw error;
      throw new Error(
        "No hay conexión con el servidor. Revisa la red y vuelve a intentar.",
      );
    });
    if (!response.ok) {
      if ([401, 403, 404].includes(response.status))
        window.dispatchEvent(
          new CustomEvent("access-denied", { detail: this.identity.uid }),
        );
      throw new ApiError(response.status);
    }
    return schema.parse(response.status === 204 ? null : await response.json());
  }
  async all<T>(
    path: string,
    schema: z.ZodType<T>,
    signal?: AbortSignal,
  ): Promise<T[]> {
    const items: T[] = [];
    let cursor = "";
    const seen = new Set<string>();
    do {
      const page = await this.request(
        path +
          (path.includes("?") ? "&" : "?") +
          "cursor=" +
          encodeURIComponent(cursor),
        z.object({ items: z.array(schema), next_cursor: z.string() }),
        undefined,
        "GET",
        signal,
      );
      items.push(...page.items);
      cursor = page.next_cursor;
      if (cursor && seen.has(cursor))
        throw new Error("La paginación no pudo completarse.");
      seen.add(cursor);
    } while (cursor);
    return items;
  }
}
