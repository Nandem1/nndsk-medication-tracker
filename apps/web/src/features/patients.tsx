import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useSession } from "../app/session";
import {
  patient,
  scopeLabels,
  projection,
  adherence,
  type Patient,
} from "../lib/api/contracts";
import { useList } from "../lib/queries";
import { patientLabel } from "../lib/sections";
import { shiftDate, patientDate } from "../lib/dashboard";
import { QueryState } from "../components/query-state";

function PatientCard({ person }: { person: Patient }) {
  const { api, identity } = useSession();
  const date = patientDate(person.timezone);
  const summary = useQuery({
    queryKey: [identity.uid, "patient-summary", person.patient_id, date, person.timezone],
    queryFn: async ({ signal }) => {
      const base = "/patients/" + person.patient_id;
      const report = await api.request(
        base + "/adherence?from=" + date + "&to=" + shiftDate(date, 1),
        adherence,
        undefined,
        "GET",
        signal,
      );
      const inventory = await api.all(base + "/inventory", projection, signal);
      return {
        report,
        replenishments: inventory.filter((item) => item.low_stock).length,
      };
    },
  });
  return (
    <article className="panel patient">
      <Link
        to="/patients/$patientId"
        params={{ patientId: person.patient_id }}
        search={{ section: "treatments" }}
      >
        <h2>{patientLabel(person)}</h2>
      </Link>
      <p>{person.scopes.map((scope) => scopeLabels[scope]).join(" · ")}</p>
      <QueryState query={summary}>
        {summary.data && (
          <>
            <p className="eyebrow">Hoy hasta ahora · {date} · {person.timezone}</p>
            <p>
              <strong>
                {summary.data.report.summary.confirmed} de {summary.data.report.summary.evaluable} registradas
              </strong>
            </p>
            <p>{summary.data.report.summary.unconfirmed} sin confirmar</p>
            <p>{summary.data.replenishments} reposiciones por revisar</p>
          </>
        )}
      </QueryState>
      <Link
        to="/patients/$patientId"
        params={{ patientId: person.patient_id }}
        search={{ section: "treatments" }}
      >
        Abrir registro →
      </Link>
    </article>
  );
}

export function Patients() {
  const query = useList("/patients", patient);
  return (
    <main>
      <p className="eyebrow">Seguimiento con consentimiento</p>
      <h1>Personas a tu cuidado</h1>
      <p>Revisa los registros de hoy y las reposiciones pendientes.</p>
      <Link to="/consent">Invitar a alguien</Link>
      <QueryState query={query}>
        {query.data?.length === 0 && (
          <p>No tienes pacientes vinculados. Crea una invitación para comenzar.</p>
        )}
        <div className="patients">
          {query.data?.map((person) => (
            <PatientCard key={person.patient_id} person={person} />
          ))}
        </div>
      </QueryState>
    </main>
  );
}
