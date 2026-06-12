export const decodeHexUtf8 = (input) =>
  Buffer.from(input, "hex").toString("utf8");

export const nowEpochMilliseconds = () => Date.now();
