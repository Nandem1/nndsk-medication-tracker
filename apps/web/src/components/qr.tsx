import { useMemo } from "react";
import qrcode from "qrcode-generator";

/** QR del enlace de invitación, en SVG para que se vea nítido a cualquier tamaño. */
export function QRCode({ value, label }: { value: string; label: string }) {
  const path = useMemo(() => {
    const qr = qrcode(0, "M");
    qr.addData(value);
    qr.make();
    const size = qr.getModuleCount();
    let d = "";
    for (let row = 0; row < size; row++)
      for (let col = 0; col < size; col++) if (qr.isDark(row, col)) d += `M${col} ${row}h1v1h-1z`;
    return { d, size };
  }, [value]);
  const margin = 4;
  const box = path.size + margin * 2;
  return (
    <svg className="qr" role="img" aria-label={label} viewBox={`${-margin} ${-margin} ${box} ${box}`} shapeRendering="crispEdges">
      <rect x={-margin} y={-margin} width={box} height={box} fill="#fff" />
      <path d={path.d} fill="#111" />
    </svg>
  );
}
