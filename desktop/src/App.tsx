import { useEffect, useState } from "react";
import { Sidebar, type Screen } from "./Sidebar";
import { TransfersScreen } from "./screens/Transfers";
import { DiscoverScreen } from "./screens/Discover";
import { SeedingScreen } from "./screens/Seeding";
import { DriveScreen } from "./screens/Drive";
import { FollowingScreen } from "./screens/Following";
import { SettingsScreen } from "./screens/Settings";
import { AddModal } from "./modals/AddModal";
import { Icon } from "./components/icons";

const ACCENTS = {
  violet: {
    solid: "#8b7cf6",
    soft: "rgba(139,124,246,0.14)",
    border: "rgba(139,124,246,0.4)",
    dim: "#a99ff8",
  },
  teal: {
    solid: "#2bb6a3",
    soft: "rgba(43,182,163,0.14)",
    border: "rgba(43,182,163,0.42)",
    dim: "#56cdbc",
  },
};
type Accent = keyof typeof ACCENTS;
type Density = "comfy" | "compact";

function load<T extends string>(key: string, fallback: T): T {
  return (localStorage.getItem(key) as T) || fallback;
}

function Tweaks({
  accent,
  setAccent,
  density,
  setDensity,
  showRoutes,
  setShowRoutes,
}: {
  accent: Accent;
  setAccent: (a: Accent) => void;
  density: Density;
  setDensity: (d: Density) => void;
  showRoutes: boolean;
  setShowRoutes: (v: boolean) => void;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div
      style={{ position: "fixed", right: 16, bottom: 16, zIndex: 150 }}
    >
      {open && (
        <div
          style={{
            background: "var(--bg-1)",
            border: "1px solid var(--border)",
            borderRadius: "var(--r-lg)",
            padding: 14,
            marginBottom: 10,
            width: 230,
            boxShadow: "0 12px 40px rgba(0,0,0,.5)",
            display: "flex",
            flexDirection: "column",
            gap: 12,
          }}
        >
          <div className="field">
            <label className="field-label">Accent</label>
            <div className="route-select">
              {(["violet", "teal"] as const).map((a) => (
                <button
                  key={a}
                  className={"rsl-btn" + (accent === a ? " active" : "")}
                  onClick={() => setAccent(a)}
                  style={{ textTransform: "capitalize" }}
                >
                  {a}
                </button>
              ))}
            </div>
          </div>
          <div className="field">
            <label className="field-label">Density</label>
            <div className="route-select">
              {(["comfy", "compact"] as const).map((d) => (
                <button
                  key={d}
                  className={"rsl-btn" + (density === d ? " active" : "")}
                  onClick={() => setDensity(d)}
                  style={{ textTransform: "capitalize" }}
                >
                  {d}
                </button>
              ))}
            </div>
          </div>
          <label className={"toggle-row" + (showRoutes ? " on" : "")} onClick={() => setShowRoutes(!showRoutes)}>
            <span className="tr-switch">
              <span className="tr-knob" />
            </span>
            <span className="tr-txt">
              <span className="tr-label">Route labels on rows</span>
            </span>
          </label>
        </div>
      )}
      <button
        className="btn"
        onClick={() => setOpen(!open)}
        title="Tweaks"
        style={{ float: "right" }}
      >
        <Icon name="settings" size={15} /> Tweaks
      </button>
    </div>
  );
}

export function App() {
  const [screen, setScreen] = useState<Screen>(
    () => (localStorage.getItem("carl.screen") as Screen) || "transfers",
  );
  const [showAdd, setShowAdd] = useState(false);
  const [accent, setAccent] = useState<Accent>(() => load("carl.accent", "violet"));
  const [density, setDensity] = useState<Density>(() => load("carl.density", "comfy"));
  const [showRoutes, setShowRoutes] = useState<boolean>(
    () => localStorage.getItem("carl.showRoutes") !== "0",
  );

  useEffect(() => {
    localStorage.setItem("carl.screen", screen);
  }, [screen]);

  useEffect(() => {
    const ac = ACCENTS[accent] ?? ACCENTS.violet;
    const r = document.documentElement;
    r.style.setProperty("--accent", ac.solid);
    r.style.setProperty("--accent-soft", ac.soft);
    r.style.setProperty("--accent-border", ac.border);
    r.style.setProperty("--accent-dim", ac.dim);
    localStorage.setItem("carl.accent", accent);
  }, [accent]);

  useEffect(() => {
    document.documentElement.setAttribute("data-density", density);
    localStorage.setItem("carl.density", density);
  }, [density]);

  useEffect(() => {
    document.documentElement.setAttribute(
      "data-show-routes",
      showRoutes ? "1" : "0",
    );
    localStorage.setItem("carl.showRoutes", showRoutes ? "1" : "0");
  }, [showRoutes]);

  return (
    <div className="app">
      <Sidebar screen={screen} setScreen={setScreen} />
      <main className="main">
        {screen === "transfers" && (
          <TransfersScreen openAdd={() => setShowAdd(true)} />
        )}
        {screen === "discover" && <DiscoverScreen />}
        {screen === "following" && <FollowingScreen />}
        {screen === "seeding" && <SeedingScreen />}
        {screen === "drive" && <DriveScreen />}
        {screen === "settings" && <SettingsScreen />}
      </main>

      {showAdd && <AddModal onClose={() => setShowAdd(false)} />}

      <Tweaks
        accent={accent}
        setAccent={setAccent}
        density={density}
        setDensity={setDensity}
        showRoutes={showRoutes}
        setShowRoutes={setShowRoutes}
      />
    </div>
  );
}
