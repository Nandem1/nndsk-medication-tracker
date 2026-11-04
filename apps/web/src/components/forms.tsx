import { useRef, useState, type ReactNode, type FormEvent } from "react";
import { useMutation } from "@tanstack/react-query";
import { Button } from "./ui/button";
import type { Schedule } from "../lib/api/contracts";
export function Field({
  label,
  name,
  type = "text",
  value = "",
  required = true,
  ...props
}: {
  label: string;
  name: string;
  type?: string;
  value?: string;
  required?: boolean;
  maxLength?: number;
  minLength?: number;
  autoComplete?: string;
  min?: string;
  max?: string;
  placeholder?: string;
}) {
  return (
    <label className="field">
      {label}
      <input
        name={name}
        type={type}
        defaultValue={value}
        required={required}
        {...props}
      />
    </label>
  );
}
export function MutationForm<T>({
  prepare,
  submit,
  done,
  children,
  label,
  variant = "default",
}: {
  prepare: (data: FormData) => T;
  submit: (payload: T & { client_operation_id: string }) => Promise<unknown>;
  done: () => void;
  children: ReactNode;
  label: string;
  variant?: "default" | "outline" | "destructive";
}) {
  const last = useRef<{ fingerprint: string; id: string } | null>(null);
  const [validation, setValidation] = useState("");
  const mutation = useMutation({
    mutationFn: submit,
    onSuccess: () => {
      last.current = null;
      done();
    },
    retry: false,
  });
  function send(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setValidation("");
    try {
      const payload = prepare(new FormData(event.currentTarget));
      const fingerprint = JSON.stringify(payload);
      if (last.current?.fingerprint !== fingerprint)
        last.current = { fingerprint, id: crypto.randomUUID() };
      mutation.mutate({ ...payload, client_operation_id: last.current.id });
    } catch (error) {
      setValidation(
        error instanceof Error ? error.message : "Revisa los datos.",
      );
    }
  }
  return (
    <form onSubmit={send}>
      {children}
      {(validation || mutation.error) && (
        <p role="alert">{validation || mutation.error?.message}</p>
      )}
      <Button variant={variant} disabled={mutation.isPending}>
        {mutation.isPending ? "Guardando…" : label}
      </Button>
      {mutation.isSuccess && <p role="status">Cambios guardados.</p>}
    </form>
  );
}
export function ScheduleFields({ schedule }: { schedule?: Schedule }) {
  const [slots, setSlots] = useState(
    schedule?.slots ?? [{ time: "08:00", quantity: "1" }],
  );
  return (
    <fieldset>
      <legend>Horarios de la indicación existente</legend>
      {slots.map((slot, index) => (
        <div className="columns" key={index}>
          <Field
            label={"Horario " + (index + 1)}
            name="time"
            type="time"
            value={slot.time}
          />
          <Field
            label={"Cantidad de la toma " + (index + 1)}
            name="dose_quantity"
            value={slot.quantity}
          />
        </div>
      ))}
      <div className="actions">
        <Button
          type="button"
          variant="outline"
          disabled={slots.length >= 24}
          onClick={() => setSlots([...slots, { time: "20:00", quantity: "1" }])}
        >
          Agregar horario
        </Button>
        {slots.length > 1 && (
          <Button
            type="button"
            variant="outline"
            onClick={() => setSlots(slots.slice(0, -1))}
          >
            Quitar último horario
          </Button>
        )}
      </div>
      <Field
        label="Zona horaria"
        name="timezone"
        value={schedule?.timezone ?? "America/Santiago"}
      />
      <div className="weekdays">
        {["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"].map((day, i) => (
          <label key={day}>
            <input
              type="checkbox"
              name="weekday"
              value={i}
              defaultChecked={schedule ? schedule.weekdays.includes(i) : true}
            />
            {day}
          </label>
        ))}
      </div>
      <label className="field">
        Cambio de hora
        <select
          name="dst_policy"
          defaultValue={schedule?.dst_policy ?? "reject"}
        >
          <option value="reject">
            Avisar y rechazar horarios inexistentes o ambiguos
          </option>
          <option value="next_valid_earliest">
            Siguiente instante válido; primera ocurrencia si se repite
          </option>
        </select>
      </label>
      <p className="hint">
        La política afecta el horario al cambiar la hora. Confirma esta elección
        con quien indicó el tratamiento.
      </p>
    </fieldset>
  );
}
