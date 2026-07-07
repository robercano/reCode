'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { greet } = require('../src/greet.js')

test('greet greets by name', () => {
  assert.equal(greet('Ada'), 'Hello, Ada!')
})

test('greet rejects an empty name', () => {
  assert.throws(() => greet(''), TypeError)
})
