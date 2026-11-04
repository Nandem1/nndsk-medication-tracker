import { useState, type ReactNode } from "react";
import { logout } from "@identity";
import { useSession } from "../app/session";
import { useRefresh, useResource } from "../lib/queries";
import { me, profile, type Profile } from "../lib/api/contracts";
import { Field, MutationForm } from "../components/forms";
import { QueryState } from "../components/query-state";
import { Button } from "../components/ui/button";

export function ProfileEditor({
  initial,
  path = "/me/profile",
  done,
  label = "Guardar nombre",
}: {
  initial: Pick<Profile, "display_name" | "profile_version">;
  path?: string;
  done: () => void;
  label?: string;
}) {
  const { api } = useSession();
  const [snapshot] = useState(initial);
  return (
    <MutationForm
      label={label}
      prepare={(form) => {
        const display_name = String(form.get("display_name")).trim();
        if (
          [...display_name].length < 1 ||
          [...display_name].length > 60 ||
          /[\u0000\r\n\u0085\u2028\u2029]/u.test(display_name)
        ) {
          throw new Error("Escribe un nombre de 1 a 60 caracteres, sin saltos de línea.");
        }
        return { display_name, expected_version: snapshot.profile_version };
      }}
      submit={(body) => api.request(path, profile, body, "PUT")}
      done={done}
    >
      <Field
        label="Nombre visible"
        name="display_name"
        value={snapshot.display_name ?? ""}
        autoComplete="name"
      />
      <p className="hint">
        Este nombre será visible para las personas con las que compartes acceso.
      </p>
    </MutationForm>
  );
}

export function ProfileGate({ children }: { children: ReactNode }) {
  const query = useResource("/me", me);
  const refresh = useRefresh();
  const [editorVersion, setEditorVersion] = useState(0);
  const [error, setError] = useState("");
  if (query.data?.profile_complete) return children;
  return (
    <main className="login">
      <QueryState query={query}>
        {query.data && (
          <>
            <p className="eyebrow">Tu cuenta</p>
            <h1>¿Cómo te llamas?</h1>
            <p>Usaremos tu nombre para que tu familia te reconozca.</p>
            <ProfileEditor
              key={editorVersion}
              initial={query.data}
              done={refresh}
              label="Continuar"
            />
            <Button
              className="clipboard-action"
              variant="outline"
              onClick={() => {
                void query.refetch().then((result) => {
                  if (result.isSuccess) setEditorVersion((value) => value + 1);
                });
              }}
            >
              Recargar perfil
            </Button>
          </>
        )}
      </QueryState>
      {error && <p role="alert">{error}</p>}
      <Button
        variant="outline"
        onClick={() => {
          void logout().catch(() => setError("No pudimos cerrar la sesión. Intenta otra vez."));
        }}
      >
        Cerrar sesión
      </Button>
    </main>
  );
}

export function MyProfile() {
  const query = useResource("/me", me);
  const refresh = useRefresh();
  const [editing, setEditing] = useState<Profile | null>(null);
  return (
    <main>
      <h1>Mi perfil</h1>
      <QueryState query={query}>
        {query.data && (
          <section className="panel">
            {editing ? (
              <>
                <ProfileEditor
                  initial={editing}
                  done={() => {
                    setEditing(null);
                    refresh();
                  }}
                />
                <Button variant="outline" onClick={() => setEditing(null)}>
                  Cancelar edición
                </Button>
              </>
            ) : (
              <>
                <h2>{query.data.display_name}</h2>
                <Button
                  variant="outline"
                  onClick={() => setEditing(query.data ?? null)}
                >
                  Cambiar nombre
                </Button>
              </>
            )}
          </section>
        )}
      </QueryState>
    </main>
  );
}
