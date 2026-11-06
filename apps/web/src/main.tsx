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
import { FamilyPage } from "./features/family";
import { JoinFamily } from "./features/join";
import { parseSection } from "./lib/sections";
import "@fontsource-variable/geist";
import "@fontsource-variable/geist-mono";
import "./style.css";
const rootRoute = createRootRoute({
  component: () => (
    <SessionBoundary>
      <nav className="main-nav" aria-label="Navegación principal">
        <Link to="/">Pacientes</Link>
        <Link to="/familia">Familia</Link>
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
const familyRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/familia",
  component: FamilyPage,
});
const joinRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/unirse",
  component: JoinFamily,
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
  routeTree: rootRoute.addChildren([patientsRoute, familyRoute, joinRoute, patientRoute, profileRoute]),
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
