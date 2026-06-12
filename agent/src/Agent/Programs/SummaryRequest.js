export const encodeBase64Utf8 = (input) =>
  Buffer.from(input, "utf8").toString("base64");
