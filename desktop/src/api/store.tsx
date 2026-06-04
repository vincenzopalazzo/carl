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
  refresh: () => Promise<void>;
}

const CarlContext = createContext<CarlContextValue | null>(null);

export function CarlProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<AppState>(emptyState);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const clientRef = useRef<DaemonClient | null>(null);

  // Resolve config, fetch the initial snapshot, and subscribe to the live
  // WebSocket. Reconnects with a fixed backoff if the socket drops.
  useEffect(() => {
    let ws: WebSocket | null = null;
    let retry: ReturnType<typeof setTimeout> | null = null;
    let cancelled = false;

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
          if (!isConnected && !cancelled) {
            // The socket dropped (daemon restart / not up yet) — retry.
            if (retry) clearTimeout(retry);
            retry = setTimeout(() => connect(client), 1500);
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

  const setRoute = useCallback(
    async (route: Route) => {
      const c = clientRef.current;
      if (!c) return;
      await c.setRoute(route);
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
    refresh,
  };
  return <CarlContext.Provider value={value}>{children}</CarlContext.Provider>;
}

export function useCarl(): CarlContextValue {
  const ctx = useContext(CarlContext);
  if (!ctx) throw new Error("useCarl must be used within CarlProvider");
  return ctx;
}
