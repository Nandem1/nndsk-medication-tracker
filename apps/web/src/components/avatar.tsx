import { initials } from "../lib/invitations";

/** Iniciales sobre un tono estable por persona. El nombre siempre aparece junto a él. */
export function Avatar({ name, seed, size = "md" }: { name: string | null; seed: string; size?: "md" | "lg" }) {
  let hash = 0;
  for (const char of seed) hash = (hash * 31 + char.charCodeAt(0)) >>> 0;
  return (
    <span className={"avatar avatar-" + size + " avatar-tone-" + (hash % 6)} aria-hidden="true">
      {initials(name)}
    </span>
  );
}
