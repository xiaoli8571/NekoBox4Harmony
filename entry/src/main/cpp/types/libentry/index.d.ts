export const startCoreNative: (configPath: string, tunFd: number,
  onResult: (err: string) => void) => void;
export const stopCoreNative: (onResult: (err: string) => void) => void;
export const isCoreRunning: () => boolean;
