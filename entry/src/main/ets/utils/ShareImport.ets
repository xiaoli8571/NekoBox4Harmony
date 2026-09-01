import common from '@ohos.app.ability.common';
import { Profile } from '../model/Profile';
import { ProfileStorage } from '../common/storage/ProfileStorage';
import { upsertSub, subNameOf } from '../core/Subscriptions';
import { fetchSubscriptionWithInfo, looksLikeClashYaml, parseClashProxies, ClashParseResult } from './Subscription';
import { parseShareText, parseSingleLink, looksLikeHttpProxyLink } from './LinkParser';
import { LogStore } from '../model/Store';

/** Result returned by the text-share importer. */
export interface ShareImportResult {
  imported: number;
  skipped: number;
  subscriptionUrl: string;
  subscriptionName: string;
}

function newProfileId(): string {
  return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

/**
 * Import one or more node links, a base64 list, or an HTTP(S) subscription.
 *
 * HTTP(S) is intentionally handled as an ambiguous input: a URL that looks
 * like a node is still downloaded first unless it carries a strong node hint;
 * a failed/empty download then falls back to the parsed HTTP proxy candidate.
 * This mirrors the main page behaviour and prevents a subscription root from
 * being silently stored as a proxy node.
 */
export async function importShareText(context: common.Context, raw: string): Promise<ShareImportResult> {
  const text = raw === undefined || raw === null ? '' : raw.trim();
  if (text.length === 0) {
    throw new Error('请先粘贴分享内容');
  }

  const firstLine = text.split(/[\r\n]+/)[0].trim();
  let parsed: Array<Profile> = [];
  let skipped = 0;
  let subUrl = '';
  let subUserinfo = '';
  const isHttpUrl = firstLine.startsWith('http://') || firstLine.startsWith('https://');
  if (isHttpUrl) {
    let nodeCandidate: Profile | null = null;
    try {
      nodeCandidate = parseSingleLink(firstLine);
    } catch (e) {
      nodeCandidate = null;
    }
    if (looksLikeHttpProxyLink(firstLine) && nodeCandidate !== null) {
      parsed = [nodeCandidate];
    } else {
      subUrl = firstLine;
      try {
        const fetched = await fetchSubscriptionWithInfo(firstLine);
        subUserinfo = fetched.userinfo;
        if (looksLikeClashYaml(fetched.content)) {
          const clash: ClashParseResult = parseClashProxies(fetched.content);
          parsed = clash.profiles;
          skipped = clash.skipped;
        } else {
          parsed = parseShareText(fetched.content);
        }
        if (parsed.length === 0 && nodeCandidate !== null) {
          parsed = [nodeCandidate];
          subUrl = '';
          subUserinfo = '';
        }
      } catch (e) {
        if (nodeCandidate === null) {
          const message = e instanceof Error ? e.message : `${e}`;
          throw new Error(message);
        }
        parsed = [nodeCandidate];
        subUrl = '';
        subUserinfo = '';
        const message = e instanceof Error ? e.message : `${e}`;
        LogStore.addLog(`[ui] 分享订阅下载失败,回退 HTTP 节点: ${message}`);
      }
    }
  } else {
    parsed = parseShareText(text);
  }
  if (parsed.length === 0) {
    throw new Error('未解析到可识别的节点');
  }

  await ProfileStorage.initialize(context);
  const profiles = await ProfileStorage.profiles();
  let imported = 0;
  for (const candidate of parsed) {
    // Avoid creating an unbounded list when a user shares the same list more
    // than once.  Existing IDs are not used for identity because subscriptions
    // regenerate IDs on update.
    const duplicate = profiles.find((existing: Profile) => existing.type === candidate.type
      && existing.server === candidate.server
      && existing.serverPort === candidate.serverPort
      && existing.uuid === candidate.uuid
      && existing.password === candidate.password);
    if (duplicate !== undefined) {
      continue;
    }
    candidate.id = newProfileId();
    candidate.subUrl = subUrl;
    candidate.updatedAt = Date.now();
    if (subUrl.length > 0) {
      candidate.groupId = `subscription:${subUrl}`;
      candidate.groupName = subNameOf(subUrl);
    }
    profiles.push(candidate);
    imported++;
  }
  if (imported > 0) {
    await ProfileStorage.saveProfiles(profiles);
  }
  if (subUrl.length > 0) {
    await upsertSub(subUrl, subUserinfo);
  }
  const result: ShareImportResult = {
    imported: imported,
    skipped: skipped + parsed.length - imported,
    subscriptionUrl: subUrl,
    subscriptionName: subUrl.length > 0 ? subNameOf(subUrl) : ''
  };
  return result;
}

