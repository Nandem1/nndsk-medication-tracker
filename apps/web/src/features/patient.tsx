import { useState } from "react";
import { useList } from "../lib/queries";
import { patient, treatment } from "../lib/api/contracts";
import { QueryState } from "../components/query-state";
import { Treatments } from "./treatments";
import { Inventory } from "./inventory";
import { Agenda } from "./agenda";
import { Dashboard } from "./dashboard";
import { Button } from "../components/ui/button";
export function PatientDetail({ patientId }: { patientId: string }) {
  const access = useList("/patients", patient);
  const query = useList("/patients/" + patientId + "/treatments", treatment);
  const [tab, setTab] = useState<"treatments" | "inventory" | "agenda" | "dashboard">(
    "treatments",
  );
  const permissions =
    access.data?.find((p) => p.patient_id === patientId)?.scopes ?? [];
  return (
    <main>
      <p className="eyebrow">Registro compartido</p>
      <h1>Tratamientos y seguimiento</h1>
      <p className="reference">Paciente {patientId}</p>
      <nav aria-label="Secciones del paciente">
        <Button aria-pressed={tab === "dashboard"} variant={tab === "dashboard" ? "default" : "outline"} onClick={() => setTab("dashboard")}>Seguimiento</Button>
        <Button
          aria-pressed={tab === "treatments"}
          variant={tab === "treatments" ? "default" : "outline"}
          onClick={() => setTab("treatments")}
        >
          Tratamientos
        </Button>
        <Button
          aria-pressed={tab === "inventory"}
          variant={tab === "inventory" ? "default" : "outline"}
          onClick={() => setTab("inventory")}
        >
          Inventario
        </Button>
        <Button
          aria-pressed={tab === "agenda"}
          variant={tab === "agenda" ? "default" : "outline"}
          onClick={() => setTab("agenda")}
        >
          Agenda
        </Button>
      </nav>
      <QueryState query={access}>
        <QueryState query={query}>
          {query.data &&
            (tab === "treatments" ? (
              <Treatments
                patientId={patientId}
                items={query.data}
                canEdit={permissions.includes("treatments")}
              />
            ) : tab === "inventory" ? (
              <Inventory
                patientId={patientId}
                treatments={query.data}
                canEdit={permissions.includes("inventory")}
              />
            ) : tab === "dashboard" ? (
              <Dashboard key={patientId} patientId={patientId} treatments={query.data} />
            ) : (
              <Agenda patientId={patientId} treatments={query.data} />
            ))}
        </QueryState>
      </QueryState>
    </main>
  );
}
