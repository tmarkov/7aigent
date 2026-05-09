// Terminal output helpers.
export const printLnImpl = (s) => () => process.stdout.write(s + "\n");
export const printStrImpl = (s) => () => process.stdout.write(s);
export const printErrImpl = (s) => () => process.stderr.write(s + "\n");
