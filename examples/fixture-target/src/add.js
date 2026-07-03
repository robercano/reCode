// Trivial product source for the fixture-target repo. Plain CommonJS so a bare
// `node` runs it with zero config — no build step, no package manager.
function add(a, b) {
  return a + b
}

module.exports = { add }
