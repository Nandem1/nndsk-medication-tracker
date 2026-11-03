import type { ReactNode } from "react";
import { Button } from "./ui/button";
export function QueryState({
  query,
  children,
}: {
  query: {
    isPending: boolean;
    isError: boolean;
    error: Error | null;
    refetch: () => unknown;
  };
  children: ReactNode;
}) {
  if (query.isPending) return <p role="status">Cargando información…</p>;
  if (query.isError)
    return (
      <div role="alert">
        <p>{query.error?.message ?? "No se pudo cargar la información."}</p>
        <Button variant="outline" onClick={() => query.refetch()}>
          Volver a intentar
        </Button>
      </div>
    );
  return children;
}
