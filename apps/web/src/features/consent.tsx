import { useRef, useState } from "react";
import { flushSync } from "react-dom";
import { z } from "zod";
import { Link } from "@tanstack/react-router";
import { useSession } from "../app/session";
import { useList, useRefresh } from "../lib/queries";
import {
  preview,
  link,
  scopeLabels,
} from "../lib/api/contracts";
import { invitationToken } from "../lib/invitations";
import { dateTimeLabel } from "../lib/inventory";
import { MutationForm } from "../components/forms";
import { Button } from "../components/ui/button";
import { QueryState } from "../components/query-state";
export function Consent() {
  const { api } = useSession();
  const refresh = useRefresh();
  const links = useList("/caregiver-links", link);
  const reviewForm = useRef<HTMLFormElement>(null);
  const [consent, setConsent] = useState<{
    token: string;
    preview: z.infer<typeof preview>;
  } | null>(null);
  const [error, setError] = useState("");
  const [received, setReceived] = useState("");
  const ordered = links.data?.toSorted((a, b) => Number(b.status === "active") - Number(a.status === "active"));
  return (
    <main className="narrow">
      <h1>Accesos</h1>
      <p>Cada paciente decide quién ve sus datos y puede quitar ese acceso cuando quiera.</p>
      <p>¿Quieres cuidar a alguien? <Link to="/invite">Invítalo desde aquí.</Link></p>
      {error && <p role="alert">{error}</p>}
      <section className="panel">
        <h2>Aceptar una invitación</h2>
        <MutationForm
          label="Revisar invitación"
          quiet
          formRef={reviewForm}
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
              rows={4}
              value={received}
              onChange={(event) => setReceived(event.target.value)}
            />
          </label>
          <Button
            className="clipboard-action"
            type="button"
            variant="outline"
            onClick={() => {
              setError("");
              void navigator.clipboard.readText()
                .then((text) => {
                  flushSync(() => setReceived(text));
                  reviewForm.current?.requestSubmit();
                })
                .catch(() => setError("No pudimos leer el portapapeles. Pega el código en el campo."));
            }}
          >
            Pegar código
          </Button>
        </MutationForm>
        {consent && (
          <div className="invite-result">
            <h3>Revisa antes de aceptar</h3>
            <p><strong>{consent.preview.caregiver_display_name ?? "Cuidador sin nombre"}</strong> podrá:</p>
            <ul>
              {consent.preview.scopes.map((s) => (
                <li key={s}>{scopeLabels[s]}</li>
              ))}
            </ul>
            {consent.preview.patient_name_hint && <p>Nombre sugerido: {consent.preview.patient_name_hint}</p>}
            <p className="hint">Vence: {dateTimeLabel(consent.preview.expires_at)}</p>
            <p className="hint">Podrás quitar este acceso en cualquier momento.</p>
            <MutationForm
              label="Acepto y autorizo el acceso"
              quiet
              prepare={() => ({ token: consent.token })}
              submit={(data) =>
                api.request("/invitations/accept", link, data)
              }
              done={() => {
                setConsent(null);
                setReceived("");
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
      <section>
        <h2>Accesos vinculados</h2>
        <QueryState query={links}>
          {links.data?.length === 0 && (
            <p>Todavía no hay accesos vinculados.</p>
          )}
          {ordered?.map((item) => (
            <article className="panel" key={item.link_id}>
              <p>Paciente: {item.patient_display_name ?? "Nombre no disponible"}</p>
              <p>Cuidador: {item.caregiver_display_name ?? "Nombre no disponible"}</p>
              <p>
                {item.status === "active"
                  ? "Acceso autorizado"
                  : "Acceso quitado"}{" "}
                · {item.scopes.map((s) => scopeLabels[s]).join(", ")}
              </p>
              {item.status === "active" && (
                <Button
                  variant="destructive"
                  onClick={() => {
                    if (
                      !window.confirm(
                        "¿Quitar el acceso? La cuenta cuidadora dejará de consultar estos datos.",
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
                  Quitar acceso
                </Button>
              )}
            </article>
          ))}
        </QueryState>
      </section>
    </main>
  );
}
