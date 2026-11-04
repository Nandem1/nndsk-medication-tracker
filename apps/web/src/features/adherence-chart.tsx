import { useRef, useState } from "react";
import type { z } from "zod";
import type { adherence } from "../lib/api/contracts";

type Report = z.infer<typeof adherence>;
type Day = Report["days"][number];

const series = [
  { key: "taken", label: "Tomada", className: "series-taken" },
  { key: "taken_late", label: "Tomada tarde", className: "series-late" },
  { key: "skipped", label: "Omitida", className: "series-skipped" },
  { key: "unconfirmed", label: "Sin confirmar", className: "series-unconfirmed" },
] as const;

const shortDate = (date: string) => date.slice(8, 10) + "/" + date.slice(5, 7);

function labelStep(count: number) {
  if (count <= 14) return 1;
  if (count <= 62) return 7;
  return 30;
}

function daySummary(day: Day) {
  return series.map((item) => item.label + ": " + day[item.key]).join(" · ");
}

/** Barras apiladas por día con los conteos que entrega la API, sin agregar nada en cliente. */
export function AdherenceChart({ report, until }: { report: Report; until: string }) {
  const [hover, setHover] = useState<{ day: Day; left: number } | null>(null);
  const figure = useRef<HTMLElement>(null);
  const max = Math.max(1, ...report.days.map((day) => day.evaluable));
  const step = labelStep(report.days.length);
  const { summary } = report;
  const description =
    "Dosis evaluables por día, del " + report.from + " al " + until + ". En total, " +
    summary.taken + " declaradas tomadas, " + summary.taken_late + " declaradas tomadas tarde, " +
    summary.skipped + " declaradas omitidas y " + summary.unconfirmed + " sin confirmar, de " +
    summary.evaluable + " evaluables. La tabla siguiente contiene el detalle.";
  return (
    <figure className="chart" ref={figure}>
      <figcaption>
        <h3>Registros por día</h3>
        <p className="report-caption">{report.from} a {until} · {summary.evaluable} evaluables</p>
      </figcaption>
      <ul className="chart-legend" aria-label="Leyenda">
        {series.map((item) => (
          <li key={item.key}>
            <span aria-hidden="true" className={"chart-swatch " + item.className} />
            {item.label}
          </li>
        ))}
      </ul>
      {summary.evaluable === 0 ? (
        <p>No hay dosis evaluables en este período.</p>
      ) : (
        <div className="chart-frame">
          <div className="chart-axis" aria-hidden="true">
            <span>{max}</span>
            <span>0</span>
          </div>
          <div className="chart-scroll" onPointerLeave={() => setHover(null)}>
            <div role="img" aria-label={description} className="chart-plot" style={{ minWidth: report.days.length * 14 }}>
              {report.days.map((day, index) => (
                <div
                  key={day.date}
                  className="chart-column"
                  onPointerEnter={(event) => {
                    const bounds = figure.current?.getBoundingClientRect();
                    const column = event.currentTarget.getBoundingClientRect();
                    if (bounds) setHover({ day, left: column.left - bounds.left + column.width / 2 });
                  }}
                >
                  <div className="chart-bar-area">
                    <div className="chart-stack" style={{ height: (day.evaluable / max) * 100 + "%" }}>
                      {[...series].reverse().map((item) =>
                        day[item.key] > 0 ? (
                          <span key={item.key} className={item.className} style={{ flexGrow: day[item.key] }} />
                        ) : null,
                      )}
                    </div>
                  </div>
                  <span className="chart-tick">{index % step === 0 ? shortDate(day.date) : ""}</span>
                </div>
              ))}
            </div>
          </div>
          {hover && (
            <p className="chart-tooltip" aria-hidden="true" style={{ left: hover.left }}>
              <strong>{hover.day.date}</strong>
              {hover.day.evaluable === 0 ? "Sin dosis evaluables" : daySummary(hover.day) + " · de " + hover.day.evaluable}
            </p>
          )}
        </div>
      )}
      <details className="chart-table">
        <summary>Ver como tabla</summary>
        <div className="table-scroll">
          <table>
            <caption>Registros por día, del {report.from} al {until}</caption>
            <thead>
              <tr>
                <th scope="col">Fecha</th>
                {series.map((item) => <th key={item.key} scope="col">{item.label}</th>)}
                <th scope="col">Evaluables</th>
              </tr>
            </thead>
            <tbody>
              {report.days.map((day) => (
                <tr key={day.date}>
                  <th scope="row">{day.date}</th>
                  {series.map((item) => <td key={item.key}>{day[item.key]}</td>)}
                  <td>{day.evaluable}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </figure>
  );
}
