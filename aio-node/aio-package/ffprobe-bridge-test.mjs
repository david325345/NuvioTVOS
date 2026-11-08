// Checks ffprobe through Nuvio (installer/ffprobe-bridge.mjs, FFPROBE.md)
// with AIOStreams' own ffprobe code (packages/core/dist/media-info/ffprobe.js
// of an installed version) and a stand-in for Nuvio that answers with the
// real ffprobe:
//
// - the version comes through,
// - a file probed through the bridge gives exactly what ffprobe run directly
//   gives (tracks, languages, container, duration, chapters),
// - Nuvio's requests are the documented ones,
// - a file Nuvio can't read is a failed probe, not a missing ffprobe,
// - with nobody answering, AIOStreams sees no ffprobe.
//
//   node ffprobe-bridge-test.mjs <AIOStreams root> <installer folder> <media file>
import { execFile } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';

const [aioRoot, installerDir, media] = process.argv.slice(2);
if (!aioRoot || !installerDir || !media) {
  console.error('usage: ffprobe-bridge-test.mjs <AIOStreams root> <installer folder> <media file>');
  process.exit(2);
}

let failed = false;
function check(name, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? `: ${detail}` : ''}`);
  if (!ok) failed = true;
}

const realFfprobe = (args) => new Promise((resolve, reject) => {
  execFile('ffprobe', args, { maxBuffer: 8 << 20 }, (error, stdout) => (error ? reject(error) : resolve(stdout)));
});

// The stand-in for Nuvio.
const requests = [];
const stand = http.createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  requests.push(body);
  response.setHeader('content-type', 'application/json');
  try {
    if (body.version) {
      const out = await realFfprobe(['-version']);
      response.end(JSON.stringify({ version: /ffprobe version (\S+)/.exec(out)?.[1] || 'unknown' }));
      return;
    }
    const args = ['-v', 'error', '-print_format', 'json'];
    if (body.selectStreams) args.push('-select_streams', body.selectStreams);
    for (const what of body.show) args.push(`-show_${what}`);
    if (body.readIntervals) args.push('-read_intervals', body.readIntervals);
    args.push(body.input);
    response.end(await realFfprobe(args));
  } catch (error) {
    response.statusCode = 422;
    response.end(JSON.stringify({ error: String(error.message).split('\n').slice(-2).join(' ').slice(0, 200) }));
  }
});
await new Promise((resolve) => stand.listen(0, '127.0.0.1', resolve));
const endpoint = `http://127.0.0.1:${stand.address().port}/aio/ffprobe`;

const { installFfprobeBridge, FFPROBE_NAME } = await import(pathToFileURL(path.join(installerDir, 'ffprobe-bridge.mjs')).href);
check('bridge installed', installFfprobeBridge(endpoint, (text) => console.log(`     ${text}`)));
check('FFPROBE_PATH for AIOStreams', process.env.FFPROBE_PATH === FFPROBE_NAME, process.env.FFPROBE_PATH);

const ffprobe = await import(pathToFileURL(path.join(aioRoot, 'packages/core/dist/media-info/ffprobe.js')).href);

const version = await ffprobe.ffprobeVersion(FFPROBE_NAME);
check('version through Nuvio', !!version, String(version));

const direct = await ffprobe.probeMediaInfo('ffprobe', media);
const bridged = await ffprobe.probeMediaInfo(FFPROBE_NAME, media);
check('tracks found', (bridged?.tracks?.length ?? 0) >= 2,
  (bridged?.tracks ?? []).map((t) => `${t.type}:${t.codec ?? '?'}${t.language ? `/${t.language}` : ''}`).join(' '));
check('same as ffprobe run directly', isDeepStrictEqual(direct, bridged));
if (!isDeepStrictEqual(direct, bridged)) {
  console.log(`     direct:  ${JSON.stringify(direct)}`);
  console.log(`     bridged: ${JSON.stringify(bridged)}`);
}

const shapes = requests.filter((r) => !r.version).map((r) => JSON.stringify({ show: r.show, selectStreams: r.selectStreams, readIntervals: r.readIntervals }));
check('requests as documented', shapes.length === 2
  && shapes[0] === JSON.stringify({ show: ['format', 'streams', 'chapters'] })
  && shapes[1] === JSON.stringify({ show: ['streams', 'frames'], selectStreams: 'v', readIntervals: '%+#5' }),
  shapes.join(' | '));
check('input passed as given', requests.filter((r) => !r.version).every((r) => r.input === media));

let unreadable;
try {
  await ffprobe.probeMediaInfo(FFPROBE_NAME, `${media}.missing`);
} catch (error) {
  unreadable = error;
}
check('unreadable file: a failed probe', !!unreadable && !(unreadable instanceof ffprobe.FfprobeMissingError), unreadable && unreadable.message);

await new Promise((resolve) => stand.close(resolve));
let missing;
try {
  await ffprobe.probeMediaInfo(FFPROBE_NAME, media);
} catch (error) {
  missing = error;
}
check('nobody answering: no ffprobe', missing instanceof ffprobe.FfprobeMissingError, missing && missing.message);

process.exit(failed ? 1 : 0);
