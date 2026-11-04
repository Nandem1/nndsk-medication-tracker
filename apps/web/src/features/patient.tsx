import { Link } from "@tanstack/react-router";
import { useList } from "../lib/queries";
import { patient, treatment } from "../lib/api/contracts";
import { sections, type Section } from "../lib/sections";
import { QueryState } from "../components/query-state";
import { Treatments } from "./treatments";
import { Inventory } from "./inventory";
import { Agenda } from "./agenda";
import { Dashboard } from "./dashboard";
export function PatientDetail({
  patientId,
  section,
}: {
  patientId: string;
  section: Section;
}) {
  const access = useList("/patients", patient);
  const query = useList("/patients/" + patientId + "/treatments", treatment);
  const permissions =
    access.data?.find((p) => p.patient_id === patientId)?.scopes ?? [];
  return (
    <main>
      <p className="eyebrow">Registro compartido</p>
      <h1>Tratamientos y seguimiento</h1>
      <p className="reference">Paciente {patientId}</p>
      <nav className="section-nav" aria-label="Secciones del paciente">
        {sections.map((item) => (
          <Link
            key={item.id}
            to="/patients/$patientId"
            params={{ patientId }}
            search={{ section: item.id }}
          >
            {item.label}
          </Link>
        ))}
      </nav>
      <QueryState query={access}>
        <QueryState query={query}>
          {query.data &&
            (section === "treatments" ? (
              <Treatments
                patientId={patientId}
                items={query.data}
                canEdit={permissions.includes("treatments")}
              />
            ) : section === "inventory" ? (
              <Inventory
                patientId={patientId}
                treatments={query.data}
                canEdit={permissions.includes("inventory")}
              />
            ) : section === "dashboard" ? (
              <Dashboard key={patientId} patientId={patientId} treatments={query.data} />
            ) : (
              <Agenda patientId={patientId} treatments={query.data} />
            ))}
        </QueryState>
      </QueryState>
    </main>
  );
}
