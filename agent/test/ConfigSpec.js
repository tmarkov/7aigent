export const setEnv = (name) => (value) => () => {
  process.env[name] = value;
};

export const unsetEnv = (name) => () => {
  delete process.env[name];
};
