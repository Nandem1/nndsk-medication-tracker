import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useSession } from "../app/session";
import {
  patient,
  projection,
  adherence,
  type Patient,
} from "../lib/api/contracts";
import { useList } from "../lib/queries";
import { patientLabel } from "../lib/sections";
import { shiftDate, patientDate } from "../lib/dashboard";
import { QueryState } from "../components/query-state";
import { StateChip, StateIcon } from "../components/state-chip";
import { Button } from "../components/ui/button";

const boxIcon = "M3 8l9-5 9 5v8l-9 5-9-5V8ZM3 8l9 5 9-5M12 13v8";

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
  const otherZone = person.timezone !== Intl.DateTimeFormat().resolvedOptions().timeZone;
  const unconfirmed = summary.data?.report.summary.unconfirmed ?? 0;
  const replenishments = summary.data?.replenishments ?? 0;
  return (
    <article className="panel patient">
      <Link
        to="/patients/$patientId"
        params={{ patientId: person.patient_id }}
        search={{ section: "dashboard" }}
      >
        <h2>{patientLabel(person)}</h2>
      </Link>
      <QueryState query={summary}>
        {summary.data && (
          <>
            <p className="eyebrow">Hoy hasta ahora{otherZone ? " · " + person.timezone : ""}</p>
            <p className="patient-progress">
              <strong>
                {summary.data.report.summary.confirmed} de {summary.data.report.summary.evaluable} registradas
              </strong>
            </p>
            {(unconfirmed > 0 || replenishments > 0) && (
              <p className="patient-flags">
                {unconfirmed > 0 && <StateChip state="unconfirmed" label={unconfirmed + " sin confirmar"} />}
                {replenishments > 0 && (
                  <span className="badge">
                    <StateIcon path={boxIcon} />
                    {replenishments === 1 ? "1 reposición por revisar" : replenishments + " reposiciones por revisar"}
                  </span>
                )}
              </p>
            )}
          </>
        )}
      </QueryState>
      {person.scopes.length === 1 && person.scopes[0] === "read" && (
        <p className="hint">Tu acceso permite sólo mirar.</p>
      )}
      <p className="patient-open" aria-hidden="true">Ver seguimiento →</p>
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
      <div className="page-actions">
        <Button asChild><Link to="/invite">Invitar a alguien</Link></Button>
      </div>
      <QueryState query={query}>
        {query.data?.length === 0 && (
          <section className="panel">
            <p>No tienes pacientes vinculados. Invita a una persona y aparecerá aquí cuando autorice el acceso.</p>
            <p><Link to="/consent">¿Te invitaron a ti? Pega tu código en Accesos.</Link></p>
          </section>
        )}
        <div className="patients">
          {query.data?.map((person) => (
            <PatientCard key={person.patient_id} person={person} />
          ))}
        </div>
        {!!query.data?.length && (
          <p className="hint">Los registros son declaraciones. No demuestran que el medicamento se haya tomado.</p>
        )}
      </QueryState>
    </main>
  );
}
