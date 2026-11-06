export const errorToString = (e: unknown): string =>
  e instanceof Error && e.message ? e.message : String(e);
