import {
  invitationPresets,
  invitationToken,
  invitationMessage,
} from "../lib/invitations";
import { useState } from "react";
import { z } from "zod";
import { useSession } from "../app/session";
import { useList, useRefresh } from "../lib/queries";
import {
  invitation,
  preview,
  link,
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
  const [copied, setCopied] = useState("");
  const [received, setReceived] = useState("");
  async function copy(value: string, message: string) {
    setError("");
    setCopied("");
    try {
      await navigator.clipboard.writeText(value);
      setCopied(message);
    } catch {
      setError("No pudimos copiar. Selecciona el código y cópialo manualmente.");
    }
  }
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
            prepare={(f) => {
              const preset = invitationPresets.find((item) => item.value === f.get("preset"));
              if (!preset) throw new Error("Elige los permisos.");
              const hint = String(f.get("patient_name_hint")).trim();
              return { scopes: preset.scopes, ...(hint ? { patient_name_hint: hint } : {}) };
            }}
            submit={async (data) => {
              setCreated(null);
              setCopied("");
              setCreated(await api.request("/invitations", invitation, {
                ...data,
                client_operation_id: crypto.randomUUID(),
              }));
            }}
            done={() => {}}
          >
            <Field
              label="¿Cómo se llama?"
              name="patient_name_hint"
              required={false}
              maxLength={60}
              placeholder="Por ejemplo, Mamá"
            />
            <fieldset>
              <legend>Permisos solicitados</legend>
              {invitationPresets.map((preset) => (
                <label className="check" key={preset.value}>
                  <input
                    type="radio"
                    name="preset"
                    value={preset.value}
                    defaultChecked={preset.value === "manage"}
                  />
                  {preset.label}
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
              <div className="actions">
                <Button variant="outline" onClick={() => void copy(created.token, "Código copiado.")}>
                  Copiar código
                </Button>
                <Button variant="outline" onClick={() => void copy(invitationMessage(created.token), "Mensaje copiado.")}>
                  Copiar mensaje
                </Button>
              </div>
              {copied && <p role="status">{copied}</p>}
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
            prepare={(f) => ({ token: invitationToken(String(f.get("token"))) })}
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
            <label className="field">
              Código recibido
              <textarea
                name="token"
                required
                value={received}
                onChange={(event) => setReceived(event.target.value)}
              />
            </label>
            <Button
              className="clipboard-action"
              type="button"
              variant="outline"
              onClick={() => {
                void navigator.clipboard.readText()
                  .then(setReceived)
                  .catch(() => setError("No pudimos leer el portapapeles. Pega el código en el campo."));
              }}
            >
              Pegar código
            </Button>
          </MutationForm>
          {consent && (
            <div className="notice">
              <h3>Revisa antes de aceptar</h3>
              <p><strong>{consent.preview.caregiver_display_name ?? "Cuidador sin nombre"}</strong> podrá:</p>
              <p>Vence el {new Date(consent.preview.expires_at).toLocaleString("es-CL")}.</p>
              {consent.preview.patient_name_hint && <p>Nombre sugerido: {consent.preview.patient_name_hint}</p>}
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
              <p>Paciente: {item.patient_display_name ?? "Nombre no disponible"}</p>
              <p>Cuidador: {item.caregiver_display_name ?? "Nombre no disponible"}</p>
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
