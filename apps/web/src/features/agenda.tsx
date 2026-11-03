import { useState } from "react";
import {
  dose,
  stateLabels,
  unitLabels,
  type Treatment,
} from "../lib/api/contracts";
import { useList } from "../lib/queries";
import { localDate, nextDate } from "../lib/forms";
import { QueryState } from "../components/query-state";
export function Agenda({
  patientId,
  treatments,
}: {
  patientId: string;
  treatments: Treatment[];
}) {
  const [date, setDate] = useState(localDate());
  const query = useList(
    "/patients/" + patientId + "/doses?from=" + date + "&to=" + nextDate(date),
    dose,
  );
  return (
    <section>
      <div className="section-heading">
        <h2>Agenda diaria</h2>
        <label className="field">
          Fecha de la agenda
          <input
            aria-label="Fecha de la agenda"
            type="date"
            value={date}
            required
            onChange={(e) => {
              if (e.target.value) setDate(e.target.value);
            }}
          />
        </label>
      </div>
      <p>
        Sin confirmar no significa omitida. Las tomas registradas son
        declaraciones de la persona.
      </p>
      <QueryState query={query}>
        {query.data?.length === 0 && (
          <p>No hay dosis programadas para esta fecha.</p>
        )}
        <ol className="timeline">
          {query.data
            ?.toSorted((a, b) => a.scheduled_at.localeCompare(b.scheduled_at))
            .map((item) => (
              <li key={item.dose_id}>
                <time dateTime={item.scheduled_at}>{item.local_time}</time>
                <div>
                  <h3>
                    {treatments.find(
                      (t) => t.treatment_id === item.treatment_id,
                    )?.name ?? "Tratamiento"}
                  </h3>
                  <p>
                    {item.quantity}{" "}
                    {
                      unitLabels[
                        treatments.find(
                          (t) => t.treatment_id === item.treatment_id,
                        )?.unit ?? "other"
                      ]
                    }{" "}
                    · {item.timezone}
                  </p>
                  <span className={"badge state-" + item.state}>
                    {stateLabels[item.state]}
                  </span>
                  {item.dst_adjusted && (
                    <p>
                      Horario ajustado por cambio de hora según la política
                      elegida.
                    </p>
                  )}
                </div>
              </li>
            ))}
        </ol>
      </QueryState>
    </section>
  );
}
