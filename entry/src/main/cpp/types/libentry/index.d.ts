export const startCoreNative: (configPath: string, tunFd: number,
  onResult: (err: string) => void) => void;
export const stopCoreNative: (onResult: (err: string) => void) => void;
export const isCoreRunning: () => boolean;
export const testStartNative: (configPath: string, bindIfname: string,
  onResult: (err: string) => void) => void;
export const testProxyNative: (tag: string, url: string, timeoutMs: number, expectStatus: string,
  onResult: (res: string) => void) => void;
export const testStopNative: (onResult: (err: string) => void) => void;
export const testCapsNative: (onResult: (caps: string) => void) => void;
export const checkConfigNative: (configPath: string, onResult: (res: string) => void) => void;
export const validateSrsNative: (path: string, onResult: (res: string) => void) => void;
export const testStartNativeV3: (sessionId: string, configPath: string, bindIfname: string,
  onResult: (res: string) => void) => void;
export const testProxyNativeV3: (sessionId: string, tag: string, url: string,
  timeoutMs: number, expectStatus: string, onResult: (res: string) => void) => void;
export const testStopNativeV3: (sessionId: string, onResult: (res: string) => void) => void;
export const testSessionInfoNativeV3: (sessionId: string, onResult: (res: string) => void) => void;
export const testActiveSessionsNative: (onResult: (res: string) => void) => void;
