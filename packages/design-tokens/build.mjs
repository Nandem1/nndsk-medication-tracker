#!/usr/bin/env node
// Genera los adaptadores de tokens para CSS, SwiftUI y Compose desde tokens.json.
// Uso: node packages/design-tokens/build.mjs [--check]
// --check no escribe: falla si algún adaptador no coincide o si un par no cumple contraste.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const tokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));
const check = process.argv.includes("--check");
const header = "Generado por packages/design-tokens/build.mjs desde tokens.json. No editar a mano.";

const outputs = {
  css: join(root, "apps/web/src/tokens.css"),
  swift: join(root, "apps/ios/MedicationTracker/DesignSystem/Tokens.generated.swift"),
  kotlin: join(root, "apps/android/app/src/main/kotlin/cl/nndsk/medication/ui/theme/Tokens.kt"),
};

// --- Validación -----------------------------------------------------------

const hex = /^#[0-9A-F]{6}$/;
const colors = tokens.color;
for (const [name, value] of Object.entries(colors)) {
  for (const mode of ["light", "dark"]) {
    if (!hex.test(value[mode] ?? "")) throw new Error(`color.${name}.${mode} debe ser #RRGGBB en mayúsculas`);
  }
}

function luminance(value) {
  const channels = [1, 3, 5].map((i) => parseInt(value.slice(i, i + 2), 16) / 255);
  const [r, g, b] = channels.map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a, b) {
  const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
}

const failures = [];
for (const [group, minimum] of [["text", 4.5], ["nonText", 3]]) {
  for (const [fg, bg] of tokens.contrast[group]) {
    for (const mode of ["light", "dark"]) {
      if (!colors[fg] || !colors[bg]) throw new Error(`Par de contraste desconocido: ${fg}/${bg}`);
      const ratio = contrast(colors[fg][mode], colors[bg][mode]);
      if (ratio < minimum) failures.push(`${fg} sobre ${bg} (${mode}): ${ratio.toFixed(2)} < ${minimum}`);
    }
  }
}
if (failures.length) {
  console.error("Contraste insuficiente:\n  " + failures.join("\n  "));
  process.exit(1);
}

// --- Adaptadores ----------------------------------------------------------

const kebab = (name) => name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
const entries = (object) => Object.entries(object);

function css() {
  const vars = (mode, indent = "  ") => entries(colors).map(([n, v]) => `${indent}--mt-color-${kebab(n)}: ${v[mode]};`).join("\n");
  const scalar = [
    ...entries(tokens.space).map(([n, v]) => `  --mt-space-${kebab(n)}: ${v / 16}rem;`),
    ...entries(tokens.radius).map(([n, v]) => `  --mt-radius-${kebab(n)}: ${v === 999 ? "999px" : v / 16 + "rem"};`),
    ...entries(tokens.size).map(([n, v]) => `  --mt-size-${kebab(n)}: ${v}px;`),
    `  --mt-font-sans: ${tokens.font.web.sans};`,
    `  --mt-font-mono: ${tokens.font.web.mono};`,
    ...entries(tokens.type).flatMap(([n, t]) => [
      `  --mt-type-${kebab(n)}-size: ${t.size / 16}rem;`,
      `  --mt-type-${kebab(n)}-line: ${(t.lineHeight / t.size).toFixed(3)};`,
      `  --mt-type-${kebab(n)}-weight: ${t.weight};`,
    ]),
  ].join("\n");
  return `/* ${header} */
:root {
  color-scheme: light dark;
${vars("light")}
${scalar}
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
${vars("dark", "    ")}
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
${vars("dark")}
}
:root[data-theme="light"] {
  color-scheme: light;
}
`;
}

const swiftWeight = { 400: "regular", 500: "medium", 600: "semibold", 700: "bold", 800: "heavy" };
const rgb = (value) => "0x" + value.slice(1);

function swift() {
  const colorLines = entries(colors)
    .map(([n, v]) => `        /// ${v.role}\n        static let ${n} = adaptive(light: ${rgb(v.light)}, dark: ${rgb(v.dark)})`)
    .join("\n");
  const numbers = (object) => entries(object).map(([n, v]) => `        static let ${n}: CGFloat = ${v}`).join("\n");
  const fonts = entries(tokens.type)
    .map(([n, t]) => `        /// ${t.role}. Escala con Dynamic Type desde .${t.ios}.\n        static let ${n} = Font.system(.${t.ios}, design: ${t.mono ? ".monospaced" : ".default"}, weight: .${swiftWeight[t.weight]})`)
    .join("\n");
  return `// ${header}
import SwiftUI
import UIKit

enum Tokens {
    enum Colors {
${colorLines}

        private static func adaptive(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(UIColor { traits in
                let value = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            })
        }
    }

    enum Space {
${numbers(tokens.space)}
    }

    enum Radius {
${numbers(tokens.radius)}
    }

    enum Size {
${numbers(tokens.size)}
    }

    enum Typography {
${fonts}
    }
}
`;
}

function kotlin() {
  const names = Object.keys(colors);
  const fields = names.map((n) => `    val ${n}: Color,`).join("\n");
  const values = (mode) => names.map((n) => `        ${n} = Color(0xFF${colors[n][mode].slice(1)}),`).join("\n");
  const dps = (object) => entries(object).map(([n, v]) => `        val ${n} = ${v}.dp`).join("\n");
  const type = entries(tokens.type)
    .map(([n, t]) => `        val ${n} = TextStyle(fontFamily = ${t.mono ? "FontFamily.Monospace" : "FontFamily.Default"}, fontWeight = FontWeight(${t.weight}), fontSize = ${t.size}.sp, lineHeight = ${t.lineHeight}.sp)`)
    .join("\n");
  return `// ${header}
package cl.nndsk.medication.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Immutable
data class GraphiteColors(
${fields}
)

object GraphiteTokens {
    val light = GraphiteColors(
${values("light")}
    )

    val dark = GraphiteColors(
${values("dark")}
    )

    object Space {
${dps(tokens.space)}
    }

    object Radius {
${dps(tokens.radius)}
    }

    object Size {
${dps(tokens.size)}
    }

    object Type {
${type}
    }
}
`;
}

const generated = { css: css(), swift: swift(), kotlin: kotlin() };
let stale = [];
for (const [key, path] of Object.entries(outputs)) {
  const current = existsSync(path) ? readFileSync(path, "utf8") : null;
  if (current === generated[key]) continue;
  if (check) stale.push(relative(root, path));
  else writeFileSync(path, generated[key]);
}
if (stale.length) {
  console.error("Adaptadores desactualizados. Ejecuta `make tokens`:\n  " + stale.join("\n  "));
  process.exit(1);
}
console.log(check ? "Tokens: adaptadores al día y contraste válido." : "Tokens: adaptadores generados.");
