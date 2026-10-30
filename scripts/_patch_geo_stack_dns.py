#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""2026-10-26 用户四项要求:
  1) GeoSite/GeoIP:自动代理后在后台自动更新(连接建立后异步刷新,7 天过期 + 1 小时节流)
  2) 协议栈:固定 gvisor(纯用户态 netstack,GSO 支持最好;OHOS 禁 netlink,system 栈会降级),界面去掉选项
  3) 远程 DNS:保留默认值 tcp://8.8.8.8,界面去掉输入框
  4) 直连域名 / 直连 IP:分流页已有「直连」规则,设置页去掉两个输入框(字段保留,旧备份仍可往返)
幂等:以 GeoAssets 里的 GEO_AUTO_TTL_MS 标记判断。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def path(rel):
    return os.path.join(ROOT, rel)


def rd(rel):
    with io.open(path(rel), encoding='utf-8') as f:
        return f.read()


def wr(rel, text):
    with io.open(path(rel), 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


if 'GEO_AUTO_TTL_MS' in rd('entry/src/main/ets/utils/GeoAssets.ets'):
    print('已应用过,退出(幂等)')
    sys.exit(0)

# ---------------------------------------------------------------- 1) Geo 自动更新
geo = rd('entry/src/main/ets/utils/GeoAssets.ets')
assert geo.rstrip().endswith('}'), 'GeoAssets 结尾不是 }'

geo += '''
// ---- GeoSite/GeoIP 后台自动更新(2026-10-26 用户要求:自动代理后在后台自动更新) ----
/** 库文件超过该年龄即视为过期(7 天) */
export const GEO_AUTO_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
/** 两次自动检查的最小间隔(1 小时):频繁重连时不必反复拉取 */
const GEO_CHECK_INTERVAL_MS: number = 60 * 60 * 1000;
const GEO_CHECK_STAMP = 'auto-check.stamp';

let geoAutoRunning: boolean = false;

function stampPath(context: common.Context): string {
  return `${geoDir(context)}/${GEO_CHECK_STAMP}`;
}

function lastCheckMs(context: common.Context): number {
  try {
    return fs.statSync(stampPath(context)).mtime * 1000;
  } catch (e) {
    // 从未检查过
    return 0;
  }
}

function ageMsOf(path: string): number {
  try {
    return Date.now() - fs.statSync(path).mtime * 1000;
  } catch (e) {
    // 文件缺失 = 无限期过期
    return Number.MAX_SAFE_INTEGER;
  }
}

function touchCheckStamp(context: common.Context): void {
  try {
    const f = fs.openSync(stampPath(context), fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, `${Date.now()}`);
    fs.closeSync(f.fd);
  } catch (e) {
    // 戳记写失败不影响更新本身
  }
}

/** 是否需要后台自动更新:节流通过 + 任一库缺失/过期 */
export function geoAutoUpdateDue(context: common.Context): boolean {
  if (Date.now() - lastCheckMs(context) < GEO_CHECK_INTERVAL_MS) {
    return false;
  }
  return ageMsOf(geoSitePath(context)) > GEO_AUTO_TTL_MS || ageMsOf(geoIpPath(context)) > GEO_AUTO_TTL_MS;
}

/**
 * 后台自动更新 Geo 库:连接建立后调用,不阻塞连接。
 * 返回 'updated' / ''(无需更新);下载失败时抛错由调用方记录,不打断隧道。
 */
export async function autoUpdateGeoAssets(context: common.Context): Promise<string> {
  if (geoAutoRunning) {
    return '';
  }
  if (!geoAutoUpdateDue(context)) {
    return '';
  }
  geoAutoRunning = true;
  try {
    await downloadGeoAssets(context);
    return 'updated';
  } finally {
    geoAutoRunning = false;
    touchCheckStamp(context);
  }
}
'''
wr('entry/src/main/ets/utils/GeoAssets.ets', geo)

# ---- 挂到连接建立处 ----
vpn = rd('entry/src/main/ets/vpnext/VpnExtAbility.ets')
assert "from '../utils/ErrText'" in vpn
vpn = vpn.replace("import { errText } from '../utils/ErrText';",
                  "import { errText } from '../utils/ErrText';\nimport { autoUpdateGeoAssets } from '../utils/GeoAssets';\nimport { addMessage } from '../model/MessageStore';", 1)

old_log = "    LogStore.addLog(`[vpn] 准备连接: ${node.name} (${node.server}:${node.serverPort}) [mode=${settings.mode} mtu=${settings.mtu} stack=${settings.stack} mixed=${settings.mixedPort}]`);"
new_log = """    LogStore.addLog(`[vpn] 准备连接: ${node.name} (${node.server}:${node.serverPort}) [mode=${settings.mode} mtu=${settings.mtu} stack=${TUN_STACK} mixed=${settings.mixedPort}]`);

    /* GeoSite/GeoIP 后台自动更新(2026-10-26):隧道起来后异步刷新,7 天过期 + 1 小时节流。
       不 await、失败只写日志与消息,绝不影响本次连接。 */
    autoUpdateGeoAssets(this.context).then((geoResult: string) => {
      if (geoResult === 'updated') {
        LogStore.addLog('[vpn] Geo 数据已自动更新(geosite-cn / geoip-cn),下次连接生效');
        addMessage('geo', 'Geo 数据已自动更新', 'geosite-cn / geoip-cn 已在后台刷新,下次连接生效。')
          .catch((e: Error) => LogStore.addLog(`[vpn] Geo 更新消息写入失败: ${e.message}`));
      }
    }).catch((e: Error) => {
      LogStore.addLog(`[vpn] Geo 自动更新失败(下次连接重试): ${e.message}`);
    });"""
assert old_log in vpn, '连接日志锚点不匹配'
vpn = vpn.replace(old_log, new_log, 1)
wr('entry/src/main/ets/vpnext/VpnExtAbility.ets', vpn)

# ---------------------------------------------------------------- 2) 协议栈固定 gvisor
cb = rd('entry/src/main/ets/core/ConfigBuilder.ets')
assert "tun['stack'] = s.stack;" in cb
cb = cb.replace("  tun['stack'] = s.stack;",
                """  /* 2026-10-26:协议栈固定 gvisor —— 本项目在 OHOS 上禁用了 netlink,system 栈失去内核路由支持;
     gvisor 是纯用户态 netstack,兼容性最好且 sing-tun 对其开启 GSO,综合性能最优。界面已去掉该选项。 */
  tun['stack'] = TUN_STACK;""", 1)
anchor = cb.index('\n', cb.index('export '))
cb = cb[:anchor + 1] + "\n/** 唯一可选协议栈(界面已下线选项,2026-10-26) */\nexport const TUN_STACK: string = 'gvisor';\n" + cb[anchor + 1:]
wr('entry/src/main/ets/core/ConfigBuilder.ets', cb)

schema = rd('entry/src/main/ets/model/SettingsSchema.ets')
old_def = """  out.push(def('stack', 'advanced', APPLY_RECONNECT, 'enum', '"system"',
    'settings_stack', '协议栈 栈 stack system gvisor'));"""
new_def = """  /* 2026-10-26:协议栈无 UI(固定 gvisor),字段保留以免旧备份导入报错 */
  out.push(def('stack', 'advanced', APPLY_RECONNECT, 'enum', '"gvisor"',
    'settings_stack', '协议栈 栈 stack gvisor'));"""
assert old_def in schema, 'schema stack 定义锚点不匹配'
wr('entry/src/main/ets/model/SettingsSchema.ets', schema.replace(old_def, new_def, 1))

t = rd('tests/settings-schema.cjs')
if "assert.equal(all.stack, 'system');" in t:
    wr('tests/settings-schema.cjs', t.replace("assert.equal(all.stack, 'system');",
                                              "assert.equal(all.stack, 'gvisor');", 1))

# ---------------------------------------------------------------- 3)/4) 设置页去掉三处 UI
sp = rd('entry/src/main/ets/pages/SettingsPage.ets')

stack_ui = """            Column() {
              Text($r('app.string.settings_tun_stack')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
                .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
                .value(this.s.stack)
                .onSelect((index: number) => {
                  this.s.stack = STACKS[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

"""
assert stack_ui in sp, '协议栈 UI 块锚点不匹配'
sp = sp.replace(stack_ui, '', 1)

assert "const STACKS: Array<string> = ['system'];\n" in sp
sp = sp.replace("const STACKS: Array<string> = ['system'];\n", '', 1)

dns_ui = """            Column() {
              Text($r('app.string.settings_remote_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.remoteDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.remoteDns = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_remote_dns_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

"""
assert dns_ui in sp, '远程 DNS UI 块锚点不匹配'
sp = sp.replace(dns_ui, '', 1)

direct_ui = """                Text($r('app.string.settings_direct_domain_suffix')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                TextInput({ text: this.s.directDomains, placeholder: 'baidu.com,qq.com,163.com' })
                  .width('100%').height(40)
                  .onChange((v: string) => {
                    this.s.directDomains = v;
                    this.markDirty();
                  })
                Text($r('app.string.settings_direct_cidr')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                  .margin({ top: 6 })
                TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
                  .width('100%').height(40)
                  .onChange((v: string) => {
                    this.s.directIpCidrs = v;
                    this.markDirty();
                  })
"""
assert direct_ui in sp, '直连域名/直连 IP UI 块锚点不匹配'
sp = sp.replace(direct_ui, '', 1)

wr('entry/src/main/ets/pages/SettingsPage.ets', sp)
print('四项改动完成')
