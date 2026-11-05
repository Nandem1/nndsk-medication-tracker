import { useState } from "react";
import { z } from "zod";
import { Link } from "@tanstack/react-router";
import { useSession } from "../app/session";
import { invitation } from "../lib/api/contracts";
import { invitationMessage, invitationPresets } from "../lib/invitations";
import { dateTimeLabel } from "../lib/inventory";
import { Field, MutationForm } from "../components/forms";
import { Button } from "../components/ui/button";

export function Invite() {
  const { api } = useSession();
  const [created, setCreated] = useState<z.infer<typeof invitation> | null>(null);
  const [copied, setCopied] = useState("");
  const [error, setError] = useState("");
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
    <main className="narrow">
      <p><Link to="/">← Pacientes</Link></p>
      <h1>Invitar a alguien</h1>
      {created ? (
        <section className="panel">
          <h2>Invitación lista</h2>
          <div className="invite-result" role="status">
            <label className="field">
              Código de invitación
              <textarea readOnly value={created.token} />
            </label>
            <div className="actions">
              <Button onClick={() => void copy(invitationMessage(created.token), "Mensaje copiado.")}>
                Copiar mensaje
              </Button>
              <Button variant="outline" onClick={() => void copy(created.token, "Código copiado.")}>
                Copiar código
              </Button>
            </div>
            {copied && <p>{copied}</p>}
          </div>
          {error && <p role="alert">{error}</p>}
          <h3>Qué sigue</h3>
          <ol className="next-steps">
            <li>Envía el mensaje por WhatsApp u otro medio privado.</li>
            <li>La persona abre la app, entra en Ajustes › Acceso de cuidadores y pega el código.</li>
            <li>Cuando autorice, aparecerá en Pacientes.</li>
          </ol>
          <p className="hint">Vence: {dateTimeLabel(created.expires_at)}</p>
          <p className="hint">El código no se vuelve a mostrar al salir de esta pantalla.</p>
          <Button
            variant="outline"
            onClick={() => {
              setCreated(null);
              setCopied("");
              setError("");
            }}
          >
            Crear otra invitación
          </Button>
        </section>
      ) : (
        <section className="panel">
          <p>La persona revisará estos permisos desde su propia cuenta antes de autorizarte. El código vence en 24 horas.</p>
          <MutationForm
            label="Crear invitación"
            quiet
            prepare={(f) => {
              const preset = invitationPresets.find((item) => item.value === f.get("preset"));
              if (!preset) throw new Error("Elige los permisos.");
              const hint = String(f.get("patient_name_hint")).trim();
              return { scopes: preset.scopes, ...(hint ? { patient_name_hint: hint } : {}) };
            }}
            submit={async (data) => {
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
              <legend>¿Qué podrás hacer?</legend>
              {invitationPresets.map((preset) => (
                <div className="choice" key={preset.value}>
                  <label className="check">
                    <input
                      type="radio"
                      name="preset"
                      value={preset.value}
                      defaultChecked={preset.value === "manage"}
                      aria-describedby={"preset-" + preset.value}
                    />
                    {preset.label}
                  </label>
                  <p className="hint" id={"preset-" + preset.value}>{preset.description}</p>
                </div>
              ))}
            </fieldset>
          </MutationForm>
        </section>
      )}
    </main>
  );
}
