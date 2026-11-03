import { useQuery, useQueryClient } from "@tanstack/react-query";
import { z } from "zod";
import { useSession } from "../app/session";
export function useList<T>(path: string, schema: z.ZodType<T>) {
  const { api, identity } = useSession();
  return useQuery({
    queryKey: [identity.uid, path],
    queryFn: ({ signal }) => api.all(path, schema, signal),
    retry: false,
    staleTime: 0,
  });
}
export function useRefresh() {
  const client = useQueryClient();
  return () => {
    void client.invalidateQueries();
  };
}
