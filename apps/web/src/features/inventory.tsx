import { useState } from "react";
import { z } from "zod";
import { useSession } from "../app/session";
import { useList, useRefresh } from "../lib/queries";
import {
  projection,
  movement,
  poolCandidate,
  poolResult,
  unitLabels,
  type Treatment,
  type Projection,
} from "../lib/api/contracts";
import { decimal } from "../lib/forms";
import { coverageDays, coverageLabel, coveredShare, movementDate, poolOthers, quantityLabel, subtractDecimal } from "../lib/inventory";
import { Button } from "../components/ui/button";
import { Field, MutationForm } from "../components/forms";
import { QueryState } from "../components/query-state";
const reasons: Record<string, string> = {
  initial: "Stock inicial",
  consumption: "Consumo declarado",
  replenishment: "Reposición",
  reversal: "Reversa por corrección",
  manual_adjustment: "Ajuste por conteo físico",
  pool_transfer: "Traspaso por inventario compartido",
  shared_activity: "Actividad compartida",
};
const unitLabel = (unit: string) => unitLabels[unit as keyof typeof unitLabels] ?? unit;
function zonedDate(value: string, timezone: string) {
  return new Date(value).toLocaleDateString("es-CL", { timeZone: timezone });
}
/** Ventana de proyección del servidor. No muestra saldo diario porque la API no lo entrega. */
function ProjectionBar({ item }: { item: Projection }) {
  const share = coveredShare(item);
  const through = zonedDate(item.through, item.timezone);
  const description = item.first_uncovered_at
    ? "Según la agenda, el saldo cubre hasta el " + zonedDate(item.first_uncovered_at, item.timezone) + ". La proyección llega hasta el " + through + "."
    : "Según la agenda, el saldo cubre toda la proyección, hasta el " + through + ".";
  return (
    <div className="projection">
      <h4>Proyección hasta {through}</h4>
      <div className="projection-track" role="img" aria-label={description}>
        <span className="projection-covered" style={{ width: share * 100 + "%" }} />
      </div>
      <div className="projection-scale" aria-hidden="true">
        <span>{zonedDate(item.from, item.timezone)}</span>
        <span>{through}</span>
      </div>
      <ul className="chart-legend" aria-label="Leyenda de la proyección">
        <li><span aria-hidden="true" className="chart-swatch projection-covered" />Con saldo</li>
        {item.first_uncovered_at && <li><span aria-hidden="true" className="chart-swatch projection-track" />Sin saldo</li>}
      </ul>
      <p>{description}</p>
    </div>
  );
}
function SharedInventory({ item, canEdit, unit }: { item: Projection; canEdit: boolean; unit: string }) {
  const { api } = useSession();
  const refresh = useRefresh();
  const [leaving, setLeaving] = useState(false);
  const [partner, setPartner] = useState<{ account_id: string; name: string } | null>(null);
  const candidates = useList("/inventory/" + item.account_id + "/pool-candidates", poolCandidate, canEdit && !item.pool);
  if (item.pool) {
    return (
      <div className="shared-inventory">
        <p><span className="badge">Misma caja que {poolOthers(item.pool)}</span></p>
        <p className="hint">El saldo es común: suma lo que registra cada persona.</p>
        {canEdit && !leaving && <Button variant="outline" onClick={() => setLeaving(true)}>Dejar de compartir</Button>}
        {canEdit && leaving && (
          <div className="notice">
            <p>El saldo se queda con {poolOthers(item.pool)}. Esta cuenta quedará en 0: después registra el stock que tengas.</p>
            <MutationForm
              label="Confirmar"
              variant="destructive"
              prepare={() => ({ account_id: item.account_id })}
              submit={(data) => api.request("/inventory-pools/" + item.pool?.pool_id + "/leave", poolResult, data)}
              done={refresh}
            />
            <Button variant="outline" onClick={() => setLeaving(false)}>Cancelar</Button>
          </div>
        )}
      </div>
    );
  }
  if (!canEdit || !candidates.data?.length) return null;
  if (partner) {
    return (
      <div className="shared-inventory notice-neutral">
        <h4>Misma caja con {partner.name}</h4>
        <p className="hint">Sumar dos saldos de una misma caja la contaría dos veces. El saldo común parte de lo que cuentes ahora.</p>
        <MutationForm
          label="Compartir la caja"
          prepare={(f) => ({
            account_ids: [item.account_id, partner.account_id],
            counted_account_id: item.account_id,
            counted_quantity: decimal(String(f.get("counted_quantity"))),
          })}
          submit={(data) => api.request("/inventory-pools", poolResult, data)}
          done={refresh}
        >
          <Field label={"¿Cuántos " + unit + " hay en la caja?"} name="counted_quantity" />
        </MutationForm>
        <Button variant="outline" onClick={() => setPartner(null)}>Cancelar</Button>
      </div>
    );
  }
  return (
    <div className="shared-inventory">
      <h4>¿Usan la misma caja?</h4>
      <p className="hint">Si la comparten físicamente, el saldo será uno solo para ambos.</p>
      <div className="actions">
        {candidates.data.map((candidate) => {
          const name = candidate.patient_display_name ?? "Paciente sin nombre";
          return (
            <Button key={candidate.account_id} variant="outline" onClick={() => setPartner({ account_id: candidate.account_id, name })}>
              Misma caja que {name}
            </Button>
          );
        })}
      </div>
    </div>
  );
}
function Account({
  item,
  name,
  canEdit,
}: {
  item: Projection;
  name: string;
  canEdit: boolean;
}) {
  const { api } = useSession();
  const refresh = useRefresh();
  const history = useList(
    "/inventory/" + item.account_id + "/movements",
    movement,
  );
  const unit = unitLabel(item.unit);
  const estimate = subtractDecimal(item.balance, item.scheduled_quantity);
  const through = zonedDate(item.through, item.timezone);
  const people = history.data?.some((m) => m.patient_display_name);
  return (
    <article className="panel account-detail">
      <h3>{name}</h3>
      <div className="balances">
        <div className="balance-card">
          <h4>{item.pool?.status === "active" ? "Saldo común confirmado" : "Saldo confirmado"}</h4>
          <p className="balance">
            {quantityLabel(item.balance)} <span>{unit}</span>
          </p>
          <p className="hint">Según los movimientos registrados en el servidor.</p>
        </div>
        <div className="balance-card is-estimate">
          <h4>Saldo estimado al {through}</h4>
          <p className="balance-estimate">
            {quantityLabel(estimate)} <span>{unit}</span>
          </p>
          <p className="hint">
            Saldo confirmado menos {quantityLabel(item.scheduled_quantity)} {unit} previstas sin
            registrar. Es una estimación, no un conteo.
            {estimate.startsWith("-") && " Un valor negativo indica que la agenda necesita más de lo disponible."}
          </p>
        </div>
      </div>
      {item.balance.startsWith("-") && (
        <p className="notice">
          El saldo confirmado es negativo. Conviene revisar el conteo físico.
        </p>
      )}
      <SharedInventory item={item} canEdit={canEdit} unit={unit} />
      <ProjectionBar item={item} />
      {item.replenish_on ? (
        <p className={item.low_stock ? "notice" : "hint"}>
          {item.low_stock ? "Revisar reposición. " : ""}Fecha de revisión: {item.replenish_on} · {item.timezone}.
        </p>
      ) : (
        <p className="hint">Sin fecha de revisión dentro de la proyección.</p>
      )}
      <p>Antelación configurada: {item.low_stock_days_threshold} días.</p>
      <details className="inventory-note">
        <summary>Cómo se calcula</summary>
        <p className="hint">
          Estimación según la agenda, hasta 30 días. El saldo se basa en registros
          declarados, no en una verificación de ingestión.
        </p>
        <p className="hint">La fecha de revisión usa días de calendario de la pauta. No activa notificaciones push.</p>
      </details>
      {canEdit && (
        <div className="inventory-actions">
          <details className="action-panel">
            <summary>Registrar reposición</summary>
            <MutationForm
              label="Agregar reposición"
              prepare={(f) => ({
                quantity: decimal(String(f.get("quantity")), true),
              })}
              submit={(data) =>
                api.request(
                  "/inventory/" + item.account_id + "/movements",
                  z.unknown(),
                  data,
                )
              }
              done={refresh}
            >
              <Field label="Cantidad recibida" name="quantity" />
            </MutationForm>
          </details>
          <details className="action-panel">
            <summary>Conteo físico</summary>
            <MutationForm
              key={item.balance}
              label="Guardar conteo"
              prepare={(f) => ({
                counted_quantity: decimal(String(f.get("counted_quantity"))),
                expected_balance: item.balance,
                reason: String(f.get("reason")),
              })}
              submit={(data) =>
                api.request(
                  "/inventory/" + item.account_id + "/counts",
                  z.unknown(),
                  data,
                )
              }
              done={refresh}
            >
              <Field label="Cantidad contada" name="counted_quantity" />
              <Field label="Motivo del ajuste" name="reason" maxLength={1000} />
              <p className="hint">
                Se compara con el saldo mostrado. Si cambió, actualiza y vuelve
                a contar.
              </p>
            </MutationForm>
          </details>
          <details className="action-panel">
            <summary>Aviso de reposición</summary>
            <MutationForm
              key={item.low_stock_days_threshold}
              label="Guardar antelación"
              prepare={(f) => ({ expected_days: item.low_stock_days_threshold, days: z.coerce.number().int().min(0).max(30).parse(f.get("days")) })}
              submit={(data) => api.request("/inventory/" + item.account_id + "/threshold", z.unknown(), data)}
              done={refresh}
            >
              <Field label="Días de antelación" name="days" type="number" min="0" max="30" value={String(item.low_stock_days_threshold)} />
            </MutationForm>
          </details>
        </div>
      )}
      <h4>Movimientos</h4>
      <QueryState query={history}>
        {history.data?.length === 0 && <p>Sin movimientos registrados.</p>}
        {!!history.data?.length && (
          <div className="table-scroll">
            <table className="movements">
              <caption>Movimientos de {name}, más recientes primero</caption>
              <thead>
                <tr>
                  <th scope="col">Fecha</th>
                  <th scope="col">Motivo</th>
                  {people && <th scope="col">Persona</th>}
                  <th scope="col" className="numeric">Cantidad ({unit})</th>
                  <th scope="col">Nota</th>
                </tr>
              </thead>
              <tbody>
                {history.data
                  .toSorted((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))
                  .map((m) => (
                    <tr key={m.movement_id}>
                      <td>{movementDate(m)}</td>
                      <td>{reasons[m.reason] ?? m.reason}</td>
                      {people && <td>{m.patient_display_name}</td>}
                      <td className="numeric">{quantityLabel(m.quantity_delta)}</td>
                      <td>{m.note}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        )}
      </QueryState>
    </article>
  );
}
export function Inventory({
  patientId,
  treatments,
  canEdit,
}: {
  patientId: string;
  treatments: Treatment[];
  canEdit: boolean;
}) {
  const query = useList("/patients/" + patientId + "/inventory", projection);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const nameOf = (item: Projection) =>
    treatments.find((t) => t.treatment_id === item.treatment_id)?.name ?? "Tratamiento";
  const selected = query.data?.find((item) => item.account_id === selectedId) ?? query.data?.[0];
  return (
    <section>
      <h2>Inventario</h2>
      {!canEdit && (
        <p className="notice">Tu acceso no permite cambiar el inventario.</p>
      )}
      <QueryState query={query}>
        {query.data?.length === 0 && (
          <p>
            No hay inventario. Crea un tratamiento para registrar sus
            existencias.
          </p>
        )}
        {selected && (
          <div className="inventory-layout">
            <ul className="account-list" aria-label="Cuentas de inventario">
              {query.data?.map((item) => (
                <li key={item.account_id}>
                  <button
                    type="button"
                    aria-current={item.account_id === selected.account_id ? "true" : undefined}
                    onClick={() => setSelectedId(item.account_id)}
                  >
                    <span className="account-name">{nameOf(item)}</span>
                    <span className="account-coverage">{coverageLabel(item)}</span>
                    <span className="hint">
                      {coverageDays(item) === null ? "de cobertura en la proyección" : "de cobertura estimada"}
                      {item.low_stock ? " · Revisar reposición" : ""}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
            <Account
              key={selected.account_id}
              item={selected}
              name={nameOf(selected)}
              canEdit={canEdit}
            />
          </div>
        )}
      </QueryState>
    </section>
  );
}
