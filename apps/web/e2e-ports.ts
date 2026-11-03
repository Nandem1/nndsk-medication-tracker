const offset = Number(process.env.E2E_PORT_OFFSET ?? "0");
if (!Number.isInteger(offset) || offset < 0 || offset > 40000) {
  throw new Error("E2E_PORT_OFFSET must be an integer between 0 and 40000");
}

export const e2eApiURL = `http://127.0.0.1:${18083 + offset}`;
export const e2eWebPort = 5173 + offset;
export const e2eWebURL = `http://127.0.0.1:${e2eWebPort}`;
