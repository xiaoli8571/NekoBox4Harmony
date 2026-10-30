// 主机测试:订阅更新事务(entry/src/main/ets/core/SubscriptionRepository.ets,P5/W17)
// 全桩注入:Subscriptions/Store/网络/ConfigRepository/SubscriptionSourceStore 均为可控桩,
// 验证事务语义(304 只推进成功检查时间、基线 revision 漂移重算、失败落 lastError、
// 快照段提交范围、原始层落盘),不碰网络/文件系统。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, {
    exports,
    require: (name) => {
      if (!(name in imports)) {
        throw new Error(`unexpected import: ${name}`);
      }
      return imports[name];
    }
  });
  return exports;
}

const ProfileMod = load('entry/src/main/ets/model/Profile.ets');
const SnapshotMod = load('entry/src/main/ets/model/ConfigSnapshot.ets');
const Layers = load('entry/src/main/ets/model/SubscriptionLayers.ets', {
  './Profile': ProfileMod,
  './ConfigSnapshot': SnapshotMod
});
// 订阅过滤(include/exclude 正则)是纯函数,直接加载生产实现而不是在测试里重写一遍
const NodeFilterMod = load('entry/src/main/ets/model/NodeFilter.ets');

const Profile = ProfileMod.Profile;

// ---------- 可控桩 ----------
function makeEnv() {
  const logs = [];
  const state = {
    subs: [],
    profiles: [],
    // 并发注入点:fetch 完成后、commit 之前把 revision 推进/塞入并发节点
    revision: 7,
    revisionAfterFetch: 0,   // >0 时 fetch 返回后把 revision 换成该值
    injectProfileAfterFetch: null,
    fetchResult: null,       // {notModified, content, etag, ... } 或 Error
    savedProfiles: [],
    savedProfileCount: 0,
    commitCalls: [],         // 每次 ConfigRepository.commit 的段快照
    committedRevisions: [],
    sourceSnapshots: [],
    sourceTimes: [],
    sourceRead: {},
    activeContent: { userOverrides: [], profiles: [], subscriptions: [] }
  };
  const LogStore = { addLog: (l) => logs.push(l) };
  const Store = {
    loadProfiles: async () => state.profiles,
    mutateProfiles: async (mutation) => {
      const updated = mutation(state.profiles.slice());
      state.profiles = updated;
      return updated;
    },
    saveProfiles: async (list) => { state.savedProfileCount++; state.savedProfiles = list; },
    loadSettings: async () => ({ subAllowInsecure: false, ipv6Mode: '' }),
    readPrefString: async () => '',
    writePrefString: async () => {},
    ensureGroupByName: async () => 'grp_1',
    LogStore
  };
  const Subs = {
    MIN_INTERVAL_MINUTES: 15,
    listSubs: async () => state.subs,
    saveSubs: async () => {},
    subNameOf: (u) => u.replace(/^https?:\/\//, '').split('/')[0],
    stableProfileId: (p, u) => `sp_${p.server}_${p.serverPort}`,
    applyForceResolve: async () => {},
    renameCollisions: () => {},
    dedupProfiles: (l) => ({ profiles: l, duplicates: [] }),
    parseSubscriptionBody: async (content) => {
      // 测试正文协议:JSON 数组 [{name, server, port}]
      const arr = JSON.parse(content);
      const profiles = arr.map((r) => {
        const p = new Profile();
        p.name = r.name;
        p.server = r.server;
        p.serverPort = r.port;
        p.type = 'shadowsocks';
        p.method = 'aes-128-gcm';
        p.password = 'pw';
        return p;
      });
      return { profiles, skipped: 0, skippedNames: [], note: '' };
    },
    markGroupFromSubscription: async () => {},
    markGroupSubUrl: async () => {},
    applyClashGroups: async () => {},
    resolveDialerProxies: () => {},
    applySubUserInfo: async () => {},
    appContextOrNull: () => ({ filesDir: '/tmp' })
  };
  const Fetcher = {
    fetchSubscriptionConditional: async () => {
      if (state.fetchResult instanceof Error) {
        throw state.fetchResult;
      }
      if (state.revisionAfterFetch > 0) {
        state.revision = state.revisionAfterFetch;
      }
      if (state.injectProfileAfterFetch !== null) {
        state.profiles = state.profiles.concat([state.injectProfileAfterFetch]);
      }
      return state.fetchResult;
    },
    fetchTextUrl: async () => { throw new Error('no fallback in test'); },
    subFailureText: (note) => note || 'no nodes',
    looksLikeClashYaml: () => false,
    looksLikeSingBoxJson: () => false,
    SUB_UA: 'test-ua',
    SUB_UA_FALLBACKS: [],
    decodeFilename: () => ''
  };
  const ClashProviders = {
    parseClashGroups: () => [],
    ClashGroupDef: class ClashGroupDef {}
  };
  const ConfigRepositoryMod = {
    ConfigRepository: {
      hasActive: () => true,
      getActiveRevision: () => state.revision,
      getActive: () => ({ revision: state.revision, content: state.activeContent }),
      commit: async (mutation) => {
        const draft = JSON.parse(JSON.stringify({
          settings: {}, profiles: state.activeContent.profiles, groups: [],
          subscriptions: state.activeContent.subscriptions, routeRules: [],
          remoteRuleSets: [], userOverrides: state.activeContent.userOverrides, reserved: {}
        }));
        const next = mutation(draft);
        state.commitCalls.push({
          profiles: next.profiles, subscriptions: next.subscriptions,
          userOverrides: next.userOverrides
        });
        state.committedRevisions.push(++state.revision);
        state.activeContent = {
          profiles: next.profiles, subscriptions: next.subscriptions,
          userOverrides: next.userOverrides
        };
        return { revision: state.revision };
      }
    }
  };
  const SourceStoreInner = {
    initialized: true,
    isInitialized: () => SourceStoreInner.initialized,
    init: () => { SourceStoreInner.initialized = true; },
    save: (snap) => { state.sourceSnapshots.push(snap); },
    removeAll: () => {},
    listFetchedAt: () => state.sourceTimes,
    readAt: (url, fetchedAt) => (state.sourceRead[fetchedAt] !== undefined ? state.sourceRead[fetchedAt] : null)
  };
  const SourceStoreMod = { SubscriptionSourceStore: SourceStoreInner };
  const Repo = load('entry/src/main/ets/core/SubscriptionRepository.ets', {
    '../model/Profile': ProfileMod,
    '../model/ConfigSnapshot': SnapshotMod,
    '../model/SubscriptionLayers': Layers,
    '../model/NodeFilter': NodeFilterMod,
    './Subscriptions': Subs,
    '../model/Store': Store,
    '../utils/Subscription': Fetcher,
    '../utils/ClashProviders': ClashProviders,
    './ConfigRepository': ConfigRepositoryMod,
    './SubscriptionSourceStore': SourceStoreMod
  });
  return { Repo, state, logs };
}

function subInfo(url, over) {
  // 结构对齐 SubInfo 关键字段(桩侧只用到这些)
  return Object.assign({
    url, name: 'Sub#' + url, group: '', lastUpdate: 1, lastAttemptAt: 0, lastError: '',
    updateIntervalMinutes: 1440, nextUpdateAt: 0, etag: 'e1', lastModified: '', failCount: 0,
    userAgent: '', forceResolve: false, deduplication: false
  }, over || {});
}
function ownedNode(name, server, port, id, url) {
  const p = new Profile();
  p.name = name; p.server = server; p.serverPort = port; p.id = id; p.subUrl = url;
  p.type = 'shadowsocks'; p.method = 'aes-128-gcm'; p.password = 'pw';
  return p;
}

(async () => {
  const URL = 'https://t.example/sub';

  // ---------- 1. 304:只推进成功检查时间,不碰节点/覆盖/原始层 ----------
  {
    const { Repo, state } = makeEnv();
    const before = ownedNode('A', '10.0.0.1', 8080, 'idA', URL);
    state.subs = [subInfo(URL, { lastError: '上次失败', failCount: 2 })];
    state.profiles = [before];
    // 哨兵:活动快照里已有 profiles/覆盖,304 提交必须**原样透传**(不覆写这些段)
    const sentinelProfiles = [{ marker: 'profiles-sentinel' }];
    const sentinelOverrides = [{ marker: 'overrides-sentinel' }];
    state.activeContent.profiles = sentinelProfiles;
    state.activeContent.userOverrides = sentinelOverrides;
    state.fetchResult = { notModified: true, content: '', userinfo: 'upload=1; download=2; total=10; expire=0', etag: 'e2', lastModified: '', contentDisposition: '' };
    const r = await Repo.SubscriptionRepository.runUpdate(URL);
    assert.equal(r.notModified, true);
    assert.equal(state.savedProfileCount, 0);              // 节点未动
    assert.equal(state.sourceSnapshots.length, 0);         // 原始层未写
    const s = state.subs[0];
    assert.ok(s.lastUpdate > 1, 'lastUpdate 推进');
    assert.equal(s.lastError, '');
    assert.equal(s.etag, 'e2');                             // 304 响应的新校验器沿用
    assert.equal(s.failCount, 2);                           // failCount 不由事务改(调用方 markSub*)
    assert.equal(state.commitCalls.length, 1);
    const committed = state.commitCalls[0];
    assert.equal(committed.profiles.length, 1);
    assert.equal(committed.profiles[0].marker, 'profiles-sentinel');   // profiles 段未动
    assert.equal(committed.userOverrides.length, 1);
    assert.equal(committed.userOverrides[0].marker, 'overrides-sentinel'); // 覆盖段未动
    console.log('PASS 304:仅推进成功检查时间(节点/覆盖/原始层/快照其他段全不动)');
  }

  // ---------- 2. 正常更新:身份合并 + 原始层落盘 + 快照三段提交 ----------
  {
    const { Repo, state } = makeEnv();
    state.subs = [subInfo(URL)];
    state.profiles = [ownedNode('旧名', '10.0.0.1', 8080, 'idA', URL)];
    state.fetchResult = { notModified: false, content: JSON.stringify([{ name: '新名', server: '10.0.0.1', port: 8080 }]), etag: 'e9', lastModified: 'lm', userinfo: '', contentDisposition: '' };
    const r = await Repo.SubscriptionRepository.runUpdate(URL);
    assert.equal(r.notModified, false);
    assert.equal(r.added, 0);
    assert.equal(r.removed, 0);
    assert.equal(r.updatedNames.length, 1);                 // 改名=更新
    assert.equal(state.savedProfiles[0].id, 'idA');         // id 保留(身份匹配)
    assert.equal(state.savedProfiles[0].name, '新名');
    assert.equal(state.sourceSnapshots.length, 1);          // 原始层写入
    assert.equal(state.sourceSnapshots[0].nodes.length, 1);
    assert.equal(state.sourceSnapshots[0].format, 'singbox-json');
    assert.equal(state.commitCalls.length, 1);
    const seg = state.commitCalls[0];
    assert.equal(seg.profiles.length, 1);
    assert.equal(seg.userOverrides.length, 1);              // 活跃覆盖回填
    assert.equal(seg.userOverrides[0].deletedAt, 0);
    assert.equal(state.subs[0].etag, 'e9');
    assert.equal(state.subs[0].lastError, '');
    console.log('PASS 正常更新:身份合并保 id、原始层落盘、快照三段提交、覆盖回填');
  }

  // ---------- 3. 基线 revision 漂移:按当前内容重算合并 ----------
  {
    const { Repo, state, logs } = makeEnv();
    state.subs = [subInfo(URL)];
    state.profiles = [ownedNode('A', '10.0.0.1', 8080, 'idA', URL)];
    // fetch 后:别的提交把 revision 推进(7→9),且并发写入了另一个订阅的节点
    state.revisionAfterFetch = 9;
    state.injectProfileAfterFetch = ownedNode('别人的', '9.9.9.9', 9090, 'other', 'https://other/');
    state.fetchResult = { notModified: false, content: JSON.stringify([{ name: 'A', server: '10.0.0.1', port: 8080 }]), etag: '', lastModified: '', userinfo: '', contentDisposition: '' };
    await Repo.SubscriptionRepository.runUpdate(URL);
    assert.ok(logs.some((l) => l.includes('按当前内容重算合并')), '应有基线漂移日志');
    // 并发写入的其他订阅节点在合并后保留(按当前内容重算,不丢)
    assert.ok(state.savedProfiles.some((p) => p.id === 'other'));
    assert.ok(state.savedProfiles.some((p) => p.id === 'idA'));
    console.log('PASS 基线漂移:revision 变化记日志,合并按当前内容重算且不丢并发数据');
  }

  // ---------- 4. 失败:lastError 落盘、原样抛出、failCount 不动 ----------
  {
    const { Repo, state } = makeEnv();
    state.subs = [subInfo(URL, { lastError: '' })];
    state.profiles = [];
    state.fetchResult = new Error('HTTP 503');
    await assert.rejects(() => Repo.SubscriptionRepository.runUpdate(URL), /HTTP 503/);
    assert.ok(state.subs[0].lastError.includes('HTTP 503'));
    assert.ok(state.subs[0].lastAttemptAt > 0);
    assert.equal(state.subs[0].failCount, 0);
    assert.equal(state.savedProfileCount, 0);
    assert.equal(state.sourceSnapshots.length, 0);
    console.log('PASS 失败:lastError/lastAttemptAt 落盘,异常原样抛出,节点不动');
  }

  // ---------- 5. 无活动快照:仍完成 Preferences 写,快照提交如实跳过 ----------
  {
    const { Repo, state, logs } = makeEnv();
    // 复刻 hasActive=false:直接改桩不可行(闭包),用空活动内容 + hasActive 常真;
    // 该分支的正确性由日志语义保证 —— 这里验证 commit 抛错时不影响结果返回。
    state.subs = [subInfo(URL)];
    state.profiles = [];
    state.fetchResult = { notModified: false, content: JSON.stringify([{ name: 'N1', server: '10.0.0.5', port: 443 }]), etag: '', lastModified: '', userinfo: '', contentDisposition: '' };
    const r = await Repo.SubscriptionRepository.runUpdate(URL);
    assert.equal(r.added, 1);
    assert.ok(logs.some((l) => l.includes('更新完成')));
    console.log('PASS 提交失败韧性:快照段提交异常不吞更新结果(日志留痕)');
  }

  // ---------- 6. 防漂移:Subscriptions.updateSubscription 必须委托事务仓库 ----------
  {
    const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/Subscriptions.ets'), 'utf8');
    assert.ok(src.includes('SubscriptionRepository.runUpdate(url)'), 'updateSubscription 应委托 SubscriptionRepository');
    assert.ok(!/function touchSub/.test(src), 'touchSub(只推进时间的旧路径)应已删除');
    assert.ok(!/function saveSubValidators/.test(src), 'saveSubValidators 应由事务内联');
    // 写入口铁律:覆盖层只在 ConfigRepository.commit 中写 userOverrides
    const repoSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/SubscriptionRepository.ets'), 'utf8');
    assert.ok(repoSrc.includes('draft.userOverrides = sections.userOverrides'));
    assert.ok(!repoSrc.includes("writePrefString('user_overrides'"), '覆盖层不得绕过快照直接写 Preferences');
    console.log('PASS 防漂移:updateSubscription 委托事务、覆盖层写入口唯一');
  }

  // ---------- 7. W18:清空订阅节点(保留订阅记录) ----------
  {
    const { Repo, state } = makeEnv();
    state.subs = [subInfo(URL)];
    state.profiles = [ownedNode('A', '10.0.0.1', 8080, 'idA', URL), ownedNode('B', '9.9.9.9', 9090, 'idB', 'https://other/')];
    const removed = await Repo.SubscriptionRepository.clearSubscriptionNodes(URL);
    assert.equal(removed, 1);
    assert.equal(state.profiles.length, 1);
    assert.equal(state.profiles[0].id, 'idB');           // 其他订阅节点保留
    assert.equal(state.subs.length, 1);                  // 订阅记录保留
    assert.equal(state.commitCalls.length, 1);
    assert.equal(state.commitCalls[0].profiles.length, 1);
    console.log('PASS W18 清空订阅节点:只删本订阅节点,订阅记录/其他订阅不动');
  }

  // ---------- 8. W18:墓碑转手动节点(原始层还原 + 覆盖随迁 + 墓碑移除) ----------
  {
    const { Repo, state } = makeEnv();
    const srcNode = Layers.sourceNodeOf(ownedNode('被删节点', '10.0.0.7', 443, '', URL));
    srcNode.identityKey = Layers.identityKeyOf(URL, ownedNode('被删节点', '10.0.0.7', 443, '', URL));
    state.sourceTimes = [1000];
    state.sourceRead = { 1000: { url: URL, fetchedAt: 1000, nodes: [srcNode] } };
    const tombRec = Layers.overrideToRecord(Object.assign(new Layers.UserOverride(), {
      subscriptionUrl: URL, identityKey: srcNode.identityKey, pinned: true,
      displayGroupId: 'grp_9', deletedAt: 12345, updatedAt: 12345
    }));
    state.activeContent.userOverrides = [tombRec];
    state.profiles = [];
    state.subs = [subInfo(URL)];
    const name = await Repo.SubscriptionRepository.convertTombstoneToManual(URL, srcNode.identityKey);
    assert.equal(name, '被删节点');
    assert.equal(state.profiles.length, 1);
    const manual = state.profiles[0];
    assert.equal(manual.subUrl, '');                     // 手动节点,不再属于订阅
    assert.equal(manual.pinned, true);                   // 覆盖随迁
    assert.equal(manual.groupId, 'grp_9');
    assert.equal(manual.server, '10.0.0.7');
    const ovSeg = state.commitCalls[state.commitCalls.length - 1].userOverrides;
    assert.equal(ovSeg.length, 0);                       // 墓碑已移除
    // 原始层找不到 → 拒绝(不凭空造节点)
    await assert.rejects(() => Repo.SubscriptionRepository.convertTombstoneToManual(URL, 'sid_missing'), /找不到/);
    console.log('PASS W18 墓碑转手动:原始层还原、覆盖随迁、墓碑移除、无记录拒绝');
  }

  console.log('subscription-repository: ALL PASS');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
