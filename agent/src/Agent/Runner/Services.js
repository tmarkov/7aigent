// nowIsoImpl :: Effect String
export const nowIsoImpl = () => new Date().toISOString();

// exitImpl :: Int -> Effect Unit
export const exitImpl = (code) => () => process.exit(code);
