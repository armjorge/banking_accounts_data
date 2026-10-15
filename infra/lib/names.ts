export const PROJECT = "strm_bank";
export const CONTROL_PARAM_PREFIX = "/strm_bank/control";

const ENV_PATTERN = /^[a-z][a-z0-9_]{0,20}$/;

export function assertEnvironmentName(name: string): string {
  if (!ENV_PATTERN.test(name)) {
    throw new Error(
      `Invalid environment '${name}'. Use lowercase letters, digits, underscore; start with a letter.`,
    );
  }
  return name;
}

export function objectPrefix(environmentName: string): string {
  return `strm_bank_${assertEnvironmentName(environmentName)}`;
}

export function isProtectedEnvironment(environmentName: string): boolean {
  return ["prod", "prd", "production"].includes(environmentName);
}
