import { Link, useSearch } from "@tanstack/react-router";
import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { useQueryClient } from "@tanstack/react-query";
import { watch, logout, type Identity } from "@identity";
import { Api } from "../lib/api/client";
import { patient } from "../lib/api/contracts";
import { useList } from "../lib/queries";
import { parseSection, patientLabel } from "../lib/sections";
import { Button } from "../components/ui/button";
import { Account } from "../features/account";
import { ProfileGate } from "../features/profile";
type Session =
  | { status: "loading" }
  | { status: "anonymous" }
  | { status: "authenticated"; identity: Identity; api: Api };
const Context = createContext<Extract<
  Session,
  { status: "authenticated" }
> | null>(null);
export function useSession() {
  const value = useContext(Context);
  if (!value) throw new Error("Sesión requerida");
  return value;
}
/** Selector de paciente. La carga y los errores se informan en la página, no en el encabezado. */
function PatientTabs() {
  const query = useList("/patients", patient);
  const search = useSearch({ strict: false });
  if (!query.data?.length) return null;
  return (
    <nav className="patient-tabs" aria-label="Pacientes">
      {query.data.map((item) => (
        <Link
          key={item.patient_id}
          to="/patients/$patientId"
          params={{ patientId: item.patient_id }}
          search={{ section: parseSection(search.section) }}
          activeOptions={{ includeSearch: false }}
        >
          {patientLabel(item)}
        </Link>
      ))}
    </nav>
  );
}
/** Marca: una cápsula dentro de un corazón, dibujada con los colores del tema. */
export function BrandMark() {
  return (
    <svg className="brand-mark" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="9" fill="var(--mt-color-accent-fill)" />
      <path d="M16 24.5s-7.5-4.4-7.5-10.1A4.3 4.3 0 0 1 16 11.8a4.3 4.3 0 0 1 7.5 2.6c0 5.7-7.5 10.1-7.5 10.1Z" fill="var(--mt-color-on-accent)" opacity=".95" />
      <path d="M13 17.5l6-6" stroke="var(--mt-color-accent-fill)" strokeWidth="2.2" strokeLinecap="round" />
    </svg>
  );
}

export function SessionBoundary({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session>({ status: "loading" });
  const [error, setError] = useState("");
  const client = useQueryClient();
  useEffect(() => {
    let generation = 0;
    let active = true;
    const stop = watch((identity) => {
      const current = ++generation;
      if (identity) setError("");
      setSession({ status: "loading" });
      void client.cancelQueries().then(() => {
        if (!active || current !== generation) return;
        client.clear();
        setSession(
          identity
            ? { status: "authenticated", identity, api: new Api(identity) }
            : { status: "anonymous" },
        );
      });
    });
    return () => {
      active = false;
      generation++;
      stop();
    };
  }, [client]);
  useEffect(() => {
    const deny = (event: Event) => {
      if (
        !(event instanceof CustomEvent) ||
        session.status !== "authenticated" ||
        event.detail !== session.identity.uid
      )
        return;
      setError(
        "No tienes permiso para consultar esta información. La sesión se cerró y los datos locales se borraron.",
      );
      setSession({ status: "loading" });
      void client.cancelQueries().then(() => {
        client.clear();
        return logout();
      });
    };
    window.addEventListener("access-denied", deny);
    return () => window.removeEventListener("access-denied", deny);
  }, [client, session]);
  if (session.status === "loading")
    return <p role="status">Cargando sesión…</p>;
  if (session.status === "anonymous") return <Account sessionError={error} />;
  return (
    <Context.Provider value={session}>
      <ProfileGate>
        <div key={session.identity.uid}>
        <header className="app-header">
          <Link to="/" className="brand" aria-label="Cuidados, inicio">
            <BrandMark />
            <span className="brand-text">Cuidados<small>Portal familiar de Mis tomas</small></span>
          </Link>
          <PatientTabs />
          <Button
            variant="outline"
            onClick={() => {
              setSession({ status: "loading" });
              void client
                .cancelQueries()
                .then(() => {
                  client.clear();
                  return logout();
                })
                .catch(() => setSession({ status: "anonymous" }));
            }}
          >
            Cerrar sesión
          </Button>
        </header>
        {children}
        </div>
      </ProfileGate>
    </Context.Provider>
  );
}
