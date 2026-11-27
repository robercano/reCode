// @orchestrator-managed feature-fanout v3
// This file is installed and re-stamped by `/orchestrator:setup` (scaffold.sh). It is NOT
// user-owned: re-running setup will overwrite it whenever the marker version above is older
// than the version the installed plugin ships. Do not hand-edit if you want future setup runs
// to keep it in sync — fork it under a different name instead.
export const meta = {
  name: 'feature-fanout',
  description: 'Scope a task into independent sub-tasks, implement each in an isolated worktree, adversarially review every change through the adapter lenses, and loop until all gates pass.',
  phases: [
    { title: 'Scope', detail: 'decompose into non-overlapping sub-tasks + read the adapter' },
    { title: 'Implement', detail: 'one worker per sub-task, isolated worktrees' },
    { title: 'Review', detail: 'multi-lens adversarial review + iterate' },
  ],
}

// Invoke with: Workflow({ name: 'feature-fanout', args: { task: "..." } })
// or just type "ultracode <your task>" and ask to run this workflow.
//
// Optional args (each overrides what the Scope agent reads from .claude/gates.json):
//   lenses:          ['correctness', 'tests', ...]   (gates.json -> review.lenses)
//   baseBranch:      'main'                          (gates.json -> merge.baseBranch)
//   workerModel:     'sonnet'                        (gates.json -> budget.worker_model)
//   reviewerModel:   'sonnet'                        (gates.json -> budget.reviewer_model)
//   reviewerModels:  { correctness: 'opus', ... }    (gates.json -> budget.reviewer_models)
//   maxIters:        3
//
// v3 (vs v2):
//   * The fix iteration continues on the SAME branch/worktree the implementer produced. v2 spawned
//     every fix agent with isolation:'worktree', i.e. in a FRESH worktree branched from the default
//     branch — without the implementer's commits — so "fix the findings" ran against code that
//     didn't contain the change under review.
//   * Lenses, base branch and per-role models come from the adapter (gates.json) instead of being
//     hardcoded (v2 always reviewed with 3 fixed lenses, ignoring review.lenses and reviewer_models).
//   * Reviewers read the diff themselves (`git diff <base>...<branch>`) instead of receiving the
//     implementer's prose report pasted into every prompt (token discipline: reference, don't paste).

const A = (typeof args === 'object' && args) || {}
const TASK = A.task || 'No task provided. Pass args.task.'
const MAX_ITERS = Number.isInteger(A.maxIters) && A.maxIters > 0 ? A.maxIters : 3

const withModel = (opts, model) => (model ? { ...opts, model } : opts)

phase('Scope')
const plan = await agent(
  `Read .claude/gates.json (or the file named by $GATES_FILE if set) and CLAUDE.md first.
   1) Report the adapter config: review.lenses, merge.baseBranch, budget.worker_model,
      budget.reviewer_model and budget.reviewer_models (empty/missing values -> omit them).
   2) Decompose this task into INDEPENDENT, non-overlapping sub-tasks. Each sub-task must be scoped
      to a single module/path from gates.json "modules" so no two workers touch the same files.
      Merge or sequence anything that would overlap. Scale to complexity — a small task may yield ONE
      sub-task.
   TASK: ${TASK}`,
  { phase: 'Scope', schema: {
    type: 'object',
    required: ['config', 'subtasks'],
    properties: {
      config: {
        type: 'object',
        properties: {
          lenses: { type: 'array', items: { type: 'string' } },
          baseBranch: { type: 'string' },
          workerModel: { type: 'string' },
          reviewerModel: { type: 'string' },
          reviewerModels: { type: 'object', additionalProperties: { type: 'string' } },
        },
      },
      subtasks: { type: 'array', items: {
        type: 'object',
        required: ['title', 'module', 'prompt'],
        properties: {
          title: { type: 'string' },
          module: { type: 'string' },
          prompt: { type: 'string', description: 'full self-contained instruction for the implementer' },
        },
      } },
    },
  } }
)

const cfg = plan.config || {}
const LENSES = (Array.isArray(A.lenses) && A.lenses.length ? A.lenses
  : Array.isArray(cfg.lenses) && cfg.lenses.length ? cfg.lenses
  : ['correctness', 'tests', 'security'])
const BASE = A.baseBranch || cfg.baseBranch || 'main'
const WORKER_MODEL = A.workerModel || cfg.workerModel
const REVIEWER_MODEL = A.reviewerModel || cfg.reviewerModel
const REVIEWER_MODELS = { ...(cfg.reviewerModels || {}), ...(A.reviewerModels || {}) }
const reviewerModelFor = lens => REVIEWER_MODELS[lens] || REVIEWER_MODEL

log(`Scoped into ${plan.subtasks.length} sub-task(s): ${plan.subtasks.map(s => s.title).join(', ')}`)
log(`Lenses: ${LENSES.join(', ')} · base: ${BASE}`)

// What every implementer/fixer must hand back, so the next step can find the work.
const IMPL_SCHEMA = {
  type: 'object',
  required: ['branch', 'worktree', 'gatesPassed', 'summary'],
  properties: {
    branch: { type: 'string', description: 'the branch holding your commits' },
    worktree: { type: 'string', description: 'ABSOLUTE path of the worktree you worked in (`pwd -P` at its root)' },
    gatesPassed: { type: 'boolean', description: 'true only if every configured gate in gates.json is green' },
    summary: { type: 'string', description: 'terse report: files touched, tests added, open risks' },
  },
}

// Each sub-task: implement (own worktree) -> review through all lenses -> iterate on the SAME
// branch until approved or out of tries.
const results = await pipeline(
  plan.subtasks,
  async (st) => {
    let attempt = 0
    let impl = await agent(
      `${st.prompt}\n\nBoundary: stay within module "${st.module}". Commit your work on a branch, ` +
      `run the gates in .claude/gates.json before reporting done, and report the branch and the ` +
      `absolute worktree path.`,
      withModel({ label: `impl:${st.module}`, phase: 'Implement', isolation: 'worktree', schema: IMPL_SCHEMA }, WORKER_MODEL)
    )
    if (!impl || !impl.branch) {
      return { subtask: st.title, module: st.module, status: 'needs-human', attempts: 0, impl, reason: 'implementer returned no branch' }
    }
    // Token discipline: lenses that approve stay approved — each iteration re-reviews
    // ONLY the lenses that rejected, so a fix doesn't re-buy the full review panel.
    let lensesToReview = LENSES
    while (attempt < MAX_ITERS) {
      const reviews = await parallel(lensesToReview.map(lens => () =>
        agent(
          `Adversarially review the change on branch "${impl.branch}" (worktree: ${impl.worktree}) ` +
          `through the "${lens}" lens. Read it yourself with ` +
          `\`git -C ${impl.worktree} diff ${BASE}...HEAD\` plus the code it touches — read-only, never ` +
          `edit. Try to refute it. Return verdict approve|reject with concrete, actionable findings.\n\n` +
          `Implementer's own summary (claims to verify, not to trust): ${impl.summary}`,
          withModel({ label: `review:${lens}:${st.module}`, phase: 'Review', schema: {
            type: 'object',
            required: ['verdict', 'findings'],
            properties: {
              verdict: { type: 'string', enum: ['approve', 'reject'] },
              findings: { type: 'array', items: { type: 'string' } },
            },
          } }, reviewerModelFor(lens))
        )
      ))
      // A reviewer that died (null) counts as a reject: an unreviewed lens never approves a change.
      const rejectedLenses = lensesToReview.filter((lens, i) => !reviews[i] || reviews[i].verdict === 'reject')
      if (rejectedLenses.length === 0 && impl.gatesPassed) {
        return { subtask: st.title, module: st.module, status: 'approved', attempts: attempt + 1, impl }
      }
      attempt++
      log(`"${st.title}" not approved on attempt ${attempt} (${rejectedLenses.length}/${lensesToReview.length} lenses rejected, gates ${impl.gatesPassed ? 'green' : 'RED'}). Iterating.`)
      const reasons = reviews
        .map((r, i) => (!r ? [`[${lensesToReview[i]}] reviewer failed to return a verdict — re-check this lens`] : r.verdict === 'reject' ? r.findings : []))
        .flat()
        .concat(impl.gatesPassed ? [] : ['Gates are RED — make every configured gate in gates.json pass.'])
        .map(f => `- ${f}`).join('\n')
      // Continue IN THE SAME WORKTREE/BRANCH (no new isolation): a fresh isolated worktree would be
      // branched from the default branch and would not contain the change being fixed.
      impl = await agent(
        `You are continuing an implementer's work. cd into the EXISTING worktree ${impl.worktree} ` +
        `(branch "${impl.branch}") and do ALL work there — never touch the main checkout, never ` +
        `create a new branch. Stay within module "${st.module}". Fix every finding, commit, re-run ` +
        `the gates in .claude/gates.json, and report again:\n${reasons}`,
        withModel({ label: `fix:${st.module}`, phase: 'Implement', schema: IMPL_SCHEMA }, WORKER_MODEL)
      ) || impl
      // Gate failures and dead reviewers re-check every lens that hasn't approved yet.
      lensesToReview = rejectedLenses.length ? rejectedLenses : lensesToReview
    }
    return { subtask: st.title, module: st.module, status: 'needs-human', attempts: attempt, impl }
  }
)

const approved = results.filter(r => r && r.status === 'approved')
const stuck = results.filter(r => r && r.status !== 'approved')
log(`Done. ${approved.length} approved, ${stuck.length} need human attention.`)
return { task: TASK, lenses: LENSES, approved, stuck }
