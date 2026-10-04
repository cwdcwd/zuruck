import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BASE_CLIENTS, loadLocalClients, mergeClients } from '../lib/config/clients';

const tmpFile = (contents: string): string => {
  const dir = mkdtempSync(join(tmpdir(), 'zuruck-clients-'));
  const path = join(dir, 'clients.local.json');
  writeFileSync(path, contents);
  return path;
};

describe('loadLocalClients', () => {
  test('missing file yields no clients', () => {
    expect(loadLocalClients(join(tmpdir(), 'does-not-exist-zuruck.json'))).toEqual([]);
  });

  test('valid file is loaded', () => {
    const path = tmpFile(JSON.stringify([
      { name: 'host-1a2b3c', description: 'test host', freshnessThresholdHours: 12 },
      { name: 'other-4d5e6f', description: 'default threshold' },
    ]));
    expect(loadLocalClients(path)).toEqual([
      { name: 'host-1a2b3c', description: 'test host', freshnessThresholdHours: 12 },
      { name: 'other-4d5e6f', description: 'default threshold', freshnessThresholdHours: undefined },
    ]);
  });

  test.each([
    ['invalid JSON', '{not json', /not valid JSON/],
    ['non-array', '{"name":"x"}', /JSON array/],
    ['bad name', '[{"name":"Bad_Name","description":"d"}]', /Invalid client name/],
    ['missing description', '[{"name":"host-1a2b3c"}]', /description/],
    ['non-positive threshold', '[{"name":"host-1a2b3c","description":"d","freshnessThresholdHours":0}]', /positive number/],
  ])('rejects %s', (_label, contents, err) => {
    expect(() => loadLocalClients(tmpFile(contents))).toThrow(err);
  });
});

describe('mergeClients', () => {
  test('appends local clients to the base list', () => {
    const local = [{ name: 'host-1a2b3c', description: 'd' }];
    expect(mergeClients(BASE_CLIENTS, local)).toEqual([...BASE_CLIENTS, ...local]);
  });

  test('rejects a duplicate name', () => {
    const dup = [{ name: BASE_CLIENTS[0].name, description: 'dup' }];
    expect(() => mergeClients(BASE_CLIENTS, dup)).toThrow(/Duplicate client name/);
  });
});
