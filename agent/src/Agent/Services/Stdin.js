import * as readline from "node:readline";

let rl = null;
const pendingCallbacks = [];
const pendingLines = [];
let closed = false;

function setup() {
  if (rl) return;
  rl = readline.createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    if (pendingCallbacks.length > 0) {
      const cb = pendingCallbacks.shift();
      cb(line)();
    } else {
      pendingLines.push(line);
    }
  });
  rl.on("close", () => {
    closed = true;
    while (pendingCallbacks.length > 0) {
      pendingCallbacks.shift()("")();
    }
  });
}

// readLineImpl :: (String -> Effect Unit) -> Effect Unit
export const readLineImpl = (callback) => () => {
  setup();
  if (pendingLines.length > 0) {
    callback(pendingLines.shift())();
  } else if (closed) {
    callback("")();
  } else {
    pendingCallbacks.push(callback);
  }
};

// closeStdinImpl :: Effect Unit
export const closeStdinImpl = () => {
  if (rl) { rl.close(); rl = null; }
};

// writePromptImpl :: String -> Effect Unit
export const writePromptImpl = (prompt) => () => {
  process.stdout.write(prompt);
};
