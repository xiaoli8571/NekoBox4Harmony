export const startCoreNative: (configPath: string, tunFd: number,
  onResult: (err: string) => void) => void;
export const stopCoreNative: (onResult: (err: string) => void) => void;
export const isCoreRunning: () => boolean;
export const testStartNative: (configPath: string,
  onResult: (err: string) => void) => void;
export const testProxyNative: (tag: string, url: string, timeoutMs: number,
  onResult: (res: string) => void) => void;
export const testStopNative: (onResult: (err: string) => void) => void;
