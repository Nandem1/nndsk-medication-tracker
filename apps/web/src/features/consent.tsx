import { useState } from "react";
import { z } from "zod";
import { useSession } from "../app/session";
import { useList, useRefresh } from "../lib/queries";
import {
  invitation,
  preview,
  link,
  scope,
  scopeLabels,
} from "../lib/api/contracts";
import { MutationForm, Field } from "../components/forms";
import { Button } from "../components/ui/button";
import { QueryState } from "../components/query-state";
export function Consent() {
  const { api } = useSession();
  const refresh = useRefresh();
  const links = useList("/caregiver-links", link);
  const [created, setCreated] = useState<z.infer<typeof invitation> | null>(
    null,
  );
  const [consent, setConsent] = useState<{
    token: string;
    preview: z.infer<typeof preview>;
  } | null>(null);
  const [error, setError] = useState("");
  return (
    <main>
      <h1>Invitaciones y consentimiento</h1>
      <p>
        El cuidador genera una invitación. El paciente revisa los permisos desde
        su propia cuenta antes de aceptarla.
      </p>
      <div className="columns">
        <section className="panel">
          <h2>Invitar a un paciente</h2>
          <p>
            Cada envío crea una invitación nueva. Si se pierde la respuesta,
            vuelve a crearla. El código anterior no se puede recuperar y vence
            en 24 horas.
          </p>
          <MutationForm
            label="Crear invitación"
            prepare={(f) => ({
              scopes: f.getAll("scope").map((v) => scope.parse(v)),
            })}
            submit={async ({ scopes }) => {
              setCreated(null);
              setCreated(
                await api.request("/invitations", invitation, {
                  scopes,
                  client_operation_id: crypto.randomUUID(),
                }),
              );
            }}
            done={() => {}}
          >
            <fieldset>
              <legend>Permisos solicitados</legend>
              {scope.options.map((s) => (
                <label className="check" key={s}>
                  <input
                    name="scope"
                    value={s}
                    type="checkbox"
                    defaultChecked
                    disabled={s === "read"}
                  />
                  {scopeLabels[s]}
                  {s === "read" && (
                    <input type="hidden" name="scope" value="read" />
                  )}
                </label>
              ))}
            </fieldset>
          </MutationForm>
          {created && (
            <div className="notice" role="status">
              <p>
                Comparte este código por un medio privado. Vence el{" "}
                {new Date(created.expires_at).toLocaleString("es-CL")}.
              </p>
              <label className="field">
                Código de invitación
                <textarea readOnly value={created.token} />
              </label>
              <p>
                No se guarda al cerrar esta pantalla. Si la respuesta se pierde,
                crea una nueva invitación.
              </p>
            </div>
          )}
        </section>
        <section className="panel">
          <h2>Aceptar como paciente</h2>
          <MutationForm
            label="Revisar invitación"
            prepare={(f) => ({ token: String(f.get("token")).trim() })}
            submit={async (data) => {
              setConsent(null);
              setConsent({
                token: data.token,
                preview: await api.request("/invitations/preview", preview, {
                  token: data.token,
                }),
              });
            }}
            done={() => {}}
          >
            <Field label="Código recibido" name="token" />
          </MutationForm>
          {consent && (
            <div className="notice">
              <h3>Revisa antes de aceptar</h3>
              <p>Darás acceso a la cuenta {consent.preview.caregiver_id}.</p>
              <ul>
                {consent.preview.scopes.map((s) => (
                  <li key={s}>{scopeLabels[s]}</li>
                ))}
              </ul>
              <p>Podrás revocar este acceso en cualquier momento.</p>
              <MutationForm
                label="Acepto y autorizo el acceso"
                prepare={() => ({ token: consent.token })}
                submit={(data) =>
                  api.request("/invitations/accept", link, data)
                }
                done={() => {
                  setConsent(null);
                  refresh();
                }}
              >
                <label className="check">
                  <input type="checkbox" required />
                  Entiendo los permisos y autorizo el acceso a mis datos.
                </label>
              </MutationForm>
            </div>
          )}
        </section>
      </div>
      <section>
        <h2>Accesos vinculados</h2>
        {error && <p role="alert">{error}</p>}
        <QueryState query={links}>
          {links.data?.length === 0 && (
            <p>Todavía no hay accesos vinculados.</p>
          )}
          {links.data?.map((item) => (
            <article className="panel" key={item.link_id}>
              <p>Paciente {item.patient_id}</p>
              <p>Cuidador {item.caregiver_id}</p>
              <p>
                {item.status === "active"
                  ? "Acceso autorizado"
                  : "Acceso revocado"}{" "}
                · {item.scopes.map((s) => scopeLabels[s]).join(", ")}
              </p>
              {item.status === "active" && (
                <Button
                  variant="destructive"
                  onClick={() => {
                    if (
                      !window.confirm(
                        "¿Revocar el acceso? La cuenta cuidadora dejará de consultar estos datos.",
                      )
                    )
                      return;
                    void api
                      .request(
                        "/caregiver-links/" + item.link_id,
                        z.null(),
                        undefined,
                        "DELETE",
                      )
                      .then(refresh)
                      .catch((e) => setError(e.message));
                  }}
                >
                  Revocar acceso
                </Button>
              )}
            </article>
          ))}
        </QueryState>
      </section>
    </main>
  );
}
