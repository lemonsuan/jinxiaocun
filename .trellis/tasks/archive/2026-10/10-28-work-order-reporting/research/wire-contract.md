# 实施共享协议（用户已批准，2026-10-28）

## 授权与三角色

店铺角色仅CREATOR/ADMIN/WORKER。原库存AuthBearer只准APPROVED CREATOR/ADMIN；拍手独立WorkerAccount，不获库存membership。按店铺注册，无报名。禁用/重置/重新启用均递增auth_version，旧JWT不复活。仅创建人批准ADMIN加入；管理员可管理本店拍手。原已批准MEMBER迁移为启用拍手，其他旧MEMBER迁移禁用，原CustomUser/历史关联保留，旧membership改WORKER。

## 数字店铺

Shop.shop_number全局唯一BigInteger，10000起。创建和my-shops响应新增shop_number十进制字符串；原id/shop_id UUID继续作为内部稳定关联、认证头和手机scope。新加入支持{shop_number}，兼容旧{shop_id}。新管理员加入为ADMIN/PENDING。独立注册/登录必填shop_number。店铺公开查询只返回名称和数字。注册链接/#/worker/register?shop=10000，自动带入且展示正确店名；通用入口可手填。分享URL支持VITE_PUBLIC_APP_URL，默认当前页面origin，不硬编码localhost；复制失败显示可手动复制的链接。

## 迁移顺序与文件责任

shops/0003数字字段和计数器（identity代理）→jobs/0001作业及WorkerAccount模型（jobs_api代理，依赖shops0003）→shops/0004旧MEMBER转Worker与角色（identity代理，依赖jobs0001）。WorkerAccount应提供shop,username,password,display_name,phone,is_active,auth_version,legacy_user(可空CustomUser FK),created_at/updated_at。密码字段存哈希，legacy复制哈希；(shop,username)唯一。identity代理拥有backend/shops/**与shop_sync_backend/api.py；jobs_api拥有backend/jobs/**与settings.py。api.py调用jobs.api.register_jobs(api,auth_bearer)挂载新路由，jobs模块不要反向import根api造成循环。两个代理直接协调具体迁移文件名，不硬猜。

## 管理API（Bearer+X-Active-Shop-ID+批准管理角色）

- GET /api/jobs：page/page_size<=100,q?,status?；POST /api/jobs：title,description,cost_amount,refund_amount,photo_sha256s[],status(open/closed)。
- GET /api/jobs/{job_id}；PATCH同路径：同业务字段+expected_version。
- POST /api/jobs/media multipart file返回{sha256,size,content_type}。GET /api/jobs/{job_id}/photos/{sha256}验证本店作业关联；复用私有字节存储。
- GET /api/jobs/orders：page/page_size,q?,job_id?,status?,worker_id?。GET /api/jobs/orders/{order_id}含整订单全部快递证据/商品汇总。
- POST /api/jobs/orders/{order_id}/settle：{expected_version,expected_job_version,operation_id,evidence:[{tracking_number,receipt_id,revision}]}。全部到货且版本匹配才可结算，保存当前作业金额/订单/证据/操作者/时间快照；重复key幂等，不重复有效结算。
- POST /api/jobs/orders/{order_id}/reopen：{expected_version,operation_id,reason}；明确撤销结算标记留审计，不操作资金。
- GET /api/jobs/workers：page/page_size,q?,enabled?。POST /api/jobs/workers/{id}/enabled：{enabled,expected_version}；POST /api/jobs/workers/{id}/password：{new_password,expected_version}。Worker管理DTO的version映射auth_version，返回信息不含密码hash/token。

## 拍手API（独立JWT/独立session store，不用库存请求client）

- GET /api/worker/shop?shop_number=10000 → {shop_number,name}，只公开注册所需字段。
- POST /api/worker/register：{shop_number,username,password,display_name,phone?}；POST /api/worker/login：{shop_number,username,password}。返回{token,worker:{id,username,display_name,shop_number,shop_name}}。密码8..128，用户名/姓名/手机号限长，禁用不能登录。
- GET /api/worker/me → 上述worker资料，逐次检查active/version。
- GET /api/worker/jobs：page/page_size,q?，仅本店开放或本人有历史订单的关闭作业；GET /api/worker/jobs/{id}。
- GET /api/worker/jobs/{id}/photos/{sha256}：只准可见作业自身的照片，不开放任意入库digest。
- GET /api/worker/orders：page/page_size,job_id?,status?,q?；GET /api/worker/orders/{id}。
- POST /api/worker/orders：{job_id,order_number,tracking_numbers[],operation_id}；PATCH /api/worker/orders/{id}：{order_number,tracking_numbers[],expected_version,operation_id}。owner和shop由认证决定，不接受伪造；至少1最多20个不同快递，单号最长100字符，保留字母/前导零。同本人作业内order_number唯一，操作键避免重试重复，版本冲突409保留表单。

所有列表形状{items,total,page,page_size}，400/401/403/404/409/422说明字段detail或message为中文。两类JWT不能互换。管理401仅清管理session，拍手401/禁用只清拍手session，切换店铺/身份代际丢弃旧响应。

## DTO与状态

金额为Decimal两位，JSON返回字符串（cost_amount/refund_amount），不使用float计算财务。

Job：{id,shop_number,title,description,status,cost_amount,refund_amount,photos:[{sha256}],version,created_at,updated_at}。管理列表可附order_count等；拍手仅本人own_order_count/can_report，不包含其他拍手数量或身份。

Order共同字段：{id,job:{id,title,status,version,cost_amount,refund_amount},order_number,version,status,parcel_count,arrived_count,parcels,settled_at,created_at,updated_at}。status严格in_transit/arrived/settled，中文运输中/已到货/已结算。

拍手parcel只含{id,tracking_number,arrived,arrived_at}，不带receipt/图片/商品价格/库存数据或他人声明。管理订单增加worker:{id,username,display_name}；管理parcel增加duplicate_claim和receipt（可空）：{receipt_id:内部UUID,document_key:client_key或UUID,revision,image_sha256,created_at,items:[{product_code,product_name,quantity,purchase_price?,sale_price?}]}；管理详情另含products整单汇总和当前settlement摘要/历史，供结算evidence使用。

到货按同shop完整号精确匹配有效InboundReceipt，部分到货仍in_transit、显示已到X/N；全部到货arrived。有效settlement优先settled且拍手不可编辑。关闭作业不准新报单，已有未结算可补改、历史可见。结算/撤销和编辑同一事务锁顺序店铺→订单→证据，核对版本防旧证据确认；不改库存、入库is_settled或同步协议。跨订单重复快递对管理员警示，不把他人资料给拍手。

## 批量查单子任务

POST /api/view/inbound/batch（必须先于动态路由注册）：{tracking_numbers:[],page:1,page_size:<=20,product_page:1,product_page_size:<=100,include_archived:false}。规范化去重后最多200号；按完整号、本店精确匹配。

响应{tracking_numbers:[],duplicate_count,unmatched_numbers:[],matched_count,documents:{items:[既有record],total,page,page_size},products:{items:[{key,product_code,product_name,quantity,receipt_count,tracking_numbers:[],name_variants:[]}],total,page,page_size},totals:{document_count,product_count,total_quantity}}。总计覆盖整批，不能只算当前页；非空编码合并，不同编码不按名称合并，空编码逐行保留。图片按当前页少量鉴权加载。不得给WORKER开放本接口。

## 结算金额展示补充

WorkerOrder已结算时提供本人安全摘要settlement:{cost_amount,refund_amount,settled_at}，字段使用结算时快照；拍手显示历史已结算金额必须优先该摘要，不能用作业之后修改的当前金额替代。管理端保留完整证据快照，拍手仍无入库证据/他人字段。
