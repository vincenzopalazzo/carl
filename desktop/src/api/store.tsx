import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import { DaemonClient, resolveConfig } from "./client";
import { type AppState, emptyState, type Route } from "./types";

interface CarlContextValue {
  state: AppState;
  /** WebSocket connected to the daemon. */
  connected: boolean;
  /** Set when the daemon can't be reached at all. */
  error: string | null;
  addTransfer: (source: string, route: Route, nostr: boolean) => Promise<void>;
  removeTransfer: (id: string) => Promise<void>;
  search: (query: string) => Promise<import("./types").DiscoverResult[]>;
  setRoute: (route: Route) => Promise<void>;
  updateSettings: (patch: {
    route?: Route;
    downloadDir?: string;
    relays?: string[];
  }) => Promise<void>;
  createSeed: (file: File, route: Route, nostr: boolean) => Promise<void>;
  refresh: () => Promise<void>;
}

const CarlContext = createContext<CarlContextValue | null>(null);

export function CarlProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<AppState>(emptyState);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const clientRef = useRef<DaemonClient | null>(null);

  // Resolve config, fetch the initial snapshot, and subscribe to the live
  // WebSocket. Reconnects with exponential backoff (capped, jittered) if the
  // socket drops, so a down daemon isn't hammered every tick.
  useEffect(() => {
    let ws: WebSocket | null = null;
    let retry: ReturnType<typeof setTimeout> | null = null;
    let cancelled = false;
    let backoff = 1000;
    const MAX_BACKOFF = 15000;

    async function start() {
      try {
        const cfg = await resolveConfig();
        const client = new DaemonClient(cfg);
        clientRef.current = client;
        // Initial snapshot so the UI paints before the first WS tick.
        try {
          setState(await client.getState());
          setError(null);
        } catch (e) {
          setError(String(e));
        }
        connect(client);
      } catch (e) {
        setError(String(e));
      }
    }

    function connect(client: DaemonClient) {
      if (cancelled) return;
      ws = client.openStateSocket(
        (s) => {
          setState(s);
          setError(null);
        },
        (isConnected) => {
          setConnected(isConnected);
          if (isConnected) {
            backoff = 1000; // reset on success
            // Refresh the snapshot immediately so a reconnect doesn't show
            // stale data until the first WS tick arrives.
            client
              .getState()
              .then((s) => {
                setState(s);
                setError(null);
              })
              .catch(() => {});
          } else if (!cancelled) {
            // The socket dropped (daemon restart / not up yet) — retry with
            // capped, jittered exponential backoff.
            if (retry) clearTimeout(retry);
            const delay = backoff + Math.random() * 500;
            backoff = Math.min(backoff * 2, MAX_BACKOFF);
            retry = setTimeout(() => connect(client), delay);
          }
        },
      );
    }

    start();
    return () => {
      cancelled = true;
      if (retry) clearTimeout(retry);
      ws?.close();
    };
  }, []);

  const refresh = useCallback(async () => {
    const c = clientRef.current;
    if (!c) return;
    setState(await c.getState());
  }, []);

  const addTransfer = useCallback(
    async (source: string, route: Route, nostr: boolean) => {
      const c = clientRef.current;
      if (!c) throw new Error("daemon not connected");
      await c.addTransfer(source, route, nostr);
      await refresh();
    },
    [refresh],
  );

  const removeTransfer = useCallback(
    async (id: string) => {
      const c = clientRef.current;
      if (!c) return;
      await c.removeTransfer(id);
      await refresh();
    },
    [refresh],
  );

  const search = useCallback(async (query: string) => {
    const c = clientRef.current;
    if (!c) throw new Error("daemon not connected");
    return c.search(query);
  }, []);

  const updateSettings = useCallback(
    async (patch: { route?: Route; downloadDir?: string; relays?: string[] }) => {
      const c = clientRef.current;
      if (!c) throw new Error("daemon not connected");
      await c.updateSettings(patch);
      await refresh();
    },
    [refresh],
  );

  const setRoute = useCallback(
    (route: Route) => updateSettings({ route }),
    [updateSettings],
  );

  const createSeed = useCallback(
    async (file: File, route: Route, nostr: boolean) => {
      const c = clientRef.current;
      if (!c) throw new Error("daemon not connected");
      await c.createSeed(file, route, nostr);
      await refresh();
    },
    [refresh],
  );

  const value: CarlContextValue = {
    state,
    connected,
    error,
    addTransfer,
    removeTransfer,
    search,
    setRoute,
    updateSettings,
    createSeed,
    refresh,
  };
  return <CarlContext.Provider value={value}>{children}</CarlContext.Provider>;
}

export function useCarl(): CarlContextValue {
  const ctx = useContext(CarlContext);
  if (!ctx) throw new Error("useCarl must be used within CarlProvider");
  return ctx;
}
