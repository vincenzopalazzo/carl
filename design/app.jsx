// app.jsx — shell: sidebar nav, routing, tweaks, mount

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "accent": "violet",
  "density": "comfy",
  "showRoutes": true
}/*EDITMODE-END*/;

const ACCENTS = {
  violet: { a: "139 92% ", solid: "#8b7cf6", soft: "rgba(139,124,246,0.14)", border: "rgba(139,124,246,0.4)", dim: "#a99ff8" },
  teal: { solid: "#2bb6a3", soft: "rgba(43,182,163,0.14)", border: "rgba(43,182,163,0.42)", dim: "#56cdbc" },
};

const NAV = [
  ["transfers", "Transfers", "transfers"],
  ["discover", "Discover", "discover"],
  ["seeding", "Seeding", "seeding"],
  ["settings", "Settings", "settings"],
];

function Sidebar({ screen, setScreen }) {
  const counts = {
    transfers: TRANSFERS.filter((t) => t.status === "downloading" || t.status === "metadata").length,
    seeding: SEEDS.length,
  };
  const connected = RELAYS.filter((r) => r.state === "connected").length;
  return (
    <aside className="sidebar">
      <div className="brand">
        <span className="brand-mark"><OnionIcon size={20} /></span>
        <span className="brand-word">carl</span>
        <span className="brand-ver mono">0.9.2</span>
      </div>
      <div className="brand-tag">curl, but for torrents</div>

      <nav className="nav">
        {NAV.map(([id, label, icon]) => (
          <button key={id} className={"nav-item" + (screen === id ? " active" : "")} onClick={() => setScreen(id)}>
            <span className="nav-ic"><Icon name={icon} size={17} /></span>
            <span className="nav-label">{label}</span>
            {counts[id] != null && counts[id] > 0 && <span className="nav-count">{counts[id]}</span>}
          </button>
        ))}
      </nav>

      <div className="sidebar-foot">
        <div className="route-status">
          <div className="rstat-row">
            <span className="rstat-lbl">Route</span>
            <RouteBadge route="tor" size="sm" />
          </div>
          <div className="rstat-row">
            <span className="rstat-lbl">Relays</span>
            <span className="rstat-relays"><RelayDot state="connected" /> <span className="mono">{connected}/{RELAYS.length}</span></span>
          </div>
          <div className="rstat-row">
            <span className="rstat-lbl">Identity</span>
            <span className="mono rstat-npub">npub1carl…v3sba</span>
          </div>
        </div>
      </div>
    </aside>
  );
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [screen, setScreen] = React.useState(() => localStorage.getItem("carl.screen") || "transfers");
  const [showAdd, setShowAdd] = React.useState(false);

  React.useEffect(() => { localStorage.setItem("carl.screen", screen); }, [screen]);

  React.useEffect(() => {
    const ac = ACCENTS[t.accent] || ACCENTS.violet;
    const r = document.documentElement;
    r.style.setProperty("--accent", ac.solid);
    r.style.setProperty("--accent-soft", ac.soft);
    r.style.setProperty("--accent-border", ac.border);
    r.style.setProperty("--accent-dim", ac.dim);
  }, [t.accent]);

  React.useEffect(() => {
    document.documentElement.setAttribute("data-density", t.density);
    document.documentElement.setAttribute("data-show-routes", t.showRoutes ? "1" : "0");
  }, [t.density, t.showRoutes]);

  return (
    <div className="app">
      <Sidebar screen={screen} setScreen={setScreen} />
      <main className="main">
        {screen === "transfers" && <TransfersScreen openAdd={() => setShowAdd(true)} />}
        {screen === "discover" && <DiscoverScreen />}
        {screen === "seeding" && <SeedingScreen />}
        {screen === "settings" && <SettingsScreen />}
      </main>

      {showAdd && <AddModal onClose={() => setShowAdd(false)} />}

      <TweaksPanel>
        <TweakSection label="Brand" />
        <TweakRadio label="Accent" value={t.accent} options={["violet", "teal"]} onChange={(v) => setTweak("accent", v)} />
        <TweakSection label="Layout" />
        <TweakRadio label="Density" value={t.density} options={["compact", "comfy"]} onChange={(v) => setTweak("density", v)} />
        <TweakToggle label="Route labels on rows" value={t.showRoutes} onChange={(v) => setTweak("showRoutes", v)} />
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
