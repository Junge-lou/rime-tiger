import {
  createReadStream,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { createServer } from 'node:http';
import { basename, dirname, extname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';

const BACKUP_ROOT = 'Rime皮肤编辑器备份';
const FRONTEND_FILES = new Set(['squirrel.custom.yaml', 'weasel.custom.yaml', 'default.custom.yaml']);
const STATIC_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MODULE_PATH = fileURLToPath(import.meta.url);
const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
};

export function resolveAllowedPath(root, requestedPath) {
  const rootPath = realpathSync(resolve(root));
  const raw = String(requestedPath || '');
  if (!raw || raw.includes('\0') || raw.startsWith('/') || raw.startsWith('\\')) {
    throw new Error('不允许访问这个路径。');
  }

  const rawParts = raw.split(/[\\/]+/);
  if (rawParts.includes('..')) {
    throw new Error('不允许访问这个路径。');
  }

  const normalized = normalize(raw);
  if (normalized === '..' || normalized.startsWith(`..${sep}`) || normalized.includes(`${sep}..${sep}`)) {
    throw new Error('不允许访问这个路径。');
  }

  const parts = normalized.split(/[\\/]+/);
  const isFrontendFile = parts.length === 1 && FRONTEND_FILES.has(parts[0]);
  const isSchemaFile = parts.length === 1 && parts[0].endsWith('.schema.yaml');
  const isBackupFile = parts[0] === BACKUP_ROOT && parts.length >= 2;
  if (!isFrontendFile && !isSchemaFile && !isBackupFile) {
    throw new Error('不允许访问这个路径。');
  }

  const target = resolve(rootPath, normalized);
  const relation = relative(rootPath, target);
  if (relation === '..' || relation.startsWith(`..${sep}`) || resolve(relation) === relation) {
    throw new Error('不允许访问这个路径。');
  }
  if (isSymbolicLink(target)) {
    throw new Error('不允许访问这个路径。');
  }
  const realParent = existingParentRealPath(dirname(target));
  if (!realParent || !isInsideRoot(rootPath, realParent)) {
    throw new Error('不允许访问这个路径。');
  }
  return target;
}

function isSymbolicLink(path) {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

function existingParentRealPath(path) {
  let current = path;
  while (!existsSync(current)) {
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
  return realpathSync(current);
}

function isInsideRoot(rootPath, targetPath) {
  const relation = relative(rootPath, targetPath);
  return relation === '' || (!relation.startsWith(`..${sep}`) && relation !== '..' && !isAbsolute(relation));
}

export function createLocalStore(root) {
  const rootPath = resolve(root);
  return {
    root: rootPath,
    exists(path) {
      return existsSync(resolveAllowedPath(rootPath, path));
    },
    read(path) {
      return readFileSync(resolveAllowedPath(rootPath, path), 'utf8');
    },
    write(path, text) {
      const target = resolveAllowedPath(rootPath, path);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, String(text ?? ''), 'utf8');
    },
    mkdir(path) {
      const target = resolveAllowedPath(rootPath, `${path}/manifest.json`);
      mkdirSync(dirname(target), { recursive: true });
    },
    remove(path) {
      const target = resolveAllowedPath(rootPath, path);
      if (existsSync(target)) rmSync(target, { force: true });
    },
  };
}

export function readConfigSnapshot(root) {
  const rootPath = resolve(root);
  const rawFiles = {};
  const fileExists = {};
  for (const [platform, filename] of Object.entries({
    squirrel: 'squirrel.custom.yaml',
    weasel: 'weasel.custom.yaml',
    default: 'default.custom.yaml',
  })) {
    const filePath = resolveAllowedPath(rootPath, filename);
    const exists = existsSync(filePath);
    fileExists[platform] = exists;
    rawFiles[platform] = exists ? readFileSync(filePath, 'utf8') : '';
  }
  return {
    folderName: basename(rootPath) || rootPath,
    rawFiles,
    fileExists,
    hasAnySchemaFile: hasSchemaFile(rootPath),
  };
}

export function listBackups(root) {
  const rootPath = resolve(root);
  const backupRoot = resolveAllowedPath(rootPath, `${BACKUP_ROOT}/manifest.json`);
  const backupRootDir = dirname(backupRoot);
  if (!existsSync(backupRootDir)) return [];

  return readdirSync(backupRootDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => {
      const backupDir = join(backupRootDir, entry.name);
      const availableFiles = readdirSync(backupDir, { withFileTypes: true })
        .filter((file) => file.isFile())
        .map((file) => file.name)
        .sort((a, b) => a.localeCompare(b));
      const manifestPath = join(backupDir, 'manifest.json');
      const manifest = readManifest(manifestPath);
      return { name: entry.name, manifest, availableFiles };
    })
    .sort((a, b) => b.name.localeCompare(a.name));
}

function readManifest(manifestPath) {
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
}

export function createApp({ root, token, staticRoot = STATIC_ROOT }) {
  const rootPath = resolve(root);
  const requiredToken = String(token || '');
  return createServer(async (request, response) => {
    try {
      const url = new URL(request.url || '/', 'http://127.0.0.1');
      if (url.pathname.startsWith('/api/')) {
        if (request.headers['x-rime-editor-token'] !== requiredToken) {
          sendJson(response, 403, { error: '访问令牌无效。' });
          return;
        }
        await handleApi(request, response, url, rootPath);
        return;
      }
      serveStatic(response, staticRoot, url.pathname);
    } catch (error) {
      sendJson(response, 400, { error: error.message || '请求失败。' });
    }
  });
}

export async function startLocalServer({ root = resolve(STATIC_ROOT, '..'), port = 0, openBrowser = true } = {}) {
  const token = randomBytes(18).toString('hex');
  const app = createApp({ root, token });
  await new Promise((resolveListen) => app.listen(port, '127.0.0.1', resolveListen));
  const address = app.address();
  const url = `http://127.0.0.1:${address.port}/?token=${token}`;
  if (openBrowser) openUrl(url);
  return { app, url, root: resolve(root), port: address.port };
}

async function handleApi(request, response, url, root) {
  if (request.method === 'GET' && url.pathname === '/api/config') {
    sendJson(response, 200, readConfigSnapshot(root));
    return;
  }
  if (request.method === 'GET' && url.pathname === '/api/backups') {
    sendJson(response, 200, { backups: listBackups(root) });
    return;
  }
  if (request.method === 'GET' && url.pathname === '/api/file') {
    const path = url.searchParams.get('path');
    const target = resolveAllowedPath(root, path);
    if (!existsSync(target)) {
      sendJson(response, 404, { error: '文件不存在。' });
      return;
    }
    sendJson(response, 200, { exists: true, text: readFileSync(target, 'utf8') });
    return;
  }
  if (request.method === 'PUT' && url.pathname === '/api/file') {
    const body = await readJsonBody(request);
    const target = resolveAllowedPath(root, body.path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, String(body.text ?? ''), 'utf8');
    sendJson(response, 200, { ok: true });
    return;
  }
  if (request.method === 'DELETE' && url.pathname === '/api/file') {
    const path = url.searchParams.get('path');
    const target = resolveAllowedPath(root, path);
    if (existsSync(target)) rmSync(target, { force: true });
    sendJson(response, 200, { ok: true });
    return;
  }
  if (request.method === 'POST' && url.pathname === '/api/mkdir') {
    const body = await readJsonBody(request);
    const target = resolveAllowedPath(root, `${body.path}/manifest.json`);
    mkdirSync(dirname(target), { recursive: true });
    sendJson(response, 200, { ok: true });
    return;
  }
  sendJson(response, 404, { error: '接口不存在。' });
}

function serveStatic(response, staticRoot, pathname) {
  const requested = decodeURIComponent(pathname === '/' ? '/index.html' : pathname);
  const relativePath = requested.replace(/^\/+/, '');
  const target = resolve(staticRoot, relativePath);
  const relation = relative(staticRoot, target);
  if (relation === '..' || relation.startsWith(`..${sep}`) || !existsSync(target) || !statSync(target).isFile()) {
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('Not found');
    return;
  }
  response.writeHead(200, {
    'content-type': MIME_TYPES[extname(target)] || 'application/octet-stream',
    'cache-control': 'no-store',
  });
  createReadStream(target).pipe(response);
}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 2 * 1024 * 1024) throw new Error('请求内容过大。');
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function sendJson(response, status, value) {
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  response.end(JSON.stringify(value));
}

function hasSchemaFile(root) {
  return readdirSync(root, { withFileTypes: true }).some((entry) => entry.isFile() && entry.name.endsWith('.schema.yaml'));
}

function openUrl(url) {
  const command = process.platform === 'darwin'
    ? 'open'
    : process.platform === 'win32'
      ? 'cmd'
      : 'xdg-open';
  const args = process.platform === 'win32' ? ['/c', 'start', '', url] : [url];
  const child = spawn(command, args, { stdio: 'ignore', detached: true });
  child.unref();
}

if (process.argv[1] && resolve(process.argv[1]) === MODULE_PATH) {
  const rootArgIndex = process.argv.indexOf('--root');
  const root = rootArgIndex >= 0 ? process.argv[rootArgIndex + 1] : resolve(STATIC_ROOT, '..');
  const portArgIndex = process.argv.indexOf('--port');
  const port = portArgIndex >= 0 ? Number(process.argv[portArgIndex + 1]) : 0;
  startLocalServer({ root, port, openBrowser: !process.argv.includes('--no-open') })
    .then(({ url, root: startedRoot }) => {
      console.log(`Rime 皮肤编辑器已启动：${url}`);
      console.log(`配置目录：${startedRoot}`);
      console.log('关闭这个窗口即可停止本地服务。');
    })
    .catch((error) => {
      console.error(`启动失败：${error.message}`);
      process.exit(1);
    });
}
