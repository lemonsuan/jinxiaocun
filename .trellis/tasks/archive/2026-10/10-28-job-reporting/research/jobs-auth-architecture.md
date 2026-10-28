> 后续用户决定已覆盖本文的旧候选：无报名、无Enrollment；订单三态为运输中/已到货/已结算，管理员按订单确认结算。实施以final-contract.md为准。下文保留为研究与风险证据。

# 调研：作业报单的账号、权限与三端边界

- 查询：如何在现有多店铺库存系统中增加作业发布、拍手注册报名及仅本人可见的订单报单，同时让店铺管理员重置拍手密码。
- 范围：内部代码与规范；只研究，不实施。
- 日期：2026-10-28（亚洲/上海）

## 发现

### 1. 现有账号与库存权限不能直接充当拍手权限

- `backend/shops/models.py:5`：CustomUser是全局UUID用户，继承AbstractUser；手机号只是可空字符串，没有专门拍手身份、店铺绑定账号或认证版本字段。
- `backend/shops/models.py:24`：ShopMembership仅有CREATOR/ADMIN/MEMBER三种角色；APPROVED代表加入整店。
- `backend/shop_sync_backend/api.py:43`：AuthBearer解析全局JWT，取user_id，并通过任意APPROVED membership设置request.active_shop；没有拍手身份分支。
- `backend/shop_sync_backend/sync_v2.py:20`、`:131`：库存查看接口只要求active_shop，未额外区分管理员与普通成员。因此给拍手建立APPROVED MEMBER关系会获得整店库存、单据、图片和同步访问，违反“只能看自己”。
- `backend/shop_sync_backend/api.py:160`附近：现有已登录全局用户可以创建店铺。拍手若直接复用该通用令牌，还需显式阻止其进入旧账号/库存端点，不能只隐藏前端菜单。

结论：作业报名需要独立的Enrollment关系；它不等于ShopMembership，不应隐式授予库存读写权限。

### 2. 密码重置与已确认的店铺账号范围

`backend/shop_sync_backend/api.py:27`签发14天JWT，只有user_id/username/exp；`:43`认证只检查账户存在及is_active，不比较密码或认证版本。直接调用set_password不会让旧JWT失效。

现有`backend/shops/admin.py:10`只是全局CustomUserAdmin，不是面向店铺管理员的拍手密码重置流程。旧`/shops/members/update`仅管理角色/审批，没有密码接口。

若采用“拍手一个全局账号可参加多店作业”，并允许任一店铺管理员改其全局密码，管理员可接管该账号并读取别店报单。只在reset接口校验“他曾参加我店作业”不足以阻止此问题。

调研架构对比（主会话已转达用户确认：拍手按店铺注册、仅服务本店，采用方案1；其余保留为权衡记录）：

1. **按店铺绑定拍手账号**：账号只服务一个店铺，管理员只重置本店拍手。可独立WorkerAccount模型，使用Django密码哈希与独立的作业认证器/令牌用途，避免旧库存认证接受拍手令牌。这最贴近“店铺管理员能重置”，权限边界最小；代价是同一人参加其他店需切换店铺账号。
2. **全局拍手账号**：允许多店报名，但重置只能由平台级管理员完成；店铺管理员不能直接设置全局密码。需要产品接受“管理员”的平台含义。
3. **全局登录身份+各店独立作业凭据**：技术上可做，但界面和恢复流程复杂，不适合当前最小版本。

所有方案都应：密码只存哈希、不回传旧密码；重置写审计（操作者/目标店铺/目标账号/时间，不记明文新密码）；递增认证版本或撤销会话，使旧作业令牌立即失效；禁止店铺管理员重置其他店铺账号、平台管理员、店铺创建人或管理员身份。

### 3. 管理员权限可沿用，但需要对每个作业对象再做店铺约束

- `backend/shop_sync_backend/api.py:568`及`:584`的成员管理接口已用APPROVED且CREATOR/ADMIN约束操作者。
- 新建/修改作业应采用同样角色判定，并确保对象shop_id等于已授权的active_shop。
- 拍手查询订单必须始终由服务端加owner/current-worker条件；详情、更新、批量编辑、快递子记录、导出及任何图片/计数接口都不能仅凭客户端传入worker_id。
- A拍手访问B订单建议统一404，不暴露是否存在；管理员看本店某作业全部报单走独立管理接口。

### 4. 可以复用的存储、分页和客户端机制

- `backend/inventory/media.py:19`附近store_image：按店铺与SHA256存不可变图片，验证真实JPEG/PNG/WebP、15MiB及40MP上限，可复用底层字节存储。
- `backend/shop_sync_backend/sync_v2.py:73`至`:108`：当前上传/下载要求库存ShopMembership，不可让拍手直接复用该下载权限。
- 建议作业照片用JobPhoto(job, media, position)关联，只给当前有权限查看该作业的人提供`作业ID+照片ID`受保护下载。必须先验证照片确实属于目标作业，不能因为知道同店某个digest而读取无关入库图。
- `backend/shop_sync_backend/sync_v2.py:131`：列表响应已有items/total/page/page_size及最大100页大小；作业/本人订单列表可沿用这种响应形状，但所有查询先加所有权/店铺条件再分页和计数。
- `frontend/src/utils/request.ts:8`及`:18`：现有请求捕获token/activeShopId/scopeVersion，丢弃旧作用域响应。拍手端也需要账号代际标识与取消在途请求，但独立令牌不应写进店铺auth store。
- `frontend/src/components/ProtectedImage.vue:12`：鉴权blob加载、切换取消、URL.revokeObjectURL可复用模式。该组件目前硬编码库存路径/店铺store，不能原样用于拍手作业照片。
- `frontend/src/router/index.ts`和`frontend/src/store/auth.ts`默认登录进入选店/整店管理，作业拍手需要独立路由布局与身份入口，防止相互重定向或401清错另一类会话。
- `frontend/src/views/ShopLayout.vue:4`是固定w-64侧栏、`:47`固定横向header、`:64`p-8主区。拍手手机端不宜套此布局；推荐独立窄屏单栏布局，卡片作业列表、底部主要操作、订单编辑抽屉/页面、不会横向滚动的大表单。

### 5. 建议最小数据结构（尚未定稿）

- Job：UUID、shop、title、description、status、cost_amount、refund_amount、created_by、created_at/updated_at、编辑版本。金额使用Decimal的两位小数，不用float；字段究竟按每单还是作业总额，待产品明确。
- JobPhoto：job、同店PrivateMedia、position；管理员上传/关联，参与者只能读取可见作业附图。
- WorkerAccount或受约束的独立拍手身份：店铺范围（若选方案1）、登录名、密码哈希、显示名/手机号、is_active、auth_version、created_at。
- JobEnrollment：job、worker、status、joined_at；(job,worker)唯一；报名是否需要审核待确认。
- JobOrder：job/enrollment、worker、order_number、version、created_at/updated_at；订单号当字符串保留前导零。至少(job,worker,order_number)唯一，避免重复点提交产生重复报单。
- JobOrderTracking：order、tracking_number、position；一单多个快递；整单快递数组事务替换，不能半写。订单号/快递号均trim边缘空白，不转数字，不使用纯数字键盘限制字母单号。
- 管理重置审计：shop、operator、worker、时间及原因，不保存明文密码。

建议本人订单编辑提供明确保存、同单多个快递号多行粘贴/增删、批量粘贴分隔解析、保存期间防重复点击。使用版本检查：同账号多手机并发改同一单返回409，保留本机未保存输入并提示刷新，不静默覆盖。

作业成本和返款只作为资料/应返金额记录；当前请求没有授权自动转账或支付平台接入，不应自行加入实际资金支付。

## 需要用户决定的业务分歧

已确认：拍手按店铺注册，只能在本店使用；由本店管理员重置。采用独立店铺拍手身份，不给ShopMembership MEMBER，也不让通用CustomUser账号重置接口承担该职责。

尚待确认：报名即允许报单，还是管理员审核后才可报单；作业列表是全平台公开、指定店铺公开还是仅邀请链接；关闭作业后是否允许已有拍手补录/编辑；成本/返款按每个订单还是整份作业。代码无法替用户回答这些产品选择，现有通用成员审批仅可提供模式参考。

## 建议受影响文件

后端建议新建独立作业应用（models/services/api/auth/tests/migrations）并挂到Ninja API；在`shop_sync_backend/api.py`或独立认证模块复用管理员认证时保持原库存契约不变。按最终身份方案决定是否改CustomUser；尽量不让拍手身份污染现有库存JWT。

前端建议新增作业API类型、管理员作业/报单/拍手管理页、拍手auth store与请求客户端、独立手机布局和拍手注册登录/作业列表/我的报单页。`router/index.ts`、管理导航需要小范围接入；受保护照片组件应抽取可配置模式或单独创建作业照片组件。

## 必要真实验证

- 使用`backend/shop_sync_backend/test_settings.py`的隔离SQLite做行为测试，`postgres_test_settings.py`验证唯一约束/同时报名或保存，不接触当前已启动的用户开发库。
- 至少两个店铺、两个管理员、两个拍手；拍手A不能列、猜ID读、更新、搜索、统计或下载B的报单/照片；普通库存成员不能创建作业或重置密码；拍手令牌不能读原view/sync/media和修改店铺成员。
- 管理员A不能改B店作业、报名或重置B店账号；不能重置库存管理员账号；重置后旧JWT/会话立即失效，新密码可登录，明文不出现在列表/审计。
- 单订单多个快递，重复提交幂等、重复快递/空白/超长/非法金额校验；新增/修改一组tracking失败整体回滚；版本冲突保留旧数据。
- 作业照片跨作业/跨店digest不能越权；文件真实内容与大小限制；退出/切账号后blob被撤销且迟到响应拒绝。
- 浏览器在320/375/390像素视口验证报名、键盘输入、多个快递编辑、触摸按钮、加载/失败/重试、无横向滚动；桌面管理员列表分页过滤正常。现有npm test可保留会话代际单元测试，npm run build含TS检查。

## 外部参考与版本

本次未引入外部技术依赖，结论来自当前仓库；没有外部网页引用。现有requirements约束Django5.x、Django Ninja>=1.1、Pydantic>=2、PyJWT>=2.8；前端Vue3/Pinia/ElementPlus/Vite。实现应先核对实际锁定/安装版本，不以范围下限推断运行时行为。

## 相关规范

- `.trellis/spec/backend/shop-incremental-sync.md`：库存留存、私有图片、作用域和隔离测试。
- `.trellis/spec/backend/database-guidelines.md`：事务和迁移原则。
- `.trellis/spec/frontend/directory-structure.md`：Vue和Flutter边界。
- `.trellis/spec/frontend/quality-guidelines.md`：现有检查与浏览器验证约定。
- `.trellis/spec/guides/cross-layer-thinking-guide.md`：请求、权限、存储到界面的完整流。

## 限制与未发现内容

仓库未发现现成作业、拍手、报名、订单报单或密码重置API；不能将普通店铺成员审批误认为已有作业报名实现。当前Django后台的全局用户管理不等于“店铺管理员可安全重置拍手密码”。本次没有修改产品代码、用户数据库、规范或Git。


## 追加：按订单查看全部快递、到货与管理员核验

### 已确认与待确认边界

主会话已转达用户补充：管理员需要按订单快速查看对应的全部快递；拍手需要查看自己每个快递的到货与核验完成状态。主会话正在确认“同店入库记录自动匹配到货＋管理员逐快递核验”，本节是该方案的技术依据，不将尚未确认的匹配业务语义当成已定需求。

### 现有入库证据可关联，但不能开放库存权限

- `backend/inventory/models.py:33`：InboundReceipt带shop、tracking_number、image_sha256、ocr_status、is_settled及revision；`:55`确保(shop,tracking_number)唯一。
- `backend/inventory/models.py:61`：InboundItem归属receipt，保留商品编码/名称/数量与价格。
- `backend/inventory/sync_service.py:53`：每次同步变更发布新的店铺revision，适合作为“管理员核验的是哪一版证据”的快照依据。
- `backend/inventory/sync_service.py:98`：同店快递号重复入库被明确拒绝；自动到货查询必须按shop和完整规范化tracking_number精确匹配，不复用前端q的模糊搜索。
- `is_settled`在`models.py:49`含义是是否结清，不是作业核验完成；OCR confirmed也只是识别/单据状态，不能代替管理员对作业快递的核验。

建议管理端按JobOrder详情一次返回完整parcel列表，各项显示快递号、匹配到货、核验状态、入库照片及商品明细；汇总由管理员专用服务读取。拍手接口只返回自己订单下的快递号、到货/核验状态及必要时间/中文说明，不能夹带整份InboundReceipt对象、采购价、其他订单快递、库存流水或任意照片下载地址。

若采用独立WorkerAccount，应完全独立的注册/登录/令牌认证路径；拍手令牌不能被旧AuthBearer当作CustomUser接受。可使用不同用途的签名/认证器，且旧库存接口维持原有认证要求。只创建WorkerAccount而不创建CustomUser/ShopMembership，避免从现有/auth/register→shops/create获得店铺管理员能力；所有拍手新增入口只接受已配置且允许报名的本店，不接受客户端传任意role/user_id/is_staff。注册页面由店铺分享链接或店铺入口明确shop上下文。

管理员重置目标限定WorkerAccount.shop等于已批准管理店铺；不接受CustomUser或任意全局UUID作为目标类型，避免误重置已有店铺/平台管理员。auth_version在重置事务中递增，旧拍手令牌逐请求校验立即失效；同登录名可以在不同店铺各有独立账号，界面持续显示店铺名避免混淆。

### 状态与核验数据设计

建议parcel保存独立稳定UUID、order关联、tracking_number、编辑version；管理员核验记录独立保留操作人/时间/结论/当时订单号与快递号/匹配入库ID与revision，不只保存可被覆盖的verified=true。

到货状态可动态按同店精确匹配计算，或保存arrival_receipt FK及匹配时间；后者若入库记录tracking号变动仍需重新校验对应关系。核验状态至少区分待到货、已到货待核验、已核验；如允许驳回可扩展退回状态及原因。不要因为“新增入库”就自动变成“核验完成”。

编辑规则建议在最终设计中明确：

1. 修改快递号视为新parcel身份版本，旧核验归档，当前版本重新到货匹配、待核验，不能把旧verified标记带到新号码。
2. 修改订单号会改变该订单所有快递的业务归属；至少使全部当前核验失效并保留历史记录。若产品选择核验后锁定，则由管理员明确解锁后才能改，不能由前端按钮状态单独保证。
3. 增加新的快递只给新项待核验；未改变的旧项是否保留核验应按稳定UUID与订单号/快递号一致性决定。
4. 移除已核验快递应保留移除历史，不做无痕物理删除；列表/汇总仅计算当前有效项，管理员可看变更记录。
5. 入库证据的图片/商品版本在核验后有更新时，不应继续声称“当前内容已核验”。可按receipt.revision与核验快照比较，将其标记待复核；最小版本至少在核验操作时锁定并检查当前版本，避免读旧证据确认新内容。
6. 报单编辑与管理员核验采用同一行锁/版本检查，避免“核验提交”和“拍手改号”并发后旧结论落到新号码。修改与撤销核验在同事务完成。

只因拍手提交了某快递号就自动告知该号是否在本店入库，本质上允许其查询自己声明的号码存在性。严格限制在本人已保存parcel列表内计算，不提供任意号查询端点；限制批量规模并记录变更。不同拍手重复申报同一快递如何处理需在报单唯一规则中明确，管理员界面至少应能发现重复声明，避免一份凭证被重复核验。

### 新增验证要求

- 同快递号在A/B店只关联本店入库；拍手不能通过改shop/worker/order/parcel参数读取其他人状态。
- 同一订单多个快递在管理端完整展示，拍手仅看该订单自己的状态；不暴露照片、商品价格、库存JSON或未声明号码是否存在。
- 到货与已核验分开；不存在入库仍待到货，单据is_settled=true或OCR confirmed不会自动核验。
- 核验后换快递号、换订单号、移除/新增快递、入库证据变更均按最终规则处理，旧审计保留。
- 两个数据库事务同时进行“拍手编辑”和“管理员核验”只有一致结果：新号码待核验，或版本冲突拒绝其中一方；不能新号携旧核验。
- 重复快递声明、并发重复保存、分页计数/筛选的全部状态都遵守本人/本店边界。
