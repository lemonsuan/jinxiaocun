# 技术设计

## 对外编号与兼容边界

Shop新增全局唯一shop_number（BigInteger，至少10000，DB唯一及下界约束）。对外界面统一称“店铺ID”，作为数字字符串展示/传输，避免JS大整数精度问题。内部既有UUID主键保留，用于现有外键、图片目录、X-Active-Shop-ID及手机server+shop工作区标识，从而无需破坏性改号。不得把新数字替换现有JSON的shop_id/id导致旧客户端另开空库。

## 分配与迁移

新增持久编号分配器（单例计数行并行锁，或等价数据库安全序列），从10000起；不能用COUNT+10000/MAX+1或进程内变量。旧店按created_at和id稳定顺序补齐，计数器推进至下一可用值。迁移分阶段加字段、补值、加非空约束，使用历史模型；已分配号永不更改或因店铺移除回收。新Shop常规创建路径统一分配，覆盖API、后台和种子测试，不只在某个页面生成。

## API

保留原创建/my-shops的id/shop_id字段，新增shop_number字符串。申请加入支持shop_number数字输入，同时兼容旧shop_id UUID；两种参数都给时拒绝含糊不一致，不可定位A却用B做授权。新拍手注册/登录使用必填shop_number解析目标店铺，绝不接受客户端指定role或任意owner。

管理Web的显示与复制均用shop_number，内部auth.activeShopId仍是原UUID。FlutterLogin新列表可显示数字ID，申请加入改为数字输入并传shop_number；_enterShop、SavedWorkspace.shopId、数据库scope及旧token继续使用原内部id。兼容旧服务器缺少新增字段时的解析，不把数字显示字段写入已有工作区主键。

## 安全与回退

数字可枚举，不保密；公开入口只返回注册所需店铺名称/编号，不能返回库存、成员或拍手订单。所有现鉴权保持。回退保留新增数字及原UUID映射，不丢弃已发给用户的数字编号。

角色追加：店铺管理客户端的数字ID加入申请为ADMIN待创建人批准；拍手通过独立数字ID注册直接进入本店作业，不使用此申请接口。旧MEMBER处理归作业账号迁移契约，数字字段不自动授予任何角色。

## 追加：可复制拍手注册链接

遵循job-reporting/research/registration-link-contract.md。在管理页生成数字shop_number的注册URL并复制，拍手打开后自动带店铺上下文并显示服务器确认的店名，不需手填；通用注册入口保留手填。链接只含公开店铺数字ID，不携带管理JWT/密码/内部UUID，图片和报单授权仍由拍手登录逐请求检查。复制不可用时有手动复制回退。
