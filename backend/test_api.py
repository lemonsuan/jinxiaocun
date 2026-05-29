import urllib.request
import urllib.parse
import json
import uuid
import datetime

BASE_URL = "http://127.0.0.1:8000/api"

def make_request(url, method="GET", data=None, headers=None):
    if headers is None:
        headers = {}
    
    req_data = None
    if data is not None:
        req_data = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
        
    req = urllib.request.Request(url, data=req_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as response:
            res_body = response.read().decode("utf-8")
            return response.status, json.loads(res_body) if res_body else {}
    except urllib.error.HTTPError as e:
        res_body = e.read().decode("utf-8")
        return e.code, json.loads(res_body) if res_body else {"message": e.reason}

def run_tests():
    print("=== 开始后台 API 自动化冒烟测试 ===")
    
    # 1. 注册一个测试账户
    username = f"test_user_{uuid.uuid4().hex[:6]}"
    print(f"\n1. 注册新用户: {username}")
    status, auth_data = make_request(f"{BASE_URL}/auth/register", method="POST", data={
        "username": username,
        "password": "securepassword123",
        "email": "test@example.com"
    })
    assert status == 200, f"注册失败: {auth_data}"
    token = auth_data["token"]
    print("注册成功！")

    # 2. 创建新店铺
    print("\n2. 创建新店铺...")
    headers = {
        "Authorization": f"Bearer {token}"
    }
    status, shop_data = make_request(f"{BASE_URL}/shops/create", method="POST", data={
        "name": "极速酷跑滑板店"
    }, headers=headers)
    assert status == 200, f"店铺创建失败: {shop_data}"
    shop_id = shop_data["id"]
    print(f"店铺创建成功！店铺ID: {shop_id}")

    # 3. 携带 X-Active-Shop-ID 推送增量数据 (Push)
    print("\n3. 测试增量数据上报 (Push)...")
    headers["X-Active-Shop-ID"] = shop_id
    
    prod_uuid = str(uuid.uuid4())
    inbound_uuid = str(uuid.uuid4())
    
    push_payload = {
        "products": [
            {
                "id": prod_uuid,
                "code": "SKATE-BOARD-001",
                "name": "专业双翘木滑板",
                "default_purchase_price": 120.00,
                "default_sale_price": 299.00,
                "is_deleted": False,
                "updated_at": datetime.datetime.utcnow().isoformat() + "Z"
            }
        ],
        "inbound_receipts": [
            {
                "id": inbound_uuid,
                "tracking_number": "YT998822114400",
                "ocr_status": "confirmed",
                "is_settled": False,
                "created_at": datetime.datetime.utcnow().isoformat() + "Z",
                "is_deleted": False,
                "updated_at": datetime.datetime.utcnow().isoformat() + "Z"
            }
        ]
    }
    status, push_res = make_request(f"{BASE_URL}/sync/push", method="POST", data=push_payload, headers=headers)
    assert status == 200, f"数据上报失败: {push_res}"
    print("数据上报 (Push) 成功！")

    # 4. 测试增量数据拉取 (Pull)
    print("\n4. 测试增量数据拉取 (Pull)...")
    yesterday = (datetime.datetime.utcnow() - datetime.timedelta(days=1)).isoformat() + "Z"
    # urlencode params
    params = urllib.parse.urlencode({"last_sync_time": yesterday})
    status, pull_data = make_request(f"{BASE_URL}/sync/pull?{params}", headers=headers)
    assert status == 200, f"数据拉取失败: {pull_data}"
    
    assert len(pull_data["products"]) > 0, "拉取的商品数据不能为空"
    assert pull_data["products"][0]["id"] == prod_uuid, "拉取的商品UUID不匹配"
    assert pull_data["products"][0]["code"] == "SKATE-BOARD-001", "商品编码不匹配"
    print("数据拉取 (Pull) 成功，拉取到的商品:", pull_data["products"][0]["name"])

    # 5. 跨店铺隔离越权自测
    print("\n5. 测试多租户店铺越权隔离拦截...")
    username2 = f"test_user_{uuid.uuid4().hex[:6]}"
    status, auth_data2 = make_request(f"{BASE_URL}/auth/register", method="POST", data={
        "username": username2,
        "password": "password123"
    })
    token2 = auth_data2["token"]
    
    headers2 = {
        "Authorization": f"Bearer {token2}",
        "X-Active-Shop-ID": shop_id
    }
    status_malicious, pull_res2 = make_request(f"{BASE_URL}/sync/pull?{params}", headers=headers2)
    assert status_malicious == 403, f"越权拦截失败，竟然返回了状态码: {status_malicious}"
    print("多租户越权隔离拦截成功！返回状态码 403 Forbidden")

    print("\n=== 所有 API 接口自动化集成测试 100% 成功通过！ ===")

if __name__ == '__main__':
    run_tests()
