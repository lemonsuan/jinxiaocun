/// Internal per-workspace state. None of these tables is a backup payload.
class SyncDatabaseSchema {
  static List<String> get purgeStatements => [
        'CREATE TABLE IF NOT EXISTS sync_purged(kind TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(kind,id))',
        'CREATE TABLE IF NOT EXISTS local_purge_gc(path TEXT PRIMARY KEY)',
      ];
  static List<String> get statements => [
        ...purgeStatements,
        'CREATE TABLE IF NOT EXISTS sync_control(id INTEGER PRIMARY KEY CHECK(id=1),suppressed INTEGER NOT NULL DEFAULT 0,cursor INTEGER NOT NULL DEFAULT 0)',
        'INSERT OR IGNORE INTO sync_control(id) VALUES(1)',
        'CREATE TABLE IF NOT EXISTS sync_dirty(kind TEXT NOT NULL,id TEXT NOT NULL,generation INTEGER NOT NULL,PRIMARY KEY(kind,id))',
        'CREATE TABLE IF NOT EXISTS sync_meta(kind TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(kind,id))',
        'CREATE TABLE IF NOT EXISTS sync_outbox(operation_id TEXT PRIMARY KEY,kind TEXT NOT NULL,id TEXT NOT NULL,generation INTEGER NOT NULL,base_revision INTEGER NOT NULL,data TEXT NOT NULL,status TEXT NOT NULL DEFAULT \'pending\')',
        'CREATE TABLE IF NOT EXISTS sync_conflicts(operation_id TEXT PRIMARY KEY,kind TEXT NOT NULL,id TEXT NOT NULL,local_data TEXT NOT NULL,generation INTEGER NOT NULL DEFAULT 0,remote_record TEXT,message TEXT NOT NULL,code TEXT,resolved INTEGER NOT NULL DEFAULT 0)',
        'CREATE TABLE IF NOT EXISTS sync_abandoned(kind TEXT NOT NULL,id TEXT NOT NULL,data TEXT NOT NULL,operation_id TEXT NOT NULL,PRIMARY KEY(kind,id))',
        'CREATE TABLE IF NOT EXISTS sync_hidden(kind TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(kind,id))',
        'CREATE TABLE IF NOT EXISTS sync_media(kind TEXT NOT NULL,id TEXT NOT NULL,position INTEGER NOT NULL,sha256 TEXT NOT NULL,local_path TEXT,PRIMARY KEY(kind,id,position))',
        'CREATE TABLE IF NOT EXISTS sync_hash(path TEXT PRIMARY KEY,size INTEGER NOT NULL,modified INTEGER NOT NULL,digest TEXT NOT NULL)',
        for (final table in {
          'products': ('product', 'code'),
          'inbound_receipts': ('inbound', 'id'),
          'outbound_orders': ('outbound', 'id'),
          'inbound_items': ('inbound', 'receipt_id'),
          'outbound_items': ('outbound', 'order_id'),
          'outbound_attachments': ('outbound', 'order_id')
        }.entries)
          for (final event in ['INSERT', 'UPDATE', 'DELETE'])
            '''CREATE TRIGGER IF NOT EXISTS sync_${table.key}_${event.toLowerCase()} AFTER $event ON ${table.key}
        WHEN (SELECT suppressed FROM sync_control WHERE id=1)=0 AND NOT EXISTS(SELECT 1 FROM sync_abandoned WHERE kind='${table.value.$1}' AND id=${event == 'DELETE' ? 'OLD' : 'NEW'}.${table.value.$2}) BEGIN
        UPDATE sync_dirty SET generation=generation+1 WHERE kind='${table.value.$1}' AND id=${event == 'DELETE' ? 'OLD' : 'NEW'}.${table.value.$2};
        INSERT INTO sync_dirty(kind,id,generation) SELECT '${table.value.$1}',${event == 'DELETE' ? 'OLD' : 'NEW'}.${table.value.$2},1
        WHERE NOT EXISTS(SELECT 1 FROM sync_dirty WHERE kind='${table.value.$1}' AND id=${event == 'DELETE' ? 'OLD' : 'NEW'}.${table.value.$2}); END''',
        // Backfill legacy records once; repeated initialization does not redirty accepted data.
        for (final entry in {
          'products': ('product', 'code'),
          'inbound_receipts': ('inbound', 'id'),
          'outbound_orders': ('outbound', 'id')
        }.entries)
          "INSERT OR IGNORE INTO sync_dirty(kind,id,generation) SELECT '${entry.value.$1}',${entry.value.$2},1 FROM ${entry.key} WHERE NOT EXISTS(SELECT 1 FROM sync_abandoned WHERE kind='${entry.value.$1}' AND id=${entry.key}.${entry.value.$2}) AND NOT EXISTS(SELECT 1 FROM sync_meta WHERE kind='${entry.value.$1}' AND id=${entry.key}.${entry.value.$2})",
      ];
}
