import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';

/**
 * 备份文件加密信封(PBKDF2-SHA256 派生 + AES-256-GCM)。
 *
 * 为什么必须有:导出的备份包含节点密码、UUID、私钥、Clash API 密钥、LAN 口令 ——
 * 明文 JSON 一旦落到网盘/聊天记录/剪贴板就等于全部凭据泄漏。
 *
 * 兼容口径:
 *  - 旧版(明文)备份仍是合法输入:importBackup 先看信封标记,不是信封就走原路径;
 *  - 加密只在用户显式设了口令时发生,不改变既有导出的字节形态;
 *  - **加密后立刻在本进程内解密自检**,自检不通过直接抛错、不产出文件 ——
 *    宁可导出失败,也不产出一个自己都解不开的备份。
 */
export const ENCRYPTED_FORMAT: string = 'nekobox-backup-encrypted';
export const ENCRYPTED_SCHEMA: number = 1;

const KDF_ALG: string = 'PBKDF2|SHA256';
const KDF_ITERATIONS: number = 200000;
const KEY_BYTES: number = 32;
const SALT_BYTES: number = 16;
const IV_BYTES: number = 12;
const TAG_BYTES: number = 16;
const CIPHER_ALG: string = 'AES256|GCM|NoPadding';
const GCM_PARAMS_ALG: string = 'GcmParamsSpec';
/** 口令下限:太短的口令在 PBKDF2 下也只是"看起来像加密"。 */
export const MIN_PASSWORD_LENGTH: number = 8;

/** 加密信封(落盘形态)。 */
export class EncryptedEnvelope {
  format: string = ENCRYPTED_FORMAT;
  schemaVersion: number = ENCRYPTED_SCHEMA;
  kdf: string = KDF_ALG;
  iterations: number = KDF_ITERATIONS;
  salt: string = '';
  cipher: string = CIPHER_ALG;
  iv: string = '';
  tag: string = '';
  payload: string = '';
}

function base64Of(bytes: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(bytes);
}

function bytesOfBase64(text: string): Uint8Array {
  return new util.Base64Helper().decodeSync(text);
}

function randomBytes(len: number): Uint8Array {
  const random = cryptoFramework.createRandom();
  const blob: cryptoFramework.DataBlob = random.generateRandomSync(len);
  return blob.data;
}

function utf8Of(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function textOf(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

/** 文本是否是加密信封(只看标记,不做解密)。 */
export function isEncryptedBackup(text: string): boolean {
  const trimmed: string = text.trim();
  if (trimmed.length === 0 || trimmed.charAt(0) !== '{') {
    return false;
  }
  try {
    const marker: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
    return marker['format'] === ENCRYPTED_FORMAT;
  } catch (e) {
    return false;
  }
}

async function deriveKey(password: string, salt: Uint8Array, iterations: number): Promise<cryptoFramework.SymKey> {
  const kdf = cryptoFramework.createKdf(KDF_ALG);
  const spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: password,
    salt: salt,
    iterations: iterations,
    keySize: KEY_BYTES
  };
  const secret: cryptoFramework.DataBlob = await kdf.generateSecret(spec);
  const generator = cryptoFramework.createSymKeyGenerator('AES256');
  const key: cryptoFramework.SymKey = await generator.convertKey({ data: secret.data });
  return key;
}

function gcmParams(iv: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
  const spec: cryptoFramework.GcmParamsSpec = {
    algName: GCM_PARAMS_ALG,
    iv: { data: iv },
    // 无附加认证数据:GCM 允许空 AAD(文档:传空 Uint8Array 即可)。
    aad: { data: new Uint8Array(0) },
    authTag: { data: tag }
  };
  return spec;
}

/** 用口令加密备份明文,返回信封 JSON 字符串(已自检可解密)。 */
export async function encryptBackup(plain: string, password: string): Promise<string> {
  if (!canIUse('SystemCapability.Security.CryptoFramework')) {
    // 设备没有加密框架:不静默降级成明文,直接让调用方看到"不支持"。
    throw new Error('backup_crypto_unsupported');
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    throw new Error('backup_password_too_short');
  }
  const salt: Uint8Array = randomBytes(SALT_BYTES);
  const iv: Uint8Array = randomBytes(IV_BYTES);
  const key = await deriveKey(password, salt, KDF_ITERATIONS);
  const cipher = cryptoFramework.createCipher(CIPHER_ALG);
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, gcmParams(iv, new Uint8Array(TAG_BYTES)));
  const produced: cryptoFramework.DataBlob = await cipher.doFinal({ data: utf8Of(plain) });
  const out: Uint8Array = produced.data;

  /* 不同实现版本对「tag 在密文尾部 / 在 authTag 字段」的处理不一致。
     两种可能都试一遍,只接受能真正解回原文的那一对 —— 这也是自检。 */
  const candidates: Array<Array<Uint8Array>> = [];
  if (out.length > TAG_BYTES) {
    candidates.push([out.slice(0, out.length - TAG_BYTES), out.slice(out.length - TAG_BYTES)]);
  }
  candidates.push([out, new Uint8Array(TAG_BYTES)]);

  for (const candidate of candidates) {
    const body: Uint8Array = candidate[0];
    const tag: Uint8Array = candidate[1];
    const envelope = new EncryptedEnvelope();
    envelope.salt = base64Of(salt);
    envelope.iv = base64Of(iv);
    envelope.tag = base64Of(tag);
    envelope.payload = base64Of(body);
    const text: string = JSON.stringify(envelope);
    let roundTrip: string = '';
    try {
      roundTrip = await decryptBackup(text, password);
    } catch (e) {
      continue;
    }
    if (roundTrip === plain) {
      return text;
    }
  }
  throw new Error('backup_crypto_unsupported');
}

/** 解信封,返回备份明文;口令错/文件被改由 GCM 认证失败暴露。 */
export async function decryptBackup(text: string, password: string): Promise<string> {
  if (!canIUse('SystemCapability.Security.CryptoFramework')) {
    throw new Error('backup_crypto_unsupported');
  }
  let envelope: EncryptedEnvelope;
  try {
    envelope = JSON.parse(text) as EncryptedEnvelope;
  } catch (e) {
    throw new Error('backup_invalid_json');
  }
  if (envelope.format !== ENCRYPTED_FORMAT) {
    throw new Error('backup_bad_format');
  }
  if (envelope.kdf !== KDF_ALG || envelope.cipher !== CIPHER_ALG) {
    throw new Error('backup_crypto_unsupported');
  }
  if (password.length === 0) {
    throw new Error('backup_encrypted_needs_password');
  }
  const iterations: number = Number.isFinite(envelope.iterations) && envelope.iterations > 0
    ? Math.floor(envelope.iterations) : KDF_ITERATIONS;
  let salt: Uint8Array;
  let iv: Uint8Array;
  let tag: Uint8Array;
  let body: Uint8Array;
  try {
    salt = bytesOfBase64(envelope.salt);
    iv = bytesOfBase64(envelope.iv);
    tag = bytesOfBase64(envelope.tag);
    body = bytesOfBase64(envelope.payload);
  } catch (e) {
    throw new Error('backup_bad_format');
  }
  if (salt.length === 0 || iv.length === 0 || body.length === 0) {
    throw new Error('backup_bad_format');
  }
  const key = await deriveKey(password, salt, iterations);
  const cipher = cryptoFramework.createCipher(CIPHER_ALG);
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, gcmParams(iv, tag));
  try {
    const produced: cryptoFramework.DataBlob = await cipher.doFinal({ data: body });
    return textOf(produced.data);
  } catch (e) {
    throw new Error('backup_crypto_bad_password');
  }
}
