import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { sendInputToFifoPath } from "../Agent.Services.Sandbox/foreign.js";

function withFifo(fn, onError, onSuccess) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "7aigent-fifo-test-"));
  const fifoPath = path.join(dir, "stdin");
  try {
    childProcess.execFileSync("mkfifo", [fifoPath]);
    fn(fifoPath, onError, onSuccess);
  } catch (err) {
    cleanup(dir);
    onError(String(err?.message || err))();
  }
}

function cleanup(dir) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch (_) {}
}

export const testSuccessfulFifoWriteImpl = (value) => (onError) => (onSuccess) => () => {
  withFifo((fifoPath, fail, succeed) => {
    const readFd = fs.openSync(fifoPath, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    sendInputToFifoPath(fifoPath, value, (err) => {
      try { fs.closeSync(readFd); } catch (_) {}
      cleanup(path.dirname(fifoPath));
      fail(err)();
    }, () => {
      const buf = Buffer.alloc(4096);
      const n = fs.readSync(readFd, buf, 0, buf.length, null);
      try { fs.closeSync(readFd); } catch (_) {}
      cleanup(path.dirname(fifoPath));
      succeed(buf.subarray(0, n).toString("utf8"))();
    });
  }, onError, onSuccess);
};

export const testOversizeFifoWriteImpl = (value) => (onError) => (onSuccess) => () => {
  withFifo((fifoPath, fail, succeed) => {
    const readFd = fs.openSync(fifoPath, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    sendInputToFifoPath(fifoPath, value, (err) => {
      try { fs.closeSync(readFd); } catch (_) {}
      cleanup(path.dirname(fifoPath));
      fail(err)();
    }, () => {
      try { fs.closeSync(readFd); } catch (_) {}
      cleanup(path.dirname(fifoPath));
      succeed("unexpected success")();
    });
  }, onError, onSuccess);
};

export const testWouldBlockFifoWriteImpl = (value) => (onError) => (onSuccess) => () => {
  withFifo((fifoPath, fail, succeed) => {
    const readFd = fs.openSync(fifoPath, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    const writeFd = fs.openSync(fifoPath, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK);
    const chunk = Buffer.alloc(4096, "x");
    try {
      while (true) {
        fs.writeSync(writeFd, chunk, 0, chunk.length);
      }
    } catch (err) {
      if (err?.code !== "EAGAIN" && err?.code !== "EWOULDBLOCK") {
        try { fs.closeSync(writeFd); } catch (_) {}
        try { fs.closeSync(readFd); } catch (_) {}
        cleanup(path.dirname(fifoPath));
        fail(String(err?.message || err))();
        return;
      }
    }

    sendInputToFifoPath(fifoPath, value, (err) => {
      try { fs.closeSync(writeFd); } catch (_) {}
      try { fs.closeSync(readFd); } catch (_) {}
      cleanup(path.dirname(fifoPath));
      fail(err)();
    }, () => {
      try { fs.closeSync(writeFd); } catch (_) {}
      try { fs.closeSync(readFd); } catch (_) {}
      cleanup(path.dirname(fifoPath));
      succeed("unexpected success")();
    });
  }, onError, onSuccess);
};
