# 管理员端恢复实施

## 完成内容

- 作业列表与详情接入复制填报链接，目标是带公开店铺编号的拍手登录入口与当前作业，失败可手工全选复制；不携带管理凭据。
- 订单详情接入当前收款资料、拍手补充文字与照片；补图明确区别于各快递入库凭证。
- 已结算详情及历史快照展示当时收款资料、备注和附件，旧快照未留存时明确显示缺失，不用现资料冒充。
- 结算前确认订单、返款金额和收款人/账号，继续携带订单、作业、收款资料版本与各快递证据，不执行真实转账。
- 修正原未知结果在关抽屉/刷新时遗失操作键的问题：账号+店铺隔离的sessionStorage只保存原提交参数、目标订单与操作键，不存token/收款隐私/整份快照；先持久化再请求，结果未知保留并显示“确认上次操作结果”，不从新详情重新构造请求。后续切页/刷新仍可继续确认，明确失败后释放，存储不可用时拒绝发起新操作。
- 修正作业编辑器旧提示，不再声称拍手可查看照片；管理员仍可留档核对照片。

## 文件

修改frontend/src/admin/JobDetail.vue、JobManagement.vue、api.ts、components/JobEditor.vue、JobOrdersPanel.vue、SettlementSnapshotView.vue；新增order-attempts.ts与frontend/tests/admin_orders.test.mjs。原WIP的OrderPayoutDetails/OrderSupplementDetails/JobShareLink组件已接入。

## 验证

- `node --test tests/admin_orders.test.mjs tests/admin_clipboard.test.mjs tests/admin_batch.test.mjs tests/admin_session.test.mjs`：14项通过。
- `vue-tsc -b --pretty false`：通过。
- `git diff --check`：通过。
- 新5项逻辑测试覆盖收款版本与证据、冻结请求且不留收款隐私、跨账号跨店作用域、存储恢复及坏值、撤销原因/操作键、作业分享的公开参数与安全目标。

未操作实际用户数据库，未提交/打包或改版本。完整前端回归构建、后端联调和浏览器管理员核对结算/未知网络结果验收由root完成；本报告不将单元测试等同浏览器验收。
