#!/usr/bin/env node
// mock-upstream.mjs - an OpenAI-style upstream provider for the acceptance drill, on 127.0.0.1.
//
//   node script/e2e/mock-upstream.mjs --port 19101 --name a [--fail]
//
// Node standard library only. Same semantics as the Server repo's test/e2e/mock-upstream.mjs
// (an independent copy: this repo never imports from the Server repo), as a command:
//
// - GET  /v1/models            lists glm-5 and mock-chat (owned_by = --name).
// - POST /v1/chat/completions  answers a non-streaming chat completion whose content is
//                              "served-by:<name>", with model = the requested model and
//                              usage {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15};
//                              server-sent events when the body asks for stream: true.
//   With --fail every chat request answers 500 with an OpenAI-style error body that names
//   --name, so a test can tell which provider answered.
// - Anything else answers 404.
//
// Standard output: one JSON line per request, {"name","method","path","model","status"} (never
// headers or bodies: the engine sends the upstream credential in Authorization). Standard
// error: one line "mock-upstream <name> listening on http://127.0.0.1:<port>/v1" once the port
// is bound. --port 0 picks a free port. SIGTERM and SIGINT close the listener and exit 0.
import http from 'node:http';

const MODELS = ['glm-5', 'mock-chat'];

function parseArgs(argv) {
  const options = { port: null, name: null, fail: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--fail') options.fail = true;
    else if (arg === '--port' || arg === '--name') {
      const value = argv[i + 1];
      if (value === undefined) throw new Error(`${arg} needs a value`);
      options[arg.slice(2)] = value;
      i += 1;
    } else throw new Error(`unknown argument: ${arg}`);
  }
  const port = Number(options.port);
  if (options.port === null || !Number.isInteger(port) || port < 0 || port > 65535) throw new Error('--port must be 0-65535');
  if (!options.name || !/^[A-Za-z0-9._-]{1,40}$/.test(options.name)) throw new Error('--name must be 1-40 characters [A-Za-z0-9._-]');
  return { port, name: options.name, fail: options.fail };
}

const sendJson = (res, status, payload) => {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload));
};

const usage = () => ({ prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 });

function completion(name, model) {
  return {
    id: `chatcmpl-${name}`,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: `served-by:${name}` } }],
    usage: usage(),
  };
}

function sendStream(res, name, model) {
  const base = { id: `chatcmpl-${name}`, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model };
  const events = [
    { ...base, choices: [{ index: 0, delta: { role: 'assistant', content: `served-by:${name}` }, finish_reason: null }] },
    { ...base, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: usage() },
  ];
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
  res.end(`${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join('')}data: [DONE]\n\n`);
}

function start({ port, name, fail }) {
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const pathname = new URL(req.url, 'http://upstream').pathname;
      let body = null;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8') || 'null'); } catch { /* not JSON */ }
      const model = body && typeof body.model === 'string' ? body.model : null;
      const entry = { name, method: req.method, path: pathname, model, status: 200 };
      res.on('finish', () => process.stdout.write(`${JSON.stringify(entry)}\n`));

      if (req.method === 'GET' && pathname === '/v1/models') {
        sendJson(res, 200, { object: 'list', data: MODELS.map((id) => ({ id, object: 'model', created: 1, owned_by: name })) });
        return;
      }
      if (req.method !== 'POST' || pathname !== '/v1/chat/completions') {
        entry.status = 404;
        sendJson(res, 404, { error: { message: `${name}: no route ${req.method} ${pathname}`, type: 'invalid_request_error' } });
        return;
      }
      if (fail) {
        entry.status = 500;
        sendJson(res, 500, { error: { message: `${name} answers 500 for ${model}`, type: 'upstream_error' } });
        return;
      }
      if (body?.stream === true) sendStream(res, name, model);
      else sendJson(res, 200, completion(name, model));
    });
  });
  server.on('error', (error) => {
    process.stderr.write(`mock-upstream ${name}: ${error.message}\n`);
    process.exit(1);
  });
  server.listen(port, '127.0.0.1', () => {
    process.stderr.write(`mock-upstream ${name} listening on http://127.0.0.1:${server.address().port}/v1\n`);
  });
  const stop = () => {
    server.closeAllConnections?.();
    server.close(() => process.exit(0));
  };
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}

let options;
try {
  options = parseArgs(process.argv.slice(2));
} catch (error) {
  process.stderr.write(`mock-upstream: ${error.message}\nusage: node mock-upstream.mjs --port <port> --name <name> [--fail]\n`);
  process.exit(2);
}
start(options);
