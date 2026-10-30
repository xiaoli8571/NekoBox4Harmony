import { readPrefString, writePrefString } from './Store';

/**
 * 消息中心(对齐 OwnBox MessageStore.kt)。
 *
 * 纯逻辑 + 注入式存储:parse/serialize/append/unread 都可以在 Node 主机上直接测,
 * 落盘只经 Store 的 readPrefString/writePrefString,跨进程口径与其它偏好一致。
 * 上限 200 条,超出丢最旧 —— 消息中心是"最近发生了什么",不是审计日志。
 */
const KEY_MESSAGES: string = 'message_center_v1';
export const MAX_MESSAGES: number = 200;

export class AppMessage {
  id: string = '';
  kind: string = '';   // sub(订阅) / test(测速) / vpn(连接) / other
  title: string = '';
  body: string = '';
  at: number = 0;
  read: boolean = false;
}

/** 容错解析:任何脏值都当空列表,绝不抛错(消息中心不能拖垮启动) */
export function parseMessages(raw: string): Array<AppMessage> {
  const out: Array<AppMessage> = [];
  if (raw.length === 0) {
    return out;
  }
  try {
    const parsed = JSON.parse(raw) as Array<AppMessage>;
    if (parsed === null || parsed === undefined) {
      return out;
    }
    for (const item of parsed) {
      if (item === null || item === undefined) {
        continue;
      }
      const msg = new AppMessage();
      msg.id = item.id !== undefined && item.id.length > 0 ? item.id : `${item.at}`;
      msg.kind = item.kind !== undefined ? item.kind : 'other';
      msg.title = item.title !== undefined ? item.title : '';
      msg.body = item.body !== undefined ? item.body : '';
      msg.at = item.at !== undefined && item.at > 0 ? item.at : 0;
      msg.read = item.read === true;
      out.push(msg);
    }
  } catch (e) {
    return [];
  }
  return out;
}

export function serializeMessages(list: Array<AppMessage>): string {
  return JSON.stringify(list);
}

/** 新消息插到最前,并按上限裁剪(返回新数组,便于断言) */
export function appendMessage(list: Array<AppMessage>, item: AppMessage,
  max: number = MAX_MESSAGES): Array<AppMessage> {
  const out: Array<AppMessage> = [item];
  for (const old of list) {
    if (out.length >= max) {
      break;
    }
    out.push(old);
  }
  return out;
}

export function unreadOf(list: Array<AppMessage>): number {
  let n = 0;
  for (const item of list) {
    if (!item.read) {
      n++;
    }
  }
  return n;
}

function makeMessage(kind: string, title: string, body: string): AppMessage {
  const msg = new AppMessage();
  msg.kind = kind;
  msg.title = title;
  msg.body = body;
  msg.at = Date.now();
  msg.id = `${msg.at}-${Math.floor(Math.random() * 100000)}`;
  msg.read = false;
  return msg;
}

export async function addMessage(kind: string, title: string, body: string): Promise<void> {
  try {
    const raw = await readPrefString(KEY_MESSAGES, '');
    const list = appendMessage(parseMessages(raw), makeMessage(kind, title, body));
    await writePrefString(KEY_MESSAGES, serializeMessages(list));
  } catch (e) {
    // 落盘失败只丢消息,不影响主流程
  }
}

export async function listMessages(): Promise<Array<AppMessage>> {
  try {
    return parseMessages(await readPrefString(KEY_MESSAGES, ''));
  } catch (e) {
    return [];
  }
}

export async function unreadCount(): Promise<number> {
  return unreadOf(await listMessages());
}

export async function markAllRead(): Promise<void> {
  try {
    const list = await listMessages();
    for (const item of list) {
      item.read = true;
    }
    await writePrefString(KEY_MESSAGES, serializeMessages(list));
  } catch (e) {
    // ignore
  }
}

export async function clearMessages(): Promise<void> {
  try {
    await writePrefString(KEY_MESSAGES, '[]');
  } catch (e) {
    // ignore
  }
}
