import { z } from "zod";
import { useSession } from "../app/session";
import { useList, useRefresh } from "../lib/queries";
import {
  projection,
  movement,
  type Treatment,
  type Projection,
} from "../lib/api/contracts";
import { decimal } from "../lib/forms";
import { Field, MutationForm } from "../components/forms";
import { QueryState } from "../components/query-state";
const reasons: Record<string, string> = {
  initial: "Stock inicial",
  consumption: "Consumo declarado",
  replenishment: "Reposición",
  reversal: "Reversa por corrección",
  manual_adjustment: "Ajuste por conteo físico",
};
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
  const days = item.first_uncovered_at
    ? Math.max(
        0,
        Math.floor(
          (Date.parse(item.first_uncovered_at) - Date.parse(item.from)) /
            86400000,
        ),
      )
    : null;
  return (
    <article className="panel">
      <h3>{name}</h3>
      <p className="balance">
        {item.balance} <span>{item.unit}</span>
      </p>
      <p>
        {days === null
          ? "Las dosis previstas están cubiertas hasta el " +
            new Date(item.through).toLocaleDateString("es-CL")
          : days +
            " días completos estimados. Primera dosis sin cobertura: " +
            new Date(item.first_uncovered_at!).toLocaleString("es-CL")}
      </p>
      <p className="hint">
        Estimación según la agenda, hasta 30 días. El saldo se basa en registros
        declarados, no en una verificación de ingestión.
      </p>
      {canEdit && (
        <div className="columns">
          <div>
            <h4>Registrar reposición</h4>
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
          </div>
          <div>
            <h4>Conteo físico</h4>
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
          </div>
        </div>
      )}
      <details>
        <summary>Historial de movimientos</summary>
        <QueryState query={history}>
          {history.data?.length === 0 && <p>Sin movimientos registrados.</p>}
          <ul>
            {history.data
              ?.toSorted(
                (a, b) => Date.parse(b.created_at) - Date.parse(a.created_at),
              )
              .map((m) => (
                <li key={m.movement_id}>
                  {new Date(m.created_at).toLocaleString("es-CL")} ·{" "}
                  {reasons[m.reason] ?? m.reason} · {m.quantity_delta}
                  {m.note && " · " + m.note}
                </li>
              ))}
          </ul>
        </QueryState>
      </details>
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
        {query.data?.map((item) => (
          <Account
            key={item.account_id}
            item={item}
            name={
              treatments.find((t) => t.treatment_id === item.treatment_id)
                ?.name ?? "Tratamiento"
            }
            canEdit={canEdit}
          />
        ))}
      </QueryState>
    </section>
  );
}
