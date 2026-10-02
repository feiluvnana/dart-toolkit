export const meta = {
  name: 'optimize-audit',
  description: 'Read-only dart-toolkit audit: find per dimension x module group, dedupe, verify each finding through two lenses',
  whenToUse: 'One audit round of .claude/skills/optimize/procedure.md (round 1 foundation, 2 design, 3 hardening); the lead applies the results',
  phases: [
    { title: 'Find', detail: 'one finder per dimension x module group' },
    { title: 'Verify', detail: 'two skeptics per finding: is it real, does it clear the bar' },
  ],
}

// args: { round: 1 | 2 | 3, modules?: string[], skip?: string[] }
//   modules: limit to these module names (e.g. ['http', 'formats']); default all.
//   skip:    titles already rejected in earlier audit records; never re-proposed.
const round = (args && args.round) || 1
const only = (args && args.modules) || null
const skip = (args && args.skip) || []

const GROUPS = [
  { key: 'foundation', modules: ['core', 'collection', 'async', 'process', 'native', 'hash'] },
  { key: 'data', modules: ['formats', 'fs', 'http'] },
  { key: 'surface', modules: ['cli', 'tui', 'chrome'] },
]
  .map(g => ({ ...g, modules: only ? g.modules.filter(m => only.includes(m)) : g.modules }))
  .filter(g => g.modules.length)

const paths = g =>
  g.modules.map(m => (m === 'native' ? '`native/src/*.rs`, `lib/src/native/`' : `\`lib/${m}.dart\`, \`lib/src/${m}/\``)).join(', ') +
  `, \`test/{${g.modules.join(',')}}_test.dart\`` +
  (g.key === 'surface' ? ', `bin/*.dart`' : '')

const DIMENSIONS = {
  1: [
    { tag: 'FEAT', ask: 'capabilities a script genuinely needs that are missing (verify with git grep they do not already exist under another name); verbose signatures; public classes missing Dart 3 modifiers (final/sealed/interface).' },
    { tag: 'BLOAT', ask: 'extensions on String/List/Map/int used by one module only; duplicate helpers; aliases (two spellings of one operation); dead code; test-only seams; duplicate bin/ examples. Each item must delete something.' },
    { tag: 'PERF', ask: 'extra copies across the FFI boundary; tk_alloc/tk_free pairing on error paths; per-element allocation or record churn in hot loops and parsers; isolate closures capturing large outer state; missing cleanup on cancel. State how you would measure it.' },
    { tag: 'DOC', ask: 'README/GUIDE/CONVENTIONS/CHANGELOG snippets and public dartdoc for these modules that do not compile against the current API or describe old behaviour; self-contradicting rules; POSIX-only assumptions; `is`/`case` checks on extension types (Path, Row, Elements, Nodes), which match raw String/Map/List after erasure.' },
  ],
  2: [
    { tag: 'DISC', ask: 'workflows reachable only by knowing a top-level function exists, or missing from their facade (Http, Path, Shell, Hash, Console, ...) where adding them would NOT lengthen the common call. Short globals such as run(...) stay.' },
    { tag: 'CONS', ask: 'naming drift between sibling APIs (ConsoleTheme vs TuiTheme fields, HTTP verbs vs Client methods); parameter order across related functions; null vs throw vs Either for the same kind of failure; `_ =>` wildcards over sealed types.' },
  ],
  3: [
    { tag: 'BUG', ask: 'correctness bugs: cancellation under Cancel.scope leaving timers/isolates/processes/sockets open; worker errors losing the original stack trace; resource leaks on error paths; edge inputs (empty, unicode, CRLF, huge) that crash or mis-parse.' },
    { tag: 'BUG', ask: 'platform parity: Windows cmd /d /c, unsafe cmd args, path separators, file locking during atomic replace; POSIX pipefail exit codes and signal forwarding. Note which findings cannot be executed on a macOS host.' },
  ],
}[round]

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      maxItems: 10,
      items: {
        type: 'object',
        properties: {
          tag: { type: 'string' },
          title: { type: 'string' },
          file: { type: 'string' },
          lines: { type: 'string' },
          severity: { type: 'string', enum: ['High', 'Medium'] },
          problem: { type: 'string' },
          fix: { type: 'string' },
          callSiteEffect: { type: 'string' },
          blastRadius: { type: 'array', items: { type: 'string' } },
        },
        required: ['tag', 'title', 'file', 'lines', 'severity', 'problem', 'fix', 'callSiteEffect', 'blastRadius'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: { upheld: { type: 'boolean' }, reason: { type: 'string' } },
  required: ['upheld', 'reason'],
}

const BAR = `The bar (CONVENTIONS.md): speed first (measured startup, throughput, memory), call-site brevity second, everything else after. ` +
  `A shorter spelling that costs measurable time loses. An addition must delete more at call sites than it adds to the surface and add no import cost. ` +
  `A perf claim needs a concrete A/B measurement plan; <5% gain plus more code is rejected. No deprecations or aliases: clean cuts only.`

const finderPrompt = (d, g) => `You are auditing the dart-toolkit Dart package (repo root = cwd), read-only.
Dimension ${d.tag}. Modules: ${g.modules.join(', ')}. Files: ${paths(g)}.
Look for: ${d.ask}
${BAR}
Rules: use git grep before reading; read only the line ranges you need. Every finding cites a path and line range you opened yourself.
High/Medium only, at most 10, ranked by impact. Return an empty list if nothing clears the bar.
${skip.length ? `Already rejected earlier, do not re-propose: ${skip.join('; ')}` : ''}`

const key = f => `${f.file}:${f.title.toLowerCase().replace(/\W+/g, ' ').trim()}`

phase('Find')
const found = await parallel(
  DIMENSIONS.flatMap(d => GROUPS.map(g => () =>
    agent(finderPrompt(d, g), { label: `${d.tag}:${g.key}`, phase: 'Find', schema: FINDINGS, agentType: 'Explore' }))),
)
// Barrier is deliberate: dedupe across all finders before paying for verification.
const seen = new Map()
for (const f of found.filter(Boolean).flatMap(r => r.findings)) if (!seen.has(key(f))) seen.set(key(f), f)
const unique = [...seen.values()]
log(`${unique.length} unique findings from ${found.filter(Boolean).length} finders`)

const LENSES = [
  { name: 'real', ask: 'Open the cited lines and the blast radius. Is the problem real in the CURRENT code, and does the fix work without breaking callers or tests? Default upheld=false if you cannot confirm it.' },
  { name: 'bar', ask: `${BAR} Does this fix clear that bar? Reject speculative features, churn without call-site or measured gain, and anything already present under another name. Default upheld=false if uncertain.` },
]

phase('Verify')
const judged = await parallel(unique.map(f => () =>
  parallel(LENSES.map(l => () =>
    agent(`Skeptically review this dart-toolkit audit finding (read-only, repo root = cwd).\n${JSON.stringify(f, null, 2)}\nLens "${l.name}": ${l.ask}`,
      { label: `${l.name}:${f.tag}:${f.file.split('/').pop()}`, phase: 'Verify', schema: VERDICT, agentType: 'Explore' })))
    .then(vs => ({ ...f, verdicts: vs.filter(Boolean) }))))

const rank = { High: 0, Medium: 1 }
const ok = j => j.verdicts.length === LENSES.length && j.verdicts.every(v => v.upheld)
const confirmed = judged.filter(Boolean).filter(ok).sort((a, b) => rank[a.severity] - rank[b.severity])
const rejected = judged.filter(Boolean).filter(j => !ok(j))
  .map(j => ({ tag: j.tag, title: j.title, file: j.file, why: j.verdicts.filter(v => !v.upheld).map(v => v.reason).join(' | ') || 'verifier failed' }))
log(`${confirmed.length} confirmed, ${rejected.length} rejected`)
return { round, confirmed, rejected }
