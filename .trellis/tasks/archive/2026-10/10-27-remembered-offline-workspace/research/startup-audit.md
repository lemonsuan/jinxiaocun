# 启动与切换现状

- main.dart启动不发HTTP，按activeShopId直接进AppHome；首次创建本地默认店铺。需求中的“下次不用选择”已有基础，应补一致性而非重复启动系统。
- LoginPage._enterShop每次_fetchShops复查审批，随后逐项saveAuthMode/server/token/shop/name；历史入口与原子选择缺失。
- AppHome设置切换先clearAuthCredentials，不保留可直接离线返回的入口；现有退出文案与目标不符。
- 数据层_inventory_scope按规范化server加shop构成不可变工作区，独立本地固定offline；不能因断网把共享shop写成offline。
- ShopSyncService已注入HTTP、15秒前台重试、401/403保留本机资料和迟到scope拦截，可复用暂停/排空逻辑。
- AiInboundExtractor为远程HTTP服务，纯本地模式仍有UI调用入口；需明确阻止网络且不改端侧Paddle OCR。
- 当前代码已有部分英文注释；按用户新要求本轮新增/修改注释说明均中文，不在本任务批量翻译无关代码。
- 当前聊天和上轮已归档任务已完整提供历史决策，不另挖会话索引，符合session-insight的“已有即时上下文则不检索”规则。
