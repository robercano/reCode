// @orchestrator-managed feature-fanout v2
// This file is installed and re-stamped by `/orchestrator:setup` (scaffold.sh). It is NOT
// user-owned: re-running setup will overwrite it whenever the marker version above is older
// than the version the installed plugin ships. Do not hand-edit if you want future setup runs
// to keep it in sync — fork it under a different name instead.
export const meta = {
  name: 'feature-fanout',
  description: 'Scope a task into independent sub-tasks, implement each in an isolated worktree, adversarially review every change through multiple lenses, and loop until all gates pass.',
  phases: [
    { title: 'Scope', detail: 'decompose into non-overlapping sub-tasks' },
    { title: 'Implement', detail: 'one worker per sub-task, isolated worktrees' },
    { title: 'Review', detail: 'multi-lens adversarial review + iterate' },
  ],
}

// Invoke with: Workflow({ name: 'feature-fanout', args: { task: "..." } })
// or just type "ultracode <your task>" and ask to run this workflow.

const TASK = (args && args.task) || 'No task provided. Pass args.task.'
const LENSES = ['correctness', 'tests', 'security']
const MAX_ITERS = 3

phase('Scope')
const plan = await agent(
  `Decompose this task into INDEPENDENT, non-overlapping sub-tasks. Each sub-task must be scoped to a
   single module/path (read .claude/gates.json "modules") so no two workers touch the same files.
   Merge or sequence anything that would overlap. Scale to complexity — a small task may yield ONE sub-task.
   TASK: ${TASK}`,
  { phase: 'Scope', schema: {
    type: 'object',
    properties: { subtasks: { type: 'array', items: {
      type: 'object',
      required: ['title', 'module', 'prompt'],
      properties: {
        title: { type: 'string' },
        module: { type: 'string' },
        prompt: { type: 'string', description: 'full self-contained instruction for the implementer' },
      },
    } } },
    required: ['subtasks'],
  } }
)

log(`Scoped into ${plan.subtasks.length} sub-task(s): ${plan.subtasks.map(s => s.title).join(', ')}`)

// Each sub-task: implement (own worktree) -> review through all lenses -> iterate until approved or out of tries.
const results = await pipeline(
  plan.subtasks,
  async (st) => {
    let attempt = 0
    let impl = await agent(
      `${st.prompt}\n\nBoundary: stay within module "${st.module}". Run the gates in .claude/gates.json before reporting done.`,
      { label: `impl:${st.module}`, phase: 'Implement', isolation: 'worktree' }
    )
    // Token discipline: lenses that approve stay approved — each iteration re-reviews
    // ONLY the lenses that rejected, so a fix doesn't re-buy the full review panel.
    let lensesToReview = LENSES
    while (attempt < MAX_ITERS) {
      const reviews = await parallel(lensesToReview.map(lens => () =>
        agent(
          `Adversarially review this change through the "${lens}" lens. Try to refute it. ` +
          `Return verdict approve|reject with concrete, actionable findings.\n\nCHANGE:\n${impl}`,
          { label: `review:${lens}:${st.module}`, phase: 'Review', schema: {
            type: 'object',
            required: ['verdict', 'findings'],
            properties: {
              verdict: { type: 'string', enum: ['approve', 'reject'] },
              findings: { type: 'array', items: { type: 'string' } },
            },
          } }
        )
      ))
      const rejectedLenses = lensesToReview.filter((lens, i) => reviews[i] && reviews[i].verdict === 'reject')
      if (rejectedLenses.length === 0) {
        return { subtask: st.title, module: st.module, status: 'approved', attempts: attempt + 1, impl }
      }
      attempt++
      log(`"${st.title}" rejected on attempt ${attempt} (${rejectedLenses.length}/${lensesToReview.length} lenses). Iterating.`)
      const reasons = reviews
        .filter(r => r && r.verdict === 'reject')
        .flatMap(r => r.findings).map(f => `- ${f}`).join('\n')
      impl = await agent(
        `Reviewers rejected your change to "${st.module}". Fix every finding, re-run the gates, report again:\n${reasons}`,
        { label: `fix:${st.module}`, phase: 'Implement', isolation: 'worktree' }
      )
      lensesToReview = rejectedLenses
    }
    return { subtask: st.title, module: st.module, status: 'needs-human', attempts: attempt, impl }
  }
)

const approved = results.filter(r => r && r.status === 'approved')
const stuck = results.filter(r => r && r.status !== 'approved')
log(`Done. ${approved.length} approved, ${stuck.length} need human attention.`)
return { task: TASK, approved, stuck }
