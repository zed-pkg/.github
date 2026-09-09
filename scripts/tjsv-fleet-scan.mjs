import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SHA40 = /^[0-9a-f]{40}$/u;
const TEXT_DECODER = new TextDecoder();

function need(condition, message) {
  if (!condition) throw new Error(`TJSV fleet scan: ${message}`);
}

export function validatePolicy(policy) {
  need(policy?.schema === 'zed.tjsv-fleet-policy/v1', 'unexpected policy schema');
  need(typeof policy.organization === 'string' && policy.organization.length > 0, 'organization is required');
  need(SHA40.test(policy.currentValidatorRevision), 'current validator revision must be an immutable SHA');
  need(SHA40.test(policy.reusableWorkflowRevision), 'reusable workflow revision must be an immutable SHA');
  need(Array.isArray(policy.requiredConsumers) && policy.requiredConsumers.length > 0, 'required consumer inventory is empty');
  need(new Set(policy.requiredConsumers).size === policy.requiredConsumers.length, 'duplicate required consumers');
  need(Array.isArray(policy.minimumCapabilities) && policy.minimumCapabilities.length > 0, 'minimum capabilities are empty');
  need(policy.capabilityMarkers && typeof policy.capabilityMarkers === 'object', 'capability marker policy is missing');
  return policy;
}

export function validateExceptions(ledger, now = new Date()) {
  need(ledger?.schema === 'zed.tjsv-pin-exceptions/v1', 'unexpected exception schema');
  need(Array.isArray(ledger.exceptions), 'exceptions must be an array');
  const keys = new Set();
  for (const item of ledger.exceptions) {
    need(typeof item.repository === 'string' && item.repository.includes('/'), 'exception repository is invalid');
    need(typeof item.code === 'string' && item.code.length > 0, 'exception code is required');
    need(typeof item.owner === 'string' && item.owner.length > 0, 'exception owner is required');
    need(typeof item.reason === 'string' && item.reason.length >= 24, 'exception reason is too short');
    need(/^\d{4}-\d{2}-\d{2}$/u.test(item.expiresAt), 'exception expiry must be YYYY-MM-DD');
    if (item.pin !== undefined) need(SHA40.test(item.pin), 'exception pin must be a 40-character SHA');
    const key = `${item.repository}\u0000${item.code}\u0000${item.pin ?? ''}\u0000${item.path ?? ''}`;
    need(!keys.has(key), `duplicate exception: ${key}`);
    keys.add(key);
    item.expired = new Date(`${item.expiresAt}T23:59:59Z`) < now;
  }
  return ledger;
}

export function extractReferences(text, path = '<memory>') {
  const references = [];
  const lines = text.split(/\r?\n/u);
  const push = (kind, value, line) => references.push({ kind, value: value.replace(/["']/gu, ''), path, line });
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    let match = line.match(/uses:\s*ORESoftware\/typespec-json-schema-validator(?:\/actions\/test-consumer-admission)?@([^\s#]+)/u);
    if (match) push('validator-action', match[1], index + 1);
    match = line.match(/uses:\s*zed-pkg\/\.github\/\.github\/workflows\/reusable-tjsv-admission\.yml@([^\s#]+)/u);
    if (match) push('reusable-workflow', match[1], index + 1);
    match = line.match(/VALIDATOR_REVISION\s*=\s*["']([^"']+)["']/u);
    if (match) push('validator-constant', match[1], index + 1);
    if (/repository:\s*ORESoftware\/typespec-json-schema-validator\s*$/u.test(line)) {
      for (let offset = 1; offset <= 12 && index + offset < lines.length; offset += 1) {
        const ref = lines[index + offset].match(/^\s*ref:\s*([^\s#]+)/u);
        if (ref) { push('validator-checkout', ref[1], index + offset + 1); break; }
        if (/^\s*-\s+uses:/u.test(lines[index + offset])) break;
      }
    }
  }
  const mentioned = text.includes('typespec-json-schema-validator') || text.includes('TJSV');
  return { references, mentioned };
}

function markerPresent(allText, alternatives) {
  return alternatives.some((marker) => allText.includes(marker));
}

export function analyzeRepository(repository, policy) {
  const findings = [];
  const records = [];
  const files = repository.files ?? {};
  const allText = Object.values(files).join('\n');
  let mentioned = false;
  for (const [path, text] of Object.entries(files)) {
    const extracted = extractReferences(text, path);
    records.push(...extracted.references);
    mentioned ||= extracted.mentioned;
    if (extracted.mentioned && extracted.references.length === 0) {
      findings.push({ repository: repository.full_name, code: 'unparsed-tjsv-reference', path, message: 'TJSV is mentioned but no supported immutable reference shape was parsed.' });
    }
  }
  const direct = records.filter((item) => item.kind.startsWith('validator-'));
  const reusable = records.filter((item) => item.kind === 'reusable-workflow');
  const required = policy.requiredConsumers.includes(repository.full_name);
  if (repository.unreadable) {
    if (required) findings.push({ repository: repository.full_name, code: 'unreadable-required-repository', message: 'Required repository is not visible to the scan credential.' });
    return { repository: repository.full_name, records, findings, mentioned };
  }
  if (required && direct.length === 0 && reusable.length === 0) {
    findings.push({ repository: repository.full_name, code: 'missing-tjsv-admission', message: 'Required consumer has no direct validator pin or reusable admission workflow.' });
  }
  for (const item of direct) {
    if (!SHA40.test(item.value)) findings.push({ repository: repository.full_name, code: 'mutable-validator-pin', pin: item.value, path: item.path, line: item.line, message: 'TJSV must be pinned to an immutable 40-character commit.' });
    else if (item.value !== policy.currentValidatorRevision) findings.push({ repository: repository.full_name, code: 'stale-validator-pin', pin: item.value, path: item.path, line: item.line, message: `Validator pin lacks the current minimum capability baseline ${policy.currentValidatorRevision}.` });
  }
  for (const item of reusable) {
    if (!SHA40.test(item.value)) findings.push({ repository: repository.full_name, code: 'mutable-reusable-pin', pin: item.value, path: item.path, line: item.line, message: 'Reusable admission must be pinned to an immutable merge commit.' });
    else if (item.value !== policy.reusableWorkflowRevision) findings.push({ repository: repository.full_name, code: 'stale-reusable-pin', pin: item.value, path: item.path, line: item.line, message: `Reusable workflow pin must match reviewed merge ${policy.reusableWorkflowRevision}.` });
  }
  const inheritsCurrentReusable = reusable.some((item) => item.value === policy.reusableWorkflowRevision);
  if ((required || direct.length > 0 || reusable.length > 0) && !inheritsCurrentReusable) {
    for (const [capability, alternatives] of Object.entries(policy.capabilityMarkers)) {
      if (!markerPresent(allText, alternatives)) findings.push({ repository: repository.full_name, code: 'missing-capability-marker', capability, message: `Consumer does not expose evidence for required capability: ${capability}.` });
    }
  }
  return { repository: repository.full_name, records, findings, mentioned };
}

function exceptionMatches(finding, exception) {
  return finding.repository === exception.repository && finding.code === exception.code &&
    (exception.pin === undefined || finding.pin === exception.pin) &&
    (exception.path === undefined || finding.path === exception.path);
}

export function applyExceptions(findings, ledger, now = new Date()) {
  validateExceptions(ledger, now);
  const active = ledger.exceptions.filter((item) => !item.expired);
  const expired = ledger.exceptions.filter((item) => item.expired).map((item) => ({
    repository: item.repository, code: 'expired-exception', pin: item.pin, path: item.path,
    message: `Exception ${item.code} owned by ${item.owner} expired ${item.expiresAt}.`,
  }));
  const unresolved = [];
  const excepted = [];
  for (const finding of findings) {
    const exception = active.find((item) => exceptionMatches(finding, item));
    if (exception) excepted.push({ ...finding, exception: { owner: exception.owner, reason: exception.reason, expiresAt: exception.expiresAt } });
    else unresolved.push(finding);
  }
  unresolved.push(...expired);
  return { unresolved, excepted };
}

export function analyzeSnapshot(snapshot, policy, ledger, now = new Date()) {
  validatePolicy(policy);
  const byName = new Map((snapshot.repositories ?? []).map((repo) => [repo.full_name, repo]));
  for (const required of policy.requiredConsumers) if (!byName.has(required)) byName.set(required, { full_name: required, unreadable: true, files: {} });
  const repositoryResults = [...byName.values()].sort((a, b) => a.full_name.localeCompare(b.full_name)).map((repo) => analyzeRepository(repo, policy));
  const findings = repositoryResults.flatMap((result) => result.findings);
  const { unresolved, excepted } = applyExceptions(findings, ledger, now);
  return {
    schema: 'zed.tjsv-fleet-scan/v1',
    generatedAt: now.toISOString(),
    currentValidatorRevision: policy.currentValidatorRevision,
    reusableWorkflowRevision: policy.reusableWorkflowRevision,
    repositoriesScanned: repositoryResults.length,
    directReferenceCount: repositoryResults.reduce((sum, result) => sum + result.records.filter((item) => item.kind.startsWith('validator-')).length, 0),
    reusableReferenceCount: repositoryResults.reduce((sum, result) => sum + result.records.filter((item) => item.kind === 'reusable-workflow').length, 0),
    findings: unresolved,
    exceptionsApplied: excepted,
    repositories: repositoryResults,
    status: unresolved.length === 0 ? 'passed' : 'failed',
  };
}

function candidatePath(path) {
  return /^(?:\.github\/(?:workflows|actions)\/.*\.ya?ml|contract-admission\/.*\.mjs|validation\/.*\.(?:mjs|js|json|ya?ml))$/u.test(path) || /tjsv/iu.test(path);
}

async function githubJson(url, token) {
  const headers = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(url, { headers });
  if (!response.ok) {
    const error = new Error(`GitHub ${response.status} for ${url}`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

async function listRepositories(policy, token) {
  const repositories = [];
  for (let page = 1; page <= 10; page += 1) {
    const batch = await githubJson(`https://api.github.com/orgs/${encodeURIComponent(policy.organization)}/repos?per_page=100&type=all&page=${page}`, token);
    repositories.push(...batch.filter((repo) => !repo.archived));
    if (batch.length < 100) break;
  }
  return repositories;
}

async function readRepository(repo, policy, token) {
  let tree;
  try {
    tree = await githubJson(`https://api.github.com/repos/${repo.full_name}/git/trees/${encodeURIComponent(repo.default_branch)}?recursive=1`, token);
  } catch (error) {
    if (error.status === 403 || error.status === 404) return { full_name: repo.full_name, unreadable: true, files: {} };
    throw error;
  }
  const candidates = (tree.tree ?? []).filter((entry) => entry.type === 'blob' && candidatePath(entry.path)).slice(0, policy.candidateFileLimitPerRepository ?? 96);
  const files = {};
  for (const entry of candidates) {
    try {
      const file = await githubJson(`https://api.github.com/repos/${repo.full_name}/contents/${entry.path.split('/').map(encodeURIComponent).join('/')}?ref=${encodeURIComponent(repo.default_branch)}`, token);
      if (file.encoding === 'base64' && typeof file.content === 'string') files[entry.path] = TEXT_DECODER.decode(Buffer.from(file.content.replace(/\n/gu, ''), 'base64'));
    } catch (error) {
      if (error.status !== 403 && error.status !== 404) throw error;
    }
  }
  return { full_name: repo.full_name, files };
}

export async function createLiveSnapshot(policy, token) {
  const listed = await listRepositories(policy, token);
  const repositories = [];
  for (const repo of listed.sort((a, b) => a.full_name.localeCompare(b.full_name))) repositories.push(await readRepository(repo, policy, token));
  return { schema: 'zed.tjsv-fleet-snapshot/v1', repositories };
}

function markdown(result) {
  const lines = [
    '# TJSV fleet scan', '',
    `Status: **${result.status}**`,
    `Validator baseline: \`${result.currentValidatorRevision}\``,
    `Reusable workflow: \`${result.reusableWorkflowRevision}\``,
    `Repositories scanned: ${result.repositoriesScanned}`, `Direct references: ${result.directReferenceCount}`, `Reusable references: ${result.reusableReferenceCount}`, '',
    '## Unresolved findings', '',
  ];
  if (result.findings.length === 0) lines.push('None.');
  else for (const finding of result.findings) lines.push(`- **${finding.repository}** ${finding.code}${finding.pin ? ` \`${finding.pin}\`` : ''}${finding.path ? ` — ${finding.path}` : ''}: ${finding.message}`);
  lines.push('', '## Active exceptions', '');
  if (result.exceptionsApplied.length === 0) lines.push('None.');
  else for (const finding of result.exceptionsApplied) lines.push(`- **${finding.repository}** ${finding.code}${finding.pin ? ` \`${finding.pin}\`` : ''} — owner ${finding.exception.owner}, expires ${finding.exception.expiresAt}: ${finding.exception.reason}`);
  return `${lines.join('\n')}\n`;
}

async function main() {
  assert.equal(process.argv.length, 2, 'this fixed repository task accepts no command-line options');
  const [policy, ledger] = await Promise.all([
    readFile(join(ROOT, '.github/tjsv-fleet-policy.json'), 'utf8').then(JSON.parse),
    readFile(join(ROOT, '.github/tjsv-pin-exceptions.json'), 'utf8').then(JSON.parse),
  ]);
  const fixture = process.env.TJSV_SCAN_FIXTURE;
  const snapshot = fixture ? JSON.parse(await readFile(resolve(ROOT, fixture), 'utf8')) :
    await createLiveSnapshot(validatePolicy(policy), process.env.ZED_FLEET_READ_TOKEN || process.env.GITHUB_TOKEN || '');
  const result = analyzeSnapshot(snapshot, policy, ledger, new Date());
  const output = join(ROOT, 'tmp/tjsv-fleet-scan');
  await mkdir(output, { recursive: true });
  await writeFile(join(output, 'scan.json'), `${JSON.stringify(result, null, 2)}\n`);
  await writeFile(join(output, 'summary.md'), markdown(result));
  console.log(markdown(result));
  if (result.status !== 'passed') process.exitCode = 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch((error) => { console.error(error.message); process.exitCode = 2; });
