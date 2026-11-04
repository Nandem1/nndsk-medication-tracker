import { useState } from "react";
import { login, register, resetPassword, configured } from "@identity";
import { Field } from "../components/forms";
import { Button } from "../components/ui/button";

type Mode = "login" | "register" | "reset";
export function Account({ sessionError }: { sessionError: string }) {
  const [mode, setMode] = useState<Mode>("login");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const title = mode === "register"
    ? "Crear cuenta"
    : mode === "reset"
      ? "Recuperar contraseña"
      : "Acompañar, con información clara.";
  function change(next: Mode) {
    setMode(next);
    setError("");
    setNotice("");
  }
  return (
    <main className="login">
      <p className="eyebrow">Cuidados · Portal del cuidador</p>
      <h1>{title}</h1>
      <p>Cada persona usa su propia cuenta. El acceso a un paciente requiere su consentimiento.</p>
      <form
        key={mode}
        onSubmit={(event) => {
          event.preventDefault();
          const form = new FormData(event.currentTarget);
          const email = String(form.get("email")).trim();
          const password = String(form.get("password"));
          setBusy(true);
          setError("");
          setNotice("");
          if (mode === "reset") {
            void resetPassword(email).catch(() => {}).finally(() => {
              setNotice("Si existe una cuenta con ese correo, recibirás instrucciones para recuperar tu contraseña.");
              setBusy(false);
            });
          } else {
            void (mode === "register" ? register(email, password) : login(email, password))
              .catch(() => setError(mode === "register"
                ? "No pudimos crear la cuenta. Revisa los datos o intenta iniciar sesión."
                : "No pudimos iniciar sesión. Revisa el correo y la contraseña o vuelve a intentar."))
              .finally(() => setBusy(false));
          }
        }}
      >
        <Field label="Correo electrónico" name="email" type="email" autoComplete="email" />
        {mode !== "reset" && (
          <Field
            label="Contraseña"
            name="password"
            type="password"
            minLength={mode === "register" ? 8 : undefined}
            autoComplete={mode === "register" ? "new-password" : "current-password"}
          />
        )}
        {mode === "register" && <p className="hint">Usa al menos 8 caracteres.</p>}
        {!configured && <p role="alert">El inicio de sesión no está configurado en este entorno.</p>}
        {(error || sessionError) && <p role="alert">{error || sessionError}</p>}
        {notice && <p role="status">{notice}</p>}
        <Button disabled={busy || !configured}>
          {busy ? "Procesando…" : mode === "login" ? "Iniciar sesión" : mode === "register" ? "Crear mi cuenta" : "Enviar instrucciones"}
        </Button>
      </form>
      <div className="actions">
        {mode !== "login" && (
          <Button variant="outline" disabled={busy} onClick={() => change("login")}>
            Iniciar sesión
          </Button>
        )}
        {mode !== "register" && (
          <Button variant="outline" disabled={busy} onClick={() => change("register")}>
            Crear cuenta
          </Button>
        )}
        {mode !== "reset" && (
          <Button variant="outline" disabled={busy} onClick={() => change("reset")}>
            ¿Olvidaste tu contraseña?
          </Button>
        )}
      </div>
    </main>
  );
}
