# 作业报单后端

作业不设报名。拍手通过数字店铺 ID 注册后直接报单，独立于库存用户与会员；只访问本店作业及本人订单。账号支持 1～150 位非空白登录名，以兼容旧账号；密码 8～128 位，登录不会去掉密码边缘空白。

- 管理接口：`/api/jobs`、`/api/jobs/orders`、`/api/jobs/workers`，需要原管理 Bearer 及 `X-Active-Shop-ID`，并且当前角色是已批准的创建人或管理员。
- 拍手公开接口：`/api/worker/shop?shop_number=10000`、`/api/worker/register`、`/api/worker/login`。注册/登录返回 `{token,worker}`，`/api/worker/me` 返回拍手资料本体。
- 拍手订单：`/api/worker/orders`，一单 1～20 个去重快递号，完整单据保存必须带操作键；编辑带当前版本。拍手令牌不可以调用库存、店铺创建或管理端。
- 金额为两位十进制字符串。订单状态仅 `in_transit`、`arrived`、`settled`，分别为运输中、已到货、已结算。

到货动态精确匹配同店有效入库号。全部快递到货后，管理员才可按订单、作业与入库证据的当前版本确认结算。结算保留当时金额、订单、每个快递及完整商品/照片摘要证据；只记录结算，不转账，也不改库存或入库结算字段。已结算订单锁定，管理员写明原因撤销后方可编辑，历史记录仍保留。

写操作锁顺序为店铺、订单/账号、入库证据，与同步服务兼容。操作键按店铺和操作者隔离，重复请求返回现有订单，不重复记结算；换目标或内容重用键返回冲突。关闭作业保留本人旧订单，禁止新增，未结算仍可补改。

拍手启用、禁用、重置密码均增加认证版本。禁用时新登录和所有旧令牌失败；重新启用不恢复旧令牌。管理员只能管理本店拍手，不能以拍手操作接口修改管理员。Django 内部作业表只对超级用户只读开放，密码哈希不作为表单字段展示。

登录失败按连接 IP、店铺和账号限制 5 分钟内 10 次；注册按连接 IP 和店铺限制 5 分钟内 30 次。当前使用 Django 缓存，多实例部署应配置共享缓存；不信任客户端提供的代理 IP 头。成功登录清除失败计数。业务审计不会保存明文密码。

隔离检查：

```sh
python manage.py test jobs --settings=shop_sync_backend.test_settings
python manage.py test jobs --settings=shop_sync_backend.postgres_test_settings
python manage.py makemigrations --check --dry-run --settings=shop_sync_backend.test_settings
```

SQLite 共 30 个用例，其中 6 个真实行锁并发用例会跳过；PostgreSQL 执行并发结算、拍手编辑/结算竞态、重复撤销、重复建单、禁用/编辑竞态及管理员等待锁期间被撤权的验证。测试不连接开发库。

最小验收数据应由管理 API 创建作业，再通过拍手注册 API 建测试账号并报单。用正常入库同步上传这些快递后，管理订单详情返回可供确认结算的 `expected_version`、`job.version` 及 `parcels[].receipt`；不得直接伪造到货或修改库存来演示。管理详情可查询全部快递、对应入库照片及整单商品汇总，拍手结果仅含本人状态与安全的结算金额/时间摘要。
