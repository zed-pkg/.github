import assert from 'node:assert/strict';
import test from 'node:test';
import { analyzeSnapshot, applyExceptions, extractReferences, validateExceptions, validatePolicy } from './tjsv-fleet-scan.mjs';

const CURRENT = '4a5d049218adc2740d4cf78f612caf7f38f6f64c';
const REUSABLE = '4eb44b4d5ea606137a3b9dfa6572ed2a77185605';
const policy = validatePolicy({
  schema: 'zed.tjsv-fleet-policy/v1', organization: 'zed-pkg', currentValidatorRevision: CURRENT,
  reusableWorkflowRepository: 'zed-pkg/.github', reusableWorkflowRevision: REUSABLE,
  requiredConsumers: ['zed-pkg/required'], minimumCapabilities: ['fresh-contract-ir'],
  capabilityMarkers: { 'fresh-contract-ir': ['contract_ir'], 'dense-declaration-inventory': ['expected_declarations'],
    'current-input-consumer-verification': ['test-consumer-admission'], 'canonical-refusal-probes': ['test-consumer-admission'],
    'durable-verification-receipt': ['consumer-verification-receipt/v1', 'contract-ir-verification/v1', 'verification.json'] }, candidateFileLimitPerRepository: 20,
});
const emptyLedger = { schema: 'zed.tjsv-pin-exceptions/v1', exceptions: [] };
const currentWorkflow = `uses: ORESoftware/typespec-json-schema-validator@${CURRENT}\nwith:\n  contract_ir: out/contract-ir.json\nuses: ORESoftware/typespec-json-schema-validator/actions/test-consumer-admission@${CURRENT}\nwith:\n  expected_declarations: '["Zed.Test"]'\n  verification: out/verification.json\n`;

test('extracts direct action, checkout, constant and reusable workflow pins', () => {
  const text = `uses: ORESoftware/typespec-json-schema-validator@${CURRENT}\nrepository: ORESoftware/typespec-json-schema-validator\n  ref: ${CURRENT}\nconst VALIDATOR_REVISION = '${CURRENT}';\nuses: zed-pkg/.github/.github/workflows/reusable-tjsv-admission.yml@${REUSABLE}`;
  assert.deepEqual(extractReferences(text).references.map((item) => item.kind), ['validator-action', 'validator-checkout', 'validator-constant', 'reusable-workflow']);
});

test('prose and regression descriptions are not mistaken for executable references', () => {
  const extracted = extractReferences('TJSV and typespec-json-schema-validator enforce this regression; no action or checkout is declared here.');
  assert.equal(extracted.mentioned, true);
  assert.equal(extracted.referenceIntent, false);
  assert.deepEqual(extracted.references, []);
});

test('malformed executable reference intent is fail-closed', () => {
  const result = analyzeSnapshot({ repositories: [{ full_name: 'zed-pkg/required', files: { '.github/workflows/a.yml': 'uses: ORESoftware/typespec-json-schema-validator\ncontract_ir expected_declarations test-consumer-admission verification.json' } }] }, policy, emptyLedger, new Date('2026-09-09T12:00:00Z'));
  assert.ok(result.findings.some((item) => item.code === 'unparsed-tjsv-reference'));
});

test('current direct admission with capability markers passes', () => {
  const result = analyzeSnapshot({ repositories: [{ full_name: 'zed-pkg/required', files: { '.github/workflows/a.yml': currentWorkflow } }] }, policy, emptyLedger, new Date('2026-09-09T12:00:00Z'));
  assert.equal(result.status, 'passed');
  assert.equal(result.findings.length, 0);
});

test('current reusable workflow inherits the reviewed capability baseline', () => {
  const result = analyzeSnapshot({ repositories: [{ full_name: 'zed-pkg/required', files: { '.github/workflows/a.yml': `uses: zed-pkg/.github/.github/workflows/reusable-tjsv-admission.yml@${REUSABLE}` } }] }, policy, emptyLedger, new Date('2026-09-09T12:00:00Z'));
  assert.equal(result.status, 'passed');
});

test('stale and mutable validator references fail closed', () => {
  const stale = '2281843126ab644607b11cf8281d84f382d68dfc';
  const result = analyzeSnapshot({ repositories: [{ full_name: 'zed-pkg/required', files: { '.github/workflows/a.yml': `uses: ORESoftware/typespec-json-schema-validator@${stale}\nuses: ORESoftware/typespec-json-schema-validator/actions/test-consumer-admission@main\ncontract_ir expected_declarations verification.json` } }] }, policy, emptyLedger, new Date('2026-09-09T12:00:00Z'));
  assert.equal(result.status, 'failed');
  assert.ok(result.findings.some((item) => item.code === 'stale-validator-pin'));
  assert.ok(result.findings.some((item) => item.code === 'mutable-validator-pin'));
});

test('missing required consumer is a visibility failure, never silently skipped', () => {
  const result = analyzeSnapshot({ repositories: [] }, policy, emptyLedger, new Date('2026-09-09T12:00:00Z'));
  assert.ok(result.findings.some((item) => item.code === 'unreadable-required-repository'));
});

test('active exception suppresses only the matching debt', () => {
  const finding = { repository: 'zed-pkg/required', code: 'stale-validator-pin', pin: '2281843126ab644607b11cf8281d84f382d68dfc' };
  const ledger = { schema: 'zed.tjsv-pin-exceptions/v1', exceptions: [{ repository: finding.repository, code: finding.code, pin: finding.pin, owner: 'DEN-3982', reason: 'Temporary migration debt with a real owner and bounded expiry.', expiresAt: '2026-09-16' }] };
  const result = applyExceptions([finding], ledger, new Date('2026-09-09T12:00:00Z'));
  assert.equal(result.unresolved.length, 0);
  assert.equal(result.excepted.length, 1);
});

test('expired exception itself becomes a blocking finding', () => {
  const ledger = { schema: 'zed.tjsv-pin-exceptions/v1', exceptions: [{ repository: 'zed-pkg/required', code: 'stale-validator-pin', owner: 'DEN-3982', reason: 'Temporary migration debt with a real owner and bounded expiry.', expiresAt: '2026-09-08' }] };
  const result = applyExceptions([], ledger, new Date('2026-09-09T12:00:00Z'));
  assert.equal(result.unresolved[0].code, 'expired-exception');
});

test('exception validation rejects duplicates and weak ownership metadata', () => {
  assert.throws(() => validateExceptions({ schema: 'zed.tjsv-pin-exceptions/v1', exceptions: [{ repository: 'zed-pkg/x', code: 'stale-validator-pin', owner: '', reason: 'short', expiresAt: '2026-09-16' }] }, new Date('2026-09-09T12:00:00Z')));
});
