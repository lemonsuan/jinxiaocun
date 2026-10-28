# 数字店铺与作业报单契约

## 1. 适用范围

适用于 `shops` 数字编号和角色迁移、`jobs` 独立拍手身份、作业报单与结算，以及 Web 批量查快递。库存增量同步仍遵循 [同步契约](./shop-incremental-sync.md)。

## 2. 数据与接口签名

- `Shop.id` 保留 UUID；新增唯一 `shop_number >= 10000`。单行 `ShopNumberSequence` 加事务锁分配、不回收编号。迁移按创建时间及 UUID 稳定补号，不能重建业务外键、私有图片路径或手机库作用域。
- 管理接口使用管理 Bearer、`X-Active-Shop-ID`（内部 UUID）及已批准的 `CREATOR/ADMIN`。三种店铺角色仅 `CREATOR/ADMIN/WORKER`；旧 MEMBER 迁为独立拍手并保留旧密码哈希、用户关联和启停状态。
- 公开：`GET /api/worker/shop?shop_number=10000`；`POST /api/worker/register`、`/login`。拍手接口使用独立认证器及 WorkerAccount，不能授予库存会员权限。
- 管理：`/api/jobs`、`/api/jobs/orders`、`/api/jobs/workers`。拍手：`/api/worker/jobs`、`/api/worker/orders`。不存在报名模型或接口。
- 批量：`POST /api/view/inbound/batch`，静态路由须在入库动态详情路由之前注册。

## 3. 请求、响应与环境约定

拍手注册包含 `shop_number/username/password/display_name/phone`；登录包含前三项。编号用十进制字符串传输；数字编号仅定位店铺，不构成授权。密码保持原始空白，8～128 位；账号去掉首尾空白后 1～150 位，不含空白或控制字符。注册和登录返回 `{token,worker}`。资料更新、禁用、启用、密码重置以 `auth_version` 使旧 JWT 失效。

作业包含 `title/description/cost_amount/refund_amount/status/photo_sha256s`，金额传十进制字符串；状态 `open/closed`，最多10张同店授权图片。关闭后不接新订单，已有未结算订单仍可编辑。

订单创建：`{job_id,order_number,tracking_numbers,operation_id}`；修改追加 `expected_version`。1～20 个完整快递号，支持分隔、去重，保留字母和前导零。所有查询和修改都按当前拍手及店铺过滤，他人订单返回404。

订单仅有 `in_transit/arrived/settled`：全部有效快递匹配同店服务器有效入库才到货，部分到货仍运输中。拍手仅获自己的进度、每个快递状态及结算摘要；不返回完整入库、商品价格、入库图片或他人身份。

结算提交 `{expected_version,expected_job_version,operation_id,evidence:[{tracking_number,receipt_id,revision}]}`。事务锁顺序为店铺、当前管理员成员记录、订单或账号、证据；取店铺锁后重新验证管理员资格。结算保存当时订单、作业金额、完整商品和图片快照，不修改库存流水或入库 `is_settled`，不执行转账。撤销需订单版本、操作键和原因，保留原历史。已结算禁止拍手修改。

批量请求 `tracking_numbers` 分隔去重后最多200个，单号最多100字符；记录页最多20条、商品页最多100条，二者独立。`include_archived=false` 默认排除服务端归档；手机本地隐藏不影响查询。响应包含匹配/未匹配编号、重复数、分页记录、分页商品及整批总数。按完整编码合并商品，空白编码逐明细独立分组；全量统计不随当前页变化。

管理 Web 和 Worker 使用独立 store/client/token；异步返回先核对会话代际。图片使用鉴权 blob，切店和卸载中止请求并释放 URL。复制注册链接使用 `VITE_PUBLIC_APP_URL` 或当前 origin，格式 `/#/worker/register?shop=10000`，无管理凭据。自动带入后必须验证真实店名；剪贴板异常或1500ms未完成则显示可全选的链接。

## 4. 校验与错误矩阵

| 场景 | 结果 |
|---|---|
| 无效字段、超量快递或错误金额 | 400或422，无业务写入 |
| 管理身份访问他店、拍手访问库存 | 403或401 |
| 拍手访问他人订单或不可见作业 | 404 |
| 禁用账号登录、旧认证版本请求 | 403，前端只清拍手会话 |
| 订单、作业、证据版本冲突 | 409，刷新后确认，保留输入 |
| 同一操作键重试同一内容 | 返回原结果，不重复结算或报单 |
| 同键更换内容或目标 | 409 |
| 保存响应未知 | 保留不可变请求及操作键，先确认原结果 |

## 5. 正常、边界与错误示例

正常：拍手点店铺注册链接注册，打开作业直接报单；订单两个快递到货1/2时运输中、2/2时已到货，管理员核实图片和商品后结算。

边界：手机离线入库尚未同步，网页保持运输中；管理员修改作业金额不重写历史结算。管理员重新启用拍手后，拍手须重新登录。

错误：前端直接提交 `status=settled`、仅凭快递编号返回他店照片、重试时更换操作键、将匿名数字店铺号视作库存授权。

## 6. 必须验证

`shops/tests.py` 覆盖稳定补号、并发编号、历史成员迁移、数字与旧 UUID 接口兼容；`inventory/test_batch_view.py` 覆盖全量合计、分页、去重、空白编码及隔离；`jobs/tests.py` 覆盖两店两拍手、禁用与重置、照片授权、三态、CAS、幂等和真实 PostgreSQL 竞态。

前端 `npm test`、`npm run build`；浏览器桌面及360/390宽度验证发布图片、直接报单、多快递编辑、批量照片汇总、到货结算快照和禁用重置。手机编号改动须验证原 UUID 缓存作用域未变化。测试只用隔离库，不能用实际开发库跑破坏性测试。

## 7. 错误与正确实现对照

错误：把所有 `APPROVED` 成员视作管理员；仅请求入口鉴权；修改 Shop 主键为数字导致手机找不到旧缓存。

正确：库存与作业管理只允许 `CREATOR/ADMIN`，事务获取店铺锁后重新校验成员；数字号只供展示和输入，原 UUID 及手机存储关联不变。

错误：展示当前商品和价格冒充历史结算证据，或者一次入库就把多快递订单全部标记到货。

正确：逐个当前有效快递判断到货；历史面板从该笔 Settlement.snapshot 读取原商品、照片和金额。
