import { resolveDefaultEnvFile } from '../app/core/env';

describe('resolveDefaultEnvFile', () => {
  const home = '/home/alice';
  const none = () => false;

  test('explicit RESTIC_ENV_FILE wins', () => {
    expect(resolveDefaultEnvFile({ RESTIC_ENV_FILE: '/x/env' }, () => true, home)).toBe('/x/env');
  });

  test('user-mode file when present', () => {
    const exists = (p: string) => p === '/home/alice/.config/zuruck/env';
    expect(resolveDefaultEnvFile({}, exists, home)).toBe('/home/alice/.config/zuruck/env');
  });

  test('honours XDG_CONFIG_HOME', () => {
    const exists = (p: string) => p === '/cfg/zuruck/env';
    expect(resolveDefaultEnvFile({ XDG_CONFIG_HOME: '/cfg' }, exists, home)).toBe('/cfg/zuruck/env');
  });

  test('falls back to the system file', () => {
    expect(resolveDefaultEnvFile({}, none, home)).toBe('/etc/restic/env');
  });
});
