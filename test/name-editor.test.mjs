import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

const source = fs.readFileSync(new URL('../PortRow.qml', import.meta.url), 'utf8')
const submit = source.match(/              onAccepted: \{([\s\S]*?)\n              \}/)[1]
const remove = source.match(/id: removeLink[\s\S]*?onClicked: \{([\s\S]*?)\n              \}/)[1]
for (const accepted of [false, true]) {
  for (const action of ['rename', 'empty-remove', 'remove']) {
    const calls = []
    let closed = 0
    const context = vm.createContext({
      text: action === 'empty-remove' ? ' ' : 'typed-name',
      nameEditor: { editable: true },
      row: {
        named: true,
        entry: { port: 3000 },
        editorDone() { closed++ },
        service: {
          expose(...args) { calls.push(args); return accepted },
          unexpose(...args) { calls.push(args); return accepted }
        }
      }
    })
    vm.runInContext('(function(){' + (action === 'remove' ? remove : submit) + '})()', context)
    assert.equal(calls.length, 1)
    assert.equal(closed, Number(accepted), `${action} closes only after acceptance`)
    assert.equal(context.text, action === 'empty-remove' ? ' ' : 'typed-name')
  }
}
console.log('Rejected rename and removal preserve the editor and typed alias')
