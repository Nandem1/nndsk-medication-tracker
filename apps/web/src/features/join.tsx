import { useRef, useState } from "react";
import { flushSync } from "react-dom";
import { z } from "zod";
import { useNavigate } from "@tanstack/react-router";
import { useSession } from "../app/session";
import { family, familyPreview } from "../lib/api/contracts";
import { useRefresh } from "../lib/queries";
import { invitationToken, memberName, roleLabels } from "../lib/invitations";
import { dateTimeLabel } from "../lib/inventory";
import { MutationForm } from "../components/forms";
import { Button } from "../components/ui/button";
import { Avatar } from "../components/avatar";

/** Lee el código del fragmento y lo quita de la barra de direcciones. */
function tokenFromHash() {
  const hash = window.location.hash.slice(1);
  if (!hash) return "";
  history.replaceState(null, "", window.location.pathname);
  return hash;
}

export function JoinFamily() {
  const { api } = useSession();
  const refresh = useRefresh();
  const navigate = useNavigate();
  const reviewForm = useRef<HTMLFormElement>(null);
  const [received, setReceived] = useState(tokenFromHash);
  const [error, setError] = useState("");
  const [consent, setConsent] = useState<{ token: string; preview: z.infer<typeof familyPreview> } | null>(null);
  return (
    <main className="narrow">
      <p className="eyebrow">Invitación</p>
      <h1>Unirse a una familia</h1>
      <p className="lead">Pega el código o el mensaje completo que te enviaron. Antes de unirte verás quiénes están.</p>
      {error && <p role="alert">{error}</p>}
      <section className="panel">
        <MutationForm
          label="Revisar invitación"
          quiet
          formRef={reviewForm}
          prepare={(f) => ({ token: invitationToken(String(f.get("token"))) })}
          submit={async (data) => {
            setConsent(null);
            // La vista previa no es una mutación: sólo recibe el token.
            setConsent({ token: data.token, preview: await api.request("/family-invitations/preview", familyPreview, { token: data.token }) });
          }}
          done={() => {}}
        >
          <label className="field">
            Código recibido
            <textarea name="token" required rows={3} value={received} onChange={(event) => setReceived(event.target.value)} />
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
            <h2>{consent.preview.family_name}</h2>
            <p>
              <strong>{consent.preview.inviter_display_name ?? "Alguien"}</strong> te invita como <strong>{roleLabels[consent.preview.role]}</strong>.
            </p>
            {consent.preview.role === "patient" && (
              <p>Al unirte, quienes cuidan en esta familia, y quienes se unan después, podrán ver tu agenda y tu inventario. Verás siempre quiénes son y podrás salir cuando quieras.</p>
            )}
            <h3>Quiénes están</h3>
            <ul className="members">
              {consent.preview.members.map((m) => (
                <li className="member" key={m.user_id}>
                  <Avatar name={m.display_name} seed={m.user_id} />
                  <span className="member-name">{memberName(m)}</span>
                  <span className="member-role">{roleLabels[m.role]}</span>
                </li>
              ))}
            </ul>
            {consent.preview.patient_name_hint && <p>Nombre sugerido: {consent.preview.patient_name_hint}</p>}
            <p className="hint">Vence: {dateTimeLabel(consent.preview.expires_at)}</p>
            <MutationForm
              label="Unirme a la familia"
              quiet
              prepare={() => ({ token: consent.token })}
              submit={(data) => api.request("/family-invitations/accept", family, data)}
              done={() => {
                refresh();
                void navigate({ to: "/familia" });
              }}
            >
              <label className="check">
                <input type="checkbox" required />
                {consent.preview.role === "patient" ? "Entiendo quiénes podrán ver mi información." : "Quiero unirme a esta familia."}
              </label>
            </MutationForm>
          </div>
        )}
      </section>
    </main>
  );
}
