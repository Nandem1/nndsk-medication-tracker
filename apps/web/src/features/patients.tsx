import { Link } from "@tanstack/react-router";
import { patient, scopeLabels } from "../lib/api/contracts";
import { useList } from "../lib/queries";
import { patientLabel } from "../lib/sections";
import { QueryState } from "../components/query-state";
export function Patients() {
  const query = useList("/patients", patient);
  return (
    <main>
      <p className="eyebrow">Seguimiento con consentimiento</p>
      <h1>Personas a tu cuidado</h1>
      <p>
        Abre un registro para revisar sus tratamientos, existencias y agenda.
      </p>
      <QueryState query={query}>
        {query.data?.length === 0 && (
          <p>
            No tienes pacientes vinculados. Crea una invitación para comenzar.
          </p>
        )}
        <div className="patients">
          {query.data?.map((p, i) => (
            <Link
              className="panel patient"
              key={p.patient_id}
              to="/patients/$patientId"
              params={{ patientId: p.patient_id }}
              search={{ section: "treatments" }}
            >
              <h2>{patientLabel(p, i)}</h2>
              <p className="reference">Referencia {p.patient_id}</p>
              <p>{p.scopes.map((s) => scopeLabels[s]).join(" · ")}</p>
              <strong>Abrir registro →</strong>
            </Link>
          ))}
        </div>
      </QueryState>
    </main>
  );
}
