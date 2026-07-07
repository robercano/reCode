'use strict'

/** The fixture's one real function — enough surface for gates to bite on. */
function greet(name) {
  if (typeof name !== 'string' || name.length === 0) {
    throw new TypeError('name must be a non-empty string')
  }
  return `Hello, ${name}!`
}

module.exports = { greet }
