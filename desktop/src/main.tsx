import React from "react";
import ReactDOM from "react-dom/client";
import "./fonts.css";
import "./styles.css";
import { CarlProvider } from "./api/store";
import { App } from "./App";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <CarlProvider>
      <App />
    </CarlProvider>
  </React.StrictMode>,
);
