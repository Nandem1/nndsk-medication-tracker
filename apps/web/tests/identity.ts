export type Identity = { uid: string; token: () => Promise<string> };
export const configured = true;
let identity: Identity | null = null;
const listeners = new Set<(identity: Identity | null) => void>();
export function watch(callback: (identity: Identity | null) => void) {
  listeners.add(callback);
  callback(identity);
  return () => {
    listeners.delete(callback);
  };
}
export async function login(email: string, password: string) {
  if (password !== "test-only") throw new Error("Invalid synthetic password");
  const uid = "synthetic-" + email.split("@")[0];
  identity = { uid, token: async () => uid };
  listeners.forEach((fn) => fn(identity));
}
export async function logout() {
  identity = null;
  listeners.forEach((fn) => fn(null));
}
