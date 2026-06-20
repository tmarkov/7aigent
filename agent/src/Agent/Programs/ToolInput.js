"use strict";

export const decodeJsonStringLiteral = (text) => JSON.parse(text);

export const parseJuliaReplInputImpl = (input) => {
  try {
    const value = JSON.parse(input);
    const isObject =
      value !== null && typeof value === "object" && !Array.isArray(value);
    return {
      parsed: true,
      isObject,
      hasCodeString: isObject && typeof value.code === "string",
      code: isObject && typeof value.code === "string" ? value.code : "",
      hasTimeoutNumber: isObject && typeof value.timeout_seconds === "number",
      timeoutSeconds:
        isObject && typeof value.timeout_seconds === "number"
          ? value.timeout_seconds
          : 0,
    };
  } catch (_error) {
    return {
      parsed: false,
      isObject: false,
      hasCodeString: false,
      code: "",
      hasTimeoutNumber: false,
      timeoutSeconds: 0,
    };
  }
};
