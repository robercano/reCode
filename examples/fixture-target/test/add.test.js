// Trivial test for the fixture-target repo. Runs via plain `node` (no test
// runner needed) and exits non-zero on failure, so it works as a real gate.
const assert = require('assert')
const { add } = require('../src/add')

assert.strictEqual(add(2, 3), 5, 'add(2, 3) should equal 5')
assert.strictEqual(add(-1, 1), 0, 'add(-1, 1) should equal 0')

console.log('add.test.js: OK')
