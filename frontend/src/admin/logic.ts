/**
 * 生成拍手自主注册并自动带入店铺编号的邀请链接，注册仍需设置密码。
 *
 * @param origin 当前管理后台站点访问的基础 Origin 域名（例如 http://192.168.1.100:5173）
 * @param shopNumber 目标店铺的数字编号（例如 10003）
 * @returns 完整的 Hash 路由注册链接，若店铺编号非法或协议不受支持则返回空字符串
 */
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

/** 链接只带公开店铺号和作业目标，注册或登录后仍按本人权限进入。 */
export function jobReportLink(origin: string, shopNumber: string, jobId: string): string {
  const base = registrationLink(origin, shopNumber);
  if (!base || BigInt(shopNumber) > 9223372036854775807n ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(jobId)) return '';
  const url = new URL(base);
  url.hash = `/worker/login?${new URLSearchParams({
    shop: shopNumber,
    redirect: `/worker/jobs/${jobId}`,
  })}`;
  return url.toString();
}

/**
 * 将指定文本安全写入系统剪贴板。
 *
 * 针对移动端或非受信安全上下文（非 HTTPS）下部分浏览器剪贴板权限请求无响应（挂起）的边缘情况，
 * 采用带有超时竞速（Promise.race）机制。超时后平滑返回 false，由 UI 引导用户长按手动复制。
 *
 * @param value 欲复制的目标文本
 * @param timeoutMs 超时时间，默认 1500ms
 * @returns 复制成功返回 true，被拒绝或超时返回 false
 */
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

/**
 * 统一提取 Axios 或未知错误中的用户可读友好中文提示。
 *
 * @param error 捕获到的错误对象
 * @returns 格式化后的中文错误原因字符串
 */
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
