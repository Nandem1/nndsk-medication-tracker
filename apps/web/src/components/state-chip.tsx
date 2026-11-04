import { stateLabels } from "../lib/api/contracts";

type DoseStateName = keyof typeof stateLabels;

const paths: Record<DoseStateName, string> = {
  pending: "M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
  unconfirmed: "M9.5 9.5a2.5 2.5 0 1 1 3.6 2.2c-.7.4-1.1 1-1.1 1.8M12 17h.01M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
  taken: "m8 12 3 3 5-6M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
  taken_late: "M12 7v5l3 2M4 12a8 8 0 0 1 14-5.3M20 12a8 8 0 0 1-14 5.3M18 3v4h-4M6 21v-4h4",
  skipped: "M8 12h8M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
};

export function StateIcon({ path }: { path: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d={path} />
    </svg>
  );
}

/** Estado de una dosis con icono y texto: nunca depende sólo del color. */
export function StateChip({ state }: { state: DoseStateName }) {
  return (
    <span className={"badge state-" + state}>
      <StateIcon path={paths[state]} />
      {stateLabels[state]}
    </span>
  );
}
