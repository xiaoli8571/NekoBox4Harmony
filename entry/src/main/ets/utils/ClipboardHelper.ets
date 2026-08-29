import pasteboard from '@ohos.pasteboard';

/**
 * 健壮地读取剪贴板文本:
 *  1) getPrimaryText(纯文本记录)
 *  2) 逐条记录 convertToText(兼容 URI/HTML 等记录类型)
 * 取不到返回空串,由调用方提示。
 */
export async function getClipboardText(): Promise<string> {
  let data: pasteboard.PasteData;
  try {
    data = await pasteboard.getSystemPasteboard().getData();
  } catch (e) {
    return '';
  }
  if (data === undefined || data === null) {
    return '';
  }
  const primary: string = data.getPrimaryText();
  if (primary !== undefined && primary !== null && primary.trim().length > 0) {
    return primary;
  }
  const count: number = data.getRecordCount();
  for (let i = 0; i < count; i++) {
    const rec = data.getRecord(i);
    if (rec === undefined || rec === null) {
      continue;
    }
    try {
      const t: string = await rec.convertToText();
      if (t !== undefined && t !== null && t.trim().length > 0) {
        return t;
      }
    } catch (e) {
      // 尝试下一条记录
    }
  }
  return '';
}
