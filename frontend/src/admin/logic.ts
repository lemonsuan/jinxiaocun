export function registrationLink(origin: string, shopNumber: string): string {
  if (!/^[1-9]\d{4,18}$/.test(shopNumber)) return '';
  try {
    const url = new URL(origin);
    if (
      !['http:', 'https:'].includes(url.protocol) ||
      url.username ||
      url.password
    )
      return '';
    url.hash = `/worker/register?shop=${encodeURIComponent(shopNumber)}`;
    url.search = '';
    return url.toString();
  } catch {
    return '';
  }
}
export async function copyVisibleText(
  value: string,
  timeoutMs = 1500,
): Promise<boolean> {
  if (!value) return false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    // 部分浏览器的权限请求可能一直挂起，超时后交给界面提示手动复制。
    const copying = navigator.clipboard.writeText(value).then(
      () => true,
      () => false,
    );
    const timeout = new Promise<false>((resolve) => {
      timer = setTimeout(() => resolve(false), timeoutMs);
    });
    return await Promise.race([copying, timeout]);
  } catch {
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
export function errorText(error: unknown): string {
  const value = error as {
    response?: { data?: { detail?: unknown; message?: unknown } };
    message?: string;
  };
  const detail = value.response?.data?.detail ?? value.response?.data?.message;
  return typeof detail === 'string'
    ? detail
    : value.message || '操作未完成，请稍后重试。';
}
