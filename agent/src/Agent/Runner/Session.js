export const computeDurationImpl = (startIso) => (endIso) => {
    const start = Date.parse(startIso);
    const end = Date.parse(endIso);

    if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) {
        return "";
    }

    const totalSeconds = Math.floor((end - start) / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;

    if (minutes <= 0) {
        return `${seconds}s`;
    }

    return `${minutes}m ${String(seconds).padStart(2, "0")}s`;
};
