import { initializeApp } from "firebase/app";
import {
  initializeAuth,
  inMemoryPersistence,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signOut,
  createUserWithEmailAndPassword,
  sendPasswordResetEmail,
} from "firebase/auth";
const config = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
};
export const configured = Object.values(config).every(Boolean);
const auth = configured
  ? initializeAuth(initializeApp(config), { persistence: inMemoryPersistence })
  : null;
export type Identity = { uid: string; token: () => Promise<string> };
export function watch(callback: (identity: Identity | null) => void) {
  if (!auth) {
    callback(null);
    return () => {};
  }
  return onAuthStateChanged(auth, (user) =>
    callback(user ? { uid: user.uid, token: () => user.getIdToken() } : null),
  );
}
export async function login(email: string, password: string) {
  if (!auth)
    throw new Error("El inicio de sesión todavía no está configurado.");
  await signInWithEmailAndPassword(auth, email, password);
}
export async function logout() {
  if (auth) await signOut(auth);
}

export async function register(email: string, password: string) {
  if (!auth) throw new Error("El acceso no está configurado.");
  await createUserWithEmailAndPassword(auth, email, password);
}
export async function resetPassword(email: string) {
  if (!auth) throw new Error("El acceso no está configurado.");
  await sendPasswordResetEmail(auth, email);
}
