import { useQuery, useQueryClient } from "@tanstack/react-query";
import { z } from "zod";
import { useSession } from "../app/session";
export function useList<T>(path: string, schema: z.ZodType<T>, enabled = true) {
  const { api, identity } = useSession();
  return useQuery({
    queryKey: [identity.uid, path],
    queryFn: ({ signal }) => api.all(path, schema, signal),
    enabled,
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

export function useResource<T>(path: string, schema: z.ZodType<T>, enabled = true) {
  const { api, identity } = useSession();
  return useQuery({
    queryKey: [identity.uid, path],
    queryFn: ({ signal }) => api.request(path, schema, undefined, "GET", signal),
    enabled,
    retry: false,
    staleTime: 0,
  });
}
