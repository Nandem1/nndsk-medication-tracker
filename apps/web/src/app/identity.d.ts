declare module "@identity" {
  export type Identity = { uid: string; token: () => Promise<string> };
  export function watch(
    callback: (identity: Identity | null) => void,
  ): () => void;
  export function login(email: string, password: string): Promise<void>;
  export function logout(): Promise<void>;
  export const configured: boolean;
}
