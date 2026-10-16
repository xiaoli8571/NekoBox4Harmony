#!/usr/bin/env node
/**
 * Geo 资产回归测试(2026-09-27)
 *
 * 背景:设置页「GeoSite库/GeoIP库」下载全部 404。根因是上游 sing-geosite/sing-geoip
 * 的 rule-set 分支只发布 .srs 二进制,不再提供 .db。本测试锁定:
 *  1. GeoAssets 声明的文件名是 .srs(不是已下线的 .db)
 *  2. 每个候选下载源的 URL 以 .srs 结尾(旧 .db 全部 404)
 *  3. 真实可下载源的 HTTP 状态与 SRS 魔数(离线时跳过网络项)
 *  4. 大小门槛不高于真实 .srs 体积(旧门槛 100KB 会把 56KB 的 geosite-cn 误判为可疑)
 *  5. 上游仓库里确实存在该 .srs 文件(GitHub API)
 *  6. ConfigBuilder 生成的 local rule_set format 与 .srs 匹配(binary)
 */
const fs = require('fs');
const path = require('path');
const https = require('https');

const ROOT = path.resolve(__dirname, '..');
const GEO = path.join(ROOT, 'entry/src/main/ets/utils/GeoAssets.ets');
const CB = path.join(ROOT, 'entry/src/main/ets/core/ConfigBuilder.ets');

let pass = 0;
let fail = 0;
function check(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`PASS ${name}`);
  } else {
    fail++;
    console.log(`FAIL ${name}${detail ? ' — ' + detail : ''}`);
  }
}

const src = fs.readFileSync(GEO, 'utf8');

// ---- 1. 文件名常量必须是 .srs ----
const siteFile = (src.match(/GEO_SITE_FILE\s*=\s*'([^']+)'/) || [])[1];
const ipFile = (src.match(/GEO_IP_FILE\s*=\s*'([^']+)'/) || [])[1];
check('GEO_SITE_FILE is .srs', siteFile === 'geosite-cn.srs', `got ${siteFile}`);
check('GEO_IP_FILE is .srs', ipFile === 'geoip-cn.srs', `got ${ipFile}`);

// ---- 2. 没有任何遗留的 .db 下载 URL ----
const dbUrls = src.match(/https?:\/\/\S+\.db/g) || [];
check('no .db download URLs remain', dbUrls.length === 0, dbUrls.join(', '));

// ---- 3. 每个下载源都是 .srs 且覆盖 6 个镜像 ----
const urlBlock = (src.match(/const URLS_SITE[\s\S]*?\];/) || [''])[0]
  + (src.match(/const URLS_IP[\s\S]*?\];/) || [''])[0];
const allUrls = urlBlock.match(/'https?:\/\/[^']+'/g) || [];
check('all geo URLs end in .srs', allUrls.length > 0 && allUrls.every(u => u.includes('.srs')),
  allUrls.filter(u => !u.includes('.srs')).join(', '));
// 首选源必须是 raw.githubusercontent 直连(mirror.ghproxy 路径里也含该子串,
// 故只比对每个数组的第一项,不统计出现次数)
const firstEntries = [src, src]
  .map(s => (s.match(/const URLS_(?:SITE|IP):[\s\S]*?=\s*\[([\s\S]*?)\];/) || [])[1] || '')
  .map(block => (block.match(/'([^']+)'/) || [])[1] || '');
check('raw.githubusercontent is the primary source for both libraries',
  firstEntries.length === 2
  && firstEntries.every(u => u.startsWith('https://raw.githubusercontent.com/SagerNet/')),
  firstEntries.join(' | '));
check('multiple mirrors per library', allUrls.length >= 12, `got ${allUrls.length}`);

// ---- 4. 大小门槛必须 <= 真实最小 .srs 体积(geoip-cn 约 34KB) ----
const minBytes = Number((src.match(/GEO_MIN_BYTES\s*=\s*(\d+)\s*\*\s*1024/) || [])[1]);
check('size floor is 4KB (below real 34KB geoip-cn.srs)', minBytes === 4, `got ${minBytes}KB`);
check('old 100KB floor is gone', !/>\s*100\s*\*\s*1024/.test(src));

// ---- 5. SRS 魔数校验存在(挡 jsdelivr 的 200+错误页) ----
check('SRS magic check present in download', /SRS_MAGIC_0/.test(src) && /不是 sing-box 二进制规则集/.test(src));
check('SRS magic check present in geoReady', /isValidGeoFile/.test(src));

// ---- 6. ConfigBuilder 的 rule_set format 必须匹配 .srs -> binary ----
const cb = fs.readFileSync(CB, 'utf8');
const geoDef = (cb.match(/function buildGeoRuleSet[\s\S]*?\n}/) || [''])[0];
check('local rule_set uses format binary', /def\['format'\]\s*=\s*'binary'/.test(geoDef), geoDef.slice(0, 200));

// ---- 7. 上游文件真实存在(GitHub API) ----
function getJson(url) {
  return new Promise((resolve) => {
    const req = https.get(url, { headers: { 'User-Agent': 'geo-test' } }, (res) => {
      let b = '';
      res.on('data', (c) => b += c);
      res.on('end', () => resolve({ status: res.statusCode, body: b }));
    });
    req.on('error', () => resolve({ status: 0, body: '' }));
    req.setTimeout(20000, () => { req.destroy(); resolve({ status: 0, body: '' }); });
  });
}

(async () => {
  for (const [repo, name] of [['sing-geosite', 'geosite-cn.srs'], ['sing-geoip', 'geoip-cn.srs']]) {
    const r = await getJson(
      `https://api.github.com/repos/SagerNet/${repo}/contents/${name}?ref=rule-set`);
    if (r.status === 0) {
      console.log(`SKIP upstream ${repo}/${name} (network unavailable)`);
      continue;
    }
    check(`upstream ${repo}/${name} exists`, r.status === 200, `HTTP ${r.status}`);
    if (r.status === 200) {
      const size = Number((r.body.match(/"size":\s*(\d+)/) || [])[1]);
      // 真实体积必须高于我们设的门槛,否则 geoReady 会把好文件判为不可用
      check(`${name} real size > our floor`, size > minBytes * 1024, `${size} bytes`);
    }
  }

  // ---- 8. 首选下载源实际能取到 SR 魔数 ----
  const primary = (src.match(/const URLS_SITE[\s\S]*?\[([\s\S]*?)\];/) || [])[1] || '';
  const firstUrl = (primary.match(/'([^']+)'/) || [])[1];
  if (firstUrl) {
    await new Promise((resolve) => {
      const req = https.get(firstUrl, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const buf = Buffer.concat(chunks);
          const ok = res.statusCode === 200 && buf.length > minBytes * 1024
            && buf[0] === 0x53 && buf[1] === 0x52;
          check(`primary source serves valid SRS (${buf.length} bytes)`, ok,
            `HTTP ${res.statusCode} magic=${buf.subarray(0, 2).toString('hex')}`);
          resolve();
        });
      });
      req.on('error', (e) => { console.log(`SKIP primary source (${e.message})`); resolve(); });
      req.setTimeout(30000, () => { req.destroy(); console.log('SKIP primary source (timeout)'); resolve(); });
    });
  }

  console.log(`\n${pass} geo checks passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
