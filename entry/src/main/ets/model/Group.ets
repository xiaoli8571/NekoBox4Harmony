/** 统一节点分组模型。订阅天然对应一个分组，手动节点归入本地分组。 */
export class ProfileGroup {
  id: string = '';
  name: string = '';
  subscriptionUrl: string = '';
  sortOrder: number = 0;
  expanded: boolean = true;
  createdAt: number = 0;
  updatedAt: number = 0;
}

export const LOCAL_GROUP_ID: string = 'local';

export function subscriptionGroupId(url: string): string {
  let hash = 2166136261;
  for (let i = 0; i < url.length; i++) {
    hash ^= url.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `subscription_${(hash >>> 0).toString(16)}`;
}
