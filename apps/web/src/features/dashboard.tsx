import { useState } from "react";
import {
  adherence,
  dose,
  projection,
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
import { StateChip } from "../components/state-chip";
import { Button } from "../components/ui/button";
import { AdherenceChart } from "./adherence-chart";

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
                  <StateChip state={item.state} />
                  {item.dst_adjusted && <span>Horario ajustado por cambio de hora.</span>}
                </li>
              );
            })}
        </ol>
      </QueryState>
    </section>
  );
}

function todayDosesPath(patientId: string) {
  const today = localDate();
  return "/patients/" + patientId + "/doses?from=" + today + "&to=" + shiftDate(today, 1);
}

/** Alertas y agenda de hoy, siempre de todo el paciente: el filtro del informe no las oculta. */
function TodayOverview({
  patientId,
  treatments,
}: {
  patientId: string;
  treatments: Treatment[];
}) {
  const today = localDate();
  const doses = useList(todayDosesPath(patientId), dose);
  const inventory = useList("/patients/" + patientId + "/inventory", projection);
  const unconfirmed = doses.data?.filter((item) => item.state === "unconfirmed").length ?? 0;
  const low = inventory.data?.filter((item) => item.low_stock) ?? [];
  const nameOf = (treatmentId: string) =>
    treatments.find((t) => t.treatment_id === treatmentId)?.name ?? "Tratamiento";
  return (
    <div className="overview">
      <section className="panel" aria-labelledby="alerts-heading">
        <h3 id="alerts-heading">Alertas</h3>
        <QueryState query={doses}>
          <QueryState query={inventory}>
            {unconfirmed === 0 && low.length === 0 && <p>Sin alertas por ahora.</p>}
            <ul className="alert-list">
              {unconfirmed > 0 && (
                <li className="alert-unconfirmed">
                  <strong>{unconfirmed === 1 ? "1 dosis sin confirmar hoy" : unconfirmed + " dosis sin confirmar hoy"}</strong>
                  <span>Sin confirmar no significa omitida.</span>
                </li>
              )}
              {low.map((item) => (
                <li key={item.account_id} className="alert-stock">
                  <strong>Revisar reposición: {nameOf(item.treatment_id)}</strong>
                  <span>Fecha de revisión: {item.replenish_on} · {item.timezone}</span>
                </li>
              ))}
            </ul>
          </QueryState>
        </QueryState>
      </section>
      <section className="panel" aria-labelledby="today-heading">
        <h3 id="today-heading">Hoy</h3>
        <p className="report-caption">{today}</p>
        <QueryState query={doses}>
          {doses.data?.length === 0 && <p>No hay dosis programadas para hoy.</p>}
          <ol className="today-list">
            {doses.data
              ?.toSorted((a, b) => a.scheduled_at.localeCompare(b.scheduled_at))
              .map((item) => {
                const treatment = treatments.find((t) => t.treatment_id === item.treatment_id);
                return (
                  <li key={item.dose_id}>
                    <time dateTime={item.scheduled_at}>{item.local_time}</time>
                    <span>
                      {nameOf(item.treatment_id)}
                      <small>{item.quantity} {unitLabels[treatment?.unit ?? "other"]}</small>
                    </span>
                    <StateChip state={item.state} />
                  </li>
                );
              })}
          </ol>
        </QueryState>
      </section>
    </div>
  );
}

function Metric({ value, empty }: { value: string; empty: boolean }) {
  return <p className={empty ? "metric-value is-empty" : "metric-value"}>{value}</p>;
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
  // Agenda e informe materializan dosis en transacciones que chocan entre sí (409): van en orden.
  const todayDoses = useList(todayDosesPath(patientId), dose);
  const query = useResource(
    "/patients/" + patientId + "/adherence?" + filter + "&window_minutes=" + windowMinutes,
    adherence,
    valid && !todayDoses.isPending,
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
      <TodayOverview patientId={patientId} treatments={treatments} />
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
                  <Metric value={percent(report.summary.adherence_rate)} empty={report.summary.adherence_rate === null} />
                  <p>{report.summary.taken + report.summary.taken_late} tomadas / {report.summary.evaluable} evaluables</p>
                </article>
                <article className="panel">
                  <h3>Confirmación</h3>
                  <Metric value={percent(report.summary.confirmation_rate)} empty={report.summary.confirmation_rate === null} />
                  <p>{report.summary.confirmed} respuestas / {report.summary.evaluable} evaluables</p>
                </article>
                <article className="panel">
                  <h3>Puntualidad declarada</h3>
                  <Metric
                    value={report.summary.punctuality_rate === null ? "Sin tomas declaradas" : percent(report.summary.punctuality_rate)}
                    empty={report.summary.punctuality_rate === null}
                  />
                  <p>{report.summary.punctual} dentro de ± {report.window_minutes} min / {report.summary.taken + report.summary.taken_late} tomadas</p>
                </article>
                <article className="panel">
                  <h3>Sin confirmar</h3>
                  <Metric value={percent(report.summary.unconfirmed_rate)} empty={report.summary.unconfirmed_rate === null} />
                  <p>{report.summary.unconfirmed} sin confirmar / {report.summary.evaluable} evaluables</p>
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
              <AdherenceChart report={report} until={period.until} />
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
