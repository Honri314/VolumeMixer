#!/usr/bin/env node
'use strict';

// =====================================================
//  VolumeMixer 다운로드 홈페이지 서버 (pm2 전용)
//  - 바인딩: 127.0.0.1:8470 (funnel path 라우팅 전용)
//  - funnel 등록 (일회성):
//      tailscale funnel --bg --https=443 --set-path=/volumemixer http://127.0.0.1:8470
//    -> https://ubuntu.tail543772.ts.net/volumemixer 로 공개
//  - pm2 제어: pm2 start /home/honri/volumemixer/server/volumemixer-server.js --name volumemixer-download
// =====================================================

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.VOLUMEMIXER_PORT, 10) || 8470;
const SITE_DIR = path.join(__dirname, 'site');
const DL_DIR = path.join(__dirname, 'dl');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.dmg': 'application/x-apple-diskimage',
  '.sha256': 'text/plain; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function safeJoin(dir, rel) {
  const p = path.resolve(dir, rel);
  if (!p.startsWith(path.resolve(dir) + path.sep) && p !== path.resolve(dir)) return null;
  return p;
}

function send(res, code, body, type) {
  res.writeHead(code, {
    'Content-Type': type || 'text/plain; charset=utf-8',
    'Cache-Control': 'no-cache',
  });
  res.end(body);
}

function currentDmgName() {
  try {
    const files = fs.readdirSync(DL_DIR).filter(f => f.endsWith('.dmg')).sort();
    return files[files.length - 1] || null;
  } catch (e) { return null; }
}

const server = http.createServer((req, res) => {
  let u = decodeURIComponent((req.url || '/').split('?')[0]);
  // funnel 경유(/volumemixer prefix)와 로컬 테스트 양쪽 모두 지원
  const PREFIX = '/volumemixer';
  let pathname = u.startsWith(PREFIX + '/') || u === PREFIX ? u.slice(PREFIX.length) : u;
  if (pathname === '' || pathname === '/') pathname = '/index.html';

  try {
    // 다운로드 파일 (/dl/<파일>)
    if (pathname.startsWith('/dl/')) {
      const rel = pathname.slice(4);
      const p = safeJoin(DL_DIR, rel);
      if (!p || !fs.existsSync(p) || !fs.statSync(p).isFile()) {
        return send(res, 404, 'not found');
      }
      res.writeHead(200, {
        'Content-Type': MIME[path.extname(p)] || 'application/octet-stream',
        'Content-Length': fs.statSync(p).size,
        'Content-Disposition': 'attachment; filename="' + path.basename(p) + '"',
      });
      fs.createReadStream(p).pipe(res);
      return;
    }

    // SHA-256 텍스트
    if (pathname === '/sha256') {
      const dmg = currentDmgName();
      if (!dmg) return send(res, 404, 'no release file');
      const txt = path.join(DL_DIR, dmg + '.sha256');
      try { return send(res, 200, fs.readFileSync(txt, 'utf8')); }
      catch (e) { return send(res, 404, 'sha256 not found'); }
    }

    // 릴리스 버전 JSON
    if (pathname === '/api/version') {
      const dmg = currentDmgName() || '';
      const m = dmg.match(/(\d+\.\d+\.\d+)/);
      return send(res, 200, JSON.stringify({
        app: 'VolumeMixer',
        version: m ? m[1] : null,
        file: dmg ? '/dl/' + dmg : null,
        os: 'macOS 14.4+ (Apple Silicon)',
      }, null, 2), 'application/json; charset=utf-8');
    }

    // 정적 파일 (site/)
    const p = safeJoin(SITE_DIR, pathname);
    if (!p || !fs.existsSync(p) || !fs.statSync(p).isFile()) {
      // SPA 스타일: 알 수 없는 경로는 index.html로
      const fallback = path.join(SITE_DIR, 'index.html');
      if (fs.existsSync(fallback)) return send(res, 200, fs.readFileSync(fallback), MIME['.html']);
      return send(res, 404, 'not found');
    }
    return send(res, 200, fs.readFileSync(p), MIME[path.extname(p)] || 'application/octet-stream');
  } catch (e) {
    return send(res, 500, 'internal error: ' + e.message);
  }
});

process.on('uncaughtException', e => console.error('[volumemixer-server] uncaught:', e.message));

server.listen(PORT, '127.0.0.1', () => {
  console.log('[volumemixer-server] listening on http://127.0.0.1:' + PORT + '/volumemixer');
});
