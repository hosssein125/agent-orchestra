// _seed-demo.js — seed the demo workspace with a realistic mid-project state
const fs = require('fs');
const root = process.argv[2];
const p = f => root + '/' + f;
fs.writeFileSync(p('ledger/sessions.json'),
  JSON.stringify({ api: 'sess_demo_api_1', web: 'sess_demo_web_1', mobile: null }, null, 2));
const task = {
  'FEAT-20261104-orders-export': {
    title: 'FEAT-20261104-orders-export',
    status: 'active',
    created: '2026-11-04 09:10',
    holder: 'orchestrator',
    updated: '2026-11-05 09:40',
    history: [
      { t: '2026-11-04 09:10', from: 'user', to: 'orchestrator', why: 'intake: CSV export for the orders table (admin + mobile)' },
      { t: '2026-11-04 09:30', from: 'orchestrator', to: 'api', why: 'dispatch: add GET /v1/orders/export endpoint (streamed CSV)' },
      { t: '2026-11-04 11:12', from: 'api', to: 'orchestrator', why: 'endpoint done, contract note written and verified → contract-published' },
      { t: '2026-11-05 09:40', from: 'orchestrator', to: 'web', why: 'dispatch: apply export contract — button, polling, download' },
    ],
  },
};
fs.writeFileSync(p('ledger/tasks.json'), JSON.stringify(task, null, 2));
fs.mkdirSync(p('ledger/heartbeats'), { recursive: true });
fs.writeFileSync(p('ledger/heartbeats/api.md'), '2026-11-05 09:41 | api: idle after export endpoint\n');
fs.writeFileSync(p('ledger/activity.log'), [
  '2026-11-04 09:30:12 | START  | api | sess_demo_api_1 | mode=yolo harness=zcode | api-20261104-093012-out.md',
  '2026-11-04 11:12:40 | END    | api | sess_demo_api_1 | 6148s | tokens in=14200000 out=48000',
  '2026-11-05 09:40:02 | START  | web | sess_demo_web_1 | mode=yolo harness=zcode | web-20261105-094002-out.md',
].join('\n') + '\n');
console.log('seeded ' + root);
