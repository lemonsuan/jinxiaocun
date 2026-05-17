class LocalDatabaseSchema {
  static const int version = 4;

  static const List<String> createStatements = [
    '''
    CREATE TABLE products (
      code TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      default_purchase_price REAL,
      default_sale_price REAL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE inbound_receipts (
      id TEXT PRIMARY KEY,
      tracking_number TEXT NOT NULL UNIQUE,
      seller_order_number TEXT,
      rebate_order_number TEXT,
      image_path TEXT,
      ocr_status TEXT NOT NULL,
      is_settled INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE inbound_items (
      id TEXT PRIMARY KEY,
      receipt_id TEXT NOT NULL,
      product_code TEXT NOT NULL,
      product_name TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      purchase_price REAL,
      sale_price REAL,
      FOREIGN KEY(receipt_id) REFERENCES inbound_receipts(id)
    )
    ''',
    '''
    CREATE TABLE outbound_orders (
      id TEXT PRIMARY KEY,
      logistics_number TEXT,
      note TEXT,
      created_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE outbound_items (
      id TEXT PRIMARY KEY,
      order_id TEXT NOT NULL,
      product_code TEXT NOT NULL,
      product_name TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      FOREIGN KEY(order_id) REFERENCES outbound_orders(id)
    )
    ''',
    '''
    CREATE TABLE outbound_attachments (
      id TEXT PRIMARY KEY,
      order_id TEXT NOT NULL,
      image_path TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY(order_id) REFERENCES outbound_orders(id)
    )
    ''',
    '''
    CREATE TABLE stock_ledger (
      id TEXT PRIMARY KEY,
      product_code TEXT NOT NULL,
      product_name TEXT NOT NULL,
      delta INTEGER NOT NULL,
      reason TEXT NOT NULL,
      source_id TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE warehouse_stock (
      product_code TEXT PRIMARY KEY,
      product_name TEXT NOT NULL,
      quantity INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE ocr_results (
      id TEXT PRIMARY KEY,
      receipt_id TEXT NOT NULL,
      raw_json TEXT NOT NULL,
      confidence REAL,
      created_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
  ];

  static const Map<int, List<String>> migrationStatements = {
    2: [
      '''
      CREATE TABLE IF NOT EXISTS outbound_attachments (
        id TEXT PRIMARY KEY,
        order_id TEXT NOT NULL,
        image_path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(order_id) REFERENCES outbound_orders(id)
      )
      ''',
    ],
    3: [
      '''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      ''',
    ],
    4: [
      '''
      ALTER TABLE inbound_receipts ADD COLUMN seller_order_number TEXT
      ''',
      '''
      ALTER TABLE inbound_receipts ADD COLUMN rebate_order_number TEXT
      ''',
      '''
      ALTER TABLE outbound_orders ADD COLUMN logistics_number TEXT
      ''',
    ],
  };
}
