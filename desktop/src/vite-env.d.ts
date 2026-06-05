/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_CARL_BASE?: string;
  readonly VITE_CARL_TOKEN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
