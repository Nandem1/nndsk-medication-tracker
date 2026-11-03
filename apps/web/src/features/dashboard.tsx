import { useState } from "react";
import {
  adherence,
  dose,
  stateLabels,
  unitLabels,
  type Treatment,
} from "../lib/api/contracts";
import { useList, useResource } from "../lib/queries";
import { localDate } from "../lib/forms";
import {
  percent,
  reportPeriod,
  shiftDate,
  validReportRange,
} from "../lib/dashboard";
import { QueryState } from "../components/query-state";
import { Button } from "../components/ui/button";

function History({
  patientId,
  filter,
  treatments,
}: {
  patientId: string;
  filter: string;
  treatments: Treatment[];
}) {
  const query = useList("/patients/" + patientId + "/doses?" + filter, dose);
  return (
    <section aria-label="Historial filtrado">
      <h3>Historial de declaraciones</h3>
      <QueryState query={query}>
        {query.data?.length === 0 && <p>No hay dosis programadas en este rango.</p>}
        <ol className="report-history">
          {query.data
            ?.toSorted((a, b) =>
              a.scheduled_at.localeCompare(b.scheduled_at) ||
              a.dose_id.localeCompare(b.dose_id),
            )
            .map((item) => {
              const treatment = treatments.find(
                (t) => t.treatment_id === item.treatment_id,
              );
              return (
                <li key={item.dose_id}>
                  <time dateTime={item.scheduled_at}>
                    {item.local_date} · {item.local_time}
                  </time>
                  <span>{treatment?.name ?? "Tratamiento"}</span>
                  <span>
                    {item.quantity} {unitLabels[treatment?.unit ?? "other"]} · {item.timezone}
                  </span>
                  <span className="badge">{stateLabels[item.state]}</span>
                  {item.dst_adjusted && <span>Horario ajustado por cambio de hora.</span>}
                </li>
              );
            })}
        </ol>
      </QueryState>
    </section>
  );
}

export function Dashboard({
  patientId,
  treatments,
}: {
  patientId: string;
  treatments: Treatment[];
}) {
  const [period, setPeriod] = useState(() => reportPeriod(localDate(), "week"));
  const [treatmentId, setTreatmentId] = useState("");
  const [windowMinutes, setWindowMinutes] = useState(60);
  const valid = validReportRange(period.from, period.until);
  const filter = new URLSearchParams({
    from: period.from,
    to: valid ? shiftDate(period.until, 1) : period.until,
    ...(treatmentId ? { treatment_id: treatmentId } : {}),
  }).toString();
  const query = useResource(
    "/patients/" + patientId + "/adherence?" + filter + "&window_minutes=" + windowMinutes,
    adherence,
    valid,
  );
  const report = query.data;
  return (
    <section className="dashboard">
      <div className="section-heading">
        <h2>Seguimiento declarado</h2>
        <div className="actions">
          <Button variant="outline" onClick={() => setPeriod(reportPeriod(localDate(), "week"))}>
            Esta semana
          </Button>
          <Button variant="outline" onClick={() => setPeriod(reportPeriod(localDate(), "month"))}>
            Este mes
          </Button>
        </div>
      </div>
      <p>
        Los registros son declaraciones, no evidencia de ingestión. Una omisión
        registrada es una respuesta válida. Sin confirmar no significa omitida.
      </p>
      <div className="report-filters">
        <label className="field">
          Desde
          <input type="date" value={period.from} onChange={(e) => setPeriod({ ...period, from: e.target.value })} />
        </label>
        <label className="field">
          Hasta, incluido
          <input type="date" value={period.until} onChange={(e) => setPeriod({ ...period, until: e.target.value })} />
        </label>
        <label className="field">
          Tratamiento del informe
          <select value={treatmentId} onChange={(e) => setTreatmentId(e.target.value)}>
            <option value="">Todos los tratamientos</option>
            {treatments.map((t) => (
              <option key={t.treatment_id} value={t.treatment_id}>
                {t.name}{t.archived_at ? " · archivado" : ""}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          Ventana organizativa
          <select value={windowMinutes} onChange={(e) => setWindowMinutes(Number(e.target.value))}>
            {[0, 15, 30, 60, 120].map((minutes) => (
              <option key={minutes} value={minutes}>± {minutes} minutos</option>
            ))}
          </select>
        </label>
      </div>
      <p className="hint">
        La ventana sólo calcula puntualidad. No indica cuándo tomar un medicamento
        ni modifica la pauta. Las fechas corresponden al día local de cada pauta.
      </p>
      {!valid ? (
        <p role="alert">Elige un rango válido de hasta 366 días.</p>
      ) : (
        <QueryState query={query}>
          {report && (
            <>
              <p className="report-caption">
                Del {report.from} al {period.until}. Actualizado {new Date(report.as_of).toLocaleString("es-CL")}.
              </p>
              <div className="metric-grid">
                <article className="panel">
                  <h3>Adherencia declarada</h3>
                  <p className="metric-value">{percent(report.summary.adherence_rate)}</p>
                  <p>{report.summary.taken + report.summary.taken_late} tomadas / {report.summary.evaluable} evaluables</p>
                </article>
                <article className="panel">
                  <h3>Confirmación</h3>
                  <p className="metric-value">{percent(report.summary.confirmation_rate)}</p>
                  <p>{report.summary.confirmed} respuestas / {report.summary.evaluable} evaluables</p>
                </article>
                <article className="panel">
                  <h3>Puntualidad declarada</h3>
                  <p className="metric-value">
                    {report.summary.punctuality_rate === null ? "Sin tomas declaradas" : percent(report.summary.punctuality_rate)}
                  </p>
                  <p>{report.summary.punctual} dentro de ± {report.window_minutes} min / {report.summary.taken + report.summary.taken_late} tomadas</p>
                </article>
                <article className="panel">
                  <h3>Sin confirmar</h3>
                  <p className="metric-value">{report.summary.unconfirmed}</p>
                  <p>{percent(report.summary.unconfirmed_rate)} de {report.summary.evaluable} evaluables</p>
                </article>
              </div>
              <p>
                {report.summary.taken} declaradas tomadas · {report.summary.taken_late} declaradas tomadas tarde · {report.summary.skipped} declaradas omitidas.
              </p>
              <p className="hint">
                Se evalúan sólo horarios que ya pasaron. Se excluyen las dosis canceladas.
                Las correcciones actualizan el resultado sin contar dos veces.
                Las tomas declaradas tarde no se cuentan como puntuales.
              </p>
              <h3>Calendario de constancia</h3>
              <p>
                Registrar lo que ocurrió ayuda a mantener un historial útil, incluida
                una omisión. No hay puntos ni rachas que perder.
              </p>
              <ol className="response-calendar" aria-label="Calendario de respuestas">
                {report.days.map((day) => (
                  <li key={day.date} className={day.confirmed > 0 ? "has-response" : ""}>
                    <time dateTime={day.date}>{day.date}</time>
                    <strong>
                      {day.evaluable === 0 ? "Sin dosis evaluables" : `${day.confirmed} de ${day.evaluable} respuestas`}
                    </strong>
                    {day.evaluable > 0 && (
                      <span>{day.unconfirmed} sin confirmar · {day.skipped} omitidas declaradas</span>
                    )}
                  </li>
                ))}
              </ol>
              <History patientId={patientId} filter={filter} treatments={treatments} />
            </>
          )}
        </QueryState>
      )}
    </section>
  );
}
