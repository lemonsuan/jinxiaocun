# 默认工作区接口约定

## 资料与持久化

数据层新增不暴露令牌的SavedWorkspace：id、isLocal、serverUrl、shopId、shopName、accountId、accountName。

LocalInventoryDatabase公开扩展接口：

- ensureDefaultWorkspace() / loadDefaultWorkspace() 返回SavedWorkspace，负责首次本地与旧配置迁移；先调用open()。
- loadSavedWorkspaces() 返回历史入口列表，包含本地入口。
- activateSavedWorkspace(String id) 返回目标SavedWorkspace；只接受本机已登记项。
- rememberAuthenticatedWorkspace({serverUrl,token,shopId,shopName,accountId='',accountName=''}) 返回已登记并激活的SavedWorkspace。Login必须先在线核实APPROVED。

目标库预检成功后，配置库事务同时写入默认项及现有兼容的模式/地址/令牌/店铺字段；失败保留旧默认与旧凭据。工作区历史资料与凭据不导出业务备份，不保存密码。

## 页面与服务

主页打开设置前await ShopSyncService.pauseAndDrain()；取消返回resume()。成功切换后替换主页，释放旧服务和监听。

LoginPage支持selectionOnly：设置中在线添加/重新认证完成只返回选择结果，由设置和旧主页协调替换，避免留下两层AppHome。取消不清除原默认。

共享店铺缓存使用不改变authMode=online。独立本地仍为offline，不创建同步服务，远程AI发送前集中拒绝。本地网络保护必须尊重已打开的不可变工作区，不能只依赖随后被其他页面改写的全局模式键。选择工作区后旧服务和旧AI请求不能借新作用域继续发送。

新增与修改的代码注释、说明及用户可见提示全部中文。

## 启动联网口径

默认项读取及入口决策不依赖HTTP。进入共享店铺主页后，原增量服务可后台尝试同步，但网络失败不得阻塞进入或强制跳登录。完全本地模式则不创建同步服务，且所有远程AI入口均零请求。

## 认证暂停

401/403暂停同一套凭据的自动同步，保留本机数据、默认项并刷新待同步计数。手动同步可重新验证同令牌（例如管理员重新批准）；新凭据或成功鉴权解除阻塞。自动跳过与手动点击同时发生时，手动请求不得被共用运行Future吞掉。
