import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
  Link,
  Outlet,
} from "@tanstack/react-router";
import { SessionBoundary } from "./app/session";
import { Patients } from "./features/patients";
import { PatientDetail } from "./features/patient";
import { MyProfile } from "./features/profile";
import { Consent } from "./features/consent";
import { Invite } from "./features/invite";
import { parseSection } from "./lib/sections";
import "./style.css";
const rootRoute = createRootRoute({
  component: () => (
    <SessionBoundary>
      <nav className="main-nav" aria-label="Navegación principal">
        <Link to="/">Pacientes</Link>
        <Link to="/consent">Accesos</Link>
        <Link to="/profile">Mi perfil</Link>
      </nav>
      <Outlet />
      <footer>
        Registro de autocuidado. No reemplaza la indicación de un profesional.
      </footer>
    </SessionBoundary>
  ),
});
const patientsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: Patients,
});
const profileRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/profile",
  component: MyProfile,
});
const consentRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/consent",
  component: Consent,
});
const inviteRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/invite",
  component: Invite,
});
const patientRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/patients/$patientId",
  validateSearch: (search: Record<string, unknown>) => ({ section: parseSection(search.section) }),
  component: () => {
    const { patientId } = patientRoute.useParams();
    const { section } = patientRoute.useSearch();
    return <PatientDetail key={patientId} patientId={patientId} section={section} />;
  },
});
const router = createRouter({
  routeTree: rootRoute.addChildren([patientsRoute, consentRoute, inviteRoute, patientRoute, profileRoute]),
});
declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
const client = new QueryClient({
  defaultOptions: {
    queries: { retry: false, refetchOnWindowFocus: true, gcTime: 0 },
    mutations: { retry: false },
  },
});
const root = document.getElementById("root");
if (!root) throw new Error("Missing application root");
createRoot(root).render(
  <StrictMode>
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
