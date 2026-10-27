/// 可在本机直接进入的工作区资料，不向界面暴露认证令牌。
class SavedWorkspace {
  const SavedWorkspace({
    required this.id,
    required this.isLocal,
    required this.serverUrl,
    required this.shopId,
    required this.shopName,
    required this.accountId,
    required this.accountName,
  });

  static const localId = 'local';
  static const localShopId = '00000000-0000-0000-0000-000000000000';

  final String id;
  final bool isLocal;
  final String serverUrl;
  final String shopId;
  final String shopName;
  final String accountId;
  final String accountName;
}
