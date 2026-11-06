import { useState } from "react";
import { z } from "zod";
import { Link } from "@tanstack/react-router";
import { useSession } from "../app/session";
import { family as familySchema, invitation, type Family, type FamilyMember, type FamilyRole } from "../lib/api/contracts";
import { useList, useRefresh } from "../lib/queries";
import { invitationLink, invitationMessage, isNewMember, memberName, roleLabels, roles } from "../lib/invitations";
import { dateTimeLabel } from "../lib/inventory";
import { Field, MutationForm } from "../components/forms";
import { Button } from "../components/ui/button";
import { QueryState } from "../components/query-state";
import { Avatar } from "../components/avatar";
import { QRCode } from "../components/qr";

export function FamilyPage() {
  const families = useList("/families", familySchema);
  return (
    <main>
      <p className="eyebrow">Tu círculo de cuidado</p>
      <h1>Familia</h1>
      <p className="lead">Quienes están en la familia cuidan juntos. Cada paciente se une una vez y ve siempre quién tiene acceso.</p>
      <QueryState query={families}>
        {families.data?.length === 0 && <CreateFamily />}
        {families.data?.map((item) => <FamilyCard key={item.family_id} item={item} />)}
      </QueryState>
      <p className="hint">
        ¿Te invitaron? <Link to="/unirse">Únete con un código</Link>.
      </p>
    </main>
  );
}

function CreateFamily() {
  const { api } = useSession();
  const refresh = useRefresh();
  return (
    <section className="panel hero-panel">
      <h2>Crea tu familia</h2>
      <p>Después invita a tus padres como pacientes y a quienes te ayudan a cuidarlos. Basta una invitación por persona.</p>
      <MutationForm
        label="Crear familia"
        quiet
        prepare={(f) => ({ name: String(f.get("name")).trim() })}
        submit={(data) => api.request("/families", familySchema, data)}
        done={refresh}
      >
        <Field label="Nombre de la familia" name="name" value="Mi familia" maxLength={60} />
      </MutationForm>
    </section>
  );
}

function FamilyCard({ item }: { item: Family }) {
  const admin = item.role === "admin";
  const patients = item.members.filter((m) => m.role === "patient");
  const others = item.members.filter((m) => m.role !== "patient");
  return (
    <section className="panel family-card" aria-labelledby={"family-" + item.family_id}>
      <div className="family-head">
        <div>
          <h2 id={"family-" + item.family_id}>{item.name}</h2>
          <p className="hint">{item.members.length === 1 ? "1 persona" : item.members.length + " personas"} · Tu rol: {roleLabels[item.role]}</p>
        </div>
        <div className="avatar-stack" aria-hidden="true">
          {item.members.slice(0, 5).map((m) => <Avatar key={m.user_id} name={m.display_name} seed={m.user_id} />)}
        </div>
      </div>
      <MemberGroup title="Pacientes" empty="Todavía no hay pacientes. Invita a quien toma los medicamentos." members={patients} family={item} />
      <MemberGroup title="Quienes cuidan" members={others} family={item} />
      {admin ? <InvitePanel item={item} /> : <p className="hint">Sólo quien administra puede invitar o quitar personas.</p>}
      <LeaveFamily item={item} />
    </section>
  );
}

function MemberGroup({ title, members, family, empty }: { title: string; members: FamilyMember[]; family: Family; empty?: string }) {
  return (
    <div className="member-group">
      <h3>{title}</h3>
      {members.length === 0 && empty && <p className="hint">{empty}</p>}
      <ul className="members">
        {members.map((m) => <MemberRow key={m.user_id} member={m} family={family} />)}
      </ul>
    </div>
  );
}

function MemberRow({ member, family }: { member: FamilyMember; family: Family }) {
  const { api } = useSession();
  const refresh = useRefresh();
  const [error, setError] = useState("");
  return (
    <li className="member">
      <Avatar name={member.display_name} seed={member.user_id} />
      <span className="member-name">
        {memberName(member)}
        {member.you && <span className="badge badge-soft">Tú</span>}
        {isNewMember(member) && <span className="badge badge-new">Nuevo</span>}
      </span>
      <span className="member-role">{roleLabels[member.role]}</span>
      {family.role === "admin" && !member.you && (
        <Button
          variant="outline"
          onClick={() => {
            if (!window.confirm("¿Quitar a " + memberName(member) + " de " + family.name + "? Dejará de ver y de ser visto por la familia.")) return;
            setError("");
            void api.request("/families/" + family.family_id + "/members/" + member.user_id, z.null(), undefined, "DELETE").then(refresh).catch((e) => setError(e.message));
          }}
        >
          Quitar
        </Button>
      )}
      {error && <p role="alert">{error}</p>}
    </li>
  );
}

function InvitePanel({ item }: { item: Family }) {
  const { api } = useSession();
  const [role, setRole] = useState<FamilyRole>("patient");
  const [created, setCreated] = useState<{ token: string; expires: string; role: FamilyRole } | null>(null);
  const [copied, setCopied] = useState("");
  const [error, setError] = useState("");
  async function copy(value: string, message: string) {
    setError("");
    try {
      await navigator.clipboard.writeText(value);
      setCopied(message);
    } catch {
      setError("No pudimos copiar. Selecciona el texto y cópialo manualmente.");
    }
  }
  if (created) {
    const link = invitationLink(created.token);
    return (
      <div className="invite-result" role="status">
        <div className="invite-grid">
          <QRCode value={link} label={"QR para unirse a " + item.name} />
          <div>
            <h3>Invitación lista · {roleLabels[created.role]}</h3>
            <p>Para configurar un teléfono en persona, abre la cámara del otro teléfono y escanea este código.</p>
            <ol className="next-steps">
              <li>O envía el mensaje por WhatsApp u otro medio privado.</li>
              <li>La persona toca el enlace, o pega el código en Ajustes › Familia.</li>
              <li>Al unirse aparecerá aquí, y los pacientes verán que se unió.</li>
            </ol>
            <div className="actions">
              <Button onClick={() => void copy(invitationMessage(created.token, item.name), "Mensaje copiado.")}>Copiar mensaje</Button>
              <Button variant="outline" onClick={() => void copy(created.token, "Código copiado.")}>Copiar código</Button>
            </div>
            {copied && <p>{copied}</p>}
            {error && <p role="alert">{error}</p>}
            <label className="field">
              Código de invitación
              <textarea readOnly value={created.token} rows={2} />
            </label>
            <p className="hint">Vence: {dateTimeLabel(created.expires)}</p>
            <p className="hint">Sirve para una sola persona y no se vuelve a mostrar.</p>
            <Button variant="outline" onClick={() => { setCreated(null); setCopied(""); }}>Invitar a otra persona</Button>
          </div>
        </div>
      </div>
    );
  }
  return (
    <div className="invite-panel">
      <h3>Invitar a la familia</h3>
      <MutationForm
        label="Crear invitación"
        quiet
        prepare={(f) => {
          const hint = String(f.get("patient_name_hint") ?? "").trim();
          return { role, ...(role === "patient" && hint ? { patient_name_hint: hint } : {}) };
        }}
        submit={async (data) => {
          const out = await api.request("/families/" + item.family_id + "/invitations", invitation, { ...data, client_operation_id: crypto.randomUUID() });
          setCreated({ token: out.token, expires: out.expires_at, role: data.role });
        }}
        done={() => {}}
      >
        <fieldset>
          <legend>¿Cómo participará?</legend>
          <div className="role-options">
            {roles.map((option) => (
              // La descripción queda fuera de la etiqueta: el nombre accesible es sólo el rol.
              <div className={"role-option" + (role === option.value ? " is-selected" : "")} key={option.value} onClick={() => setRole(option.value)}>
                <input type="radio" id={"role-input-" + option.value} name="role" value={option.value} checked={role === option.value} onChange={() => setRole(option.value)} aria-describedby={"role-" + option.value} />
                <label className="role-title" htmlFor={"role-input-" + option.value}>{option.label}</label>
                <span className="hint" id={"role-" + option.value}>{option.description}</span>
              </div>
            ))}
          </div>
        </fieldset>
        {role === "patient" && <Field label="¿Cómo se llama? (opcional)" name="patient_name_hint" required={false} maxLength={60} placeholder="Por ejemplo, Mamá" />}
      </MutationForm>
    </div>
  );
}

function LeaveFamily({ item }: { item: Family }) {
  const { api } = useSession();
  const refresh = useRefresh();
  const me = item.members.find((m) => m.you);
  const [error, setError] = useState("");
  if (!me) return null;
  return (
    <div className="leave">
      <Button
        variant="destructive"
        onClick={() => {
          const consequence = me.role === "patient" ? "Nadie de la familia podrá seguir viendo tu información." : "Dejarás de ver a los pacientes de la familia.";
          if (!window.confirm("¿Salir de " + item.name + "? " + consequence)) return;
          setError("");
          void api.request("/families/" + item.family_id + "/members/" + me.user_id, z.null(), undefined, "DELETE").then(refresh).catch((e) => setError(e.message));
        }}
      >
        Salir de la familia
      </Button>
      {error && <p role="alert">{error}</p>}
    </div>
  );
}
