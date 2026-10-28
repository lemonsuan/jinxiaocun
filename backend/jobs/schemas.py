"""输入只接受业务字段，所有权与店铺始终由已认证身份决定。"""
import re
from decimal import Decimal
from typing import Annotated, Literal
from uuid import UUID
from ninja import Schema
from pydantic import ConfigDict, Field, StrictBool, field_validator


class Input(Schema):
    model_config = ConfigDict(extra='forbid')

    @field_validator('operation_id', check_fields=False)
    @classmethod
    def clean_operation_id(cls, value):
        value = value.strip()
        if not value or re.search(r'[\x00-\x1f\x7f]', value):
            raise ValueError('操作标识不能为空或含控制字符')
        return value


Amount = Annotated[Decimal, Field(ge=0, max_digits=12, decimal_places=2)]
Key = Annotated[str, Field(min_length=1, max_length=100)]
Digest = Annotated[str, Field(pattern=r'^[a-f0-9]{64}$')]
Version = Annotated[int, Field(strict=True, ge=1)]


class ShopNumber(Input):
    shop_number: str

    @field_validator('shop_number', mode='before')
    @classmethod
    def valid_number(cls, value):
        text = str(value).strip()
        if not re.fullmatch(r'[1-9][0-9]{4,18}', text) or int(text) < 10000 or int(text) > 9223372036854775807:
            raise ValueError('请输入10000起的数字店铺ID')
        return text


class WorkerLogin(ShopNumber):
    username: Annotated[str, Field(min_length=1, max_length=150)]
    password: Annotated[str, Field(min_length=8, max_length=128)]

    @field_validator('username')
    @classmethod
    def clean_username(cls, value):
        value = value.strip()
        if len(value) < 1 or re.search(r'[\s\x00-\x1f\x7f]', value):
            raise ValueError('账号长度为1至150位，不能包含空白或控制字符')
        return value


class WorkerRegister(WorkerLogin):
    display_name: Annotated[str, Field(min_length=1, max_length=100)]
    phone: Annotated[str, Field(max_length=20)] = ''

    @field_validator('display_name', 'phone')
    @classmethod
    def clean_text(cls, value):
        value = value.strip()
        if re.search(r'[\x00-\x1f\x7f]', value):
            raise ValueError('资料包含不支持的控制字符')
        return value

    @field_validator('display_name')
    @classmethod
    def nonempty_name(cls, value):
        if not value:
            raise ValueError('请填写姓名或称呼')
        return value


class JobData(Input):
    title: Annotated[str, Field(min_length=1, max_length=150)]
    description: Annotated[str, Field(max_length=10000)] = ''
    cost_amount: Amount
    refund_amount: Amount
    photo_sha256s: Annotated[list[Digest], Field(max_length=10)] = []
    status: Literal['open', 'closed'] = 'open'

    @field_validator('title')
    @classmethod
    def valid_title(cls, value):
        if not value.strip():
            raise ValueError('作业名称不能为空')
        return value.strip()

    @field_validator('photo_sha256s')
    @classmethod
    def unique_photos(cls, value):
        if len(set(value)) != len(value):
            raise ValueError('作业照片不能重复')
        return value


class JobUpdate(JobData):
    expected_version: Version


class OrderData(Input):
    order_number: Key
    tracking_numbers: Annotated[list[str], Field(min_length=1, max_length=20)]
    operation_id: Key

    @field_validator('order_number', 'operation_id')
    @classmethod
    def valid_key(cls, value):
        value = value.strip()
        if not value or re.search(r'[\x00-\x1f\x7f]', value):
            raise ValueError('订单号或操作标识不能为空或含控制字符')
        return value

    @field_validator('tracking_numbers')
    @classmethod
    def clean_tracking(cls, values):
        tokens = []
        for value in values:
            for token in re.split(r'[,，;；\s]+', value.strip()):
                if not token:
                    continue
                if len(token) > 100 or re.search(r'[\x00-\x1f\x7f]', token):
                    raise ValueError('快递单号最长100位且不能包含控制字符')
                if token not in tokens:
                    tokens.append(token)
        if not 1 <= len(tokens) <= 20:
            raise ValueError('每个订单请填写1至20个不同快递单号')
        return tokens


class OrderCreate(OrderData):
    job_id: UUID


class OrderUpdate(OrderData):
    expected_version: Version


class Evidence(Input):
    tracking_number: Key
    receipt_id: UUID
    revision: Annotated[int, Field(strict=True, ge=0)]


class Settle(Input):
    expected_version: Version
    expected_job_version: Version
    operation_id: Key
    evidence: Annotated[list[Evidence], Field(min_length=1, max_length=20)]


class Reopen(Input):
    expected_version: Version
    operation_id: Key
    reason: Annotated[str, Field(min_length=1, max_length=1000)]

    @field_validator('reason')
    @classmethod
    def valid_reason(cls, value):
        if not value.strip():
            raise ValueError('请填写撤销结算原因')
        return value.strip()


class WorkerEnabled(Input):
    enabled: StrictBool
    expected_version: Version


class WorkerPassword(Input):
    new_password: Annotated[str, Field(min_length=8, max_length=128)]
    expected_version: Version
