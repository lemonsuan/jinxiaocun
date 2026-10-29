# 最终实施接口与数据契约

## 身份与兼容
原管理Bearer+X-Active-Shop-ID、WorkerBearer与scope代际不变。订单仍in_transit/arrived/settled。字段新增为兼容扩展，不修改旧记录主键、库存或同步语义。所有变更锁序先店铺，再live_worker/管理员成员复验，再订单/资料；中文注释。

## 收款资料
GET /api/worker/payout 返回 {wechat,alipay_phone,alipay_name,qr_sha256,version,updated_at}；缺省空字符串/null，version=0。
PATCH同路由提交同业务字段+expected_version(>=0)+operation_id；微信<=80、手机号<=20、姓名<=100，允许空值，不把资料不全作为阻断报单的新门槛。手机号存字符串，非空时做温和格式校验（数字、+、空格、连字符），错误中文。二维码需来自本人purpose=payout上传。保存CAS；同一操作键重试同内容应幂等，换内容409，可用资料行保存最后操作键/hash避免泛化框架。资料版本独立于认证auth_version，编辑不退出登录。

## 拍手私有上传
POST /api/worker/media multipart {file,purpose:order|payout}，返回 {sha256,name,size,content_type}。同店现PrivateMedia储存+新增本人上传所有权/用途记录。限JPEG/PNG/WebP，15MiB/张；输入流有界读取并沿用真实图片校验，文件名只作安全显示。可提供GET /api/worker/media/{sha256}用于本人资料预览/授权校验，但UI不建图库；必须校验本人上传权限，不能仅凭摘要读别人的照片。管理员继续用已有同店鉴权ProtectedImage取私有图。

## 订单补充资料
新建和编辑增加 note(<=2000)、photo_sha256s(最多10，去重)。新增默认空，PATCH旧客户端省略时保留现有资料，显式空值才清空。关联需本人purpose=order上传，同店不等于同人。未结算可改，已结算锁定；同请求操作键/订单版本保护含新增字段。
WorkerOrder DTO增加 note:string、photos:[{sha256,name}]；AdminOrder detail同样增加。只返回本人补图元数据，不把入库图、商品或他人资料返回拍手。管理员查看补充图与入库图分清来源。结算snapshot保存note/photos与收款信息，不能随之后修改重写历史。

## 统计
GET /api/worker/orders/summary（在动态/{order_id}之前）返回 {in_transit,arrived,total}，只本人本店全量，独立于列表分页；arrived显示“已签收待返款”，partial仍in_transit，total含settled。不得用当前页20条统计。

## 管理员收款核对
GET /api/jobs/orders/{id} detail新增 payout:{wechat,alipay_phone,alipay_name,qr_sha256,version,updated_at}（旧历史未留存时可为null）、payout_is_snapshot:boolean。未结算用最新资料，已有有效结算时读取snapshot.payout；旧历史缺资料显示无留存而非用新资料冒充。Settlement.snapshot新增payout、note、photo_sha256s/附件元数据，保留旧字段。
POST settle新增 expected_payout_version:>=0，新UI必须提交；兼容旧无资料version0请求可省略，已有资料version>0却省略或不一致返回409刷新核对，不能静默使用变更后收款信息结算。店铺锁串行资料变更/结算，幂等重试先返回原结果。已返款快照的图片保持留存，不随个人资料替换而删除。

## 前端与职责
拍手主页面三Tab。Job页姓名/详情条/订单展开列表+固定填报；详情90vw/90dvh居中。填报弹窗note/多行tracking/附件数量及上传状态、收款按钮；可打开第二层资料弹窗但保留父输入，付款提示文案按PRD。资料同我的共用组件。草稿按店号+workerid+job/order隔离，不存token/密码，退出清理；未知结果保留不可变body/key，提交成功才清理。拍手无作业照片/入库凭证/商品清单。旧独立订单路由保留兼容，最终以同样弹窗界面承接，不再暴露另一套复杂编辑器。
管理员保留原核对/结算安全边界，补清楚收款资料/补图，优先简化常用查询和返回列表；不要新建复杂统计驾驶舱。

## 验证
两店两拍手上传/资料隔离、15MiB/坏图/数量、PATCH省略兼容、summary全量、profile CAS/offline重试、profile变更和结算竞态/快照/旧历史兼容；前端scope/草稿/路由/模态及请求key，浏览器含手机窄屏/键盘/上传失败。默认测试只隔离库。
