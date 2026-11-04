import { useState } from "react";
import { ProfileEditor } from "./profile";
import { Button } from "../components/ui/button";
import { Link } from "@tanstack/react-router";
import { useList, useRefresh } from "../lib/queries";
import { patient, treatment, type Patient } from "../lib/api/contracts";
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
  const refresh = useRefresh();
  const [editing, setEditing] = useState<Patient | null>(null);
  const access = useList("/patients", patient);
  const query = useList("/patients/" + patientId + "/treatments", treatment);
  const permissions =
    access.data?.find((p) => p.patient_id === patientId)?.scopes ?? [];
  const person = access.data?.find((p) => p.patient_id === patientId);
  return (
    <main>
      <p className="eyebrow">Registro compartido</p>
      <h1>{person?.display_name ?? "Paciente sin nombre"}</h1>
      {person && permissions.includes("treatments") && (
        <Button variant="outline" onClick={() => setEditing(person)}>
          Cambiar nombre
        </Button>
      )}
      {editing && (
        <section className="panel">
          <ProfileEditor
            initial={editing}
            path={"/patients/" + patientId + "/profile"}
            done={() => {
              setEditing(null);
              refresh();
            }}
          />
          <Button variant="outline" onClick={() => setEditing(null)}>
            Cancelar edición
          </Button>
        </section>
      )}
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
