# Design tokens · Graphite

`tokens.json` es la única fuente de verdad de los valores visuales compartidos por iOS, Android y web. La UI sigue siendo nativa: sólo se comparten valores, no componentes.

```sh
make tokens        # regenera los adaptadores
make tokens-check  # falla si un adaptador no coincide o un par no cumple contraste
```

`make lint` y `pnpm --dir apps/web lint` ejecutan la comprobación, así que el workflow Web la corre en CI.

## Adaptadores generados

No se editan a mano.

| Plataforma | Archivo | Consumo |
| --- | --- | --- |
| Web | `apps/web/src/tokens.css` | Variables `--mt-*`, importadas por `style.css`. Sigue `prefers-color-scheme`; `data-theme` en `<html>` lo fuerza. |
| iOS | `apps/ios/MedicationTracker/DesignSystem/Tokens.generated.swift` | `Tokens.Colors`, `Space`, `Radius`, `Size`, `Typography`. `Semantic` y `LargeActionStyle` en `DesignSystem.swift` los envuelven. |
| Android | `apps/android/.../ui/theme/Tokens.kt` | `GraphiteTokens`. `Theme.kt` los adapta a Material 3 y expone los estados con `MedicationTrackerTheme.colors`. |

## Reglas

- Los colores se declaran en pares claro/oscuro. `contrast.text` exige 4.5:1 y `contrast.nonText` 3:1 en ambos modos. Un par nuevo de texto sobre fondo se añade a la lista.
- Los estados de dosis tienen su par `Fg`/`Bg`. «Omitida» es neutra a propósito, y el rojo (`danger`) se reserva para conflictos que exigen decidir.
- Las series de gráfico se validaron contra separación por daltonismo con el orden tomada, tarde, omitida, sin confirmar. `chartSkipped` es gris a propósito, por eso no alcanza el croma de una serie categórica.
- Ningún estado ni serie de gráfico depende sólo del color: los componentes añaden icono, texto o trama.
- Las apps nativas usan la fuente del sistema para respetar Dynamic Type y la escala de fuente. Cada rol tipográfico declara un `ios` text style que sirve de ancla de escala. La web declara Geist y Geist Mono con alternativas del sistema. Mientras la fuente no se aloje localmente, la web cae a la fuente del sistema.
