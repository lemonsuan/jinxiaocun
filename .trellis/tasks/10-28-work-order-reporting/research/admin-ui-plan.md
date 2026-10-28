# 管理Web整合责任与手机验收

后续管理前端实施者负责现ShopSelect/ShopLayout/MemberManagement、admin auth store、根router，以及新增jobs管理API/视图、批量查单组件。当前worker_web只拥有src/worker/**和worker测试，不改上述共享文件。

worker模块会导出worker/routes.ts的workerRoutes与installWorkerGuard(router)。根routes展开workerRoutes；现管理beforeEach对/worker前缀立即next，由独立worker守卫处理，避免管理token把拍手页面重定向或清错会话。

管理端最少：

- 店铺卡片/页头显示和复制shop_number；加入输入数字，内部activeShopId仍UUID，activeShopNumber单独字段，clear/login一起清理。
- 人员管理仅管理人员（创建人/管理员）和拍手两类页签，无普通成员；仅创建人批准管理员/管理管理员，本店管理员可重置/启停拍手；禁用确认清晰，历史不删。
- “复制拍手注册链接”按钮+完整可见链接，数字shop_number参数；用VITE_PUBLIC_APP_URL或window.origin，Clipboard失败可选择手动复制。手机注册自动带ID，不露管理JWT。
- 作业列表/create/edit含照片上传、名称说明、成本返款字符串金额、开放/关闭状态，旧版本409保留编辑；作业详情按订单集中展示，每单全部快递及到货X/N、三态，搜索订单号或快递即定位。
- 管理订单详情显示所有快递对应照片/商品和整单商品汇总，未到货与重复声明清晰；全部到货才确认结算，显示金额并保存操作键+订单/作业/证据版本；已结算可明确撤销并填原因，显示历史不掩盖。
- 入库页保留常规列表，新增批量组件。多号精确查询、重复/未匹配提示、分页查图、整批汇总不随当前页变化；切店/退出取消并清理旧结果。

手机拍手无侧栏，管理布局至少在窄屏收起固定w64侧栏，页头换行，内容不过度缩窄；批量图片卡片按当前页加载。360/390实际浏览器检查，不只缩小桌面表格。保持原库存页面只读。

主会话会准备隔离浏览器API与演示店铺；不把未测新数据直接混进用户既有真实订单。后端准备完成和测试通过后，备份本机开发库再受控迁移和重启8000。5173可继续热更新；新代码不需要真实支付或物流接口。
