import { useState } from "react";
import { z } from "zod";
import { useSession } from "../app/session";
import { useRefresh } from "../lib/queries";
import { type Treatment, unitLabels } from "../lib/api/contracts";
import { decimal, parseSchedule, localDate } from "../lib/forms";
import { Field, MutationForm, ScheduleFields } from "../components/forms";
import { Button } from "../components/ui/button";
function metadata(f: FormData) {
  return {
    name: String(f.get("name")).trim(),
    strength_label: String(f.get("strength_label") ?? ""),
    form: String(f.get("form") ?? ""),
    package_label: String(f.get("package_label") ?? ""),
    instructions: String(f.get("instructions") ?? ""),
  };
}
function Metadata({ item }: { item?: Treatment }) {
  return (
    <>
      <Field
        label="Nombre del medicamento"
        name="name"
        value={item?.name}
        maxLength={200}
      />
      <div className="columns">
        <Field
          label="Concentración indicada"
          name="strength_label"
          value={item?.strength_label}
          required={false}
          maxLength={200}
        />
        <Field
          label="Forma farmacéutica"
          name="form"
          value={item?.form}
          required={false}
          maxLength={200}
        />
        <Field
          label="Presentación"
          name="package_label"
          value={item?.package_label}
          required={false}
          maxLength={200}
        />
      </div>
      <label className="field">
        Instrucciones transcritas
        <textarea
          name="instructions"
          defaultValue={item?.instructions}
          maxLength={4000}
        />
      </label>
    </>
  );
}
export function Treatments({
  patientId,
  items,
  canEdit,
}: {
  patientId: string;
  items: Treatment[];
  canEdit: boolean;
}) {
  const { api } = useSession();
  const refresh = useRefresh();
  const [mode, setMode] = useState<
    | { kind: "new" }
    | { kind: "edit" | "schedule" | "archive"; item: Treatment }
    | null
  >(null);
  function done() {
    setMode(null);
    refresh();
  }
  return (
    <section>
      <div className="section-heading">
        <h2>Tratamientos</h2>
        {canEdit && (
          <Button
            onClick={() =>
              setMode(mode?.kind === "new" ? null : { kind: "new" })
            }
          >
            Nuevo tratamiento
          </Button>
        )}
      </div>
      <p>
        Transcribe la indicación de un profesional. Este portal no prescribe ni
        recomienda compensaciones de dosis.
      </p>
      {!canEdit && (
        <p className="notice">
          Tu acceso permite consultar, pero no modificar tratamientos.
        </p>
      )}
      {mode?.kind === "new" && (
        <article className="panel">
          <h3>Crear tratamiento</h3>
          <MutationForm
            label="Guardar tratamiento"
            prepare={(f) => ({
              ...metadata(f),
              unit: String(f.get("unit")),
              initial_stock: decimal(String(f.get("initial_stock"))),
              starts_on: String(f.get("starts_on")),
              ends_on: String(f.get("ends_on")),
              schedule: parseSchedule(f),
            })}
            submit={(data) =>
              api.request(
                "/patients/" + patientId + "/treatments",
                z.unknown(),
                data,
              )
            }
            done={done}
          >
            <Metadata />
            <div className="columns">
              <label className="field">
                Unidad del inventario
                <select name="unit">
                  {Object.entries(unitLabels).map(([value, label]) => (
                    <option value={value} key={value}>
                      {label}
                    </option>
                  ))}
                </select>
              </label>
              <Field label="Stock inicial" name="initial_stock" value="0" />
              <Field
                label="Fecha de inicio"
                name="starts_on"
                type="date"
                value={localDate()}
              />
              <Field
                label="Fecha de término opcional"
                name="ends_on"
                type="date"
                required={false}
              />
            </div>
            <ScheduleFields />
          </MutationForm>
        </article>
      )}
      {items.length === 0 && (
        <p>
          No hay tratamientos registrados. Agrega el primero siguiendo la
          indicación existente.
        </p>
      )}
      {items.map((item) => (
        <article className="panel" key={item.treatment_id}>
          <div className="section-heading">
            <h3>{item.name}</h3>
            <span className="badge">
              {item.archived_at ? "Archivado" : "Activo"}
            </span>
          </div>
          <p>
            {item.strength_label} {item.form}
          </p>
          <p>{item.instructions || "Sin instrucciones adicionales."}</p>
          <p>
            {item.schedule.slots
              .map(
                (s) =>
                  s.time + " · " + s.quantity + " " + unitLabels[item.unit],
              )
              .join(" / ")}{" "}
            · {item.schedule.timezone}
          </p>
          {canEdit && !item.archived_at && (
            <div className="actions">
              <Button
                variant="outline"
                onClick={() => setMode({ kind: "edit", item })}
              >
                Editar datos
              </Button>
              <Button
                variant="outline"
                onClick={() => setMode({ kind: "schedule", item })}
              >
                Cambiar pauta
              </Button>
              <Button
                variant="outline"
                onClick={() => setMode({ kind: "archive", item })}
              >
                Archivar tratamiento
              </Button>
            </div>
          )}
          {mode &&
            mode.kind !== "new" &&
            mode.item.treatment_id === item.treatment_id && (
              <div>
                {mode.item.version !== item.version && (
                  <p role="status">
                    El tratamiento cambió mientras editabas. Cancela y vuelve a
                    abrir el formulario para revisar la versión actual.
                  </p>
                )}
                <Button variant="outline" onClick={() => setMode(null)}>
                  Cancelar edición
                </Button>
              </div>
            )}
          {mode?.kind === "edit" &&
            mode.item.treatment_id === item.treatment_id && (
              <MutationForm
                key={mode.kind + mode.item.treatment_id + mode.item.version}
                label="Guardar datos"
                prepare={(f) => ({
                  ...metadata(f),
                  expected_version: mode.item.version,
                })}
                submit={(data) =>
                  api.request(
                    "/treatments/" + item.treatment_id,
                    z.unknown(),
                    data,
                    "PATCH",
                  )
                }
                done={done}
              >
                <Metadata item={mode.item} />
              </MutationForm>
            )}
          {mode?.kind === "schedule" &&
            mode.item.treatment_id === item.treatment_id && (
              <MutationForm
                key={mode.kind + mode.item.treatment_id + mode.item.version}
                label="Guardar pauta futura"
                prepare={(f) => ({
                  schedule: parseSchedule(f),
                  expected_version: mode.item.version,
                  effective_from: new Date(
                    String(f.get("effective_from")),
                  ).toISOString(),
                })}
                submit={(data) =>
                  api.request(
                    "/treatments/" + item.treatment_id + "/schedule-revisions",
                    z.unknown(),
                    data,
                  )
                }
                done={done}
              >
                <p>
                  La nueva pauta reemplaza solo dosis futuras. El historial se
                  conserva.
                </p>
                <Field
                  label="Vigente desde (hora del dispositivo)"
                  name="effective_from"
                  type="datetime-local"
                />
                <ScheduleFields schedule={mode.item.schedule} />
              </MutationForm>
            )}
          {mode?.kind === "archive" &&
            mode.item.treatment_id === item.treatment_id && (
              <MutationForm
                key={mode.kind + mode.item.treatment_id + mode.item.version}
                label="Confirmar archivo"
                variant="destructive"
                prepare={(f) => ({
                  expected_version: mode.item.version,
                  reason: String(f.get("reason")),
                })}
                submit={(data) =>
                  api.request(
                    "/treatments/" + item.treatment_id + "/archive",
                    z.unknown(),
                    data,
                  )
                }
                done={done}
              >
                <p>
                  Archivar deja de programar dosis desde ahora y conserva todo
                  el historial. Registra este cambio solo conforme a la
                  indicación recibida.
                </p>
                <Field
                  label="Motivo del archivo"
                  name="reason"
                  maxLength={1000}
                />
              </MutationForm>
            )}
        </article>
      ))}
    </section>
  );
}
