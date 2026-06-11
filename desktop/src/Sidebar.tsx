import { Icon, OnionIcon } from "./components/icons";
import { RouteBadge, RelayDot } from "./components/atoms";
import { trunc } from "./components/format";
import { useCarl } from "./api/store";

export type Screen =
  | "transfers"
  | "discover"
  | "following"
  | "seeding"
  | "settings";

const NAV: [Screen, string, string][] = [
  ["transfers", "Transfers", "transfers"],
  ["discover", "Discover", "discover"],
  ["following", "Following", "pulse"],
  ["seeding", "Seeding", "seeding"],
  ["settings", "Settings", "settings"],
];

export function Sidebar({
  screen,
  setScreen,
}: {
  screen: Screen;
  setScreen: (s: Screen) => void;
}) {
  const { state, connected } = useCarl();
  const counts: Partial<Record<Screen, number>> = {
    transfers: state.transfers.filter(
      (t) => t.status === "downloading" || t.status === "metadata",
    ).length,
    following: (state.follows ?? []).length,
    seeding: state.seeds.length,
  };
  const connectedRelays = state.relays.filter(
    (r) => r.state === "connected",
  ).length;
  const npub = state.identity.npub;

  return (
    <aside className="sidebar">
      <div className="brand">
        <span className="brand-mark">
          <OnionIcon size={20} />
        </span>
        <span className="brand-word">carl</span>
        <span className="brand-ver mono">0.9.2</span>
      </div>
      <div className="brand-tag">curl, but for torrents</div>

      <nav className="nav">
        {NAV.map(([id, label, icon]) => (
          <button
            key={id}
            className={"nav-item" + (screen === id ? " active" : "")}
            onClick={() => setScreen(id)}
          >
            <span className="nav-ic">
              <Icon name={icon} size={17} />
            </span>
            <span className="nav-label">{label}</span>
            {counts[id] != null && counts[id]! > 0 && (
              <span className="nav-count">{counts[id]}</span>
            )}
          </button>
        ))}
      </nav>

      <div className="sidebar-foot">
        <div className="route-status">
          <div className="rstat-row">
            <span className="rstat-lbl">Route</span>
            <RouteBadge route={state.settings.route} size="sm" />
          </div>
          <div className="rstat-row">
            <span className="rstat-lbl">Relays</span>
            <span className="rstat-relays">
              <RelayDot
                state={connectedRelays > 0 ? "connected" : "configured"}
              />{" "}
              <span className="mono">
                {connectedRelays}/{state.relays.length}
              </span>
            </span>
          </div>
          <div className="rstat-row">
            <span className="rstat-lbl">Daemon</span>
            <span className="rstat-relays">
              <RelayDot state={connected ? "connected" : "unreachable"} />
              <span className="mono" style={{ fontSize: 11 }}>
                {connected ? "live" : "offline"}
              </span>
            </span>
          </div>
          {npub && (
            <div className="rstat-row">
              <span className="rstat-lbl">Identity</span>
              <span className="mono rstat-npub">{trunc(npub, 7)}</span>
            </div>
          )}
        </div>
      </div>
    </aside>
  );
}
