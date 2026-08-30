// Node harness for app.js. Run by deploy/test/backup-app.test.ps1.
//
// It exists for one defect: pollLog called get('/api/log', 'since=' + cursor) while
// get() was declared as get(path) and silently dropped the second argument. The
// server answered from cursor 0 every time and the log pane repeated its whole
// contents on every tick, forever. Nothing on the server side was wrong, so no
// amount of API testing would have caught it - the contract that broke is between
// two functions inside app.js.
//
// So: stub just enough browser to let the IIFE run, record what it asks fetch for,
// and assert the cursor is actually in the URL.
'use strict';

var fs = require('fs');
var path = require('path');
var vm = require('vm');

var appJs = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
var fetched = [];

function stubEl() {
  var el = {
    textContent: '', value: '', innerHTML: '', scrollTop: 0, scrollHeight: 0, disabled: false,
    tagName: 'DIV',
    setAttribute: function () { }, removeAttribute: function () { }, getAttribute: function () { return null; },
    addEventListener: function () { },
    getElementsByTagName: function () { return [stubEl()]; }
  };
  return el;
}

var sandbox = {
  console: console,
  setTimeout: setTimeout,
  setInterval: function () { return 0; },   // no background polling in the harness
  clearInterval: function () { },
  Date: Date,
  Math: Math,
  JSON: JSON,
  encodeURIComponent: encodeURIComponent,
  isNaN: isNaN,
  String: String,
  Number: Number,
  Error: Error,
  document: {
    body: { getAttribute: function () { return 'TESTTOKEN'; }, innerHTML: '' },
    documentElement: {
      setAttribute: function () { }, removeAttribute: function () { }, getAttribute: function () { return null; }
    },
    getElementById: function () { return stubEl(); },
    querySelectorAll: function () { return []; },
    visibilityState: 'visible',
    activeElement: null
  },
  localStorage: { getItem: function () { return null; }, setItem: function () { }, removeItem: function () { } },
  fetch: function (u) {
    fetched.push(u);
    return Promise.resolve({
      ok: true,
      json: function () { return Promise.resolve({ lines: ['one'], next: 7, idle: true, hostName: 'H' }); }
    });
  }
};
sandbox.window = sandbox;
sandbox.gsap = null;
sandbox.window.matchMedia = function () { return { matches: false }; };

vm.createContext(sandbox);
vm.runInContext(appJs, sandbox, { filename: 'app.js' });

setTimeout(function () {
  var logCalls = fetched.filter(function (u) { return u.indexOf('/api/log') === 0; });
  var problems = [];

  if (!logCalls.length) { problems.push('app.js never polled /api/log'); }
  logCalls.forEach(function (u) {
    if (u.indexOf('since=') < 0) {
      problems.push('the log poll dropped its cursor: ' + u);
    }
    if (u.indexOf('t=TESTTOKEN') < 0) {
      problems.push('a request went out without the token: ' + u);
    }
  });

  var statusCalls = fetched.filter(function (u) { return u.indexOf('/api/status') === 0; });
  if (!statusCalls.length) { problems.push('app.js never asked for status'); }
  statusCalls.forEach(function (u) {
    if (u.indexOf('t=TESTTOKEN') < 0) { problems.push('a status request went out without the token: ' + u); }
  });

  fetched.forEach(function (u) {
    if (/^https?:\/\//i.test(u)) { problems.push('app.js reached for an absolute URL: ' + u); }
  });

  if (problems.length) {
    console.log('CONTRACT-FAIL ' + problems.join(' | '));
    process.exit(1);
  }
  console.log('CONTRACT-OK ' + fetched.join(' '));
}, 300);
